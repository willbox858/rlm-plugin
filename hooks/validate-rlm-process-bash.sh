#!/bin/bash
# Hook: PreToolUse guard for rlm-process agent.
# Redirects the orchestrator toward delegation when it tries to read too much.

COMMAND=$(jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

deny() {
  jq -n \
    --arg reason "$1" \
    '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": $reason
      }
    }'
  exit 0
}

# --- REDIRECT PATTERNS ---

# 1. head -c N or tail -c N where N > 1000 → split and delegate instead
for match in $(echo "$COMMAND" | grep -oE '(head|tail)\s+-c\s*[0-9]+' | grep -oE '[0-9]+$'); do
  if [ "$match" -gt 1000 ]; then
    deny "To read more than 1000 bytes, split the input into chunks and dispatch rlm-child workers via launch.sh — each child processes its chunk and returns a result for you to aggregate."
  fi
done

# 2. cat reading non-tmp files → split and delegate
if echo "$COMMAND" | grep -qE '\bcat\s+[^|>]' && ! echo "$COMMAND" | grep -qE '\bcat\s*>'; then
  if ! echo "$COMMAND" | grep -qE '\bcat\s+/tmp/'; then
    deny "To process full file content, split it into chunks and dispatch rlm-child workers via launch.sh — use head -c 1000 to peek at structure, then split based on what you find."
  fi
fi

# 3. In-place file editing → orchestrators produce output, not modifications
if echo "$COMMAND" | grep -qE 'sed\s+-i'; then
  deny "To produce output, aggregate child results and return them — the orchestrator's product is the aggregated answer, not file modifications."
fi

# 4. Writing to non-tmp paths → orchestrators write only to /tmp/
if echo "$COMMAND" | grep -oE '>{1,2}\s*[^ ]+' | grep -vE '>\s*/tmp/' | grep -vE '>\s*/dev/' | grep -vE '>\s*&' | grep -qE '>\s*[a-zA-Z./]'; then
  deny "To save intermediate results, write to /tmp/ — the orchestrator works with temp files for chunks and child results, and returns the final answer as its output."
fi

# 5. Running interpreters → delegate processing to children
if echo "$COMMAND" | grep -qE '(python|python3|node|ruby|perl|php)\s+(-c|-e|<|[^ ]*\.(py|js|rb|pl|php))'; then
  deny "To process or transform content, dispatch rlm-child workers via launch.sh — they handle content processing at leaf depth."
fi

# 6. Reading source files directly by extension → peek and delegate
SOURCE_EXTS='\.(ts|js|py|rs|go|java|cs|cpp|c|rb|tsx|jsx|swift|kt|scala|vue|svelte)'
if echo "$COMMAND" | grep -qE "(cat|head|tail)\s+[^ ]*${SOURCE_EXTS}(\s|$)"; then
  if ! echo "$COMMAND" | grep -qE "(cat|head|tail)\s+/tmp/"; then
    deny "To analyze source files, dispatch rlm-child workers via launch.sh — use head -c 1000 to peek at the file, then delegate the full read to a child."
  fi
fi

# --- ALLOW everything else ---
# Legitimate: launch.sh, split, dd, wc, grep|head, jq, echo, cd, etc.
exit 0
