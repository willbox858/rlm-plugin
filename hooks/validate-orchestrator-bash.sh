#!/bin/bash
# Hook: Validate Bash commands for the implementation-orchestrator agent.
# Redirects the orchestrator toward delegation when it tries to do work directly.
# Uses a targeted blacklist: allow by default, redirect on dangerous patterns.

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

# 1. In-place file editing → delegate to impl-worker
if echo "$COMMAND" | grep -qE 'sed\s+-i'; then
  deny "To edit source files, dispatch impl-worker via launch.sh — it understands code style and will make targeted changes."
fi

# 2. Writing to non-tmp paths → delegate to the appropriate worker
if echo "$COMMAND" | grep -oE '>{1,2}\s*[^ ]+' | grep -vE '>\s*/tmp/' | grep -vE '>\s*/dev/' | grep -vE '>\s*&' | grep -qE '>\s*[a-zA-Z./]'; then
  deny "To write source or test files, dispatch impl-worker (for source) or impl-test-writer (for tests) via launch.sh — they work inside the worktree and follow project conventions."
fi

# 3. tee to non-tmp paths → same as above
if echo "$COMMAND" | grep -qE 'tee\s' && ! echo "$COMMAND" | grep -qE 'tee\s+/tmp/'; then
  deny "To write files, dispatch impl-worker or impl-test-writer via launch.sh — they handle file creation inside the worktree."
fi

# 4. Reading source files directly → delegate to workers who have Read/Grep/Glob
SOURCE_EXTS='\.(ts|js|py|rs|go|java|cs|cpp|c|rb|tsx|jsx|swift|kt|scala|vue|svelte|sh|json|yaml|yml|toml|cfg|ini|xml|html|css|scss|less|sql|proto|graphql|ex|exs|clj|hs|ml|php|pl|r|m|h|hpp)'
if echo "$COMMAND" | grep -qE "(cat|head|tail)\s+[^ ]*${SOURCE_EXTS}(\s|$|:)"; then
  if ! echo "$COMMAND" | grep -qE "(cat|head|tail)\s+/tmp/"; then
    deny "To understand code, dispatch impl-worker or gc-worker via launch.sh — they have Read, Grep, and Glob tools and will report back what they find."
  fi
fi

# 5. Running interpreters → delegate to impl-worker
if echo "$COMMAND" | grep -qE '(python|python3|node|ruby|perl|php)\s+(-c|-e|<|[^ ]*\.(py|js|rb|pl|php))'; then
  deny "To generate or transform code, dispatch impl-worker via launch.sh — it handles code generation inside the worktree."
fi

# 6. Package managers → include in the plan or dispatch impl-worker
if echo "$COMMAND" | grep -qE '(npm|yarn|pnpm|pip|pip3|cargo|gem|composer|go get|go install)\s+(install|add|remove|uninstall)'; then
  deny "To install dependencies, include it as a task in the impl-worker prompt — the worker runs inside the worktree and can manage packages as part of implementation."
fi

# --- ALLOW everything else ---
# Legitimate orchestrator patterns: launch.sh, eval, git, jq, cd, echo, etc.
exit 0
