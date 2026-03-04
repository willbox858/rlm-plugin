#!/bin/bash
# Hook: Validate that head/tail peek commands stay within RLM limits.
# RLM agents must never read more than 1000 bytes at a time.
# This catches head -c N and tail -c N where N > 1000.

MAX_PEEK_BYTES=1000

COMMAND=$(jq -r '.tool_input.command' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Extract byte counts from head -c <N> and tail -c <N>
# Matches: head -c 5000, head -c5000, tail -c 50000
for match in $(echo "$COMMAND" | grep -oE '(head|tail)\s+-c\s*[0-9]+' | grep -oE '[0-9]+$'); do
  if [ "$match" -gt "$MAX_PEEK_BYTES" ]; then
    jq -n \
      --arg reason "RLM peek limit exceeded: requested ${match} bytes but max is ${MAX_PEEK_BYTES}. Orchestrators must delegate large reads to child agents, not read directly." \
      '{
        "hookSpecificOutput": {
          "hookEventName": "PreToolUse",
          "permissionDecision": "deny",
          "permissionDecisionReason": $reason
        }
      }'
    exit 0
  fi
done

# Also catch cat (full file reads) — orchestrators should never cat entire files
if echo "$COMMAND" | grep -qE '^\s*cat\s+[^|]' && ! echo "$COMMAND" | grep -qE '^\s*cat\s*>' ; then
  # Allow cat > (writing) but block cat <file> (reading)
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "RLM orchestrators must not cat entire files. Use head -c 1000 to peek, or delegate full reads to child agents."
    }
  }'
  exit 0
fi

exit 0
