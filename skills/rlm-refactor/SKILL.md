---
name: rlm-refactor
description: "Restructure working code in an isolated git worktree while proving behavioral equivalence — runs existing tests before and after to guarantee zero functional change. Gathers code context, generates a multi-step refactoring plan, then dispatches the TDD implementation pipeline. Prefer this over /rlm-implement when all tests already pass and the goal is structural improvement, not new behavior. Trigger when: 'refactor', 'restructure', 'extract method', 'split module', 'reduce duplication', 'clean up this code', 'move X into its own file', 'decouple', 'rename across files', 'simplify', 'decompose', user wants to reorganize code without changing what it does."
---

# Refactor — Restructure Code with Behavioral Equivalence

Restructures working code in an isolated git worktree, proving that
behavior is preserved by running the full test suite before and after.
Gathers code context, auto-generates a multi-step refactoring plan with
acceptance criteria, and dispatches the existing TDD implementation
pipeline.

The fundamental constraint: every existing test must pass before the
refactor begins, and every existing test must still pass when it ends.
If tests fail before starting, this is a bugfix — not a refactor.

## When to use

- User wants to restructure code without changing behavior
- User says "refactor", "restructure", "clean up", "decompose"
- Extract method/class, split module, reduce duplication
- Rename across files, move code between modules
- Decouple tightly-coupled components
- Simplify overly complex functions or class hierarchies
- Consolidate scattered logic into a cohesive module
- Improve code organization while preserving all existing behavior

## When NOT to use

- Tests are failing — fix them first (use `/rlm-bugfix`)
- User wants new functionality (use `/rlm-implement`)
- User wants a review without changes (use `/rlm-review`)
- User wants to understand code structure (use `/rlm-describe`)
- The refactor is trivially small — just do it directly
- No test suite exists and user doesn't want to create one

## Step 0: Capture refactoring intent

### Input mode

Ask or infer which mode applies:

**Mode A — Specific target**: User names files, classes, or modules to
refactor ("refactor the auth middleware", "split UserService into
separate concerns"). Extract the target and desired structural change.

**Mode B — Goal-driven**: User describes the desired outcome without
naming specific files ("reduce duplication in the API handlers",
"decouple the database layer"). Extract the structural goal.

**Mode C — Conversation context**: Refactoring need emerged from an
earlier discussion (e.g., after a review or design session). Extract
the target and goal from conversation history.

### Intent capture

```bash
REFACTOR_TOPIC="<what the user wants refactored>"    # e.g. "Split UserService into UserAuth and UserProfile"
REFACTOR_SLUG="$(echo "$REFACTOR_TOPIC" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')"
REFACTOR_GOAL="<the structural improvement desired>" # e.g. "Separate authentication concerns from profile management"
```

## Step 1: Locate project config

Hard prerequisite — behavioral equivalence requires a test suite.

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
  echo "The /rlm-refactor skill requires a project config with at least a test_command."
  echo "A test suite is essential — refactoring without tests cannot guarantee"
  echo "behavioral equivalence. Create one at .claude/project.json:"
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
  echo "Refactoring requires a test suite to prove behavioral equivalence."
  # STOP
fi

# Also grab build and lint commands for full verification
BUILD_CMD=$(jq -r '.build_command // ""' "$IMPL_PROJECT_CONFIG" 2>/dev/null)
LINT_CMD=$(jq -r '.lint_command // ""' "$IMPL_PROJECT_CONFIG" 2>/dev/null)

echo "Project config: $IMPL_PROJECT_CONFIG"
echo "Test command: $TEST_CMD"
```

## Step 2: Run baseline tests (pre-refactor snapshot)

This is the behavioral equivalence baseline. If tests fail here, the
code has bugs — stop and tell the user to fix them first (or use
`/rlm-bugfix`).

```bash
BASELINE_OUTPUT="/tmp/refactor_baseline_$(date +%Y%m%d_%H%M%S).txt"

echo "Running baseline tests to establish behavioral equivalence..."
echo "===== BASELINE TEST RUN =====" > "$BASELINE_OUTPUT"
echo "Timestamp: $(date -Iseconds)" >> "$BASELINE_OUTPUT"
echo "" >> "$BASELINE_OUTPUT"

# Run test command
echo "--- test_command: $TEST_CMD ---" >> "$BASELINE_OUTPUT"
eval "$TEST_CMD" >> "$BASELINE_OUTPUT" 2>&1
TEST_EXIT=$?
echo "Exit code: $TEST_EXIT" >> "$BASELINE_OUTPUT"
echo "" >> "$BASELINE_OUTPUT"

# Run build command if present
if [ -n "$BUILD_CMD" ]; then
  echo "--- build_command: $BUILD_CMD ---" >> "$BASELINE_OUTPUT"
  eval "$BUILD_CMD" >> "$BASELINE_OUTPUT" 2>&1
  BUILD_EXIT=$?
  echo "Exit code: $BUILD_EXIT" >> "$BASELINE_OUTPUT"
  echo "" >> "$BASELINE_OUTPUT"
else
  BUILD_EXIT=0
fi

# Run lint command if present
if [ -n "$LINT_CMD" ]; then
  echo "--- lint_command: $LINT_CMD ---" >> "$BASELINE_OUTPUT"
  eval "$LINT_CMD" >> "$BASELINE_OUTPUT" 2>&1
  LINT_EXIT=$?
  echo "Exit code: $LINT_EXIT" >> "$BASELINE_OUTPUT"
  echo "" >> "$BASELINE_OUTPUT"
else
  LINT_EXIT=0
fi

# Check baseline health
if [ "$TEST_EXIT" -ne 0 ]; then
  echo "STOP: Baseline tests are failing (exit code $TEST_EXIT)."
  echo "Refactoring requires a green test suite as the starting point."
  echo "Fix the failing tests first (consider /rlm-bugfix), then retry."
  echo ""
  echo "Baseline output saved to: $BASELINE_OUTPUT"
  cat "$BASELINE_OUTPUT"
  # STOP — cannot refactor with failing tests
fi

if [ "$BUILD_EXIT" -ne 0 ]; then
  echo "STOP: Baseline build is failing (exit code $BUILD_EXIT)."
  echo "Fix the build first, then retry."
  # STOP
fi

# Extract test counts from baseline for later comparison
BASELINE_SUMMARY=$(tail -20 "$BASELINE_OUTPUT")
echo "Baseline: tests PASS (exit $TEST_EXIT), build PASS (exit $BUILD_EXIT), lint exit $LINT_EXIT"
```

Lint warnings are not a blocker — the refactor may fix some. Record
the lint exit code but only block on test and build failures.

## Step 3: Gather code context IN PARALLEL (two branches)

Both branches run concurrently and merge in Step 4.

### Branch A: Gather refactoring target and its dependencies

```bash
export GC_TASK="Find files relevant to this refactoring: $REFACTOR_TOPIC. Goal: $REFACTOR_GOAL. I need: the target code to be refactored, all files that import/depend on it (callers), all files it imports/depends on (dependencies), related tests, and configuration files. The refactoring must not break any callers, so finding the full dependency graph is critical."

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

Dispatch the root gather-context worker:

```bash
bash "$LAUNCHER" "$GC_CONFIG" "Task: $GC_TASK
mode: directory
directory: ." \
  > /tmp/gc_refactor_result.json 2>/tmp/gc_refactor_error.log
```

Validate:

```bash
if [ ! -s /tmp/gc_refactor_result.json ]; then
  echo "WARNING: Gather-context returned empty result" >&2
  cat /tmp/gc_refactor_error.log >&2
fi

jq -e '.result' /tmp/gc_refactor_result.json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "WARNING: Gather-context returned invalid JSON" >&2
fi
```

### Branch B: Read user-specified files directly (Mode A only)

If the user provided specific file paths, read them immediately without
waiting for GC:

```bash
DIRECT_READS="/tmp/refactor_direct_reads_$(date +%Y%m%d_%H%M%S).txt"

if [ -n "$USER_FILES" ]; then
  for f in $USER_FILES; do
    if [ -f "$f" ]; then
      echo "===== FILE: $f =====" >> "$DIRECT_READS"
      cat "$f" >> "$DIRECT_READS"
      echo "" >> "$DIRECT_READS"
    fi
  done
  DIRECT_FILE_COUNT=$(grep -c "^===== FILE:" "$DIRECT_READS" 2>/dev/null || echo 0)
  echo "Direct reads: $DIRECT_FILE_COUNT files"
fi
```

## Step 4: Build refactoring context and generate plan

Merge both branches into a single context file.

```bash
CONTEXT="/tmp/refactor_context_$(date +%Y%m%d_%H%M%S).txt"

echo "===== REFACTORING OBJECTIVE =====" > "$CONTEXT"
echo "Topic: $REFACTOR_TOPIC" >> "$CONTEXT"
echo "Goal: $REFACTOR_GOAL" >> "$CONTEXT"
echo "Constraint: ALL existing tests must continue to pass. Zero behavioral change." >> "$CONTEXT"
echo "" >> "$CONTEXT"

echo "===== BASELINE TEST STATUS =====" >> "$CONTEXT"
echo "All tests passing. All builds passing." >> "$CONTEXT"
echo "$BASELINE_SUMMARY" >> "$CONTEXT"
echo "" >> "$CONTEXT"

# Add direct reads first (crash-site equivalent)
if [ -s "$DIRECT_READS" ]; then
  echo "===== USER-SPECIFIED FILES =====" >> "$CONTEXT"
  cat "$DIRECT_READS" >> "$CONTEXT"
  echo "" >> "$CONTEXT"
fi

# Add GC findings
GC_RESULT=$(jq -r '.result' /tmp/gc_refactor_result.json 2>/dev/null || echo '{}')
echo "===== CODEBASE CONTEXT =====" >> "$CONTEXT"
echo "$GC_RESULT" >> "$CONTEXT"
echo "" >> "$CONTEXT"

# Read high/medium relevance files from GC
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

### Generate refactoring plan

#### Size check

```bash
echo "Context size: $CONTEXT_SIZE bytes"
```

**If under 80,000 characters**: read the context file directly and
generate the plan inline.

**If 80,000+ characters**: dispatch to RLM.

#### Plan generation prompt

Whether inline or via RLM, use this prompt to produce the plan:

```bash
PLAN_PROMPT="Generate a multi-step refactoring plan for: $REFACTOR_TOPIC
Goal: $REFACTOR_GOAL

CRITICAL CONSTRAINT: This is a refactor — all existing tests must continue to pass.
No behavioral changes. The test suite is the contract.

Analyze the code context and produce a plan with sequenced stories.
Each story should be a single, independently verifiable refactoring step.
Order them so that each step leaves the codebase in a valid state (tests pass).

For each story, provide:
- A clear title describing the structural change
- Acceptance criteria focused on structural properties AND test equivalence
- Technical tasks with specific file paths and code references
- Dependencies on previous stories (if any)
- Risk assessment (what could break callers, imports, or tests)

Common refactoring patterns to consider:
- Extract method/function — pull complex logic into a named function
- Extract class/module — split a large file into focused units
- Move code — relocate functions/classes to more appropriate modules
- Rename — consistent renaming across all references
- Inline — remove unnecessary indirection
- Replace conditional with polymorphism
- Introduce interface/protocol — decouple concrete dependencies
- Consolidate duplicates — merge repeated code into shared utility

Rules:
- Every story must include 'All existing tests pass' as an acceptance criterion
- Reference specific file paths and function/class names from the context
- Each step must leave the codebase compilable and all tests green
- Identify callers/importers that need updating when moving or renaming
- If a step risks breaking callers, list them explicitly
- Prefer small, focused steps over large sweeping changes
- Order steps to minimize risk: rename before move, move before split"
```

For RLM dispatch:

```bash
export RLM_TASK="$PLAN_PROMPT"
```

```
Use the rlm-process agent:
RLM_TASK is set in the environment.
Process the context at $CONTEXT
Task: $RLM_TASK
```

CLI fallback:

```bash
env -u CLAUDECODE \
  RLM_DEPTH=0 \
  RLM_TASK="$PLAN_PROMPT" \
  claude -p "$PLAN_PROMPT" \
    --agent rlm-process \
    < "$CONTEXT"
```

Capture the result as `$PLAN_RESULT`.

## Step 5: Write plan file

Write the plan in the format the implementation-orchestrator expects:

```bash
PLAN_FILE="/tmp/refactor_plan_$(date +%Y%m%d_%H%M%S).md"
TIMESTAMP=$(date -Iseconds)

cat > "$PLAN_FILE" <<PLAN_EOF
---
generated: $TIMESTAMP
type: refactor-plan
topic: $REFACTOR_TOPIC
goal: $REFACTOR_GOAL
baseline_tests: pass
baseline_build: pass
---

# Refactor: $REFACTOR_TOPIC

## Goal

$REFACTOR_GOAL

## Equivalence Constraint

All existing tests must pass before and after every story.
This is a structural change — zero behavioral change permitted.

$PLAN_RESULT
PLAN_EOF

echo "Generated refactoring plan: $PLAN_FILE"
```

Each story in the plan result should already have acceptance criteria
from the generation prompt. Verify that every story includes an
"All existing tests pass" criterion — if any is missing, append it.

## Step 6: Create git worktree

```bash
BRANCH_NAME="refactor/$REFACTOR_SLUG"
WORKTREE_DIR="/tmp/rlm-worktree-refactor-$REFACTOR_SLUG-$(date +%s)"

# Create worktree; add timestamp suffix if branch exists
if ! git worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME" 2>/dev/null; then
  BRANCH_NAME="refactor/$REFACTOR_SLUG-$(date +%s)"
  git worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME"
fi

echo "Created worktree: $WORKTREE_DIR"
echo "Branch: $BRANCH_NAME"
```

## Step 7: Dispatch implementation orchestrator

The implementation-orchestrator handles the TDD loop. For refactoring,
the key difference is that no new tests are written — the existing test
suite IS the acceptance test. The test-writer phase will still run but
the plan's acceptance criteria focus on structural properties, and the
"All existing tests pass" criterion is verified by the existing suite.

```bash
export IMPL_PLAN_FILE="$(realpath "$PLAN_FILE")"
export IMPL_PROJECT_CONFIG="$(realpath "$IMPL_PROJECT_CONFIG")"
export IMPL_WORKTREE_DIR="$WORKTREE_DIR"
export IMPL_TOPIC="Refactor: $REFACTOR_TOPIC"
export IMPL_MAX_ITERATIONS="${IMPL_MAX_ITERATIONS:-10}"
```

```
Use the implementation-orchestrator agent:
All IMPL_* env vars are set in the environment.
RLM_ROOT is set for config resolution.

Implement the refactoring plan at: $IMPL_PLAN_FILE
Working directory (worktree): $IMPL_WORKTREE_DIR
Project config: $IMPL_PROJECT_CONFIG
Topic: $IMPL_TOPIC

This is a REFACTOR — the primary success criterion is that all existing
tests continue to pass after every step. No new behavior is being added.
The test-writer should focus on verifying structural properties where
testable (e.g., that a new module exports the expected interface), but
the existing test suite is the main contract.

If any existing test breaks during implementation, that is a regression
and must be fixed in the source code (not by modifying the test). Tests
should only be modified if they directly reference internal structure
that changed (e.g., import paths) — never to weaken assertions.

Relevant code context from gather-context:
<list of high/medium relevance file paths and summaries>
```

CLI fallback:

```bash
env -u CLAUDECODE \
  IMPL_PLAN_FILE="$IMPL_PLAN_FILE" \
  IMPL_PROJECT_CONFIG="$IMPL_PROJECT_CONFIG" \
  IMPL_WORKTREE_DIR="$WORKTREE_DIR" \
  IMPL_TOPIC="Refactor: $REFACTOR_TOPIC" \
  IMPL_MAX_ITERATIONS="${IMPL_MAX_ITERATIONS:-10}" \
  claude -p "Implement the refactoring plan for: $REFACTOR_TOPIC" \
    --agent implementation-orchestrator
```

## Step 8: Post-refactor equivalence check

After the orchestrator reports success, run the full test suite one
final time from the worktree to confirm equivalence:

```bash
cd "$WORKTREE_DIR"

POST_OUTPUT="/tmp/refactor_post_$(date +%Y%m%d_%H%M%S).txt"

echo "Running post-refactor equivalence check..."
echo "===== POST-REFACTOR TEST RUN =====" > "$POST_OUTPUT"

echo "--- test_command: $TEST_CMD ---" >> "$POST_OUTPUT"
eval "$TEST_CMD" >> "$POST_OUTPUT" 2>&1
POST_TEST_EXIT=$?
echo "Exit code: $POST_TEST_EXIT" >> "$POST_OUTPUT"

if [ -n "$BUILD_CMD" ]; then
  echo "--- build_command: $BUILD_CMD ---" >> "$POST_OUTPUT"
  eval "$BUILD_CMD" >> "$POST_OUTPUT" 2>&1
  POST_BUILD_EXIT=$?
  echo "Exit code: $POST_BUILD_EXIT" >> "$POST_OUTPUT"
else
  POST_BUILD_EXIT=0
fi

if [ -n "$LINT_CMD" ]; then
  echo "--- lint_command: $LINT_CMD ---" >> "$POST_OUTPUT"
  eval "$LINT_CMD" >> "$POST_OUTPUT" 2>&1
  POST_LINT_EXIT=$?
  echo "Exit code: $POST_LINT_EXIT" >> "$POST_OUTPUT"
else
  POST_LINT_EXIT=0
fi

echo ""
echo "=== EQUIVALENCE REPORT ==="
echo "           Before  After"
echo "Tests:     PASS    $([ $POST_TEST_EXIT -eq 0 ] && echo 'PASS' || echo 'FAIL')"
echo "Build:     PASS    $([ $POST_BUILD_EXIT -eq 0 ] && echo 'PASS' || echo 'FAIL')"
echo "Lint:      exit $LINT_EXIT   exit $POST_LINT_EXIT"

if [ "$POST_TEST_EXIT" -ne 0 ] || [ "$POST_BUILD_EXIT" -ne 0 ]; then
  echo ""
  echo "WARNING: Post-refactor verification failed."
  echo "The worktree is preserved for investigation."
  echo "Review the failures: cat $POST_OUTPUT"
fi

cd -
```

## Step 9: Present results

Show the user:

1. **What changed**: Structural summary of the refactoring (what was
   split, moved, renamed, extracted)
2. **Equivalence status**: Before/after test results comparison
3. **Files modified**: List of created, modified, and deleted files
4. **Lint delta**: Whether lint warnings improved, stayed same, or got
   worse (informational, not a blocker)
5. **Branch name**: `refactor/<slug>`
6. **Commands to review and merge**:

```bash
# Review the structural changes
cd $WORKTREE_DIR && git log --oneline

# See all changes
git diff main...$BRANCH_NAME

# Diff stats (quick overview)
git diff --stat main...$BRANCH_NAME

# Merge into current branch (from your main working directory)
git merge $BRANCH_NAME

# Or cherry-pick specific commits
git cherry-pick <commit-hash>

# Discard if unwanted
git worktree remove $WORKTREE_DIR
git branch -D $BRANCH_NAME
```

## Step 10: Cleanup

Remove temp files. Do NOT remove the worktree — user decides.

```bash
rm -f "$CONTEXT"
rm -f "$BASELINE_OUTPUT"
rm -f "$POST_OUTPUT"
rm -f "$DIRECT_READS"
rm -f "$PLAN_FILE"
rm -f /tmp/gc_refactor_result.json /tmp/gc_refactor_error.log
rm -f /tmp/gc_*.json 2>/dev/null
# Do NOT remove the worktree — user decides via merge or discard
```

## What happens inside

This skill orchestrates a refactoring workflow with behavioral
equivalence as the core constraint:

1. **Intent capture** — the user's structural goal is extracted (what
   to refactor and how), not a bug symptom. The input is working code,
   not broken code.

2. **Baseline snapshot** — the full test suite runs against the current
   codebase. If any test fails, the skill stops — you cannot refactor
   code that is already broken. This baseline is the behavioral
   contract.

3. **Parallel context gathering** — gather-context workers search the
   codebase for the target code AND its callers/dependents (critical
   for refactoring, since restructuring can break import paths and
   call sites). User-specified files are read directly in parallel.

4. **Plan generation** — the gathered context is analyzed (via RLM if
   large) to produce a multi-step refactoring plan. Each step is
   sequenced so the codebase stays valid at every intermediate point.
   Every story includes "All existing tests pass" as an acceptance
   criterion.

5. **TDD execution** — the implementation pipeline runs in a git
   worktree. Unlike bugfix (which creates a regression test) or
   feature implementation (which creates tests from acceptance
   criteria), refactoring relies primarily on the existing test suite
   as its safety net. The test-writer may add structural verification
   tests (e.g., checking that a new module exports the right
   interface), but never weakens existing assertions.

6. **Post-refactor equivalence check** — the full test suite runs one
   final time to produce a clean before/after comparison. The user
   sees concrete proof that behavior is unchanged.

7. **Results** — structural summary, equivalence report, file list,
   and merge commands.

The key difference from `/rlm-bugfix`: bugfix is symptom-driven
(starts from errors, diagnoses root cause, creates regression tests).
Refactor is intent-driven (starts from working code, preserves
behavior, restructures for clarity). The back half (TDD pipeline in
a worktree) is shared; the front half is fundamentally different.
