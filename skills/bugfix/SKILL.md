---
name: bugfix
description: "Diagnose a bug and fix it end-to-end in one step — gathers context, identifies root cause, auto-generates a plan, and dispatches the TDD implementation pipeline in an isolated worktree. Prefer this over /diagnose when the user wants the bug actually fixed, not just analyzed. Trigger when: 'fix this bug', 'bugfix', 'there's a bug in X', 'debug and fix', 'why is this broken and fix it', 'fix the failing test', user wants a bug fixed with a regression test, or user wants diagnosis + fix in one shot."
---

# Bugfix — Diagnose and Fix a Bug End-to-End

Captures bug symptoms, gathers code context, diagnoses the root cause
inline, auto-generates a minimal implementation plan, and dispatches
the existing TDD pipeline — all in one invocation. Every fix includes
a regression test and runs in an isolated git worktree.

## When to use

- User has a bug and wants it fixed, not just diagnosed
- User says "fix this bug", "bugfix", "debug and fix this"
- User says "there's a bug in X", "why is this broken, fix it"
- Failing test needs investigation AND a fix
- User wants diagnosis + code fix in a single step
- Bug spans multiple files and needs a regression test

## When NOT to use

- User only wants a diagnosis report (use `/diagnose`)
- User wants to implement a feature (use `/implement`)
- User wants a code review (use `/review`)
- The fix is trivially obvious — just fix it directly
- User wants to understand root cause without changing code (use `/diagnose`)
- No test infrastructure exists and user doesn't want to set it up

## Step 0: Determine input mode and capture symptoms

### Input mode

Ask or infer which mode applies:

**Mode A — Error output provided**: User provides error messages, stack
traces, test failure output, or log snippets. This is the primary input.

**Mode B — Symptom description**: User describes unexpected behavior
without providing raw error output ("the API returns 500 on auth
endpoints", "tests pass locally but fail in CI"). Extract the symptom
clearly.

**Mode C — Error in current conversation**: Error/failure is visible in
recent conversation context (e.g., from running a test or command).
Capture it from the conversation.

### Symptom capture

```bash
SYMPTOM_SUMMARY="<concise description of the failure>"   # e.g. "Auth middleware returns 401 for valid tokens"
SYMPTOM_SLUG="$(echo "$SYMPTOM_SUMMARY" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')"
ERROR_OUTPUT="<raw error text if provided>"               # full stack trace, test output, etc.

ERROR_FILE="/tmp/bugfix_error_$(date +%Y%m%d_%H%M%S).txt"
echo "$ERROR_OUTPUT" > "$ERROR_FILE"
```

### Extract clues from error output

Parse the error for file paths, line numbers, function names, and module
names before gathering context. These guide the GC task and direct reads.

```bash
ERROR_FILES=$(grep -oE '[a-zA-Z0-9_/.-]+\.(ts|js|py|rs|go|java|cs|cpp|rb|sh):[0-9]+' "$ERROR_FILE" 2>/dev/null | head -20)
ERROR_MODULES=$(grep -oE 'at [a-zA-Z0-9_.]+' "$ERROR_FILE" 2>/dev/null | sed 's/^at //' | head -20)
ERROR_FILE_PATHS=$(echo "$ERROR_FILES" | sed 's/:[0-9]*$//' | sort -u)
ERROR_FILE_COUNT=$(echo "$ERROR_FILE_PATHS" | grep -c '.' || echo 0)
```

## Step 1: Gather inputs IN PARALLEL (two branches)

Run both branches concurrently. They are independent and their results
are merged in Step 2.

### Branch A: Gather code context (guided by error clues)

```bash
export GC_TASK="Find files relevant to this bug: $SYMPTOM_SUMMARY. The error involves these files: $ERROR_FILES. Look for: the failing code, its callers, its dependencies, related tests, configuration, and error handling paths. Focus on the call chain from the error location upward. Also look for related middleware, hooks, validators, and shared utilities that the failing code depends on."

# Resolve config and launcher
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
```

Dispatch the root gather-context-worker:

```bash
bash "$LAUNCHER" "$GC_CONFIG" "Task: $GC_TASK
mode: directory
directory: ." \
  > /tmp/gc_bugfix_result.json 2>/tmp/gc_bugfix_error.log
```

Validate the result:

```bash
if [ ! -s /tmp/gc_bugfix_result.json ]; then
  echo "WARNING: Gather-context returned empty result" >&2
  cat /tmp/gc_bugfix_error.log >&2
  # Continue without GC — diagnosis can still work from direct reads
fi

jq -e '.result' /tmp/gc_bugfix_result.json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "WARNING: Gather-context returned invalid JSON" >&2
  # Continue without GC
fi
```

### Branch B: Read error-referenced files directly

Read files from the error output immediately — do not wait for GC.

```bash
DIRECT_READS="/tmp/bugfix_direct_reads_$(date +%Y%m%d_%H%M%S).txt"

for f in $ERROR_FILE_PATHS; do
  if [ -f "$f" ]; then
    echo "===== FILE: $f =====" >> "$DIRECT_READS"
    cat "$f" >> "$DIRECT_READS"
    echo "" >> "$DIRECT_READS"
  fi
done

DIRECT_FILE_COUNT=$(grep -c "^===== FILE:" "$DIRECT_READS" 2>/dev/null || echo 0)
```

## Step 2: Build diagnostic context

Merge both branches into a single context file ordered for diagnostic
reasoning: symptoms, crash site, broader context.

```bash
CONTEXT="/tmp/bugfix_context_$(date +%Y%m%d_%H%M%S).txt"

echo "===== DIAGNOSTIC GOAL =====" > "$CONTEXT"
echo "Trace the following failure symptoms back to their root cause. Identify the exact code change needed to fix it." >> "$CONTEXT"
echo "" >> "$CONTEXT"

echo "===== SYMPTOMS =====" >> "$CONTEXT"
echo "Summary: $SYMPTOM_SUMMARY" >> "$CONTEXT"
echo "" >> "$CONTEXT"
if [ -f "$ERROR_FILE" ]; then
  cat "$ERROR_FILE" >> "$CONTEXT"
  echo "" >> "$CONTEXT"
fi

if [ -s "$DIRECT_READS" ]; then
  echo "===== ERROR-REFERENCED CODE =====" >> "$CONTEXT"
  cat "$DIRECT_READS" >> "$CONTEXT"
  echo "" >> "$CONTEXT"
fi

GC_RESULT=$(jq -r '.result' /tmp/gc_bugfix_result.json 2>/dev/null || echo '{}')
echo "===== BROADER CODE CONTEXT =====" >> "$CONTEXT"
echo "$GC_RESULT" >> "$CONTEXT"
echo "" >> "$CONTEXT"

for f in $(echo "$GC_RESULT" | jq -r '.findings[]? | select(.relevance == "high" or .relevance == "medium") | .file_path' 2>/dev/null); do
  if [ -f "$f" ]; then
    if ! grep -q "^===== FILE: $f =====$" "$CONTEXT" 2>/dev/null; then
      echo "===== FILE: $f =====" >> "$CONTEXT"
      cat "$f" >> "$CONTEXT"
      echo "" >> "$CONTEXT"
    fi
  fi
done

FILE_COUNT=$(grep -c "^===== FILE:" "$CONTEXT" || echo 0)
CONTEXT_SIZE=$(wc -c < "$CONTEXT")
echo "Prepared context: $CONTEXT_SIZE bytes from $FILE_COUNT files"
```

## Step 3: Diagnose — identify root cause

### Size check

```bash
echo "Context size: $CONTEXT_SIZE bytes"
```

**If under 80,000 characters**: Read the context file directly and
identify the root cause inline. Produce a structured finding with:

- **Root cause**: What code is wrong and why
- **Fix location**: File path, function/method name, line range
- **Expected behavior**: What the code should do instead
- **Regression test idea**: How to reproduce the bug in a test

Skip Step 3b (RLM dispatch) and go straight to Step 4 (plan generation).

**If 80,000+ characters**: Continue to Step 3b for RLM dispatch.

### Step 3b: RLM dispatch for large context

```bash
export RLM_TASK="Diagnose this bug and identify the root cause: $SYMPTOM_SUMMARY

Analyze the diagnostic context to find:
1. ROOT CAUSE: What specific code is wrong and why it causes the observed failure
2. FIX LOCATION: Exact file path, function/method name, and line range where the fix should be applied
3. EXPECTED BEHAVIOR: What the code should do instead
4. REGRESSION TEST: How to reproduce the bug in a test (what input triggers it, what assertion fails)

Rules:
- Every claim must reference specific code (file:line or file:function)
- Include the ACTUAL failing code snippet, not just a description
- The fix must be concrete enough to implement, not abstract advice
- Identify a single root cause if possible; if multiple, rank by likelihood
- Distinguish between the root cause (why it happens) and the trigger (what made it happen now)"
```

Dispatch to rlm-orchestrator:

```
Use the rlm-orchestrator agent:
RLM_TASK is set in the environment.
Process the context at $CONTEXT
Task: $RLM_TASK
```

If the Agent tool is unavailable, fall back to CLI:

```bash
env -u CLAUDECODE \
  RLM_DEPTH=0 \
  RLM_TASK="$RLM_TASK" \
  claude -p "$RLM_TASK" \
    --agent rlm-orchestrator \
    < "$CONTEXT"
```

Capture the diagnosis result as `$DIAGNOSIS_RESULT`.

## Step 4: Generate bugfix plan

Write a plan file compatible with the implementation-orchestrator's
expected markdown format. The plan has a single story with acceptance
criteria derived from the diagnosis.

```bash
PLAN_FILE="/tmp/bugfix_plan_$(date +%Y%m%d_%H%M%S).md"
TIMESTAMP=$(date -Iseconds)

cat > "$PLAN_FILE" <<PLAN_EOF
---
generated: $TIMESTAMP
type: bugfix-plan
symptom: $SYMPTOM_SUMMARY
---

# Bugfix: $SYMPTOM_SUMMARY

## Root Cause

$DIAGNOSIS_RESULT

## Story 1: Fix $SYMPTOM_SUMMARY

### Acceptance Criteria
- [ ] Regression test reproduces the original bug (fails before fix, passes after)
- [ ] <specific behavioral condition from diagnosis — e.g. "Auth middleware returns 200 for valid tokens">
- [ ] Root cause at <file:function from diagnosis> is corrected
- [ ] All existing tests continue to pass

### Technical Tasks
- Write regression test that fails with the current bug
- Fix <specific code change from diagnosis>
- Verify no regressions in existing test suite
PLAN_EOF

echo "Generated bugfix plan: $PLAN_FILE"
```

Fill in the `<placeholders>` with concrete values from the diagnosis
result. The acceptance criteria must be specific enough for the
test-writer agent to create a meaningful regression test.

## Step 5: Locate project config

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
  echo "The /bugfix skill requires a project config with at least a test_command."
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

## Step 6: Create git worktree

```bash
BRANCH_NAME="bugfix/$SYMPTOM_SLUG"
WORKTREE_DIR="/tmp/rlm-worktree-bugfix-$SYMPTOM_SLUG-$(date +%s)"

# Create worktree; add timestamp suffix if branch exists
if ! git worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME" 2>/dev/null; then
  BRANCH_NAME="bugfix/$SYMPTOM_SLUG-$(date +%s)"
  git worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME"
fi

echo "Created worktree: $WORKTREE_DIR"
echo "Branch: $BRANCH_NAME"
```

## Step 7: Dispatch implementation orchestrator

Set env vars and invoke the orchestrator agent:

```bash
export IMPL_PLAN_FILE="$(realpath "$PLAN_FILE")"
export IMPL_PROJECT_CONFIG="$(realpath "$IMPL_PROJECT_CONFIG")"
export IMPL_WORKTREE_DIR="$WORKTREE_DIR"
export IMPL_TOPIC="Bugfix: $SYMPTOM_SUMMARY"
export IMPL_MAX_ITERATIONS="${IMPL_MAX_ITERATIONS:-10}"
```

Invoke the implementation-orchestrator agent. It has the implement_agent
skill preloaded, bypassPermissions mode, and access to Read, Bash, Grep,
Glob, and Agent.

```
Use the implementation-orchestrator agent:
All IMPL_* env vars are set in the environment.
RLM_ROOT is set for config resolution.

Implement the bugfix plan at: $IMPL_PLAN_FILE
Working directory (worktree): $IMPL_WORKTREE_DIR
Project config: $IMPL_PROJECT_CONFIG
Topic: $IMPL_TOPIC

This is a bugfix — prioritize writing the regression test first (it
must fail before the fix and pass after). The plan has a single story.

Relevant code context from gather-context:
<list of high/medium relevance file paths and summaries>
```

If the Agent tool is unavailable, fall back to CLI:

```bash
env -u CLAUDECODE \
  IMPL_PLAN_FILE="$IMPL_PLAN_FILE" \
  IMPL_PROJECT_CONFIG="$IMPL_PROJECT_CONFIG" \
  IMPL_WORKTREE_DIR="$WORKTREE_DIR" \
  IMPL_TOPIC="Bugfix: $SYMPTOM_SUMMARY" \
  IMPL_MAX_ITERATIONS="${IMPL_MAX_ITERATIONS:-10}" \
  claude -p "Implement the bugfix plan for: $SYMPTOM_SUMMARY" \
    --agent implementation-orchestrator
```

## Step 8: Present results

Show the user a brief explanation:

1. **What was wrong**: Root cause summary (2-3 sentences from diagnosis)
2. **What was changed**: List of files created/modified
3. **Test results**: Passing/failing counts from final iteration
4. **Branch name**: `bugfix/<slug>`
5. **Commands to review and merge**:

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

## Step 9: Cleanup

Remove temp files. Do NOT remove the worktree — user decides.

```bash
rm -f "$CONTEXT"
rm -f "$ERROR_FILE"
rm -f "$DIRECT_READS"
rm -f "$PLAN_FILE"
rm -f /tmp/gc_bugfix_result.json /tmp/gc_bugfix_error.log
rm -f /tmp/gc_*.json 2>/dev/null
# Do NOT remove the worktree — user decides via merge or discard
```

## What happens inside

This skill combines diagnosis and implementation in a single flow:

1. **Symptom capture** — error output, descriptions, or conversation
   context parsed for file paths, modules, and clues.

2. **Parallel input gathering** — two independent branches:
   - **Branch A** — gather-context workers search the codebase guided
     by file paths and module names from the error output.
   - **Branch B** — files referenced in the error are read immediately,
     giving direct access to the crash site without waiting for GC.

3. **Context assembly** — three sections assembled in diagnostic order:
   symptoms, error-referenced code, broader code context. Duplicates
   between branches are eliminated.

4. **Diagnosis** — the assembled context is processed (via RLM if 80K+)
   to identify the root cause, fix location, expected behavior, and
   regression test approach. The diagnosis is NOT saved as a report —
   it feeds directly into plan generation.

5. **Plan generation** — a single-story implementation plan is written
   to a temp file in the same markdown format that
   implementation-orchestrator expects. Acceptance criteria come from
   the diagnosis.

6. **TDD execution** — the existing implementation pipeline runs in a
   git worktree: regression test first (must fail), then fix (test
   passes), then verify no regressions.

7. **Results** — brief explanation of root cause, files changed, test
   results, and merge commands.

The key innovation is auto-generating the plan file from diagnosis
output, bridging the gap between `/diagnose` (analysis only) and
`/implement` (requires a pre-existing plan).
