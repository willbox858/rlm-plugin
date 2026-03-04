---
name: review
description: "Quality and consistency review of code or documentation. Use when the user says 'review', 'code review', 'review this', 'check quality', 'quality review', 'consistency check', 'review for best practices', 'review the code in', 'what's wrong with this code', 'audit code quality', or wants a thorough review of code or docs with findings and recommendations."
---

# Review — Quality & Consistency Review

Produces a structured review report by gathering the target code or
documentation, optionally scanning the broader codebase for established
patterns to compare against, then analyzing for quality issues,
consistency gaps, and improvement opportunities. Output is an analytical
derived document in `derived/reports/`.

## When to use

- User wants a quality review of code or documentation
- User says "review", "code review", "check quality", "audit"
- Before merging or releasing, want a quality gate check
- User says "what's wrong with this code?" or "review for best practices"
- Want to check if a module follows codebase conventions
- Reviewing generated/derived documents for quality

## When NOT to use

- User wants to check code against a specific design doc (use `/validate`)
- User wants to investigate a failure or bug (use `/diagnose`)
- User wants to understand how something works (use `/create-description` or `/research`)
- User wants a design doc (use `/design`)
- The code is trivially small — just review it directly in conversation
- User wants code changes (use implementation tools)

## Step 0: Determine input mode and review scope

### Input mode

Ask or infer which mode applies:

**Mode A — Specific files**: User provides file paths or directories
to review. Use those as the review scope.

**Mode B — Concept/module**: User names a topic ("the auth module",
"the API handlers") without giving file paths. Auto-run gather-context
to find relevant files — do NOT ask the user for file paths.

**Mode C — Current conversation**: The relevant context is already
small and present in the conversation. Process inline — no file
gathering or RLM dispatch needed. Skip to Step 4.

### Review scope

```bash
REVIEW_TOPIC="<what the user wants reviewed>"              # e.g. "the auth module"
REVIEW_SLUG="<slugified-topic>"                            # e.g. "auth-module"
```

### Review type

Infer from context. Default to `code` if unclear.

- `code` — review code for quality, bugs, patterns, security, performance
- `docs` — review documentation for accuracy, completeness, clarity
- `consistency` — compare target against codebase conventions

```bash
REVIEW_TYPE="code"  # one of: code, docs, consistency
```

Heuristics: source code files -> `code`; markdown/docs -> `docs`;
user says "consistency" or "conventions" -> `consistency`.

## Step 1: Gather inputs IN PARALLEL

Resolve config and launcher once (shared by both branches):

```bash
if [ -n "$RLM_ROOT" ]; then
  GC_CONFIG="$RLM_ROOT/configs/gc.json"
  LAUNCHER="$RLM_ROOT/launch.sh"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  GC_CONFIG="$CLAUDE_PLUGIN_ROOT/configs/gc.json"
  LAUNCHER="$CLAUDE_PLUGIN_ROOT/launch.sh"
else
  GC_CONFIG="$(find . -path '*/.claude/RLM/configs/gc.json' -print -quit 2>/dev/null)"
  if [ -z "$GC_CONFIG" ]; then
    GC_CONFIG="$HOME/.claude/RLM/configs/gc.json"
  fi
  LAUNCHER="$(dirname "$(dirname "$GC_CONFIG")")/launch.sh"
fi

# Load defaults, user env vars override
export GC_MAX_AGENTS="${GC_MAX_AGENTS:-$(jq -r '.env_defaults.GC_MAX_AGENTS // "50"' "$GC_CONFIG" 2>/dev/null || echo 50)}"
export GC_EXCLUDE="${GC_EXCLUDE:-$(jq -r '.env_defaults.GC_EXCLUDE // "node_modules,.git,target,dist,build,out,__pycache__,.venv,vendor,.claude,*.lock"' "$GC_CONFIG" 2>/dev/null || echo 'node_modules,.git,target,dist,build,out,__pycache__,.venv,vendor,.claude,*.lock')}"
export GC_MAX_FILE_SIZE="${GC_MAX_FILE_SIZE:-$(jq -r '.env_defaults.GC_MAX_FILE_SIZE // "512000"' "$GC_CONFIG" 2>/dev/null || echo 512000)}"
```

### Branch A: Gather target files

**For Mode A** (specific files), read directly:

```bash
CONTEXT_TARGETS="/tmp/review_targets_$(date +%Y%m%d_%H%M%S).txt"
for f in $FILES; do
  echo "===== FILE: $f =====" >> "$CONTEXT_TARGETS"
  cat "$f" >> "$CONTEXT_TARGETS"
done
FILE_COUNT=$(echo "$FILES" | wc -w)
```

**For Mode B** (concept/module), dispatch gather-context then build
target context from findings:

```bash
export GC_TASK="Find all files relevant to: $REVIEW_TOPIC. I need the implementation files, tests, and related configuration to perform a quality and consistency review."

bash "$LAUNCHER" "$GC_CONFIG" "Task: $GC_TASK
mode: directory
directory: ." \
  > /tmp/gc_review_result.json 2>/tmp/gc_review_error.log

if [ ! -s /tmp/gc_review_result.json ]; then
  echo "ERROR: Gather-context returned empty result" >&2
  cat /tmp/gc_review_error.log >&2
  exit 1
fi
jq -e '.result' /tmp/gc_review_result.json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: Gather-context returned invalid JSON" >&2
  exit 1
fi

CONTEXT_TARGETS="/tmp/review_targets_$(date +%Y%m%d_%H%M%S).txt"
GC_TARGET_RESULT=$(jq -r '.result' /tmp/gc_review_result.json)
echo "===== GATHER-CONTEXT FINDINGS (TARGET) =====" > "$CONTEXT_TARGETS"
echo "$GC_TARGET_RESULT" >> "$CONTEXT_TARGETS"
echo "" >> "$CONTEXT_TARGETS"

for f in $(echo "$GC_TARGET_RESULT" | jq -r '.findings[]? | select(.relevance == "high" or .relevance == "medium") | .file_path' 2>/dev/null); do
  if [ -f "$f" ]; then
    echo "===== FILE: $f =====" >> "$CONTEXT_TARGETS"
    cat "$f" >> "$CONTEXT_TARGETS"
    echo "" >> "$CONTEXT_TARGETS"
  fi
done
FILE_COUNT=$(grep -c "^===== FILE:" "$CONTEXT_TARGETS" || echo 0)
```

### Branch B: Gather codebase patterns (optional)

Discover established patterns to compare the target against. Skip if:
Mode A with a narrow scope, user only wants bug/quality check, or
the codebase is very small.

```bash
export GC_TASK_PATTERNS="Find files that demonstrate established patterns and conventions in this codebase. I need examples of: error handling, testing patterns, naming conventions, project structure, documentation style, and code organization. Focus on well-established, mature areas of the codebase."

bash "$LAUNCHER" "$GC_CONFIG" "Task: $GC_TASK_PATTERNS
mode: directory
directory: ." \
  > /tmp/gc_review_patterns.json 2>/tmp/gc_review_patterns_error.log

# Soft failure — patterns are optional
GC_PATTERNS_RESULT=""
if [ -s /tmp/gc_review_patterns.json ]; then
  if jq -e '.result' /tmp/gc_review_patterns.json > /dev/null 2>&1; then
    GC_PATTERNS_RESULT=$(jq -r '.result' /tmp/gc_review_patterns.json)
  fi
fi
if [ -z "$GC_PATTERNS_RESULT" ]; then
  echo "WARNING: Pattern scan unavailable — skipping consistency comparison" >&2
fi

# Read top 10 pattern files (avoid duplicates with target set)
CONTEXT_PATTERNS="/tmp/review_patterns_$(date +%Y%m%d_%H%M%S).txt"
if [ -n "$GC_PATTERNS_RESULT" ]; then
  echo "===== CODEBASE PATTERN EXAMPLES =====" > "$CONTEXT_PATTERNS"
  echo "$GC_PATTERNS_RESULT" >> "$CONTEXT_PATTERNS"
  echo "" >> "$CONTEXT_PATTERNS"
  PATTERN_COUNT=0
  for f in $(echo "$GC_PATTERNS_RESULT" | jq -r '.findings[]? | select(.relevance == "high") | .file_path' 2>/dev/null | head -10); do
    if [ -f "$f" ] && ! grep -q "^===== FILE: $f =====$" "$CONTEXT_TARGETS" 2>/dev/null; then
      echo "===== PATTERN FILE: $f =====" >> "$CONTEXT_PATTERNS"
      cat "$f" >> "$CONTEXT_PATTERNS"
      echo "" >> "$CONTEXT_PATTERNS"
      PATTERN_COUNT=$((PATTERN_COUNT + 1))
    fi
  done
  echo "Pattern files: $PATTERN_COUNT"
fi
```

## Step 2: Build review context

Combine target files and pattern files into a single context file:

```bash
CONTEXT="/tmp/review_context_$(date +%Y%m%d_%H%M%S).txt"

echo "===== REVIEW OBJECTIVE =====" > "$CONTEXT"
echo "Review type: $REVIEW_TYPE | Topic: $REVIEW_TOPIC" >> "$CONTEXT"
echo "" >> "$CONTEXT"

echo "===== SECTION 1: REVIEW TARGET =====" >> "$CONTEXT"
cat "$CONTEXT_TARGETS" >> "$CONTEXT"
echo "" >> "$CONTEXT"

if [ -f "$CONTEXT_PATTERNS" ] && [ -s "$CONTEXT_PATTERNS" ]; then
  echo "===== SECTION 2: CODEBASE PATTERNS (BASELINE) =====" >> "$CONTEXT"
  echo "Use these as the baseline for what conventions look like in this project." >> "$CONTEXT"
  cat "$CONTEXT_PATTERNS" >> "$CONTEXT"
  echo "" >> "$CONTEXT"
  HAS_PATTERNS=true
else
  HAS_PATTERNS=false
fi

CONTEXT_SIZE=$(wc -c < "$CONTEXT")
echo "Prepared context: $CONTEXT_SIZE bytes from $FILE_COUNT target files (patterns: $HAS_PATTERNS)"
```

## Step 3: Size check

```bash
echo "Context size: $CONTEXT_SIZE bytes"
```

If under 80,000 characters: read the context file directly and produce
the review report inline. Skip Step 4 and go straight to Step 5.

If 80,000+ characters: continue to Step 4 for RLM dispatch.

## Step 4: Set RLM_TASK and dispatch

Build the review synthesis prompt:

```bash
PATTERN_INSTRUCTION=""
if [ "$HAS_PATTERNS" = true ]; then
  PATTERN_INSTRUCTION="Section 2 contains established codebase patterns — use these as the baseline for consistency analysis. Where the reviewed code follows these conventions, note it as a strength. Where it diverges, determine whether the divergence is intentional or an oversight."
fi

export RLM_TASK="Produce a structured review report for: $REVIEW_TOPIC (review type: $REVIEW_TYPE)

Analyze the target code/documentation in Section 1 for quality, correctness, and consistency. $PATTERN_INSTRUCTION

Structure the report with these 7 sections:

1. **Review Summary** — Overall quality assessment with a rating: Excellent, Good, Acceptable, Needs Work, or Critical Issues. Key stats: files reviewed, issues found by severity (Critical/High/Medium/Low counts).
2. **Scope & Methodology** — What was reviewed, what review type was applied ($REVIEW_TYPE), what was out of scope. If codebase patterns were used as baseline, mention which patterns were compared.
3. **Strengths** — What is done well. Specific examples with file:line or file:function references and code snippets. Important for balanced, actionable reviews.
4. **Issues Found** — Categorized by severity:
   - **Critical** — Bugs, security vulnerabilities, data loss risks
   - **High** — Significant logic errors, missing error handling, broken contracts
   - **Medium** — Code smells, poor naming, missing tests, inconsistency with codebase patterns
   - **Low** — Style issues, minor improvements, documentation gaps
   Each issue: description, file:line reference, actual code snippet (3-10 lines), why it matters, suggested fix.
5. **Consistency Analysis** — How the reviewed code/docs compare to established codebase patterns. Where it follows conventions, where it diverges. Distinguish intentional divergence from oversight. If no patterns were provided, analyze internal consistency only.
6. **Recommendations** — Prioritized improvements. Group by: must-fix (Critical/High), should-fix (Medium), nice-to-have (Low). Each with specific code-level guidance.
7. **Review Notes** — Files reviewed, patterns checked, areas needing deeper investigation, anything uncertain.

Rules:
- Every issue must reference a specific code location (file:line or file:function)
- Include the ACTUAL code snippet for each issue (3-10 lines)
- Suggested fixes must be specific, not generic ('add null check at line 42' not 'improve error handling')
- Distinguish between bugs (wrong behavior) and code smells (works but suboptimal)
- If something looks unusual but might be intentional, flag it as a question rather than an issue
- Balance the review — note strengths, not just problems
- Do not flag style preferences as issues unless they violate established codebase patterns
- Quantify where possible: 'missing error handling in 4 of 7 endpoints', 'no tests for 3 public methods'"
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

## Step 5: Save output

```bash
OUTPUT_DIR="derived/reports"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$OUTPUT_DIR/$REVIEW_SLUG-review-$TIMESTAMP.md"

cat > "$OUTPUT" <<EOF
---
generated: $(date -Iseconds)
type: review
review_type: $REVIEW_TYPE
topic: $REVIEW_TOPIC
files_reviewed: $FILE_COUNT
input_size: $CONTEXT_SIZE bytes
---

# Review: $REVIEW_TOPIC

EOF

# Append the result from RLM or inline processing
echo "$RESULT" >> "$OUTPUT"

echo "Saved to: $OUTPUT"
```

## Step 6: Present and cleanup

1. Show the user the review report (or a summary if it is long)
2. Tell them where the file was saved
3. Highlight the overall rating and critical/high issue counts
4. Note the review type that was applied
5. Clean up temp files:

```bash
rm -f "$CONTEXT"
rm -f "$CONTEXT_TARGETS"
rm -f "$CONTEXT_PATTERNS"
rm -f /tmp/gc_review_result.json /tmp/gc_review_error.log
rm -f /tmp/gc_review_patterns.json /tmp/gc_review_patterns_error.log
rm -f /tmp/gc_*.json 2>/dev/null
```

## What happens inside

This skill uses a two-branch gathering pattern followed by comparative
analysis:

1. **Parallel input gathering:**
   - **Target files** — the code or documentation being reviewed is
     gathered via gather-context workers (or read directly if paths
     are provided). These are the files under review.
   - **Codebase patterns** — a second gather-context pass discovers
     established patterns and conventions in the broader codebase.
     These provide the baseline for consistency comparison. Limited
     to 10 high-relevance pattern files to keep context manageable.

2. **Context assembly** — target files and pattern files are combined
   into a single context file with clear section markers. The review
   objective and type are stated in the preamble.

3. **Review synthesis** — the assembled context is processed (via RLM
   if large) with a review-specific prompt that produces a 7-section
   report: Review Summary (with rating), Scope & Methodology,
   Strengths, Issues Found (by severity), Consistency Analysis,
   Recommendations (prioritized), and Review Notes.

The pattern-scan branch is optional — it is skipped for narrow Mode A
reviews or when the user explicitly scopes the review to quality only.

For small input (under 80K), everything is processed inline — no
sub-agents.
