#!/bin/bash
# Hook: Whitelist-based Bash validation for the implementation-orchestrator.
#
# The orchestrator is an RLM-style agent that decomposes work into sub-agent
# calls via launch.sh, runs verification commands, and tracks iteration state.
# This hook ensures it stays in that role instead of doing implementation work.

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

# Strip leading whitespace for matching
TRIMMED=$(echo "$COMMAND" | sed 's/^[[:space:]]*//')
FIRST_LINE=$(echo "$COMMAND" | head -1 | sed 's/^[[:space:]]*//')

# --- WHITELIST ---
# These are the things an RLM orchestrator legitimately does.

# 1. Sub-agent calls via launch.sh (the core RLM pattern)
echo "$COMMAND" | grep -qE 'launch\.sh' && exit 0

# 2. Verification commands (eval with test/build/lint vars)
echo "$COMMAND" | grep -qE 'eval\s+"?\$' && exit 0

# 3. Git operations (commit progress after each iteration)
echo "$COMMAND" | grep -qE 'git\s+(add|commit|status|diff|log)' && exit 0

# 4. JSON parsing (reading sub-agent results)
echo "$COMMAND" | grep -qE '(^|\|)\s*jq\s' && exit 0

# 5. Working directory management
echo "$COMMAND" | grep -qE '^\s*cd\s' && exit 0

# 6. Shell control flow, variables, and environment
echo "$TRIMMED" | grep -qE '^(if|then|else|fi|for|do|done|while|case|esac|export|unset)\b' && exit 0
echo "$TRIMMED" | grep -qE '^\[' && exit 0
echo "$TRIMMED" | grep -qE '^[A-Z_][A-Z0-9_]*=' && exit 0

# 7. Logging
echo "$COMMAND" | grep -qE '^\s*echo\s' && exit 0

# 8. Temp file operations (reading results, writing intermediate state)
echo "$COMMAND" | grep -qE '(cat|head|tail)\s+/tmp/' && exit 0
echo "$COMMAND" | grep -qE '^\s*rm\s+-f\s+/tmp/' && exit 0
echo "$COMMAND" | grep -qE '^\s*mkdir\s' && exit 0
echo "$COMMAND" | grep -qE '^\s*test\s' && exit 0

# 9. Output parsing utilities (wc, grep in pipes, sed without -i)
echo "$COMMAND" | grep -qE '^\s*wc\s' && exit 0
echo "$COMMAND" | grep -qE '\|\s*grep\s' && exit 0
echo "$COMMAND" | grep -qE '^\s*grep\s.*(/tmp/|EXIT_CODE|FAIL|ERROR|PASS)' && exit 0
echo "$COMMAND" | grep -qE '^\s*sed\s' && ! echo "$COMMAND" | grep -qE 'sed\s+-i' && exit 0

# 10. Path resolution (finding configs)
echo "$COMMAND" | grep -qE '^\s*(find|dirname|basename|realpath)\s' && exit 0

# 11. Compound commands (first line matches an allowed pattern)
echo "$FIRST_LINE" | grep -qE '^(bash\s|eval\s|git\s|jq\s|cd\s|echo\s|\[|if\s|for\s|while\s|export\s|[A-Z_][A-Z0-9_]*=|cat\s+/tmp/|test\s|rm\s|mkdir\s|wc\s|find\s|dirname|sed\s|grep\s|\{|\()' && exit 0

# 12. Braces and subshells for grouping
echo "$TRIMMED" | grep -qE '^\s*[\{\(]' && exit 0

# --- DENY everything else ---
deny "You are an RLM orchestrator — your job is to decompose work into sub-agent calls. To write or modify code, dispatch impl-worker via launch.sh. To write or fix tests, dispatch impl-test-writer. To analyze failures, dispatch impl-verifier. To scan the codebase, dispatch gc-worker. You call them with: bash \"\$RLM_ROOT/launch.sh\" <config> \"<prompt>\" [KEY=VALUE ...]"
