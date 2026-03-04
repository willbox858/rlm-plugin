---
name: rlm-diagnose
description: "Systematic root cause analysis that traces failures across multiple components, cross-references design docs, and produces a structured diagnosis report. Prefer this over inline debugging when the failure spans multiple files, isn't obvious from the error message, or when initial fix attempts haven't worked. Trigger when: user has a confusing error or unexpected behavior, 'why is this failing', 'debug this', 'root cause', 'what's causing X', 'what went wrong', test failures need investigation, or user seems stuck on a bug."
---

# Diagnose — Root Cause Analysis from Symptoms

Produces a structured root cause analysis by capturing error symptoms,
gathering relevant code context, optionally cross-referencing design
documents for expected behavior, then tracing from symptoms to root
causes via RLM. Output is an analytical derived document in
`derived/reports/`.

## When to use

- User has an error, failure, or unexpected behavior to investigate
- User says "diagnose", "why is this failing", "root cause analysis"
- Test failures need investigation beyond the error message
- User says "debug this", "what's causing X", "why does this break"
- Need a structured analysis of what went wrong and why
- Complex failures spanning multiple components or layers

## When NOT to use

- User wants a general code review (use `/rlm-review`)
- User wants to check design compliance (use `/rlm-validate`)
- User wants to understand how something works (use `/rlm-research` or `/rlm-describe`)
- The error is trivially obvious from the message — just fix it directly
- User wants code changes (fix the bug directly, don't write a report about it)
- User wants to design a solution (use `/rlm-design`)

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
Capture it from the conversation. If the symptom is small and the
relevant code is already in context, process inline — skip to Step 4.

### Symptom capture

```bash
SYMPTOM_SUMMARY="<concise description of the failure>"   # e.g. "Auth middleware returns 401 for valid tokens"
SYMPTOM_SLUG="<slugified-summary>"                        # e.g. "auth-401-valid-tokens"
ERROR_OUTPUT="<raw error text if provided>"               # full stack trace, test output, etc.

ERROR_FILE="/tmp/diagnose_error_$(date +%Y%m%d_%H%M%S).txt"
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

## Step 1: Gather inputs IN PARALLEL (three branches)

Run all three branches concurrently. They are independent and their
results are merged in Step 2.

### Branch A: Gather code context (guided by error clues)

```bash
export GC_TASK="Find files relevant to this failure: $SYMPTOM_SUMMARY. The error involves these files: $ERROR_FILES. Look for: the failing code, its callers, its dependencies, related tests, configuration, and error handling paths. Focus on the call chain from the error location upward. Also look for related middleware, hooks, validators, and shared utilities that the failing code depends on."

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
  > /tmp/gc_diagnose_result.json 2>/tmp/gc_diagnose_error.log
```

Validate the result:

```bash
if [ ! -s /tmp/gc_diagnose_result.json ]; then
  echo "ERROR: Gather-context returned empty result" >&2
  cat /tmp/gc_diagnose_error.log >&2
  exit 1
fi

jq -e '.result' /tmp/gc_diagnose_result.json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: Gather-context returned invalid JSON" >&2
  exit 1
fi
```

### Branch B: Read error-referenced files directly

Read files from the error output immediately — do not wait for GC.

```bash
DIRECT_READS="/tmp/diagnose_direct_reads_$(date +%Y%m%d_%H%M%S).txt"

for f in $ERROR_FILE_PATHS; do
  if [ -f "$f" ]; then
    echo "===== FILE: $f =====" >> "$DIRECT_READS"
    cat "$f" >> "$DIRECT_READS"
    echo "" >> "$DIRECT_READS"
  fi
done

DIRECT_FILE_COUNT=$(grep -c "^===== FILE:" "$DIRECT_READS" 2>/dev/null || echo 0)
```

### Branch C: Scan design docs for expected behavior (optional)

Quick scan for design documents describing expected behavior of the
failing component — what SHOULD happen vs what IS happening.

```bash
DESIGN_DOCS="/tmp/diagnose_design_docs_$(date +%Y%m%d_%H%M%S).txt"
DESIGN_DOC_COUNT=0

# Look in common design doc locations
for dir in docs/design derived/drafts; do
  if [ -d "$dir" ]; then
    for doc in "$dir"/*.md; do
      if [ -f "$doc" ]; then
        # Check if the doc mentions any of the error-referenced modules
        if echo "$ERROR_MODULES $SYMPTOM_SUMMARY" | tr ' ' '\n' | grep -qiF -f - "$doc" 2>/dev/null; then
          echo "===== DESIGN DOC: $doc =====" >> "$DESIGN_DOCS"
          cat "$doc" >> "$DESIGN_DOCS"
          echo "" >> "$DESIGN_DOCS"
          DESIGN_DOC_COUNT=$((DESIGN_DOC_COUNT + 1))
        fi
      fi
    done
  fi
done

if [ "$DESIGN_DOC_COUNT" -gt 0 ]; then
  echo "Found $DESIGN_DOC_COUNT relevant design docs"
fi
```

If no design docs are found, skip this branch — it is supplementary.

## Step 2: Build diagnostic context

Merge all three branches into a single context file ordered for
diagnostic reasoning: symptoms, crash site, expected behavior, broader
context.

```bash
CONTEXT="/tmp/diagnose_context_$(date +%Y%m%d_%H%M%S).txt"

echo "===== DIAGNOSTIC GOAL =====" > "$CONTEXT"
echo "Trace the following failure symptoms back to their root cause. The error output and referenced code show WHERE the failure manifests. Use the broader code context and design docs to understand WHY it happens." >> "$CONTEXT"
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

if [ -s "$DESIGN_DOCS" ]; then
  echo "===== EXPECTED BEHAVIOR (from design docs) =====" >> "$CONTEXT"
  cat "$DESIGN_DOCS" >> "$CONTEXT"
  echo "" >> "$CONTEXT"
fi

GC_RESULT=$(jq -r '.result' /tmp/gc_diagnose_result.json)
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

## Step 3: Size check

```bash
echo "Context size: $CONTEXT_SIZE bytes"
```

If under 80,000 characters: read the context file directly and produce
the root cause analysis inline. Skip Step 4 dispatch and go straight to
saving (Step 5).

If 80,000+ characters: continue to Step 4 for RLM dispatch.

## Step 4: Set RLM_TASK and dispatch

```bash
export RLM_TASK="Produce a structured root cause analysis for: $SYMPTOM_SUMMARY

Analyze the diagnostic context — error output, error-referenced code, design docs (if present), and broader code context — to trace from symptoms to root cause(s).

Structure the report with these 7 sections:

1. **Diagnosis Summary** — Root cause(s) identified with confidence level (Confirmed/Likely/Possible). One-paragraph executive summary of what went wrong and why.
2. **Symptoms Observed** — Structured description of what was observed: error messages, unexpected behavior, test failures. Include the raw error output with key lines highlighted.
3. **Investigation Path** — How the diagnosis was reached. What files were examined, what hypotheses were formed and tested, what was ruled out. This shows the reasoning chain.
4. **Root Cause Analysis** — The actual cause(s) with detailed code references. For each root cause: what the code does wrong, why it fails, the exact mechanism. Include relevant code snippets (5-15 lines each).
5. **Contributing Factors** — Related issues that exacerbate the problem or made it harder to detect. Includes: missing error handling, inadequate logging, missing tests, design gaps. If design docs exist and the code violates them, note this here.
6. **Fix Recommendations** — Specific code changes to resolve each root cause. Ordered by priority. For each: what to change, where (file:line), and a code sketch of the fix. Distinguish between quick fixes and proper fixes.
7. **Prevention** — How to prevent similar issues: tests to add, monitoring to set up, design patterns to adopt, validation to add. Each prevention measure linked to the specific root cause it addresses.

Rules:
- Every claim must reference specific code (file:line or file:function)
- Include the ACTUAL failing code snippet, not just a description
- If multiple possible root causes exist, rank by likelihood with reasoning
- Distinguish between the root cause (why it happens) and the trigger (what made it happen now)
- Code fix suggestions must be concrete enough to implement, not abstract advice
- If the root cause spans multiple components, trace the full chain
- If design docs exist and the code violates them, note this as a contributing factor
- Be honest about confidence levels — 'Likely' means evidence supports it but is not conclusive
- If something is unclear from the code, say so explicitly rather than speculating"
```

Dispatch to rlm-process:

```
Use the rlm-process agent:
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
    --agent rlm-process \
    < "$CONTEXT"
```

## Step 5: Save output

Write the root cause analysis to a file:

```bash
OUTPUT_DIR="derived/reports"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$OUTPUT_DIR/$SYMPTOM_SLUG-diagnosis-$TIMESTAMP.md"

cat > "$OUTPUT" <<EOF
---
generated: $(date -Iseconds)
type: diagnosis
symptom: $SYMPTOM_SUMMARY
design_docs_found: $DESIGN_DOC_COUNT
error_files_referenced: $ERROR_FILE_COUNT
input_size: $CONTEXT_SIZE bytes
---

# Diagnosis: $SYMPTOM_SUMMARY

EOF

# Append the result from RLM or inline processing
echo "$RESULT" >> "$OUTPUT"

echo "Saved to: $OUTPUT"
```

## Step 6: Present and cleanup

1. Show the user the diagnosis summary with confidence level
2. List root cause(s) and recommended fixes
3. Tell them where the file was saved
4. If the fix is clear and the user wants it, offer to implement it
   directly — do not require them to invoke a separate skill
5. Clean up temp files:

```bash
rm -f "$CONTEXT"
rm -f "$ERROR_FILE"
rm -f "$DIRECT_READS"
rm -f "$DESIGN_DOCS"
rm -f /tmp/gc_diagnose_result.json /tmp/gc_diagnose_error.log
rm -f /tmp/gc_*.json 2>/dev/null
```

## What happens inside

This skill uses a three-branch parallel gathering pattern, then
synthesizes a diagnostic analysis:

1. **Parallel input gathering** — three independent branches run
   concurrently:
   - **Branch A** — gather-context workers search the codebase guided
     by file paths and module names from the error output.
   - **Branch B** — files referenced in the error are read immediately,
     giving direct access to the crash site without waiting for GC.
   - **Branch C** — a quick scan of `docs/design/` and `derived/drafts/`
     for design docs describing expected behavior. Skipped if none found.

2. **Context assembly** — four sections assembled in diagnostic order:
   symptoms, error-referenced code, expected behavior (design docs),
   broader code context. Duplicates between branches are eliminated.

3. **Diagnostic synthesis** — the assembled context is processed (via
   RLM if large) with a diagnosis prompt producing 7 sections: Diagnosis
   Summary, Symptoms Observed, Investigation Path, Root Cause Analysis,
   Contributing Factors, Fix Recommendations, and Prevention.

The analysis is symptom-driven — it starts from the error and traces
backward through the code, rather than surveying broadly from a topic.

For small input (under 80K), everything is processed inline — no
sub-agents.
