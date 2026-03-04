---
name: create_description
description: "Generate a clear prose description of how a module or feature works by first gathering code context across the codebase — produces accurate descriptions that reflect actual code, not assumptions. Prefer this over explaining inline when the topic spans multiple files. Trigger when: 'describe', 'explain how X works', 'how does X work', 'write up X', 'describe the architecture', or user wants a written explanation of any non-trivial part of the codebase."
---

# Create Description — Describe How Something Works

Generates a clear, well-structured prose description of a module, feature,
concept, or area of code. Output is a descriptive derived document written
for a developer new to the area. Dispatches to gather-context for discovery
and to the RLM pipeline for large inputs.

## When to use

- User asks to describe a module, feature, or concept
- User says "explain how X works" or "how does X work"
- Need a prose write-up of architecture, data flow, or design decisions
- Creating onboarding documentation for a part of the codebase
- User explicitly says "describe", "create a description", "document how X works"

## When NOT to use

- User wants a code change, not a description (use implementation tools)
- Want to extract decisions from conversations (use `/distill`)
- Want raw file listings or code search results (use `/gather-context` or grep)
- Context is trivially small and obvious — just answer directly
- User wants API reference docs, not prose explanation (use a doc generator)

## Step 0: Determine input mode

Ask or infer which mode applies:

**Mode A — Specific files**: User provides file paths explicitly.
Use those files directly as input.

**Mode B — Concept/module**: User names something ("the auth module",
"how routing works", "the payment flow") without giving file paths.
Auto-run gather-context to find relevant files — do NOT ask the user
for file paths. This is the most common mode.

**Mode C — Current conversation**: The relevant context is already
small and present in the conversation. Process inline — no file
gathering or RLM dispatch needed. Skip to Step 5.

## Step 1: Gather source material

**For Mode A** (specific files), concatenate with markers:

```bash
CONTEXT="/tmp/describe_context_$(date +%Y%m%d_%H%M%S).txt"
TARGET_SLUG="<slugified-target-name>"  # e.g. "auth-module", "routing-layer"

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
TARGET="<what the user wants described>"  # e.g. "the auth module"
TARGET_SLUG="<slugified-target-name>"     # e.g. "auth-module"

export GC_TASK="Find all files relevant to: $TARGET. I need to understand how it works — its purpose, components, data flow, and design decisions."

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
  > /tmp/gc_describe_result.json 2>/tmp/gc_describe_error.log
```

Validate the result:

```bash
if [ ! -s /tmp/gc_describe_result.json ]; then
  echo "ERROR: Gather-context returned empty result" >&2
  cat /tmp/gc_describe_error.log >&2
  exit 1
fi

jq -e '.result' /tmp/gc_describe_result.json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: Gather-context returned invalid JSON" >&2
  exit 1
fi
```

Extract the relevant file paths from the findings and build the context
file by reading each discovered file:

```bash
CONTEXT="/tmp/describe_context_$(date +%Y%m%d_%H%M%S).txt"

# Parse findings from gather-context result
# The result contains findings with file_path, relevance, summary, key_content
GC_RESULT=$(jq -r '.result' /tmp/gc_describe_result.json)

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
the description inline. Skip Steps 3-4 and go straight to Step 5.

If 80,000+ characters: continue to Step 3 for RLM dispatch.

## Step 3: Set RLM_TASK

Build the description prompt. Include the target name so every RLM
child knows what it is describing.

```bash
export RLM_TASK="Produce a clear, well-structured prose description of: $TARGET

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

Write the description (whether produced inline or by RLM) to a file:

```bash
OUTPUT_DIR="derived/descriptive"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$OUTPUT_DIR/$TARGET_SLUG-$TIMESTAMP.md"

cat > "$OUTPUT" <<EOF
---
generated: $(date -Iseconds)
type: description
target: $TARGET
input_size: $CONTEXT_SIZE bytes
---

# Description: $TARGET

EOF

# Append the result from RLM or inline processing
echo "$RESULT" >> "$OUTPUT"

echo "Saved to: $OUTPUT"
```

## Step 6: Present and cleanup

1. Show the user the description output (or a summary if it is long)
2. Tell them where the file was saved
3. Clean up temp files:

```bash
rm -f "$CONTEXT"
rm -f /tmp/gc_describe_result.json /tmp/gc_describe_error.log
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
3. Each chunk is processed by an rlm-child that writes a partial description
4. Results are aggregated into a coherent whole
5. Final prose description is returned

For small input (under 80K), you process directly — no sub-agents needed.
