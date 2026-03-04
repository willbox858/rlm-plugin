---
name: validate
description: "Check implementation against design documents and report specific drift findings. Trigger when: 'validate', 'does code match design', 'drift analysis', 'check conformance', 'are we following the spec', user wants to verify implementation aligns with design docs, or after significant code changes before release."
---

# Validate — Code vs Design Drift Analysis

Produces a structured validation report by discovering design documents
(approved in `docs/design/` and drafts in `derived/drafts/`), gathering
code context for the relevant modules, then cross-referencing requirements
and architectural decisions against actual implementation. Output is an
analytical derived document in `derived/reports/`.

## When to use

- User wants to check if code matches design docs
- User says "validate", "check against design", "drift analysis"
- Before a release or review, check implementation compliance
- After significant code changes, verify design alignment
- User says "does the code match the design?" or "are we on track?"
- After running `/design`, want to verify implementation follows it

## When NOT to use

- User wants a general code review (use `/review`)
- User wants to investigate a failure (use `/diagnose`)
- User wants a design doc created (use `/design`)
- User wants to research how something works (use `/research`)
- No design docs exist — suggest running `/design` first, then validate
- User wants code changes (use implementation tools)

## Step 0: Determine input mode and validation scope

### Input mode

Ask or infer which mode applies:

**Mode A — Specific scope**: User provides both design doc path(s) and
code path(s) to validate against. Use those directly as inputs.

**Mode B — Concept/topic**: User names a topic ("auth system",
"the caching layer", "API design") without specifying exact files.
Auto-discover design docs and gather code context. This is the most
common mode.

**Mode C — Current conversation**: The relevant design and code context
are already small and present in the conversation. Process inline — no
file gathering or RLM dispatch needed. Skip to Step 4.

### Validation scope

Capture the validation topic and slug:

```bash
VALIDATE_TOPIC="<topic from user>"         # e.g. "authentication system"
VALIDATE_SLUG="<slugified-topic>"          # e.g. "authentication-system"
```

If the user gives a broad topic, narrow it to a specific validation
objective: what design aspects to check, which modules to verify.

## Step 1: Gather inputs IN PARALLEL

Run design doc discovery and code gathering concurrently. They are
independent and their results are merged in Step 2.

### Branch A: Scan for design documents

Find approved and draft design documents:

```bash
DESIGN_DOCS=""
DESIGN_DOC_COUNT=0

# Scan approved design docs
if [ -d "docs/design" ]; then
  for doc in docs/design/*.md; do
    if [ -f "$doc" ]; then
      # If user specified a topic, filter by relevance
      if [ -n "$VALIDATE_TOPIC" ]; then
        PREVIEW=$(head -c 2000 "$doc")
        if echo "$PREVIEW" | grep -qi "$VALIDATE_TOPIC" 2>/dev/null; then
          DESIGN_DOCS="$DESIGN_DOCS $doc"
          DESIGN_DOC_COUNT=$((DESIGN_DOC_COUNT + 1))
        fi
      else
        DESIGN_DOCS="$DESIGN_DOCS $doc"
        DESIGN_DOC_COUNT=$((DESIGN_DOC_COUNT + 1))
      fi
    fi
  done
fi

# Scan draft design docs
for doc in derived/drafts/*-design-*.md derived/drafts/*design*.md; do
  if [ -f "$doc" ]; then
    if [ -n "$VALIDATE_TOPIC" ]; then
      PREVIEW=$(head -c 2000 "$doc")
      if echo "$PREVIEW" | grep -qi "$VALIDATE_TOPIC" 2>/dev/null; then
        DESIGN_DOCS="$DESIGN_DOCS $doc"
        DESIGN_DOC_COUNT=$((DESIGN_DOC_COUNT + 1))
      fi
    else
      DESIGN_DOCS="$DESIGN_DOCS $doc"
      DESIGN_DOC_COUNT=$((DESIGN_DOC_COUNT + 1))
    fi
  fi
done

echo "Found $DESIGN_DOC_COUNT design document(s)"
```

**STOP if no design docs found.** Validation without a design baseline
is meaningless:

```bash
if [ "$DESIGN_DOC_COUNT" -eq 0 ]; then
  echo "ERROR: No design documents found." >&2
  echo "Checked: docs/design/*.md and derived/drafts/*design*.md" >&2
  echo "" >&2
  echo "Validation requires a design document to validate against." >&2
  echo "Run /design first to generate a design doc, then run /validate." >&2
  exit 1
fi
```

Read all found design docs in full:

```bash
DESIGN_CONTENT="/tmp/validate_design_$(date +%Y%m%d_%H%M%S).txt"

for doc in $DESIGN_DOCS; do
  echo "===== DESIGN DOC: $doc =====" >> "$DESIGN_CONTENT"
  cat "$doc" >> "$DESIGN_CONTENT"
  echo "" >> "$DESIGN_CONTENT"
done

echo "Design baseline: $(wc -c < "$DESIGN_CONTENT") bytes from $DESIGN_DOC_COUNT documents"
```

### Branch B: Gather code context

Run gather-context to discover relevant implementation files:

```bash
export GC_TASK="Find all files relevant to: $VALIDATE_TOPIC. I need to understand the current implementation, tests, and configuration to check whether the code matches the design documents. Include source files, test files, configuration, and any related infrastructure."

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
  > /tmp/gc_validate_result.json 2>/tmp/gc_validate_error.log
```

Validate the result:

```bash
if [ ! -s /tmp/gc_validate_result.json ]; then
  echo "ERROR: Gather-context returned empty result" >&2
  cat /tmp/gc_validate_error.log >&2
  exit 1
fi

jq -e '.result' /tmp/gc_validate_result.json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: Gather-context returned invalid JSON" >&2
  exit 1
fi
```

## Step 2: Merge design docs + code context

Combine design baseline and code context into a single context file
for the validation step:

```bash
CONTEXT="/tmp/validate_context_$(date +%Y%m%d_%H%M%S).txt"

# Preamble: validation goal
cat > "$CONTEXT" <<'PREAMBLE'
===== VALIDATION GOAL =====
Compare the following design documents against the actual code
implementation. For each design requirement, architectural decision,
and specified behavior, determine whether the code conforms, has
drifted, or is missing the implementation.
PREAMBLE
echo "" >> "$CONTEXT"

# Section 1: Design documents (the baseline — what SHOULD be)
echo "===== DESIGN BASELINE (WHAT SHOULD BE) =====" >> "$CONTEXT"
cat "$DESIGN_CONTENT" >> "$CONTEXT"
echo "" >> "$CONTEXT"

# Section 2: Gather-context findings (the reality — what IS)
GC_RESULT=$(jq -r '.result' /tmp/gc_validate_result.json)
echo "===== CODE CONTEXT FINDINGS (WHAT IS) =====" >> "$CONTEXT"
echo "$GC_RESULT" >> "$CONTEXT"
echo "" >> "$CONTEXT"

# Section 3: Full content of high/medium relevance files
for f in $(echo "$GC_RESULT" | jq -r '.findings[]? | select(.relevance == "high" or .relevance == "medium") | .file_path' 2>/dev/null); do
  if [ -f "$f" ]; then
    echo "===== FILE: $f =====" >> "$CONTEXT"
    cat "$f" >> "$CONTEXT"
    echo "" >> "$CONTEXT"
  fi
done

FILE_COUNT=$(grep -c "^===== FILE:" "$CONTEXT" || echo 0)
CONTEXT_SIZE=$(wc -c < "$CONTEXT")
echo "Prepared context: $CONTEXT_SIZE bytes from $DESIGN_DOC_COUNT design docs + $FILE_COUNT code files"
```

## Step 3: Size check

```bash
echo "Context size: $CONTEXT_SIZE bytes"
```

If under 80,000 characters: read the context file directly and produce
the validation report inline. Skip Step 4 and go straight to Step 5.

If 80,000+ characters: continue to Step 4 for RLM dispatch.

## Step 4: Set RLM_TASK and dispatch

Build the validation synthesis prompt:

```bash
export RLM_TASK="Produce a structured validation report for: $VALIDATE_TOPIC

Cross-reference the design documents (the baseline) against the actual code implementation (the reality). For every requirement, decision, and specification in the design docs, determine whether the code conforms, has drifted, or is missing.

Structure the report with these 7 sections:

1. **Validation Summary** — Overall conformance assessment. How many requirements checked, how many conform, how many drifted, how many missing. Traffic light rating: Green (all conformant or minor drift only), Yellow (some meaningful drift but core design intact), Red (significant drift or missing critical implementations).
2. **Design Requirements Checked** — Enumerated list of every requirement, decision, and specification found in the design docs. Each tagged with its source document and section. This is the checklist against which code is validated.
3. **Conformant Areas** — Where code matches design intent. Reference specific code locations (file:line or file:function) that satisfy specific design requirements. Brief — confirm and move on.
4. **Drift Detected** — Where implementation diverges from design. For each drift item: what the design says (with doc reference), what the code does (with file reference), severity (Critical/High/Medium/Low), and likely cause (intentional evolution vs. oversight).
5. **Missing Implementations** — Design elements with no corresponding code. Distinguish between 'not yet implemented' (planned but absent) and 'removed or abandoned' (was there, now gone or never started).
6. **Undesigned Code** — Significant code that exists but has no corresponding design coverage. Not necessarily wrong — may indicate the design doc needs updating to reflect evolution.
7. **Recommendations** — Prioritized actions. For each item: fix the code to match the design, OR update the design to match the code. State which direction the fix should go and why.

Rules:
- Every finding must reference both a design doc location AND a code location
- Severity ratings must be justified, not arbitrary
- Distinguish intentional evolution from accidental drift
- Be specific: 'auth middleware skips token refresh (src/auth.ts:45) but design requires it (design-auth.md S3.2)'
- If a design requirement is ambiguous, note it as ambiguous rather than judging conformance
- Quantify where possible: '5 of 8 API endpoints match the design, 2 have drifted, 1 is missing'
- Do not soften findings — state drift plainly"
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

Write the validation report to a file:

```bash
OUTPUT_DIR="derived/reports"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$OUTPUT_DIR/$VALIDATE_SLUG-validate-$TIMESTAMP.md"

cat > "$OUTPUT" <<EOF
---
generated: $(date -Iseconds)
type: validation
topic: $VALIDATE_TOPIC
design_docs_checked: $DESIGN_DOC_COUNT
input_size: $CONTEXT_SIZE bytes
---

# Validation: $VALIDATE_TOPIC

EOF

# Append the result from RLM or inline processing
echo "$RESULT" >> "$OUTPUT"

echo "Saved to: $OUTPUT"
```

## Step 6: Present and cleanup

1. Show the user the validation report (or a summary if it is long)
2. Tell them where the file was saved
3. Highlight the traffic light rating and most critical drifts
4. Suggest next steps: fix drifted code, update outdated design docs,
   or implement missing features
5. Clean up temp files:

```bash
rm -f "$CONTEXT"
rm -f "$DESIGN_CONTENT"
rm -f /tmp/gc_validate_result.json /tmp/gc_validate_error.log
rm -f /tmp/gc_*.json 2>/dev/null
```

## What happens inside

This skill orchestrates two parallel input-gathering branches, then
synthesizes a cross-referenced drift report:

1. **Parallel input gathering:**
   - **Design doc discovery** — scans `docs/design/` for approved
     designs and `derived/drafts/` for draft designs. Filters by
     topic relevance if the user specified a topic. All matching
     design docs are read in full to establish the baseline.
   - **Code context** — gather-context workers discover relevant
     implementation files and return findings with relevance
     assessments. High/medium relevance files are read in full.

2. **Merge** — design docs and code context are combined into a
   single context file. The design docs provide the "what should be"
   while the code context provides the "what is." A validation
   preamble instructs the synthesis step to cross-reference them.

3. **Validation synthesis** — the merged context is processed (via
   RLM if large) with a validation-specific prompt that produces a
   7-section report: Validation Summary, Design Requirements Checked,
   Conformant Areas, Drift Detected, Missing Implementations,
   Undesigned Code, and Recommendations.

If no design documents are found, the skill stops with a helpful
message directing the user to run `/design` first.

For small input (under 80K), everything is processed inline — no
sub-agents.
