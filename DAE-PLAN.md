# DAE Loop — Design & Implementation Plan

## What It Is

`dae.sh` is a bash script that implements a **Distill-Act-Evaluate** loop — a launcher-controlled iteration cycle that wraps Claude Code sessions as stateless execution units. The launcher owns context management, iteration decisions, and inter-loop communication. Each Claude Code session within the loop is disposable; context is assembled fresh from the outside on every iteration.

## Why It Exists

The core problem: Claude Code owns the agentic loop, so we can't manage context mid-conversation. DAE sidesteps this by making each Claude Code session short-lived and assembling context externally before each invocation. This gives us:

- **Deterministic context** at each iteration (we assembled it, not Claude Code's compaction)
- **Free checkpointing** (git state = full state at every iteration boundary)
- **Free restartability** (crash mid-iteration → re-run from last commit)
- **Non-blocking child loops** (parent doesn't wait; distiller checks child branch status on next iteration)

## Architecture

```
dae.sh <task> <agent-config> [options]
│
├── Setup
│   ├── Create git worktree on branch dae/<run-id>/<loop-id>
│   ├── Write .gitignore for DAE ephemeral files (inbox/, outbox/, .dae-*)
│   ├── Resolve Claude Code session history directory
│   └── Initialize .dae-status.json in worktree
│
├── Iteration 1
│   ├── DISTILL
│   │   ├── Full project scan (parallel gc-worker swarm)
│   │   ├── Ingest full Claude Code session history (all project JSONL logs)
│   │   ├── Read inbox/ for inter-loop messages
│   │   └── Output: .dae-context.md (focused context blob, in worktree)
│   │
│   ├── ACT
│   │   ├── Receives: .dae-context.md + original task
│   │   ├── Works INSIDE the worktree (cd into it)
│   │   ├── Has full tools, bounded turns
│   │   ├── Can spawn child DAE loops (non-blocking)
│   │   ├── Can send messages (writes to outbox/)
│   │   └── Output: file changes committed to branch
│   │
│   ├── EVALUATE
│   │   ├── Receives: original task, git diff from latest commit, iteration count
│   │   ├── Checks child branch statuses (git branch --list 'dae/<run>/<loop>/*')
│   │   ├── Programmatic short-circuit: if test_command exists and tests pass → done
│   │   └── Output: {status, progress_made, summary, remaining_work}
│   │
│   └── Between iterations (programmatic, no LLM)
│       ├── Commit acting agent's changes (if uncommitted): "dae: iteration N"
│       ├── Sweep outbox/ → sibling worktrees' inbox/
│       ├── Update .dae-status.json
│       └── Branch on status: done → exit, stuck → exit error, loop → continue
│
├── Iteration 2+
│   ├── DISTILL
│   │   ├── git diff HEAD~1 → identify changed files
│   │   ├── Re-scan ONLY changed files + their dependents
│   │   ├── Re-ingest session history (new sessions may exist from parallel work)
│   │   ├── Read inbox/ (new messages from sibling loops)
│   │   ├── Check child branch statuses (completed children → pull results)
│   │   ├── Carry forward unchanged context from previous distillation
│   │   └── Output: updated .dae-context.md
│   │
│   ├── ACT → same as above
│   ├── EVALUATE → same as above
│   └── Between → same as above
│
└── Exit
    ├── Update .dae-status.json to final state (done | stuck | max_iterations)
    ├── Commit final status
    └── Return result to caller (stdout if blocking, on-disk if async)
```

## State Management via Git

All DAE state lives in git. No parallel filesystem structures.

### Branch Naming Convention

```
dae/<run-id>/<loop-id>                    # Root loop
dae/<run-id>/<loop-id>/<child-loop-id>    # Child loop
dae/<run-id>/<loop-id>/<child>/<grandchild>  # Nested children
```

This gives us:
- **Loop listing**: `git branch --list 'dae/<run-id>/*'` → all loops in a run
- **Child discovery**: `git branch --list 'dae/<run-id>/<loop-id>/*'` → all children of a loop
- **Parent-child hierarchy**: encoded in branch path, no registry needed
- **Iteration history**: `git log --oneline dae/<run-id>/<loop-id>` → every iteration as a commit

### Worktree = Loop State

Each DAE loop gets a worktree. The worktree contains:

```
<worktree>/
├── (project files)              # Tracked by git — the actual work product
├── .gitignore                   # DAE additions: inbox/, outbox/, .dae-*
├── .dae-status.json             # Loop status (gitignored, but also committed at boundaries)
├── .dae-context.md              # Distiller output — context blob for acting agent (gitignored)
├── .dae-eval.json               # Latest evaluator output (gitignored)
├── .dae-pid                     # PID of background dae.sh process (gitignored, async mode only)
├── inbox/                       # Messages from other loops (gitignored)
│   └── *.json
└── outbox/                      # Messages to send (gitignored, cleared between iterations)
    └── *.json
```

### Commit Convention

Each iteration produces one commit on the loop's branch:

```
dae: iteration 1 — created auth middleware skeleton
dae: iteration 2 — added JWT validation, 3/5 tests passing
dae: iteration 3 — all tests passing
dae: complete — auth middleware implemented
```

The commit message encodes the evaluator's summary. Reading `git log` tells you the full story.

### Checking Loop Status

To check if a child loop is done, read its `.dae-status.json` from its worktree, or check its latest commit message for the `dae: complete` prefix.

To find a child's worktree path:
```bash
git worktree list | grep "dae/$RUN_ID/$LOOP_ID/" | awk '{print $1}'
```

To check if a child's process is alive (async mode):
```bash
CHILD_WORKTREE=$(git worktree list | grep "dae/$RUN_ID/$CHILD_ID" | awk '{print $1}')
CHILD_PID=$(cat "$CHILD_WORKTREE/.dae-pid" 2>/dev/null)
kill -0 "$CHILD_PID" 2>/dev/null && echo "alive" || echo "dead"
```

### Merging Results

When a child loop completes, the parent can merge its branch:
```bash
# From parent worktree
git merge "dae/$RUN_ID/$LOOP_ID/$CHILD_ID" --no-edit
```

This naturally integrates the child's work into the parent's branch. If there are conflicts, the evaluator flags them and the next acting agent iteration resolves them.

## Interface

```bash
# Blocking (default) — runs loop, returns result on stdout
bash dae.sh "<task description>" "<path/to/agent-config.json>" \
  [MAX_ITERATIONS=8] [RUN_ID=<auto>] [LOOP_ID=<auto>] [PARENT_BRANCH=<current>]

# Non-blocking — starts loop in background, returns loop ID immediately
bash dae.sh --async "<task description>" "<path/to/agent-config.json>" \
  [MAX_ITERATIONS=8] [RUN_ID=<auto>] [LOOP_ID=<auto>] [PARENT_BRANCH=<current>]
```

**Arguments:**
- `<task>` — The task description. Passed verbatim to all three stages.
- `<agent-config>` — Path to the acting agent's config JSON (same format as existing internal/*.json configs). This defines what the acting agent can do (model, tools, turns, skills).
- `MAX_ITERATIONS` — Hard cap on loop iterations (default: 8). Evaluator tracks this.
- `RUN_ID` — Groups multiple DAE loops in a single run. Auto-generated if not provided. Shared across parent and child loops for message routing.
- `LOOP_ID` — Unique identifier for this loop. Auto-generated if not provided.
- `PARENT_BRANCH` — Branch to create the worktree from (default: current HEAD). Child loops branch off the parent loop's branch.

**Exit codes:**
- 0 — Completed successfully (evaluator returned `done`)
- 1 — Stuck (evaluator returned `stuck` or no progress for 2+ iterations)
- 2 — Max iterations reached without completion
- 3 — Fatal error (config not found, launcher failure, etc.)

## Stage Details

### DISTILL Stage

**Config:** `internal/dae-distiller.json`
- Model: sonnet
- Tools: Read, Bash, Grep, Glob (read-only)
- Max turns: 30
- Permission mode: bypassPermissions
- Structured output: `{"context": "<markdown context blob>"}`

**Inputs (all iterations):**
1. **Claude Code session history** — Full project JSONL logs from `~/.claude/projects/<project-slug>/`. These contain the complete conversation history across all sessions for this project: every user request, assistant response, tool call, and decision. The distiller processes this via RLM techniques (the session history can be enormous — potentially millions of characters across many sessions). This gives the distiller full historical context about past decisions, architectural choices, previous implementations, and user preferences.
2. **Inbox messages** — Messages from sibling/parent DAE loops, read from `<worktree>/inbox/`.
3. **The original task** — Verbatim, never paraphrased.

**Iteration 1 additional inputs:**
4. **Project files** — Full gc-worker swarm scan of the project directory, scoped to the task.

**Iteration 2+ additional inputs:**
4. **Changed files** — `git diff HEAD~1` in the worktree identifies what the previous iteration changed. Only those files + their dependents are re-scanned.
5. **Previous evaluator output** — Read from `<worktree>/.dae-eval.json`. Summary of progress and remaining work.
6. **Child branch statuses** — `git branch --list 'dae/<run>/<loop>/*'` finds children. For each, check worktree's `.dae-status.json`. Completed children: read their final committed state.
7. **Previous context (carry-forward)** — Context for unchanged files carries forward from last iteration's `.dae-context.md` without re-scanning.

**Session history processing:**
The session history is potentially the largest input. The distiller uses RLM decomposition to process it:
- Filter JSONL to text messages only (strip tool_use, tool_result, thinking blocks)
- If total size < 80K chars, process directly
- If larger, split into chunks and delegate to RLM child agents
- Extract: decisions, requirements, architectural context, relevant past work
- The distiller's job is to pull out what's relevant to *this specific task*, not summarize everything

**Context blob format (written to `<worktree>/.dae-context.md`):**
```markdown
# Task
<original task, verbatim>

# Iteration
N of MAX

# Previous Progress
<evaluator summary from last iteration, if any>

# Project History Context
<distilled decisions, requirements, and relevant past work from session logs>

# Pending Child Loops
- dae/<run>/loop/child-1: "implement auth middleware" — still running (iteration 3 of 8)
- dae/<run>/loop/child-2: "write database migration" — COMPLETED: <result summary>

# Messages
- From dae/<run>/sibling: "I refactored the User model, added email field"

# Relevant Code Context
## src/auth/handler.ts (high relevance)
<key content>

## src/models/user.ts (medium relevance, changed this iteration)
<key content>

...
```

### ACT Stage

**Config:** Caller-provided via `<agent-config>` argument. Any valid internal/*.json config works.

**Working directory:** The acting agent runs inside the loop's worktree (`cd` into it before launch).

**Prompt construction (assembled by dae.sh, passed to launch.sh):**
```
You are executing iteration N of a DAE loop.

Your working context is in: .dae-context.md (in your current directory)
Read it before doing anything else.

Your task: <original task>

You have <max_turns> turns. Do as much meaningful work as you can.
When you're done or out of turns, stop. An external evaluator will
decide whether to loop.

To send a message to another loop:
  Write a JSON file to outbox/<recipient-loop-id>.json
  Format: {"to": "<loop_id>", "subject": "...", "body": "..."}

To spawn a child DAE loop:
  bash $RLM_ROOT/dae.sh --async "<sub-task>" "<config>" \
    RUN_ID=$DAE_RUN_ID PARENT_BRANCH=$DAE_BRANCH
  This returns the child LOOP_ID on stdout.
```

The acting agent's config determines its model, tools, turn budget, and skills. DAE doesn't constrain this — whatever config you pass in is what the acting agent gets.

### EVALUATE Stage

**Config:** `internal/dae-evaluator.json`
- Model: haiku (cheap, fast — this is a judgment call, not heavy reasoning)
- Tools: Bash (for running tests), Read (for reading diffs and status)
- Max turns: 10
- Permission mode: bypassPermissions
- Structured output schema:

```json
{
  "type": "object",
  "properties": {
    "status": {"type": "string", "enum": ["loop", "done", "stuck"]},
    "progress_made": {"type": "boolean"},
    "summary": {"type": "string"},
    "remaining_work": {"type": "string"},
    "files_changed": {
      "type": "array",
      "items": {"type": "string"}
    }
  },
  "required": ["status", "progress_made", "summary", "remaining_work"]
}
```

**Inputs (passed via prompt):**
- The original task
- The git diff from this iteration (`git diff HEAD~1` in the worktree)
- Current iteration number and max iterations
- Child branch statuses (from `git branch --list` + worktree status files)
- Previous evaluator output (for trend detection — consecutive no-progress → stuck)

**Evaluation logic the evaluator is prompted to follow:**
1. Read the git diff — did anything actually change?
2. If a `test_command` is configured and tests all pass → `done`
3. Compare current state to the task goal — is the task complete?
4. If no progress was made AND previous iteration also had no progress → `stuck`
5. If progress was made but work remains → `loop`
6. If child loops are still running and there's nothing else to do → `loop` (wait for children)

**Programmatic short-circuits in dae.sh (before calling the LLM evaluator):**
- If acting agent's output contains `"ERROR: "` → check if retryable, otherwise `stuck`
- If iteration count == MAX_ITERATIONS → force exit regardless of evaluator opinion

### Between Iterations (Programmatic)

This is pure bash in `dae.sh`, no LLM calls:

```bash
# 1. Commit any uncommitted changes from the acting agent
cd "$WORKTREE_DIR"
if ! git diff --quiet || ! git diff --cached --quiet; then
  git add -A
  git commit -m "dae: iteration $ITER — $EVAL_SUMMARY"
fi

# 2. Deliver outbox messages to sibling worktrees
for msg in "$WORKTREE_DIR/outbox/"*.json; do
  [ -f "$msg" ] || continue
  RECIPIENT=$(jq -r '.to' "$msg")
  # Find recipient's worktree
  RECIPIENT_WT=$(git worktree list | grep "dae/$RUN_ID/$RECIPIENT" | awk '{print $1}')
  if [ -n "$RECIPIENT_WT" ]; then
    mkdir -p "$RECIPIENT_WT/inbox"
    cp "$msg" "$RECIPIENT_WT/inbox/$(basename "$msg")"
  fi
  rm "$msg"
done

# 3. Update status file
cat > "$WORKTREE_DIR/.dae-status.json" <<EOF
{
  "loop_id": "$LOOP_ID",
  "run_id": "$RUN_ID",
  "branch": "$BRANCH",
  "status": "$EVAL_STATUS",
  "iteration": $ITER,
  "max_iterations": $MAX_ITER,
  "summary": "$EVAL_SUMMARY",
  "updated_at": "$(date -Iseconds)"
}
EOF

# 4. Save evaluator output for next iteration's distiller
cp "$EVAL_OUTPUT" "$WORKTREE_DIR/.dae-eval.json"

# 5. Branch on status
case "$EVAL_STATUS" in
  done)
    git add -A && git commit -m "dae: complete — $EVAL_SUMMARY" 2>/dev/null
    write_result_and_exit 0
    ;;
  stuck)
    git add -A && git commit -m "dae: stuck — $EVAL_SUMMARY" 2>/dev/null
    write_result_and_exit 1
    ;;
  loop)
    ;; # continue to next iteration
esac
```

## Non-Blocking Mode (--async)

When `--async` is passed:

1. `dae.sh` creates the worktree and branch
2. Writes initial `.dae-status.json` with `status: "running"`
3. Writes PID to `.dae-pid`
4. Prints the LOOP_ID to stdout and exits immediately
5. The background process runs the loop normally, committing each iteration
6. On completion, final commit with status prefix (`dae: complete` or `dae: stuck`)

```bash
if [ "$1" = "--async" ]; then
  shift
  setup_worktree  # creates branch + worktree
  echo '{"status":"running","iteration":0}' > "$WORKTREE_DIR/.dae-status.json"
  echo "$LOOP_ID"  # Return loop ID to caller

  # Fork and run loop in background
  (echo $$ > "$WORKTREE_DIR/.dae-pid"; run_dae_loop "$@") &
  disown
  exit 0
fi
```

Parent or sibling loops check status by:
- Reading `<child-worktree>/.dae-status.json`
- Or checking `git log --oneline -1 dae/<run>/<child>` for commit message prefix
- Or checking if `.dae-pid` process is alive

## New Files Required

### 1. `dae.sh` — The loop controller
Location: `.claude/RLM/dae.sh`
~250-350 lines of bash. Handles:
- Argument parsing (task, config, options, --async)
- RUN_ID and LOOP_ID generation
- Git worktree + branch creation (branch naming: `dae/<run>/<loop>`)
- .gitignore setup for DAE ephemeral files
- Session history directory resolution
- Iteration loop (distill → act → evaluate → commit → check → repeat)
- Message delivery between iterations (outbox → sibling worktrees' inbox)
- Programmatic short-circuits (max iterations, error detection)
- Final commit with status prefix
- Result output (stdout if blocking, on-disk if async)

### 2. `internal/dae-distiller.json` — Distill stage agent config
- Model: sonnet
- Tools: Read, Bash, Grep, Glob
- Skills: rlm-map-worker (reuses existing gc methodology for file scanning), rlm-core (for RLM decomposition of large session history)
- System prompt: Instructions for context assembly — session history processing (with RLM for large histories), inbox reading, child branch status checking, diff-scoped re-scanning, gc-worker dispatch for project file scanning
- Output: `{"context": "<markdown blob>"}`

### 3. `internal/dae-evaluator.json` — Evaluate stage agent config
- Model: haiku
- Tools: Bash, Read
- Skills: none (self-contained evaluation logic in system prompt)
- System prompt: Instructions for progress assessment, test running, child status checking, loop/done/stuck decision making
- Output: `{"status": "...", "progress_made": ..., "summary": "...", "remaining_work": "...", "files_changed": [...]}`

### 4. Modifications to existing files
- **None required for v1.** `launch.sh` is used as-is. Existing configs are unchanged. The DAE loop is purely additive.

## Integration Points

### How user-facing agents call DAE loops

A skill (e.g., a future `/dae` or updated `/rlm-implement`) would:
```bash
# Blocking — simple case
RESULT=$(bash "$RLM_ROOT/dae.sh" "$TASK" "$RLM_ROOT/internal/impl-worker.json" MAX_ITERATIONS=10)

# Non-blocking — parallel case
RUN_ID=$(date +%s | head -c 8)
LOOP_A=$(bash "$RLM_ROOT/dae.sh" --async "$TASK_A" "$CONFIG_A" RUN_ID=$RUN_ID)
LOOP_B=$(bash "$RLM_ROOT/dae.sh" --async "$TASK_B" "$CONFIG_B" RUN_ID=$RUN_ID)
# Status visible via: git branch --list 'dae/$RUN_ID/*'
# Or: cat $(git worktree list | grep $LOOP_A | awk '{print $1}')/.dae-status.json
```

### How acting agents spawn child DAE loops

The acting agent calls dae.sh directly via Bash tool:
```bash
CHILD_ID=$(bash "$RLM_ROOT/dae.sh" --async "implement auth middleware" \
  "$RLM_ROOT/internal/impl-worker.json" \
  RUN_ID=$DAE_RUN_ID PARENT_BRANCH=$DAE_BRANCH)
```

The child creates a branch under the parent's branch namespace. The parent's next distill stage discovers it via `git branch --list`.

### How messages flow

1. Acting agent writes JSON to `outbox/<recipient-loop-id>.json` in its worktree
2. Between iterations, `dae.sh` finds the recipient's worktree via `git worktree list` and copies messages to `<recipient-worktree>/inbox/`
3. Next iteration's distiller reads `inbox/` and incorporates relevant messages into context

### How session history flows

1. `dae.sh` resolves the project session directory at startup:
   ```bash
   PROJECT_DIR="$HOME/.claude/projects"
   CWD_SLUG=$(pwd | sed 's|/|--|g' | sed 's|^-*||')
   SESSION_DIR="$PROJECT_DIR/$CWD_SLUG"
   ```
2. Session directory path is exported as `DAE_SESSION_DIR` for the distiller
3. The distiller ingests all `*.jsonl` files from that directory
4. For large session histories, the distiller uses RLM child agents to process chunks in parallel
5. On iteration 2+, the distiller checks for new session files (parallel work may have created them)

### How child results merge

When the distiller detects a completed child branch:
1. It can `git merge` the child branch into the parent worktree
2. Or the acting agent can do the merge in its next iteration
3. Conflicts become part of the acting agent's work in the next iteration

## Observability

Every iteration is a git commit. Monitoring a run:

```bash
# All loops in a run
git branch --list 'dae/<run-id>/*'

# Iteration history of a specific loop
git log --oneline dae/<run-id>/<loop-id>

# What a specific iteration changed
git show dae/<run-id>/<loop-id>~2  # 2 iterations ago

# Current status of all loops
for wt in $(git worktree list | grep 'dae/<run-id>' | awk '{print $1}'); do
  echo "--- $wt ---"
  cat "$wt/.dae-status.json" 2>/dev/null
done

# Live monitoring
watch -n 5 'for wt in $(git worktree list | grep "dae/" | awk "{print \$1}"); do
  echo "=== $(basename $wt) ==="; cat "$wt/.dae-status.json" 2>/dev/null; echo
done'
```

## What This Doesn't Cover (Future Work)

- **Programmatic agent construction**: Acting agent configs are still static JSON files. Future: dynamic config assembly from component libraries.
- **Observability dashboard**: Git-based monitoring works but is raw. Future: formatted TUI viewer.
- **Tiered conflict resolution**: Child branch merges use basic `git merge`. Future: tiered strategy (clean → auto → AI → reimagine) inspired by Overstory.
- **Cost tracking**: No token/cost instrumentation yet. Future: parse claude CLI output for usage stats.
