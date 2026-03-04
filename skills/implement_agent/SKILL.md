---
name: implement_agent
description: "Shared methodology for implementation agents (orchestrator, worker, test-writer, verifier). Covers TDD protocol, verification workflow, iterative narrowing, convergence criteria, iteration tracking, git discipline, and project config loading. Used by all agents in the /implement pipeline."
---

# Implementation Agent Methodology

# TDD Protocol

Tests first, implementation second. This is the core invariant.

1. Test-writer creates tests from acceptance criteria in the plan
2. Implementation-worker writes code to make tests pass
3. Verifier analyzes failures and directs the next iteration

**Hard rules:**
- Never modify tests to make them pass unless the verifier explicitly
  identifies a test bug (status: `fail_tests`)
- If acceptance criteria change, that's a new story — not a test fix
- The test-writer owns test files. The implementation-worker owns source files.
- Only the test-writer in fix mode may modify test files, and only when
  the verifier's verdict is `fail_tests`

# Verification Protocol

Run commands in this exact order. Capture all output (stdout + stderr)
to a single file for verifier analysis.

1. **Tests**: Run `test_command` from project config. Record exit code.
2. **Build**: Run `build_command` from project config (if non-empty). Record exit code.
3. **Lint**: Run `lint_command` from project config (if non-empty). Record exit code.

All commands run from `$IMPL_WORKTREE_DIR`. Example:

```bash
cd "$IMPL_WORKTREE_DIR"
TEST_CMD=$(jq -r '.test_command' "$IMPL_PROJECT_CONFIG")
BUILD_CMD=$(jq -r '.build_command // ""' "$IMPL_PROJECT_CONFIG")
LINT_CMD=$(jq -r '.lint_command // ""' "$IMPL_PROJECT_CONFIG")

{
  echo "===== TESTS ====="
  eval "$TEST_CMD" 2>&1; echo "TEST_EXIT_CODE=$?"

  if [ -n "$BUILD_CMD" ]; then
    echo "===== BUILD ====="
    eval "$BUILD_CMD" 2>&1; echo "BUILD_EXIT_CODE=$?"
  fi

  if [ -n "$LINT_CMD" ]; then
    echo "===== LINT ====="
    eval "$LINT_CMD" 2>&1; echo "LINT_EXIT_CODE=$?"
  fi
} > /tmp/impl_verify_$IMPL_ITERATION.txt 2>&1
```

# Narrowing Strategy

- **First iteration**: Implementation-worker addresses the full story scope
- **Subsequent iterations**: Worker focuses ONLY on `IMPL_FOCUS` areas
  from the verifier's verdict
- Scope shrinks with each iteration — never re-implement passing parts
- Verifier's `focus_areas` field directs exactly where to look next
- Focus areas are specific: `src/auth.ts:handleLogin` not `auth module`

# Convergence Criteria

**DONE**: All verification steps pass (test + build + lint exit code 0).

**STUCK**: Same failures appear for 3 consecutive iterations. Stop and
report partial progress. The user needs to intervene.

**MAX_ITERATIONS**: Default 10. When reached, report what passed and
what didn't. Not a failure — partial progress is valuable.

Track failure counts across iterations:
- If failures are decreasing → making progress, continue
- If failures are constant for 3 iterations → stuck, stop
- If failures are increasing → regressing, the verifier should flag this

# Iteration Tracking

Each iteration is numbered starting from 0. The orchestrator tracks:

- Iteration number
- Test pass/fail count
- Build status (pass/fail)
- Lint status (pass/fail)
- Focus areas from verifier

The verifier includes a `progress` field in its verdict:
- `"improving"` — fewer failures than previous iteration
- `"stalled"` — same failure count and same failures
- `"regressing"` — more failures than previous iteration

# Git Discipline

All work happens in a git worktree on a separate branch. Never commit
to the user's current branch.

- Commit after each iteration (even partial progress)
- Test-writer phase: `implement: tests for <story-title>`
- Implementation iterations: `implement: <story-title> (iteration N)`
- Final success: `implement: <story-title> (iteration N) — ALL PASS`
- Use `git add -A` within the worktree (worktree is isolated, safe)

# Project Config

The project config provides test/build/lint commands and project
conventions. Located at (in priority order):

1. `$IMPL_PROJECT_CONFIG` (env var, highest priority)
2. `.claude/project.json` (standard location)
3. `project.json` (project root)

Structure:
```json
{
  "test_command": "npm test",
  "build_command": "npm run build",
  "lint_command": "npm run lint",
  "test_file_patterns": ["**/*.test.ts", "**/*.spec.ts"],
  "source_dirs": ["src/"],
  "test_dirs": ["tests/", "src/__tests__/"],
  "language": "typescript",
  "framework": "jest"
}
```

- `test_command` is required (hard prerequisite for TDD)
- All other fields are optional but help agents follow conventions
- `test_file_patterns` and `test_dirs` help test-writer place files
- `source_dirs` helps implementation-worker scope changes
- `language` and `framework` help agents match project style

# Environment Variables

Set by the dispatcher skill and passed to all agents:

- `IMPL_PLAN_FILE` — Path to the feature plan file being implemented
- `IMPL_PROJECT_CONFIG` — Path to the project config file
- `IMPL_WORKTREE_DIR` — Path to the git worktree where all changes happen
- `IMPL_TOPIC` — Feature topic being implemented (human-readable)
- `IMPL_FOCUS` — Comma-separated focus areas from verifier (empty on first iteration)
- `IMPL_ITERATION` — Current iteration number (0-based)
- `IMPL_MAX_ITERATIONS` — Maximum iterations before stopping (default: 10)
- `RLM_ROOT` — Absolute path to `.claude/RLM/` for config/launcher resolution

# Config Resolution Pattern

All agents resolve the launcher and configs using the standard pattern:

```bash
if [ -n "$RLM_ROOT" ]; then
  LAUNCHER="$RLM_ROOT/launch.sh"
  WORKER_CONFIG="$RLM_ROOT/internal/impl-worker.json"
  TEST_WRITER_CONFIG="$RLM_ROOT/internal/impl-test-writer.json"
  VERIFIER_CONFIG="$RLM_ROOT/internal/impl-verifier.json"
  GC_CONFIG="$RLM_ROOT/internal/gc-worker.json"
  RLM_CONFIG="$RLM_ROOT/internal/rlm-child.json"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  LAUNCHER="$CLAUDE_PLUGIN_ROOT/launch.sh"
  WORKER_CONFIG="$CLAUDE_PLUGIN_ROOT/internal/impl-worker.json"
  TEST_WRITER_CONFIG="$CLAUDE_PLUGIN_ROOT/internal/impl-test-writer.json"
  VERIFIER_CONFIG="$CLAUDE_PLUGIN_ROOT/internal/impl-verifier.json"
  GC_CONFIG="$CLAUDE_PLUGIN_ROOT/internal/gc-worker.json"
  RLM_CONFIG="$CLAUDE_PLUGIN_ROOT/internal/rlm-child.json"
else
  # Fallback: find configs relative to project
  WORKER_CONFIG="$(find . -path '*/.claude/RLM/internal/impl-worker.json' -print -quit 2>/dev/null)"
  CONFIGS_DIR="$(dirname "$WORKER_CONFIG")"
  LAUNCHER="$(dirname "$CONFIGS_DIR")/launch.sh"
  TEST_WRITER_CONFIG="$CONFIGS_DIR/impl-test-writer.json"
  VERIFIER_CONFIG="$CONFIGS_DIR/impl-verifier.json"
  GC_CONFIG="$CONFIGS_DIR/gc.json"
  RLM_CONFIG="$CONFIGS_DIR/rlm.json"
fi
```

# Structured Output

All implementation agents return JSON matching this schema:

```json
{"result": "<answer or status>"}
```

Error reporting:

```json
{"result": "ERROR: <brief description>"}
```

The verifier returns a structured verdict inside the result string:

```json
{"result": "{\"status\":\"pass|fail_code|fail_tests|fail_build|fail_lint\",\"analysis\":\"...\",\"focus_areas\":[...],\"failing_tests\":[...],\"iteration\":N,\"progress\":\"improving|stalled|regressing\"}"}
```

Status priority (fix in this order):
1. `fail_build` — Build errors prevent tests from running
2. `fail_lint` — Lint errors indicate structural issues
3. `fail_tests` — Test bugs need fixing before judging code
4. `fail_code` — Code doesn't satisfy test expectations
5. `pass` — All verification steps succeed
