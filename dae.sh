#!/usr/bin/env bash
# dae.sh — Distill-Act-Evaluate loop controller
#
# Usage:
#   bash dae.sh "<task>" "<agent-config.json>" [KEY=VALUE ...]
#   bash dae.sh --async "<task>" "<agent-config.json>" [KEY=VALUE ...]
#
# Environment overrides (KEY=VALUE):
#   MAX_ITERATIONS=8     Max loop iterations (default: 8)
#   RUN_ID=<auto>        Shared across sibling loops
#   LOOP_ID=<auto>       Unique to this loop
#   PARENT_BRANCH=<auto> Git branch to fork from (default: current HEAD)
#
# Exit codes:
#   0 — done (evaluator returned done)
#   1 — stuck (evaluator returned stuck or no progress 2+ iterations)
#   2 — max iterations reached
#   3 — fatal error

set -euo pipefail

# --- Fatal error trap ---
cleanup_on_error() {
  local exit_code=$?
  if [ -n "${WORKTREE_DIR:-}" ] && [ -d "${WORKTREE_DIR:-}" ]; then
    local status_file="$WORKTREE_DIR/.dae-status.json"
    cat > "$status_file" 2>/dev/null <<STATUSEOF
{"loop_id":"${LOOP_ID:-unknown}","run_id":"${RUN_ID:-unknown}","status":"fatal","iteration":${ITER:-0},"max_iterations":${MAX_ITERATIONS:-8},"error":"Script exited with code $exit_code"}
STATUSEOF
    cd /
    git -C "$WORKTREE_DIR" add -A 2>/dev/null || true
    git -C "$WORKTREE_DIR" commit -m "dae: fatal error at iteration ${ITER:-0}" 2>/dev/null || true
  fi
  exit 3
}
trap cleanup_on_error ERR

# --- Parse arguments ---
ASYNC=false
if [ "${1:-}" = "--async" ]; then
  ASYNC=true
  shift
fi

if [ $# -lt 2 ]; then
  echo "Usage: bash dae.sh [--async] \"<task>\" \"<agent-config.json>\" [KEY=VALUE ...]" >&2
  exit 3
fi

TASK="$1"
ACT_CONFIG="$2"
shift 2

if [ ! -f "$ACT_CONFIG" ]; then
  echo "FATAL: Agent config not found at $ACT_CONFIG" >&2
  exit 3
fi

# --- Export per-invocation KEY=VALUE args ---
for arg in "$@"; do
  if [[ "$arg" == *=* ]]; then
    export "${arg?}"
  else
    echo "WARNING: Ignoring non-KEY=VALUE arg: $arg" >&2
  fi
done

# --- Generate IDs ---
if [ -z "${RUN_ID:-}" ]; then
  RUN_ID="$(date +%s | tail -c 9)"
fi
export RUN_ID

if [ -z "${LOOP_ID:-}" ]; then
  # Use /dev/urandom with xxd, fallback to $RANDOM for MINGW/Windows
  if command -v xxd >/dev/null 2>&1 && [ -r /dev/urandom ]; then
    LOOP_ID="dae-$(head -c 4 /dev/urandom | xxd -p)"
  else
    LOOP_ID="dae-${RANDOM}${RANDOM}"
  fi
fi
export LOOP_ID

# --- Resolve paths ---
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  RLM_ROOT="$CLAUDE_PLUGIN_ROOT"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  RLM_ROOT="$SCRIPT_DIR"
fi
export RLM_ROOT

LAUNCHER="$RLM_ROOT/launch.sh"
DISTILLER_CONFIG="$RLM_ROOT/internal/dae-distiller.json"
EVALUATOR_CONFIG="$RLM_ROOT/internal/dae-evaluator.json"

for required_file in "$LAUNCHER" "$DISTILLER_CONFIG" "$EVALUATOR_CONFIG" "$ACT_CONFIG"; do
  if [ ! -f "$required_file" ]; then
    echo "FATAL: Required file not found: $required_file" >&2
    exit 3
  fi
done

# --- Defaults ---
MAX_ITERATIONS="${MAX_ITERATIONS:-8}"

# --- Resolve session history directory ---
PROJECT_DIR="$HOME/.claude/projects"
CWD_SLUG=$(pwd | sed 's|/|--|g' | sed 's|^-*||')
DAE_SESSION_DIR="$PROJECT_DIR/$CWD_SLUG"
export DAE_SESSION_DIR

# --- Create git worktree ---
PARENT_BRANCH="${PARENT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
BRANCH="dae/$RUN_ID/$LOOP_ID"
WORKTREE_DIR="/tmp/dae-$RUN_ID-$LOOP_ID"

if [ -d "$WORKTREE_DIR" ]; then
  echo "WARNING: Worktree dir already exists, removing: $WORKTREE_DIR" >&2
  git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR"
fi

git worktree add "$WORKTREE_DIR" -b "$BRANCH" "$PARENT_BRANCH"

# --- Setup worktree ---
# Append to .gitignore (avoid duplicates)
GITIGNORE_FILE="$WORKTREE_DIR/.gitignore"
for entry in "inbox/" "outbox/" ".dae-*"; do
  if [ ! -f "$GITIGNORE_FILE" ] || ! grep -qxF "$entry" "$GITIGNORE_FILE"; then
    echo "$entry" >> "$GITIGNORE_FILE"
  fi
done

mkdir -p "$WORKTREE_DIR/inbox" "$WORKTREE_DIR/outbox"

# Write initial status
cat > "$WORKTREE_DIR/.dae-status.json" <<STATUSEOF
{"loop_id":"$LOOP_ID","run_id":"$RUN_ID","status":"running","iteration":0,"max_iterations":$MAX_ITERATIONS,"task":"$(echo "$TASK" | head -c 200 | sed 's/"/\\"/g')","branch":"$BRANCH"}
STATUSEOF

export DAE_RUN_ID="$RUN_ID"
export DAE_LOOP_ID="$LOOP_ID"
export DAE_BRANCH="$BRANCH"
export DAE_WORKTREE="$WORKTREE_DIR"

# --- Main loop function ---
run_dae_loop() {
  local NO_PROGRESS_COUNT=0
  local EVAL_SUMMARY=""
  local EVAL_STATUS=""

  for ITER in $(seq 1 "$MAX_ITERATIONS"); do
    echo "=== DAE Loop $LOOP_ID — Iteration $ITER of $MAX_ITERATIONS ===" >&2

    # ---- DISTILL stage ----
    echo "[distill] Building context for iteration $ITER..." >&2

    local DISTILL_PROMPT
    if [ "$ITER" -eq 1 ]; then
      DISTILL_PROMPT="You are distilling context for a DAE loop.

Original task: $TASK

This is iteration 1 (of $MAX_ITERATIONS). Perform a full scan:
1. Scan the project directory to find files relevant to the task
2. Check inbox/ in the worktree ($WORKTREE_DIR) for messages from sibling loops
3. If DAE_SESSION_DIR ($DAE_SESSION_DIR) exists and has .jsonl files, process session history:
   - Filter to text messages only (skip tool_use, tool_result, thinking, system)
   - Extract decisions, requirements, architecture context relevant to the task
4. Assemble everything into a comprehensive context markdown blob

Worktree path: $WORKTREE_DIR
Session history dir: $DAE_SESSION_DIR
Run ID: $RUN_ID
Loop ID: $LOOP_ID"
    else
      DISTILL_PROMPT="You are distilling context for a DAE loop.

Original task: $TASK

This is iteration $ITER (of $MAX_ITERATIONS). Perform an incremental update:
1. Run 'git diff HEAD~1' in the worktree ($WORKTREE_DIR) to find what changed
2. Re-scan only changed files and their dependents
3. Read .dae-eval.json in the worktree for previous evaluator output
4. Check child branch statuses via: git branch --list 'dae/$RUN_ID/$LOOP_ID/*'
5. Check inbox/ for new messages from sibling loops
6. Carry forward unchanged context from the previous .dae-context.md
7. Update the context blob with new information

Worktree path: $WORKTREE_DIR
Session history dir: $DAE_SESSION_DIR
Run ID: $RUN_ID
Loop ID: $LOOP_ID
Previous eval summary: ${EVAL_SUMMARY:-none yet}"
    fi

    local DISTILL_OUTPUT
    DISTILL_OUTPUT=$(bash "$LAUNCHER" "$DISTILLER_CONFIG" "$DISTILL_PROMPT" \
      DAE_ITERATION="$ITER" \
      DAE_WORKTREE="$WORKTREE_DIR" \
      DAE_TASK="$TASK" \
      DAE_RUN_ID="$RUN_ID" \
      DAE_LOOP_ID="$LOOP_ID" \
      DAE_SESSION_DIR="$DAE_SESSION_DIR" \
      2>/dev/null) || true

    # Extract context from JSON output and write to worktree
    if [ -n "$DISTILL_OUTPUT" ]; then
      local CONTEXT
      CONTEXT=$(echo "$DISTILL_OUTPUT" | jq -r '.context // empty' 2>/dev/null) || true
      if [ -n "$CONTEXT" ]; then
        echo "$CONTEXT" > "$WORKTREE_DIR/.dae-context.md"
        echo "[distill] Context written to .dae-context.md" >&2
      else
        echo "[distill] WARNING: Could not extract context from distiller output" >&2
      fi
    else
      echo "[distill] WARNING: Distiller returned no output, acting agent will work from task alone" >&2
    fi

    # ---- ACT stage ----
    echo "[act] Running acting agent for iteration $ITER..." >&2

    local ACT_PROMPT="You are executing iteration $ITER of a DAE loop.

Your working context is in: .dae-context.md (in your current directory)
Read it before doing anything else.

Your task: $TASK

You have bounded turns. Do as much meaningful work as you can.
When you're done or out of turns, stop. An external evaluator will
decide whether to loop.

To send a message to another loop:
  Write a JSON file to outbox/<recipient-loop-id>.json
  Format: {\"to\": \"<loop_id>\", \"subject\": \"...\", \"body\": \"...\"}

To spawn a child DAE loop:
  bash $RLM_ROOT/dae.sh --async \"<sub-task>\" \"<config>\" \\
    RUN_ID=$RUN_ID PARENT_BRANCH=$BRANCH
  This returns the child LOOP_ID on stdout."

    # Run the acting agent inside the worktree directory
    (cd "$WORKTREE_DIR" && bash "$LAUNCHER" "$ACT_CONFIG" "$ACT_PROMPT" \
      DAE_RUN_ID="$RUN_ID" \
      DAE_LOOP_ID="$LOOP_ID" \
      DAE_BRANCH="$BRANCH" \
      2>/dev/null) || true

    echo "[act] Acting agent finished iteration $ITER" >&2

    # ---- Between iterations (programmatic) ----
    # Commit any changes
    local COMMIT_CREATED=false
    if (cd "$WORKTREE_DIR" && git add -A && ! git diff --cached --quiet); then
      (cd "$WORKTREE_DIR" && git commit -m "dae: iteration $ITER — pending eval") && COMMIT_CREATED=true || true
    fi

    # Sweep outbox messages to sibling worktrees
    for msg in "$WORKTREE_DIR/outbox/"*.json; do
      [ -f "$msg" ] || continue
      local RECIPIENT
      RECIPIENT=$(jq -r '.to' "$msg" 2>/dev/null) || continue
      local RECIPIENT_WT
      RECIPIENT_WT=$(git worktree list 2>/dev/null | grep "dae/$RUN_ID/$RECIPIENT" | awk '{print $1}') || true
      if [ -n "$RECIPIENT_WT" ]; then
        mkdir -p "$RECIPIENT_WT/inbox"
        cp "$msg" "$RECIPIENT_WT/inbox/$(basename "$msg")"
      fi
      rm "$msg"
    done

    # ---- EVALUATE stage ----
    echo "[eval] Running evaluator for iteration $ITER..." >&2

    local GIT_DIFF_OUTPUT
    GIT_DIFF_OUTPUT=$(cd "$WORKTREE_DIR" && git diff HEAD~1 2>/dev/null) || GIT_DIFF_OUTPUT="No previous commit to diff against"

    local CHILD_BRANCHES
    CHILD_BRANCHES=$(git branch --list "dae/$RUN_ID/$LOOP_ID/*" 2>/dev/null) || CHILD_BRANCHES="none"

    local PREV_EVAL=""
    if [ -f "$WORKTREE_DIR/.dae-eval.json" ]; then
      PREV_EVAL=$(cat "$WORKTREE_DIR/.dae-eval.json")
    fi

    # Check for test command in project config (check worktree's project, not RLM template)
    local TEST_CMD_NOTE=""
    local TEST_CMD=""
    for cfg in "$WORKTREE_DIR/.claude/project.json" "$WORKTREE_DIR/project.json"; do
      if [ -f "$cfg" ]; then
        TEST_CMD=$(jq -r '.test_command // empty' "$cfg" 2>/dev/null) || true
        [ -n "$TEST_CMD" ] && break
      fi
    done
    if [ -n "$TEST_CMD" ]; then
      TEST_CMD_NOTE="A test command is available: $TEST_CMD
Run it in the worktree ($WORKTREE_DIR) to check if tests pass."
    fi

    local EVAL_PROMPT="You are evaluating iteration $ITER (of $MAX_ITERATIONS) of a DAE loop.

Original task: $TASK

## Git diff this iteration
\`\`\`
$GIT_DIFF_OUTPUT
\`\`\`

## Child branch statuses
$CHILD_BRANCHES

## Previous evaluation
${PREV_EVAL:-No previous evaluation (this is the first iteration).}

$TEST_CMD_NOTE

Assess progress and determine next action: loop, done, or stuck."

    local EVAL_OUTPUT
    EVAL_OUTPUT=$(bash "$LAUNCHER" "$EVALUATOR_CONFIG" "$EVAL_PROMPT" \
      DAE_ITERATION="$ITER" \
      2>/dev/null) || true

    # Parse evaluator output
    EVAL_STATUS="loop"
    local PROGRESS_MADE=true
    EVAL_SUMMARY="Evaluation unavailable"
    local REMAINING_WORK="Unknown"

    if [ -n "$EVAL_OUTPUT" ]; then
      EVAL_STATUS=$(echo "$EVAL_OUTPUT" | jq -r '.status // "loop"' 2>/dev/null) || EVAL_STATUS="loop"
      PROGRESS_MADE=$(echo "$EVAL_OUTPUT" | jq -r '.progress_made // true' 2>/dev/null) || PROGRESS_MADE=true
      EVAL_SUMMARY=$(echo "$EVAL_OUTPUT" | jq -r '.summary // "Evaluation unavailable"' 2>/dev/null) || EVAL_SUMMARY="Evaluation unavailable"
      REMAINING_WORK=$(echo "$EVAL_OUTPUT" | jq -r '.remaining_work // "Unknown"' 2>/dev/null) || REMAINING_WORK="Unknown"
    fi

    echo "[eval] Status: $EVAL_STATUS | Progress: $PROGRESS_MADE | Summary: $EVAL_SUMMARY" >&2

    # ---- Post-evaluate (programmatic) ----
    # Amend the iteration commit message with eval summary
    if [ "$COMMIT_CREATED" = true ]; then
      (cd "$WORKTREE_DIR" && git commit --amend -m "dae: iteration $ITER — $EVAL_SUMMARY" 2>/dev/null) || true
    fi

    # Save eval output
    if [ -n "$EVAL_OUTPUT" ]; then
      echo "$EVAL_OUTPUT" > "$WORKTREE_DIR/.dae-eval.json"
    fi

    # Update status
    cat > "$WORKTREE_DIR/.dae-status.json" <<STATUSEOF
{"loop_id":"$LOOP_ID","run_id":"$RUN_ID","status":"$EVAL_STATUS","iteration":$ITER,"max_iterations":$MAX_ITERATIONS,"summary":"$(echo "$EVAL_SUMMARY" | sed 's/"/\\"/g')","remaining_work":"$(echo "$REMAINING_WORK" | sed 's/"/\\"/g')","branch":"$BRANCH"}
STATUSEOF

    # Track no-progress streaks
    if [ "$PROGRESS_MADE" = "false" ]; then
      NO_PROGRESS_COUNT=$((NO_PROGRESS_COUNT + 1))
    else
      NO_PROGRESS_COUNT=0
    fi

    # Branch on status
    case "$EVAL_STATUS" in
      done)
        echo "[done] Task complete at iteration $ITER: $EVAL_SUMMARY" >&2
        (cd "$WORKTREE_DIR" && git add -A && \
          git diff --cached --quiet || git commit -m "dae: complete — $EVAL_SUMMARY") 2>/dev/null || true
        return 0
        ;;
      stuck)
        echo "[stuck] Loop stuck at iteration $ITER: $EVAL_SUMMARY" >&2
        (cd "$WORKTREE_DIR" && git add -A && \
          git diff --cached --quiet || git commit -m "dae: stuck — $EVAL_SUMMARY") 2>/dev/null || true
        return 1
        ;;
      loop)
        # Check for sustained no-progress
        if [ "$NO_PROGRESS_COUNT" -ge 2 ]; then
          echo "[stuck] No progress for $NO_PROGRESS_COUNT consecutive iterations, declaring stuck" >&2
          (cd "$WORKTREE_DIR" && git add -A && \
            git diff --cached --quiet || git commit -m "dae: stuck (no progress) — $EVAL_SUMMARY") 2>/dev/null || true
          return 1
        fi
        echo "[loop] Continuing to iteration $((ITER + 1))..." >&2
        ;;
      *)
        echo "[warn] Unknown eval status '$EVAL_STATUS', treating as loop" >&2
        ;;
    esac
  done

  # Max iterations reached
  echo "[max] Reached $MAX_ITERATIONS iterations: $EVAL_SUMMARY" >&2
  (cd "$WORKTREE_DIR" && git add -A && \
    git diff --cached --quiet || git commit -m "dae: max iterations — ${EVAL_SUMMARY:-no summary}") 2>/dev/null || true
  return 2
}

# --- Handle async mode ---
if [ "$ASYNC" = true ]; then
  # Write PID file and loop ID for the caller
  echo "$LOOP_ID"

  # Fork to background
  (
    run_dae_loop
    EXIT_CODE=$?
    echo "$EXIT_CODE" > "$WORKTREE_DIR/.dae-exit-code"
  ) &
  CHILD_PID=$!
  echo "$CHILD_PID" > "$WORKTREE_DIR/.dae-pid"
  disown "$CHILD_PID"
  exit 0
fi

# --- Blocking mode ---
run_dae_loop
exit $?
