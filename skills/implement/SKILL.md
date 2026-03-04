---
name: implement
description: "Execute a feature plan via TDD in an isolated git worktree — writes tests first, implements code, and iterates until all tests/build/lint pass. Prefer this over writing code directly when: a feature plan exists, the change needs tests, or the user wants worktree isolation. Trigger when: 'implement', 'build this feature', 'code this up', 'execute the plan', 'TDD this', user wants to turn a plan into working tested code, or any multi-file implementation."
---

# Implement — Execute Feature Plan via TDD

Executes a feature plan by creating a git worktree, writing tests from
acceptance criteria, implementing code, and iterating the implement-verify
loop until all tests, build, and lint pass. Dispatches
implementation-orchestrator agent which manages the test-writer,
implementation-worker, and verifier sub-agents.

## When to use

- User has a feature plan (from /plan-feature or manually written) and wants it implemented
- User says "implement", "implement this plan", "build this feature", "code this up"
- User says "TDD this feature" or "implement the plan for X"
- After running /plan-feature and wanting to move to implementation

## When NOT to use

- User wants a design doc (use /design)
- User wants an implementation plan (use /plan-feature)
- User wants to review code (use /review)
- User wants to fix a specific bug (just fix it directly)
- No feature plan exists — suggest /plan-feature first
- Trivially small change — just code it directly

## Step 0: Input Mode Detection

### Input mode

Ask or infer which mode applies:

**Mode A — Plan file path**: User provides a plan file path directly.
Use it.

**Mode B — Feature name**: User names a feature without providing a
file path. Scan `derived/drafts/*-plan-*.md` for matches:

```bash
IMPL_TOPIC="<feature topic from user>"
IMPL_SLUG="$(echo "$IMPL_TOPIC" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')"

# Scan for matching plan files
PLAN_FILE=""
PLAN_CANDIDATES=""
for f in derived/drafts/*-plan-*.md; do
  if [ -f "$f" ]; then
    if head -c 2000 "$f" | grep -qi "$IMPL_SLUG\|$IMPL_TOPIC" 2>/dev/null; then
      PLAN_CANDIDATES="$PLAN_CANDIDATES $f"
    fi
  fi
done

# If one match, use it. If multiple, present choices.
CANDIDATE_COUNT=$(echo "$PLAN_CANDIDATES" | wc -w)
if [ "$CANDIDATE_COUNT" -eq 1 ]; then
  PLAN_FILE="$PLAN_CANDIDATES"
elif [ "$CANDIDATE_COUNT" -gt 1 ]; then
  echo "Multiple plan files found for '$IMPL_TOPIC':"
  for f in $PLAN_CANDIDATES; do
    echo "  - $f"
  done
  # Ask user to choose
elif [ "$CANDIDATE_COUNT" -eq 0 ]; then
  echo "No feature plan found for '$IMPL_TOPIC'."
  echo "Checked: derived/drafts/*-plan-*.md"
  echo ""
  echo "Run /plan-feature first to create an implementation plan."
  # STOP — cannot implement without a plan
fi
```

**Mode C — Plan in conversation**: Plan content is in the current
conversation. Extract to a temp file:

```bash
PLAN_FILE="/tmp/impl_plan_$(date +%Y%m%d_%H%M%S).md"
# Write plan content from conversation into the file
```

### Capture topic

```bash
IMPL_TOPIC="<what is being implemented>"
IMPL_SLUG="<slugified-topic>"
```

## Step 1: Locate Project Config

Hard prerequisite — cannot run TDD without at least `test_command`.

```bash
IMPL_PROJECT_CONFIG=""

# Priority 1: env var
if [ -n "${IMPL_PROJECT_CONFIG:-}" ] && [ -f "$IMPL_PROJECT_CONFIG" ]; then
  echo "Using project config from env: $IMPL_PROJECT_CONFIG"
# Priority 2: .claude/project.json
elif [ -f ".claude/project.json" ]; then
  IMPL_PROJECT_CONFIG=".claude/project.json"
# Priority 3: project.json in project root
elif [ -f "project.json" ]; then
  IMPL_PROJECT_CONFIG="project.json"
else
  echo "ERROR: No project config found."
  echo ""
  echo "The /implement skill requires a project config with at least a test_command."
  echo "Create one at .claude/project.json with this structure:"
  echo ""
  echo '{
  "test_command": "npm test",
  "build_command": "npm run build",
  "lint_command": "npm run lint",
  "test_file_patterns": ["**/*.test.ts"],
  "source_dirs": ["src/"],
  "test_dirs": ["tests/"],
  "language": "typescript",
  "framework": "jest"
}'
  echo ""
  echo "Only test_command is required. Other fields help agents follow project conventions."
  echo "A template is available at: .claude/RLM/configs/project.json"
  # STOP — hard prerequisite
fi

# Validate test_command exists and is non-empty
TEST_CMD=$(jq -r '.test_command // ""' "$IMPL_PROJECT_CONFIG" 2>/dev/null)
if [ -z "$TEST_CMD" ]; then
  echo "ERROR: project config at $IMPL_PROJECT_CONFIG has empty test_command."
  echo "TDD requires a test command. Add one and try again."
  # STOP
fi

echo "Project config: $IMPL_PROJECT_CONFIG"
echo "Test command: $TEST_CMD"
```

## Step 2: Gather Code Context

Run gather-context focused on the plan's topic. This runs in parallel
with Step 1 (both are independent).

```bash
export GC_TASK="Find all files relevant to: $IMPL_TOPIC. I need to understand the current implementation, architecture, tests, and configuration to implement this feature via TDD."

# Standard config resolution
if [ -n "$RLM_ROOT" ]; then
  GC_CONFIG="$RLM_ROOT/internal/gc-worker.json"
  LAUNCHER="$RLM_ROOT/launch.sh"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  GC_CONFIG="$CLAUDE_PLUGIN_ROOT/internal/gc-worker.json"
  LAUNCHER="$CLAUDE_PLUGIN_ROOT/launch.sh"
else
  GC_CONFIG="$(find . -path '*/.claude/RLM/internal/gc-worker.json' -print -quit 2>/dev/null)"
  if [ -z "$GC_CONFIG" ]; then
    GC_CONFIG="$HOME/.claude/RLM/internal/gc-worker.json"
  fi
  LAUNCHER="$(dirname "$(dirname "$GC_CONFIG")")/launch.sh"
fi

# Load defaults, user env vars override
export GC_MAX_AGENTS="${GC_MAX_AGENTS:-$(jq -r '.env_defaults.GC_MAX_AGENTS // "50"' "$GC_CONFIG" 2>/dev/null || echo 50)}"
export GC_EXCLUDE="${GC_EXCLUDE:-$(jq -r '.env_defaults.GC_EXCLUDE // "node_modules,.git,target,dist,build,out,__pycache__,.venv,vendor,.claude,*.lock"' "$GC_CONFIG" 2>/dev/null || echo 'node_modules,.git,target,dist,build,out,__pycache__,.venv,vendor,.claude,*.lock')}"
export GC_MAX_FILE_SIZE="${GC_MAX_FILE_SIZE:-$(jq -r '.env_defaults.GC_MAX_FILE_SIZE // "512000"' "$GC_CONFIG" 2>/dev/null || echo 512000)}"

bash "$LAUNCHER" "$GC_CONFIG" "Task: $GC_TASK
mode: directory
directory: ." \
  > /tmp/gc_implement_result.json 2>/tmp/gc_implement_error.log
```

Validate the result:

```bash
if [ ! -s /tmp/gc_implement_result.json ]; then
  echo "WARNING: Gather-context returned empty result" >&2
  cat /tmp/gc_implement_error.log >&2
  # Continue without GC — the orchestrator can still work from plan + tests
fi
```

Extract high/medium relevance file paths for the orchestrator's context:

```bash
GC_RESULT=$(jq -r '.result' /tmp/gc_implement_result.json 2>/dev/null || echo '{}')
RELEVANT_FILES=$(echo "$GC_RESULT" | jq -r '.findings[]? | select(.relevance == "high" or .relevance == "medium") | .file_path' 2>/dev/null | head -30)
echo "Found $(echo "$RELEVANT_FILES" | wc -l) relevant files"
```

## Step 3: Create Git Worktree

```bash
BRANCH_NAME="implement/$IMPL_SLUG"
WORKTREE_DIR="/tmp/rlm-worktree-$IMPL_SLUG-$(date +%s)"

# Create worktree; add timestamp suffix if branch exists
if ! git worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME" 2>/dev/null; then
  BRANCH_NAME="implement/$IMPL_SLUG-$(date +%s)"
  git worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME"
fi

echo "Created worktree: $WORKTREE_DIR"
echo "Branch: $BRANCH_NAME"
```

## Step 4: Dispatch Implementation Orchestrator

Set env vars and invoke the orchestrator agent:

```bash
export IMPL_PLAN_FILE="$(realpath "$PLAN_FILE")"
export IMPL_PROJECT_CONFIG="$(realpath "$IMPL_PROJECT_CONFIG")"
export IMPL_WORKTREE_DIR="$WORKTREE_DIR"
export IMPL_TOPIC="$IMPL_TOPIC"
export IMPL_MAX_ITERATIONS="${IMPL_MAX_ITERATIONS:-10}"
```

Invoke the implementation-orchestrator agent. It has the implement_agent
skill preloaded, bypassPermissions mode, and access to Read, Bash, Grep,
Glob, and Agent.

```
Use the implementation-orchestrator agent:
All IMPL_* env vars are set in the environment.
RLM_ROOT is set for config resolution.

Implement the feature plan at: $IMPL_PLAN_FILE
Working directory (worktree): $IMPL_WORKTREE_DIR
Project config: $IMPL_PROJECT_CONFIG
Topic: $IMPL_TOPIC

Relevant code context from gather-context:
<list of high/medium relevance file paths and summaries>
```

If the Agent tool is unavailable, fall back to CLI:

```bash
env -u CLAUDECODE \
  IMPL_PLAN_FILE="$IMPL_PLAN_FILE" \
  IMPL_PROJECT_CONFIG="$IMPL_PROJECT_CONFIG" \
  IMPL_WORKTREE_DIR="$WORKTREE_DIR" \
  IMPL_TOPIC="$IMPL_TOPIC" \
  IMPL_MAX_ITERATIONS="${IMPL_MAX_ITERATIONS:-10}" \
  claude -p "Implement the feature plan for: $IMPL_TOPIC" \
    --agent implementation-orchestrator
```

## Step 5: Present Results

Show the user:

1. **Branch name**: `implement/<slug>`
2. **Worktree location**: Path to the worktree
3. **Test results**: Passing/failing counts from final iteration
4. **Iterations used**: N of max
5. **Files changed**: List of created/modified files
6. **Commands to review and merge**:

```bash
# Review changes
cd $WORKTREE_DIR && git log --oneline

# See all changes
git diff main...$BRANCH_NAME

# Merge into current branch (from your main working directory)
git merge $BRANCH_NAME

# Or cherry-pick specific commits
git cherry-pick <commit-hash>

# Discard if unwanted
git worktree remove $WORKTREE_DIR
git branch -D $BRANCH_NAME
```

## Step 6: Cleanup

Remove temp files. Do NOT remove the worktree — user decides.

```bash
rm -f /tmp/gc_implement_result.json /tmp/gc_implement_error.log
rm -f /tmp/gc_*.json 2>/dev/null
rm -f /tmp/impl_plan_*.md 2>/dev/null
# Keep /tmp/impl_* files for debugging if needed
# Do NOT remove the worktree — user decides via merge or discard
```

## What happens inside

This skill orchestrates the full TDD implementation pipeline:

1. **Input resolution** — Find the plan file and project config
2. **Context gathering** — GC workers discover relevant code files
3. **Worktree creation** — Isolated git branch for implementation
4. **Orchestrator dispatch** — implementation-orchestrator manages:
   a. Test-writer creates tests from acceptance criteria
   b. Implementation-worker writes code to pass tests
   c. Verification runs test/build/lint commands via Bash
   d. Verifier analyzes failures and directs next iteration
   e. Loop narrows focus until all pass or convergence criteria met
5. **Result presentation** — Branch, test results, files changed
6. **Cleanup** — Temp files removed, worktree preserved for user

The orchestrator handles all loop complexity. This dispatcher skill
just sets up the environment and presents results.

For trivially small plans (single story, few files), the orchestrator
may complete in 1-2 iterations. For complex multi-story plans, expect
5-10 iterations with focus narrowing.
