---
name: rlm-distill
description: "Extract decisions, requirements, key points, and open questions from long conversation history or large documents using RLM for thorough processing. Prefer this over inline summarization when the conversation is long, when precision matters (exact decisions, not paraphrases), or when preparing structured input for /rlm-design or /plan-feature. Trigger when: resuming after a break, 'catch me up', 'what did we decide', 'summarize our conversation', 'extract decisions', processing meeting notes or specs."
---

# Distill — Extract Decisions and Key Points

Processes conversation history (Claude session JSONL logs) or provided
files to extract structured decisions, requirements, key insights, and
open questions. Dispatches to the existing RLM pipeline for large inputs.

## When to use

- Resuming work after a break — "catch me up on what we did"
- Extracting decisions and requirements from past sessions
- Preparing structured context for `/rlm-design` or planning
- Processing meeting notes, spec documents, or long discussions
- User explicitly says "distill", "extract decisions", "what was decided"

## When NOT to use

- Short conversation you can just scroll up and read
- Want code context from the codebase (use `/rlm-map`)
- Want to search for specific text (use grep)
- Context is already small and in your window (just answer directly)

## Step 0: Determine input source

Ask or infer which mode applies:

**Mode A — Session logs** (default when user says "catch me up" or "distill our conversation"):
Find JSONL logs in the Claude projects directory.

```bash
# Resolve the project session directory
PROJECT_DIR="$HOME/.claude/projects"
# Find the slug matching the current working directory
CWD_SLUG=$(pwd | sed 's|/|--|g' | sed 's|^-*||')
SESSION_DIR="$PROJECT_DIR/$CWD_SLUG"

if [ ! -d "$SESSION_DIR" ]; then
  echo "No session directory found at $SESSION_DIR"
  echo "Try providing a file path instead."
  exit 1
fi

echo "Found session directory: $SESSION_DIR"
ls -lt "$SESSION_DIR"/*.jsonl 2>/dev/null | head -10
```

Let the user pick which sessions (default: most recent, or all).

**Mode B — Provided file**: User points to a specific file or set of files.
Use the file path(s) directly.

**Mode C — Current conversation**: Content is already in context and
is small. Skip to producing the distillation inline — no RLM dispatch needed.

## Step 1: Prepare context file

For **Mode A** (session logs), filter JSONL to keep only user/assistant
text messages, stripping tool_use, tool_result, thinking blocks, and
system messages:

```bash
CONTEXT="/tmp/distill_context_$(date +%Y%m%d_%H%M%S).txt"

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
done > "$CONTEXT"

SESSION_COUNT=$(ls "$SESSION_DIR"/*.jsonl 2>/dev/null | wc -l)
echo "Prepared context: $(wc -c < "$CONTEXT") bytes, $(wc -l < "$CONTEXT") lines from $SESSION_COUNT sessions"
```

For **Mode B** (provided files), concatenate with markers:

```bash
CONTEXT="/tmp/distill_context_$(date +%Y%m%d_%H%M%S).txt"
for f in $FILES; do
  echo "===== FILE: $f =====" >> "$CONTEXT"
  cat "$f" >> "$CONTEXT"
done
```

## Step 2: Size check

```bash
CONTEXT_SIZE=$(wc -c < "$CONTEXT")
echo "Context size: $CONTEXT_SIZE bytes"
```

If under 80,000 characters: read the context file directly and produce
the distillation inline. Skip Steps 3-4 and go straight to Step 5.

If 80,000+ characters: continue to Step 3 for RLM dispatch.

## Step 3: Set RLM_TASK

Build the extraction prompt. If the user specified a focus topic,
prepend it as a filter.

```bash
FOCUS=""  # Set from user input if they specified a topic, e.g. "auth work"

if [ -n "$FOCUS" ]; then
  FOCUS_LINE="Focus: $FOCUS — prioritize content related to this topic.

"
fi

export RLM_TASK="${FOCUS_LINE}Distill this conversation/document into structured findings. For every substantive point, tag it with exactly one of these prefixes:

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
```

## Step 4: Dispatch to rlm-process

Invoke the rlm-process agent. It handles all config loading,
chunking, and sub-agent delegation internally.

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

Write the distillation (whether produced inline or by RLM) to a file:

```bash
OUTPUT_DIR="derived/drafts"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$OUTPUT_DIR/distill-$TIMESTAMP.md"

cat > "$OUTPUT" <<EOF
---
generated: $(date -Iseconds)
type: distillation
sessions: $SESSION_COUNT
input_size: $CONTEXT_SIZE bytes
---

# Distillation

EOF

# Append the result from RLM or inline processing
echo "$RESULT" >> "$OUTPUT"

echo "Saved to: $OUTPUT"
```

## Step 6: Present and cleanup

1. Show the user the distillation output (or a summary if it's long)
2. Tell them where the file was saved
3. Clean up temp files:

```bash
rm -f "$CONTEXT"
```

## What happens inside

When RLM is used (large input), you don't manage this — the orchestrator
handles it:
1. Peeks at the context, determines structure
2. Chunks the conversation into manageable pieces
3. Each chunk is processed by an rlm-child that extracts tagged findings
4. Results are aggregated and deduplicated
5. Final structured output is returned

For small input (under 80K), you process directly — no sub-agents needed.
