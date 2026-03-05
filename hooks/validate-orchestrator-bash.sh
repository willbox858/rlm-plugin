#!/bin/bash
# Hook: Whitelist-based Bash validation for the implementation-orchestrator.
# Only allows the specific command patterns the orchestrator legitimately needs.
# Everything else is denied with a redirect to the appropriate worker.

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

# --- WHITELIST: Allow only these patterns ---

# 1. Dispatching workers via launch.sh
if echo "$COMMAND" | grep -qE 'bash\s+.*launch\.sh'; then
  exit 0
fi

# 2. Running verification commands (eval with test/build/lint vars)
if echo "$COMMAND" | grep -qE 'eval\s+"\$'; then
  exit 0
fi

# 3. Git operations (add, commit)
if echo "$COMMAND" | grep -qE '^\s*git\s+(add|commit)'; then
  exit 0
fi
# Also allow git inside compound commands
if echo "$COMMAND" | grep -qE 'git\s+(add|commit)' && ! echo "$COMMAND" | grep -qE 'git\s+(push|reset|checkout|rebase|merge)'; then
  exit 0
fi

# 4. Parsing JSON results with jq
if echo "$COMMAND" | grep -qE '^\s*jq\s'; then
  exit 0
fi
if echo "$COMMAND" | grep -qE '\|\s*jq\s'; then
  exit 0
fi

# 5. Changing to worktree directory
if echo "$COMMAND" | grep -qE '^\s*cd\s'; then
  exit 0
fi

# 6. Environment variable validation and control flow
if echo "$COMMAND" | grep -qE '^\s*\['; then
  exit 0
fi
if echo "$COMMAND" | grep -qE '^\s*(if|then|else|fi|for|do|done|while|case|esac)\b'; then
  exit 0
fi
if echo "$COMMAND" | grep -qE '^\s*(export|unset)\s'; then
  exit 0
fi
# Variable assignments (VAR=value or VAR=$(command))
if echo "$TRIMMED" | grep -qE '^[A-Z_][A-Z0-9_]*='; then
  exit 0
fi

# 7. Echo (logging)
if echo "$COMMAND" | grep -qE '^\s*echo\s'; then
  exit 0
fi

# 8. Reading/writing temp files only
if echo "$COMMAND" | grep -qE '^\s*(cat|head|tail)\s+/tmp/'; then
  exit 0
fi

# 9. File existence checks on specific paths (plan file, config, worktree)
if echo "$COMMAND" | grep -qE '^\s*test\s'; then
  exit 0
fi

# 10. Cleanup of temp files
if echo "$COMMAND" | grep -qE '^\s*rm\s+-f\s+/tmp/'; then
  exit 0
fi

# 11. mkdir for temp dirs
if echo "$COMMAND" | grep -qE '^\s*mkdir\s'; then
  exit 0
fi

# 12. wc (counting)
if echo "$COMMAND" | grep -qE '^\s*wc\s'; then
  exit 0
fi

# 13. Multi-line compound commands that start with allowed patterns
# Check if the first meaningful line matches an allowed pattern
FIRST_LINE=$(echo "$COMMAND" | head -1 | sed 's/^[[:space:]]*//')
if echo "$FIRST_LINE" | grep -qE '^(bash\s.*launch|eval\s|git\s|jq\s|cd\s|echo\s|\[|if\s|for\s|while\s|export\s|[A-Z_][A-Z0-9_]*=|cat\s+/tmp/|test\s|rm\s|mkdir\s|wc\s|\{)'; then
  exit 0
fi

# 14. Braces for grouping and subshells
if echo "$TRIMMED" | grep -qE '^\s*[\{\(]'; then
  exit 0
fi

# --- DENY everything else ---
deny "To explore or understand code, dispatch impl-worker or gc-worker via launch.sh — they have Read, Grep, and Glob and will report back. To write code, dispatch impl-worker. To write tests, dispatch impl-test-writer. Your job is to call launch.sh to dispatch workers and run eval for verification."
