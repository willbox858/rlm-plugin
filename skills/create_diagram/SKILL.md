---
name: create_diagram
description: "Generate an accurate Mermaid diagram by first gathering code context — ensures the diagram reflects actual code structure, not guesses. Prefer this over writing Mermaid inline when the diagram needs to be accurate to the codebase. Trigger when: 'diagram', 'visualize', 'draw', 'flowchart', 'sequence diagram', 'architecture diagram', 'show me how X connects', or user wants any visual representation of code structure, data flow, or architecture."
---

# Create Diagram — Generate a Mermaid Diagram

Generates a Mermaid diagram with a brief prose explanation of a system,
module, flow, or concept. Output is a descriptive derived document.
Dispatches to gather-context for discovery and to the RLM pipeline for
large inputs.

## When to use

- User asks for a diagram of a module, feature, or concept
- User says "diagram the auth flow" or "visualize the data model"
- Need an architecture, sequence, flowchart, state, class, or ER diagram
- User explicitly says "diagram", "create a diagram", "mermaid diagram"
- User says "draw", "visualize", or "show me how X connects"

## When NOT to use

- User wants a code change, not a diagram (use implementation tools)
- Want to extract decisions from conversations (use `/distill`)
- Want a prose description without a diagram (use `/create-description`)
- Want raw file listings or code search results (use `/gather-context` or grep)
- Context is trivially small and obvious — just answer directly with inline Mermaid
- User wants an image file, not Mermaid markdown (explain Mermaid renders in many tools)

## Step 0: Determine input mode and diagram type

Two things to resolve before proceeding:

### Input mode

Ask or infer which mode applies:

**Mode A — Specific files**: User provides file paths explicitly.
Use those files directly as input.

**Mode B — Concept/module**: User names something ("the auth flow",
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

## Step 1: Gather source material

**For Mode A** (specific files), concatenate with markers:

```bash
CONTEXT="/tmp/diagram_context_$(date +%Y%m%d_%H%M%S).txt"
TARGET="<what the user wants diagrammed>"  # e.g. "the auth flow"
TARGET_SLUG="<slugified-target-name>"      # e.g. "auth-flow"

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
TARGET="<what the user wants diagrammed>"  # e.g. "the auth flow"
TARGET_SLUG="<slugified-target-name>"      # e.g. "auth-flow"

export GC_TASK="Find all files relevant to: $TARGET. I need to understand the components, relationships, data flow, and interactions so I can diagram it."

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
  > /tmp/gc_diagram_result.json 2>/tmp/gc_diagram_error.log
```

Validate the result:

```bash
if [ ! -s /tmp/gc_diagram_result.json ]; then
  echo "ERROR: Gather-context returned empty result" >&2
  cat /tmp/gc_diagram_error.log >&2
  exit 1
fi

jq -e '.result' /tmp/gc_diagram_result.json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: Gather-context returned invalid JSON" >&2
  exit 1
fi
```

Extract the relevant file paths from the findings and build the context
file by reading each discovered file:

```bash
CONTEXT="/tmp/diagram_context_$(date +%Y%m%d_%H%M%S).txt"

# Parse findings from gather-context result
# The result contains findings with file_path, relevance, summary, key_content
GC_RESULT=$(jq -r '.result' /tmp/gc_diagram_result.json)

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
the diagram inline. Skip Steps 3-4 and go straight to Step 5.

If 80,000+ characters: continue to Step 3 for RLM dispatch.

## Step 3: Set RLM_TASK

Build the diagram generation prompt. Include the target name and
diagram type so every RLM child knows what it is diagramming and in
what format.

```bash
# Map diagram type to the correct Mermaid syntax hint
case "$DIAGRAM_TYPE" in
  architecture) MERMAID_HINT="graph TD (top-down) or graph LR (left-right) for component/architecture diagrams" ;;
  sequence)     MERMAID_HINT="sequenceDiagram with participant, ->>, -->> arrows" ;;
  flowchart)    MERMAID_HINT="flowchart TD with decision diamonds {}, process rectangles [], and directional arrows" ;;
  state)        MERMAID_HINT="stateDiagram-v2 with [*] for start/end, --> for transitions" ;;
  class)        MERMAID_HINT="classDiagram with class definitions, <|-- inheritance, *-- composition, o-- aggregation" ;;
  er)           MERMAID_HINT="erDiagram with entity blocks and ||--o{ relationship notation" ;;
  *)            MERMAID_HINT="graph TD (top-down) or graph LR (left-right) for component/architecture diagrams" ;;
esac

export RLM_TASK="Produce a Mermaid diagram ($DIAGRAM_TYPE type) of: $TARGET

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

## Step 4: Dispatch to rlm-orchestrator

Invoke the rlm-orchestrator agent. It handles all config loading,
chunking, and sub-agent delegation internally.

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

Write the diagram (whether produced inline or by RLM) to a file:

```bash
OUTPUT_DIR="derived/descriptive"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$OUTPUT_DIR/$TARGET_SLUG-diagram-$TIMESTAMP.md"

cat > "$OUTPUT" <<EOF
---
generated: $(date -Iseconds)
type: diagram
diagram_type: $DIAGRAM_TYPE
target: $TARGET
input_size: $CONTEXT_SIZE bytes
---

# Diagram: $TARGET

EOF

# Append the result from RLM or inline processing
echo "$RESULT" >> "$OUTPUT"

echo "Saved to: $OUTPUT"
```

## Step 6: Present and cleanup

1. Show the user the diagram output (render the Mermaid if the environment supports it, otherwise show the raw code block)
2. Tell them where the file was saved
3. Note that the Mermaid block can be rendered in GitHub, VS Code (with extension), Notion, or any Mermaid-compatible viewer
4. Clean up temp files:

```bash
rm -f "$CONTEXT"
rm -f /tmp/gc_diagram_result.json /tmp/gc_diagram_error.log
rm -f /tmp/gc_*.json 2>/dev/null
```

## What happens inside

When gather-context is used (Mode B), the workers handle discovery:
1. Root worker lists the project directory, filters exclusions
2. File workers assess each file's relevance to the target concept
3. Directory workers recurse and aggregate child results
4. Results bubble upward — you get back relevant file paths and summaries
5. This skill reads those files to build the context

When RLM is used (large input), the orchestrator handles processing:
1. Peeks at the context, determines structure
2. Chunks the content into manageable pieces
3. Each chunk is processed by an rlm-child that identifies diagram-relevant components and relationships
4. Results are aggregated into a coherent diagram with prose explanation
5. Final Mermaid diagram and explanation are returned

For small input (under 80K), you process directly — no sub-agents needed.
