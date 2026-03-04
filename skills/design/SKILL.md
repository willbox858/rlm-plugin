---
name: design
description: "Generate a technical design document by distilling conversation history and gathering code context in parallel, producing a persistent design artifact. Prefer this over writing inline or using EnterPlanMode when the goal is a reusable design doc that captures decisions, requirements, and architecture from discussion. Trigger when: 'design doc', 'write a design', 'RFC', 'technical design', 'architecture proposal', 'formalize our discussion', user wants to turn conversation into a structured design, or is planning a non-trivial feature."
---

# Design — Technical Design Document from Conversation + Code

Generates a structured technical design document by distilling
conversation history (decisions, requirements, open questions) and
gathering code context, then synthesizing both into a design proposal.
Dispatches distillation and gather-context in parallel, then uses RLM
for the final design generation. Output is a draft derived document.

## When to use

- Turning conversation/discussion into a formal design doc
- User says "design doc", "write a design for X", "create an RFC"
- Need to capture decisions, requirements, and proposed architecture
- Preparing a technical proposal from exploratory discussion + code
- User says "turn this into a design document" or "formalize our discussion"

## When NOT to use

- User wants to describe existing code (use `/create-description`)
- User wants a diagram only (use `/create-diagram`)
- User wants to extract decisions without a design proposal (use `/distill`)
- User wants to explore a problem space (use `/research`)
- Context is trivially small — just write the design doc directly
- User wants to implement, not design (use implementation tools)

## Step 0: Determine input mode and design topic

### Input mode

Ask or infer which mode applies:

**Mode A — Specific files + topic**: User provides file paths and/or a
design topic explicitly. Use those files directly as code context.

**Mode B — Concept/module**: User names something ("auth system",
"the new caching layer", "API redesign") without giving file paths.
Auto-run gather-context to find relevant code — do NOT ask the user
for file paths. Also look for session logs to distill.

**Mode C — Current conversation**: The relevant discussion and context
are already small and present in the conversation. Process inline — no
file gathering, distillation, or RLM dispatch needed. Skip to Step 4.

### Design topic

Capture the design topic explicitly. This is the subject of the design
document — what is being designed.

```bash
DESIGN_TOPIC="<what the user wants to design>"    # e.g. "auth system redesign"
DESIGN_SLUG="<slugified-topic>"                   # e.g. "auth-system-redesign"
```

## Step 1: Gather inputs IN PARALLEL

Run distillation and code gathering concurrently. They are independent
and their results are merged in Step 2.

### Branch A: Distill conversation history

Find and process session JSONL logs. If no session logs exist, skip
this branch — the design will be based on code context + stated topic
only.

```bash
# Resolve the project session directory
PROJECT_DIR="$HOME/.claude/projects"
CWD_SLUG=$(pwd | sed 's|/|--|g' | sed 's|^-*||')
SESSION_DIR="$PROJECT_DIR/$CWD_SLUG"

DISTILL_RESULT=""
SESSION_COUNT=0

if [ -d "$SESSION_DIR" ]; then
  SESSION_COUNT=$(ls "$SESSION_DIR"/*.jsonl 2>/dev/null | wc -l)

  if [ "$SESSION_COUNT" -gt 0 ]; then
    DISTILL_CONTEXT="/tmp/design_distill_$(date +%Y%m%d_%H%M%S).txt"

    for jsonl in "$SESSION_DIR"/*.jsonl; do
      echo "===== SESSION: $(basename "$jsonl" .jsonl) ====="
      jq -r '
        select(.type == "user" or .type == "assistant") |
        .message // {role: .type, content: ""} |
        {role: .role, content: (
          if (.content | type) == "string" then .content
          elif (.content | type) == "array" then
            [.content[] | select(.type == "text") | .text] | join("\n")
          else ""
          end
        )} |
        select(.content != "") |
        "[\(.role)] \(.content)"
      ' "$jsonl" 2>/dev/null
    done > "$DISTILL_CONTEXT"

    DISTILL_SIZE=$(wc -c < "$DISTILL_CONTEXT")
    echo "Distill context: $DISTILL_SIZE bytes from $SESSION_COUNT sessions"

    # Build distillation prompt (reuses /distill's tagged extraction)
    DISTILL_TASK="Focus: $DESIGN_TOPIC — prioritize content related to this topic.

Distill this conversation/document into structured findings. For every substantive point, tag it with exactly one of these prefixes:

[DECISION] — An explicit choice that was made. Include the reasoning and any rejected alternatives.
[REQ] — A constraint, specification, or must-have requirement.
[KEY] — An important insight, established fact, or key context.
[OPEN] — An unresolved question, deferred issue, or point of disagreement.
[TODO] — A task that was identified but not yet completed.
[STATE] — Where things stand at the end — current status, what's working, what's not.

Rules:
- Every point gets exactly one tag prefix
- Include enough context that the point is self-contained (someone reading just that line should understand it)
- Preserve specifics: names, numbers, file paths, exact decisions — do not generalize
- Chronological order within each tag category
- If a decision was later reversed, note both the original and the reversal
- Skip small talk, greetings, and meta-conversation about the tool itself"

    # If distill context is small enough, process inline
    if [ "$DISTILL_SIZE" -lt 80000 ]; then
      # Read and process inline — DISTILL_RESULT is set directly
      DISTILL_RESULT="<process $DISTILL_CONTEXT inline with $DISTILL_TASK>"
    else
      # Dispatch to RLM for large session history
      export RLM_TASK="$DISTILL_TASK"

      # Use the rlm-orchestrator agent to process the distill context
      # Result is an intermediate artifact — not saved separately
    fi
  fi
fi
```

### Branch B: Gather code context

Run gather-context to discover relevant code files:

```bash
export GC_TASK="Find all files relevant to: $DESIGN_TOPIC. I need to understand the current implementation, architecture, configuration, and tests to write a technical design document."

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
  > /tmp/gc_design_result.json 2>/tmp/gc_design_error.log
```

Validate the result:

```bash
if [ ! -s /tmp/gc_design_result.json ]; then
  echo "ERROR: Gather-context returned empty result" >&2
  cat /tmp/gc_design_error.log >&2
  exit 1
fi

jq -e '.result' /tmp/gc_design_result.json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: Gather-context returned invalid JSON" >&2
  exit 1
fi
```

## Step 2: Merge distillation + code context

Combine both inputs into a single context file for the design
generation step:

```bash
CONTEXT="/tmp/design_context_$(date +%Y%m%d_%H%M%S).txt"

# Section 1: Distilled conversation findings (if available)
if [ -n "$DISTILL_RESULT" ]; then
  echo "===== DISTILLED CONVERSATION FINDINGS =====" > "$CONTEXT"
  echo "$DISTILL_RESULT" >> "$CONTEXT"
  echo "" >> "$CONTEXT"
else
  echo "===== NO CONVERSATION HISTORY AVAILABLE =====" > "$CONTEXT"
  echo "Design based on code context and stated topic only." >> "$CONTEXT"
  echo "" >> "$CONTEXT"
fi

# Section 2: Gather-context findings
GC_RESULT=$(jq -r '.result' /tmp/gc_design_result.json)
echo "===== CODE CONTEXT FINDINGS =====" >> "$CONTEXT"
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
echo "Prepared context: $CONTEXT_SIZE bytes from $FILE_COUNT files + distillation"
```

## Step 3: Size check

```bash
echo "Context size: $CONTEXT_SIZE bytes"
```

If under 80,000 characters: read the context file directly and produce
the design document inline. Skip Step 4 and go straight to Step 5.

If 80,000+ characters: continue to Step 4 for RLM dispatch.

## Step 4: Set RLM_TASK and dispatch

Build the design-generation prompt:

```bash
export RLM_TASK="Produce a technical design document for: $DESIGN_TOPIC

Use the distilled conversation findings (decisions, requirements, open questions) and the code context to write a comprehensive design document. The document should capture what has been discussed and decided, and propose a clear path forward.

Structure the document with these 7 sections:

1. **Problem Statement** — What problem is being solved? Why does it matter? What is the current state?
2. **Context** — Relevant background: existing architecture, prior decisions, constraints, stakeholders.
3. **Requirements** — Must-have requirements ([REQ] items from distillation), nice-to-haves, non-requirements (explicitly out of scope).
4. **Proposed Design** — The recommended approach. Include architecture, data flow, key interfaces, and component responsibilities. Reference specific files/functions from the code context.
5. **Alternatives Considered** — Other approaches that were discussed or rejected. Include the reasoning for rejection (from [DECISION] items in distillation).
6. **Migration / Implementation Plan** — How to get from current state to proposed design. Sequencing, risks, rollback strategy. Reference [TODO] items from distillation.
7. **Open Questions** — Unresolved issues that need answers before or during implementation (from [OPEN] items in distillation).

Rules:
- Ground every claim in specific code references or conversation decisions
- Use exact file paths, function names, and class names from the source
- If the distillation contains [DECISION] items, ensure they are reflected in the design
- If the distillation contains [OPEN] items, they must appear in Open Questions
- If the distillation contains [REQ] items, they must appear in Requirements
- Be specific about interfaces, data structures, and behavior — avoid hand-waving
- If something is unclear or contested, say so explicitly
- Write for a technical audience that will review and approve this design"
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

Write the design document to a file:

```bash
OUTPUT_DIR="derived/drafts"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$OUTPUT_DIR/$DESIGN_SLUG-$TIMESTAMP.md"

cat > "$OUTPUT" <<EOF
---
generated: $(date -Iseconds)
type: design
design_type: technical-design
topic: $DESIGN_TOPIC
distilled_sessions: $SESSION_COUNT
input_size: $CONTEXT_SIZE bytes
---

# Design: $DESIGN_TOPIC

EOF

# Append the result from RLM or inline processing
echo "$RESULT" >> "$OUTPUT"

echo "Saved to: $OUTPUT"
```

## Step 6: Present and cleanup

1. Show the user the design document (or a summary if it is long)
2. Tell them where the file was saved
3. Note that this is a draft in `derived/drafts/` — to promote it to
   a base document, review and move to `docs/design/`
4. Clean up temp files:

```bash
rm -f "$CONTEXT"
rm -f "$DISTILL_CONTEXT"
rm -f /tmp/gc_design_result.json /tmp/gc_design_error.log
rm -f /tmp/gc_*.json 2>/dev/null
```

## What happens inside

This skill orchestrates two parallel input-gathering phases, then
synthesizes them into a design document:

1. **Parallel input gathering:**
   - **Distillation** — session JSONL logs are filtered (user/assistant
     text only, no tool_use/thinking) and processed with the tagged
     extraction prompt from `/distill` ([DECISION], [REQ], [KEY],
     [OPEN], [TODO], [STATE]). This is an intermediate artifact — not
     saved separately.
   - **Code context** — gather-context workers discover relevant code
     files and return findings with relevance assessments.

2. **Merge** — distilled findings and code context are combined into a
   single context file. The distillation provides the "what was
   discussed and decided" while the code context provides the "what
   exists today."

3. **Design generation** — the merged context is processed (via RLM if
   large) with a design-specific prompt that produces a 7-section
   design document grounded in both conversation history and code.

If no session logs exist, the distillation branch is skipped — the
design is based on code context and the stated topic only.

For small input (under 80K), everything is processed inline — no
sub-agents.
