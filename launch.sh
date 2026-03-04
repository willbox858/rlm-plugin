#!/usr/bin/env bash
# launch.sh — Unified launcher for RLM sub-agents
#
# Usage: bash launch.sh <config> <prompt> [KEY=VALUE ...]
#
# Three categories, cleanly separated:
#   Config file ($1)    — agent definition + launch settings (single JSON)
#   Prompt ($2)         — what to do (where agent intelligence belongs)
#   Key=value pairs     — per-invocation data, exported as env vars
#
# The config JSON contains: model, tools, max_turns, skills, permission_mode,
# output_format, json_schema, stdin, env_defaults, system_prompt.
# launch.sh assembles these into CLI flags for `claude -p`.

set -euo pipefail

# --- Validate args ---
if [ $# -lt 2 ]; then
  echo "Usage: bash launch.sh <config> <prompt> [KEY=VALUE ...]" >&2
  exit 1
fi

CONFIG="$1"
PROMPT="$2"
shift 2

if [ ! -f "$CONFIG" ]; then
  echo "FATAL: Config not found at $CONFIG" >&2
  exit 1
fi

# --- Export RLM_ROOT (prefer CLAUDE_PLUGIN_ROOT if set by plugin system) ---
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  export RLM_ROOT="$CLAUDE_PLUGIN_ROOT"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export RLM_ROOT="$SCRIPT_DIR"
fi

# --- Set env var defaults from config (only if not already set) ---
while IFS='=' read -r key value; do
  if [ -z "${!key:-}" ]; then
    export "$key=$value"
  fi
done < <(jq -r '.env_defaults // {} | to_entries[] | "\(.key)=\(.value)"' "$CONFIG")

# --- Export per-invocation KEY=VALUE args ---
for arg in "$@"; do
  if [[ "$arg" == *=* ]]; then
    export "$arg"
  else
    echo "WARNING: Ignoring non-KEY=VALUE arg: $arg" >&2
  fi
done

# --- Load config values ---
MODEL="$(jq -r '.model // "sonnet"' "$CONFIG")"
TOOLS="$(jq -r '.tools | if type == "array" then join(",") else . end' "$CONFIG")"
MAX_TURNS="$(jq -r '.max_turns // 30' "$CONFIG")"
OUTPUT_FORMAT="$(jq -r '.output_format' "$CONFIG")"
SCHEMA="$(jq -c '.json_schema' "$CONFIG")"
STDIN_MODE="$(jq -r '.stdin // "passthrough"' "$CONFIG")"
PERMISSION_MODE="$(jq -r '.permission_mode // ""' "$CONFIG")"

# --- Build system prompt file (skills + agent instructions) ---
PROMPT_FILE=$(mktemp /tmp/rlm_prompt_XXXXXX.md)
trap "rm -f $PROMPT_FILE" EXIT

# Load skill files (strip YAML frontmatter, keep body)
while IFS= read -r skill; do
  SKILL_FILE="$RLM_ROOT/skills/$skill/SKILL.md"
  if [ -f "$SKILL_FILE" ]; then
    # Strip frontmatter (everything between first pair of ---)
    awk 'BEGIN{n=0;p=0} /^---$/{n++;if(n==2){p=1;next}} p{print}' "$SKILL_FILE" >> "$PROMPT_FILE"
    printf '\n' >> "$PROMPT_FILE"
  fi
done < <(jq -r '.skills // [] | .[]' "$CONFIG")

# Append agent system prompt
jq -r '.system_prompt // ""' "$CONFIG" >> "$PROMPT_FILE"

# --- Build CLI flags ---
PERM_FLAG=()
if [ -n "$PERMISSION_MODE" ]; then
  PERM_FLAG=(--permission-mode "$PERMISSION_MODE")
fi

# --- Launch agent ---
if [ "$STDIN_MODE" = "devnull" ]; then
  env -u CLAUDECODE claude -p "$PROMPT" \
    --model "$MODEL" \
    --tools "$TOOLS" \
    --max-turns "$MAX_TURNS" \
    --append-system-prompt-file "$PROMPT_FILE" \
    --output-format "$OUTPUT_FORMAT" --json-schema "$SCHEMA" \
    "${PERM_FLAG[@]}" \
    < /dev/null
else
  env -u CLAUDECODE claude -p "$PROMPT" \
    --model "$MODEL" \
    --tools "$TOOLS" \
    --max-turns "$MAX_TURNS" \
    --append-system-prompt-file "$PROMPT_FILE" \
    --output-format "$OUTPUT_FORMAT" --json-schema "$SCHEMA" \
    "${PERM_FLAG[@]}"
fi
