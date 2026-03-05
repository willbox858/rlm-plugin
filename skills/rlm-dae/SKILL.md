---
name: rlm-dae
description: "Execute any task via the DAE (Distill-Act-Evaluate) loop — an iterative execution cycle with externally managed context, git-based state, and automatic progress evaluation. This is the most general-purpose execution pattern: it handles implementation, refactoring, research, bug fixing, documentation, or any multi-step task that benefits from iterative context-managed execution. Prefer this when: the task is non-trivial and could benefit from multiple iterations, you want worktree isolation, you want automatic progress tracking, or the task involves large/complex codebases where context management matters. Trigger when: 'dae', 'iterate on', 'loop on', 'keep working on', 'work on this until done', 'implement' (when no specific plan exists), 'fix this bug and verify', 'refactor until tests pass', 'research and report', any task where the user wants autonomous iterative execution with checkpointing."
---

# DAE — Distill-Act-Evaluate Loop

Executes any task via an iterative loop where context is assembled fresh
each iteration (Distill), work is performed by a bounded agent session
(Act), and progress is assessed by an evaluator (Evaluate). All state
lives in git — each iteration is a commit, each loop is a branch, each
worktree is a workspace.

## When to use

- Any non-trivial task that could take multiple iterations
- Implementation without a formal plan (has a plan → prefer /rlm-implement)
- Bug fixing with verification ("fix this and make sure it works")
- Refactoring with behavioral equivalence ("restructure this, keep tests passing")
- Research or analysis that needs to cover a large codebase
- Any task where the user wants "work on this until it's done"
- When worktree isolation and automatic checkpointing are valuable
- When context management matters (large codebase, long history)

## When NOT to use

- Trivially small change (just do it directly)
- Single-file edit with obvious fix (just edit it)
- User just wants information, not execution (answer directly)
- User has a formal feature plan ready (use /rlm-implement)

## Step 0: Understand the Task

Determine what the user wants done. DAE handles anything, but the task
description needs to be clear enough for the evaluator to judge "done."

If the user's request is vague, ask one clarifying question. Don't
over-interview — DAE loops are cheap and the evaluator can always
request more iterations.

## Step 1: Select Agent Config

Choose the right acting agent config based on task type:

```bash
# Default: general-purpose actor (read + write + edit + bash + search)
ACTOR_CONFIG="$RLM_ROOT/internal/dae-actor.json"

# For tasks that should NOT modify code (research, analysis, review):
# ACTOR_CONFIG="$RLM_ROOT/internal/gc-worker.json"  # read-only

# For tasks with a specific existing config:
# ACTOR_CONFIG="<user-provided path>"
```

**Config selection heuristics:**

| Task type | Config | Why |
|---|---|---|
| Implementation (no plan) | `dae-actor.json` | Needs Write + Edit |
| Bug fix | `dae-actor.json` | Needs Write + Edit + Bash (tests) |
| Refactoring | `dae-actor.json` | Needs Write + Edit |
| Research / analysis | `dae-actor.json` | May need to write report |
| Documentation | `dae-actor.json` | Needs Write |
| Review (read-only) | `gc-worker.json` | Should not modify code |

Default to `dae-actor.json` unless there's a clear reason for read-only.

If the user specifies a config path, use it directly.

## Step 2: Determine Parameters

```bash
# Resolve RLM_ROOT
if [ -n "${RLM_ROOT:-}" ]; then
  DAE_SCRIPT="$RLM_ROOT/dae.sh"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  RLM_ROOT="$CLAUDE_PLUGIN_ROOT"
  DAE_SCRIPT="$RLM_ROOT/dae.sh"
else
  RLM_ROOT="$(find . -path '*/.claude/RLM/dae.sh' -print -quit 2>/dev/null | xargs dirname)"
  DAE_SCRIPT="$RLM_ROOT/dae.sh"
fi

# Task description — use the user's words, don't paraphrase
TASK="<user's task description, verbatim>"

# Max iterations — scale to task complexity
# Small fix: 3-4, Medium feature: 6-8, Large effort: 10-15
MAX_ITER=8  # default

# Blocking vs async
# Default: blocking (user is waiting for results)
# Use async when spawning multiple parallel loops
MODE=""  # or "--async"
```

## Step 3: Launch the DAE Loop

### Blocking mode (default — single task, user is waiting)

```bash
bash "$DAE_SCRIPT" "$TASK" "$ACTOR_CONFIG" MAX_ITERATIONS=$MAX_ITER
DAE_EXIT=$?
```

### Async mode (parallel tasks or background work)

```bash
RUN_ID=$(date +%s | tail -c 9)

LOOP_A=$(bash "$DAE_SCRIPT" --async "$TASK_A" "$ACTOR_CONFIG" \
  RUN_ID=$RUN_ID MAX_ITERATIONS=$MAX_ITER)

LOOP_B=$(bash "$DAE_SCRIPT" --async "$TASK_B" "$ACTOR_CONFIG" \
  RUN_ID=$RUN_ID MAX_ITERATIONS=$MAX_ITER)

echo "Launched loops: $LOOP_A, $LOOP_B"
echo "Monitor: git branch --list 'dae/$RUN_ID/*'"
```

## Step 4: Present Results

After the loop completes, show the user:

### Determine outcome from exit code

```bash
case $DAE_EXIT in
  0) OUTCOME="completed successfully" ;;
  1) OUTCOME="got stuck (no progress)" ;;
  2) OUTCOME="reached max iterations" ;;
  3) OUTCOME="encountered a fatal error" ;;
esac
```

### Gather details

```bash
# Find the worktree and branch
WORKTREE=$(git worktree list | grep "dae/" | tail -1 | awk '{print $1}')
BRANCH=$(git worktree list | grep "dae/" | tail -1 | awk '{print $3}' | tr -d '[]')

# Read final status
cat "$WORKTREE/.dae-status.json" 2>/dev/null | jq .

# See iteration history
git log --oneline "$BRANCH"

# See total changes
git diff main..."$BRANCH" --stat
```

### Show the user

1. **Outcome**: Done / Stuck / Max iterations
2. **Branch**: `dae/<run>/<loop>`
3. **Iterations used**: N of max
4. **Summary**: From the final evaluator output
5. **Files changed**: From git diff stat
6. **Next steps**:

```bash
# Review changes
cd $WORKTREE && git log --oneline

# See all changes vs main
git diff main...$BRANCH

# Merge into current branch
git merge $BRANCH

# Or cherry-pick specific commits
git cherry-pick <commit-hash>

# Discard if unwanted
git worktree remove $WORKTREE
git branch -D $BRANCH
```

## Step 5: Handle Non-Success Outcomes

### Exit 1 — Stuck

The loop made no progress for 2+ consecutive iterations. This usually
means the task is blocked on something. Read `.dae-eval.json` in the
worktree for the evaluator's assessment and relay it to the user.

Options:
- Provide more guidance and re-run
- Manually unblock and re-launch from the current branch
- Abandon the worktree

### Exit 2 — Max iterations

Work was happening but didn't converge. Read the final eval summary.

Options:
- Increase MAX_ITERATIONS and re-launch (with PARENT_BRANCH set to the existing branch)
- Review partial progress and finish manually
- Break the task into smaller pieces

### Exit 3 — Fatal error

Config or infrastructure problem. Check `.dae-status.json` for the error.

## What happens inside

You don't manage this — `dae.sh` handles it:

1. **Setup**: Creates git worktree on `dae/<run>/<loop>` branch
2. **Each iteration**:
   a. **Distill** — Sonnet agent scans codebase, ingests session history,
      reads inbox, assembles focused context blob (`.dae-context.md`)
   b. **Act** — Acting agent reads context, does work, commits changes.
      Can spawn child DAE loops or send messages to siblings.
   c. **Evaluate** — Haiku agent reads git diff, runs tests if available,
      judges: done / loop / stuck
   d. **Between** — Commit with eval summary, deliver messages, update status
3. **Exit**: Final commit with status prefix, worktree preserved for user

Every iteration is a git commit. Full observability via `git log`.

## Monitoring (for async loops)

```bash
# All loops in a run
git branch --list 'dae/<run-id>/*'

# Live status of all active loops
for wt in $(git worktree list | grep 'dae/' | awk '{print $1}'); do
  echo "=== $(basename $wt) ==="
  cat "$wt/.dae-status.json" 2>/dev/null | jq -r '"\(.status) — iter \(.iteration)/\(.max_iterations) — \(.summary // "no summary")"'
done

# Iteration history of a specific loop
git log --oneline dae/<run-id>/<loop-id>
```
