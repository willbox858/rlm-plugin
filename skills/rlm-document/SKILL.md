---
name: rlm-document
description: "Generate comprehensive documentation with both prose and Mermaid diagram by gathering code context first — ensures accuracy across multi-file systems. Prefer this over writing docs inline when documenting anything that spans multiple files or when both explanation and visual are needed. Trigger when: 'document X', 'write docs for', 'documentation', 'explain X with diagrams', 'full docs', or user wants to understand/document a module, feature, or system."
---

# Document — Comprehensive Prose + Diagram

Generates a single document combining a prose description and a Mermaid
diagram for a module, feature, or concept. Gathers context once, then
dispatches two RLM invocations in parallel — one for prose, one for the
diagram. Output is a unified descriptive derived document.

## When to use

- User wants comprehensive documentation of a module or feature
- User says "document X fully", "full docs for X", "document everything about X"
- Need both a prose explanation and a visual diagram in one artifact
- Creating onboarding documentation that needs both text and visuals
- User says "document with diagrams" or "comprehensive docs"

## When NOT to use

- User only wants prose description (use `/rlm-describe`)
- User only wants a diagram (use `/rlm-diagram`)
- User wants a design doc from conversation history (use `/rlm-design`)
- Want to extract decisions from conversations (use `/rlm-distill`)
- Context is trivially small — just answer directly with inline prose + Mermaid
- User wants API reference docs (use a doc generator)

## Step 0: Determine input mode and diagram type

Two things to resolve before proceeding:

### Input mode

Ask or infer which mode applies:

**Mode A — Specific files**: User provides file paths explicitly.
Use those files directly as input.

**Mode B — Concept/module**: User names something ("the auth module",
"how routing works", "the data model") without giving file paths.
Auto-run gather-context to find relevant files — do NOT ask the user
for file paths. This is the most common mode.

**Mode C — Current conversation**: The relevant context is already
small and present in the conversation. Process inline — no file
gathering or RLM dispatch needed. Skip to Step 5.

### Diagram type

Determine the diagram type from the user's request. Either the user
specifies it explicitly, or infer from context:

- `architecture` — high-level component relationships (default if unclear)
- `sequence` — request/response flows, multi-step processes
- `flowchart` — decision logic, control flow
- `state` — state machines, lifecycle
- `class` — type relationships, inheritance
- `er` — data model, entity relationships

```bash
# Set from user input or inference
DIAGRAM_TYPE="architecture"  # one of: architecture, sequence, flowchart, state, class, er
```

Inference heuristics when the user does not specify:
- "flow", "process", "steps", "request" -> `sequence`
- "decision", "logic", "branching", "control flow" -> `flowchart`
- "state", "lifecycle", "status", "transitions" -> `state`
- "class", "types", "inheritance", "hierarchy" -> `class`
- "data model", "entities", "schema", "tables", "relationships" -> `er`
- Everything else -> `architecture`

If genuinely ambiguous, briefly ask the user which type they want.

## Step 1: Gather source material (shared for both artifacts)

Gather context ONCE. The same context file feeds both the description
and diagram RLM invocations.

**For Mode A** (specific files), concatenate with markers:

```bash
CONTEXT="/tmp/document_context_$(date +%Y%m%d_%H%M%S).txt"
TARGET="<what the user wants documented>"    # e.g. "the auth module"
TARGET_SLUG="<slugified-target-name>"        # e.g. "auth-module"

for f in $FILES; do
  echo "===== FILE: $f =====" >> "$CONTEXT"
  cat "$f" >> "$CONTEXT"
done

FILE_COUNT=$(echo "$FILES" | wc -w)
echo "Prepared context: $(wc -c < "$CONTEXT") bytes from $FILE_COUNT files"
```

**For Mode B** (concept/module), run gather-context to discover
relevant files automatically:

```bash
TARGET="<what the user wants documented>"    # e.g. "the auth module"
TARGET_SLUG="<slugified-target-name>"        # e.g. "auth-module"

export GC_TASK="Find all files relevant to: $TARGET. I need to understand how it works — its purpose, components, data flow, design decisions, and interactions so I can produce comprehensive documentation including prose and diagrams."

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
  > /tmp/gc_document_result.json 2>/tmp/gc_document_error.log
```

Validate the result:

```bash
if [ ! -s /tmp/gc_document_result.json ]; then
  echo "ERROR: Gather-context returned empty result" >&2
  cat /tmp/gc_document_error.log >&2
  exit 1
fi

jq -e '.result' /tmp/gc_document_result.json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: Gather-context returned invalid JSON" >&2
  exit 1
fi
```

Extract the relevant file paths from the findings and build the context
file by reading each discovered file:

```bash
CONTEXT="/tmp/document_context_$(date +%Y%m%d_%H%M%S).txt"

# Parse findings from gather-context result
GC_RESULT=$(jq -r '.result' /tmp/gc_document_result.json)

# Write the gather-context summary as preamble
echo "===== GATHER-CONTEXT FINDINGS =====" > "$CONTEXT"
echo "$GC_RESULT" >> "$CONTEXT"
echo "" >> "$CONTEXT"

# Read each high/medium relevance file in full
for f in $(echo "$GC_RESULT" | jq -r '.findings[]? | select(.relevance == "high" or .relevance == "medium") | .file_path' 2>/dev/null); do
  if [ -f "$f" ]; then
    echo "===== FILE: $f =====" >> "$CONTEXT"
    cat "$f" >> "$CONTEXT"
    echo "" >> "$CONTEXT"
  fi
done

FILE_COUNT=$(grep -c "^===== FILE:" "$CONTEXT" || echo 0)
echo "Prepared context: $(wc -c < "$CONTEXT") bytes from $FILE_COUNT files"
```

## Step 2: Size check

```bash
CONTEXT_SIZE=$(wc -c < "$CONTEXT")
echo "Context size: $CONTEXT_SIZE bytes"
```

If under 80,000 characters: read the context file directly and produce
BOTH the description and diagram inline. Skip Steps 3-4 and go
straight to Step 5. Write the prose description first, then the diagram.

If 80,000+ characters: continue to Step 3 for parallel RLM dispatch.

## Step 3: Build TWO RLM_TASK prompts

Build separate prompts for the description and diagram. Each prompt
is self-contained so the two RLM invocations can run independently.

### Description prompt

```bash
export DESCRIPTION_TASK="Produce a clear, well-structured prose description of: $TARGET

Write for a developer who is new to this area of the codebase. Cover all of the following:

1. **Purpose** — What is this module/feature/concept for? What problem does it solve?
2. **Key concepts** — What are the core abstractions, types, and terminology?
3. **Components** — What are the main files, classes, and functions? What does each one do?
4. **How they interact** — How do the components work together? What calls what?
5. **Data flow** — How does data move through the system? What are the inputs and outputs?
6. **Design decisions** — What important architectural choices were made? Why?
7. **Edge cases and gotchas** — What non-obvious behavior should a developer know about?

Rules:
- Use specific file paths, function names, and code references — do not be vague
- When referencing code, use the exact names from the source files
- Explain the 'why' behind design choices, not just the 'what'
- Organize logically — start with the big picture, then go deeper
- Keep it prose, not bullet lists — write paragraphs that flow and explain
- If something is unclear from the code, say so explicitly rather than guessing"
```

### Diagram prompt

```bash
# Map diagram type to Mermaid syntax hint
case "$DIAGRAM_TYPE" in
  architecture) MERMAID_HINT="graph TD (top-down) or graph LR (left-right) for component/architecture diagrams" ;;
  sequence)     MERMAID_HINT="sequenceDiagram with participant, ->>, -->> arrows" ;;
  flowchart)    MERMAID_HINT="flowchart TD with decision diamonds {}, process rectangles [], and directional arrows" ;;
  state)        MERMAID_HINT="stateDiagram-v2 with [*] for start/end, --> for transitions" ;;
  class)        MERMAID_HINT="classDiagram with class definitions, <|-- inheritance, *-- composition, o-- aggregation" ;;
  er)           MERMAID_HINT="erDiagram with entity blocks and ||--o{ relationship notation" ;;
  *)            MERMAID_HINT="graph TD (top-down) or graph LR (left-right) for component/architecture diagrams" ;;
esac

export DIAGRAM_TASK="Produce a Mermaid diagram ($DIAGRAM_TYPE type) of: $TARGET

Use Mermaid syntax: $MERMAID_HINT

Requirements for the diagram:
1. **Key components/actors** — Include the main components, services, classes, or actors involved
2. **Relationships/edges** — Label every edge with what it represents (data, calls, triggers, etc.)
3. **Data flow direction** — Show the direction data or control flows
4. **Decision points or states** — Include important branching logic, states, or conditions
5. **Readability** — Keep to 15-30 nodes maximum. If the system is larger, focus on the most important elements and note omissions in the prose
6. **Clear labels** — Use concise but descriptive labels on all nodes and edges. Avoid abbreviations unless universally understood

Output format — produce EXACTLY this structure:
1. A Mermaid code block (\`\`\`mermaid ... \`\`\`) containing a valid, well-formatted $DIAGRAM_TYPE diagram
2. Below the diagram, a prose explanation section (2-5 paragraphs) covering:
   - What the diagram shows at a high level
   - Key interactions or flows worth noting
   - Important details that cannot be captured in the diagram alone
   - Any simplifications made and what was omitted

Rules:
- Use specific names from the source code — file names, class names, function names, endpoint paths
- Every node must have a clear, descriptive label
- Every edge must be labeled with what it represents
- The diagram must be valid Mermaid syntax that renders correctly
- Keep the prose explanation brief and complementary to the diagram — do not repeat what the diagram already shows clearly"
```

## Step 4: Dispatch TWO RLM invocations IN PARALLEL

Resolve the RLM config and launcher (if not already resolved):

```bash
if [ -n "$RLM_ROOT" ]; then
  RLM_CONFIG="$RLM_ROOT/internal/rlm-child.json"
  LAUNCHER="$RLM_ROOT/launch.sh"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  RLM_CONFIG="$CLAUDE_PLUGIN_ROOT/internal/rlm-child.json"
  LAUNCHER="$CLAUDE_PLUGIN_ROOT/launch.sh"
else
  RLM_CONFIG="$(find . -path '*/.claude/RLM/internal/rlm-child.json' -print -quit 2>/dev/null)"
  if [ -z "$RLM_CONFIG" ]; then
    RLM_CONFIG="$HOME/.claude/RLM/internal/rlm-child.json"
  fi
  LAUNCHER="$(dirname "$(dirname "$RLM_CONFIG")")/launch.sh"
fi
```

Dispatch both in parallel using the Agent tool. Both use the same
`$CONTEXT` file — the shared context gathered in Step 1.

**Description dispatch:**
```
Use the rlm-process agent:
RLM_TASK="$DESCRIPTION_TASK"
Process the context at $CONTEXT
Task: $DESCRIPTION_TASK
```

**Diagram dispatch:**
```
Use the rlm-process agent:
RLM_TASK="$DIAGRAM_TASK"
Process the context at $CONTEXT
Task: $DIAGRAM_TASK
```

If the Agent tool is unavailable, fall back to CLI (run both in
background with `&`):

```bash
env -u CLAUDECODE \
  RLM_DEPTH=0 \
  RLM_TASK="$DESCRIPTION_TASK" \
  claude -p "$DESCRIPTION_TASK" \
    --agent rlm-process \
    < "$CONTEXT" \
    > /tmp/document_description_result.txt 2>/tmp/document_description_error.log &
DESC_PID=$!

env -u CLAUDECODE \
  RLM_DEPTH=0 \
  RLM_TASK="$DIAGRAM_TASK" \
  claude -p "$DIAGRAM_TASK" \
    --agent rlm-process \
    < "$CONTEXT" \
    > /tmp/document_diagram_result.txt 2>/tmp/document_diagram_error.log &
DIAG_PID=$!

# Wait for both
wait $DESC_PID
DESC_EXIT=$?
wait $DIAG_PID
DIAG_EXIT=$?
```

### Handling partial failures

If one dispatch succeeds and the other fails, produce a partial
document with a note about what failed:

```bash
if [ $DESC_EXIT -ne 0 ] && [ $DIAG_EXIT -ne 0 ]; then
  echo "ERROR: Both description and diagram generation failed" >&2
  exit 1
fi

DESCRIPTION_RESULT=""
DIAGRAM_RESULT=""

if [ $DESC_EXIT -eq 0 ]; then
  DESCRIPTION_RESULT=$(cat /tmp/document_description_result.txt)
else
  DESCRIPTION_RESULT="> **Note:** Prose description generation failed. Re-run with \`/rlm-describe\` to generate it separately."
fi

if [ $DIAG_EXIT -eq 0 ]; then
  DIAGRAM_RESULT=$(cat /tmp/document_diagram_result.txt)
else
  DIAGRAM_RESULT="> **Note:** Diagram generation failed. Re-run with \`/rlm-diagram\` to generate it separately."
fi
```

## Step 5: Save output

Merge both results into a single document:

```bash
OUTPUT_DIR="derived/descriptive"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$OUTPUT_DIR/$TARGET_SLUG-doc-$TIMESTAMP.md"

cat > "$OUTPUT" <<EOF
---
generated: $(date -Iseconds)
type: document
diagram_type: $DIAGRAM_TYPE
target: $TARGET
input_size: $CONTEXT_SIZE bytes
---

# $TARGET

## Description

EOF

echo "$DESCRIPTION_RESULT" >> "$OUTPUT"

cat >> "$OUTPUT" <<EOF

---

## Diagram

EOF

echo "$DIAGRAM_RESULT" >> "$OUTPUT"

echo "Saved to: $OUTPUT"
```

## Step 6: Present and cleanup

1. Show the user the combined document (or a summary if it is long)
2. Tell them where the file was saved
3. Note that the Mermaid block can be rendered in GitHub, VS Code, Notion, or any Mermaid-compatible viewer
4. Clean up temp files:

```bash
rm -f "$CONTEXT"
rm -f /tmp/gc_document_result.json /tmp/gc_document_error.log
rm -f /tmp/gc_*.json 2>/dev/null
rm -f /tmp/document_description_result.txt /tmp/document_description_error.log
rm -f /tmp/document_diagram_result.txt /tmp/document_diagram_error.log
```

## What happens inside

This skill gathers context once, then fans out into two parallel RLM
invocations:

1. **Gather phase** — same as `/rlm-describe` or `/rlm-diagram`:
   gather-context workers discover relevant files, this skill reads them
   into a shared context file.

2. **Dual dispatch** — two independent rlm-process invocations run
   in parallel:
   - One processes the context with the description prompt (7-point
     prose structure from `/rlm-describe`)
   - One processes the context with the diagram prompt (Mermaid +
     6-point requirements from `/rlm-diagram`)

3. **Merge** — results are combined into a single document with
   Description and Diagram sections. If one fails, the other is still
   included with a note about the failure.

For small input (under 80K), both are produced inline — no sub-agents.
