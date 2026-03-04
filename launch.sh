#!/usr/bin/env bash
# launch.sh — Unified launcher for RLM sub-agents
#
# Usage: bash launch.sh <config> <prompt> [KEY=VALUE ...]
#
# Three categories, cleanly separated:
#   Config file ($1)    — which agent, schema, format, stdin behavior, env defaults
#   Prompt ($2)         — what to do (where agent intelligence belongs)
#   Key=value pairs     — per-invocation data, exported as env vars

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
AGENT="$(jq -r '.agent' "$CONFIG")"
OUTPUT_FORMAT="$(jq -r '.output_format' "$CONFIG")"
SCHEMA="$(jq -c '.json_schema' "$CONFIG")"
STDIN_MODE="$(jq -r '.stdin // "passthrough"' "$CONFIG")"
PERMISSION_MODE="$(jq -r '.permission_mode // ""' "$CONFIG")"

# --- Build permission flag ---
PERM_FLAG=()
if [ -n "$PERMISSION_MODE" ]; then
  PERM_FLAG=(--permission-mode "$PERMISSION_MODE")
fi

# --- Launch agent ---
if [ "$STDIN_MODE" = "devnull" ]; then
  env -u CLAUDECODE claude -p "$PROMPT" \
    --agent "$AGENT" \
    --output-format "$OUTPUT_FORMAT" --json-schema "$SCHEMA" \
    "${PERM_FLAG[@]}" \
    < /dev/null
else
  env -u CLAUDECODE claude -p "$PROMPT" \
    --agent "$AGENT" \
    --output-format "$OUTPUT_FORMAT" --json-schema "$SCHEMA" \
    "${PERM_FLAG[@]}"
fi
