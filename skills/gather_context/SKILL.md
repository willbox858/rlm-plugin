---
name: gather_context
description: "Dynamically gather relevant context from a codebase for a given task. Recursively traverses the filesystem with parallel Haiku agents, assessing every file's relevance and extracting key content. Returns a structured JSON context payload. Use when starting a new task, researching a codebase, or preparing context for planning/implementation agents."
---

# Gather Context — Dispatch to Workers

Recursively traverse the project directory tree with lightweight Haiku
agents, assessing every file for relevance to a given task. Returns a
structured context payload with relevant findings, a file map, suggested
reading order, and identified gaps.

## When to use

- Starting a new task and need to understand what's relevant
- Researching an unfamiliar codebase
- Preparing context for planning or implementation agents
- User asks to "gather context", "find relevant files", or "map the codebase"

## When NOT to use

- You already know which files are relevant
- A quick grep/glob answers the question
- The codebase is tiny (< 20 files)

## Step 0: Capture task

Store the user's request verbatim. This is the "guiding light" that
every worker uses to assess relevance.

```bash
export GC_TASK="<the user's original request, verbatim, unmodified>"
```

## Step 1: Load config and resolve launcher

Read `configs/gc.json` from the plugin directory for defaults.
User-set env vars take precedence. Also resolve the launcher path.

```bash
# Find the config file and launcher
if [ -n "$RLM_ROOT" ]; then
  CONFIG="$RLM_ROOT/configs/gc.json"
  LAUNCHER="$RLM_ROOT/launch.sh"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CONFIG="$CLAUDE_PLUGIN_ROOT/configs/gc.json"
  LAUNCHER="$CLAUDE_PLUGIN_ROOT/launch.sh"
else
  CONFIG="$(find . -path '*/.claude/RLM/configs/gc.json' -print -quit 2>/dev/null)"
  if [ -z "$CONFIG" ]; then
    CONFIG="$HOME/.claude/RLM/configs/gc.json"
  fi
  LAUNCHER="$(dirname "$(dirname "$CONFIG")")/launch.sh"
fi

# Load defaults, user env vars override
export GC_MAX_AGENTS="${GC_MAX_AGENTS:-$(jq -r '.env_defaults.GC_MAX_AGENTS // "50"' "$CONFIG" 2>/dev/null || echo 50)}"
export GC_EXCLUDE="${GC_EXCLUDE:-$(jq -r '.env_defaults.GC_EXCLUDE // "node_modules,.git,target,dist,build,out,__pycache__,.venv,vendor,.claude,*.lock"' "$CONFIG" 2>/dev/null || echo 'node_modules,.git,target,dist,build,out,__pycache__,.venv,vendor,.claude,*.lock')}"
export GC_MAX_FILE_SIZE="${GC_MAX_FILE_SIZE:-$(jq -r '.env_defaults.GC_MAX_FILE_SIZE // "512000"' "$CONFIG" 2>/dev/null || echo 512000)}"
```

Defaults:
- `GC_MAX_AGENTS`: 50 (0 = unlimited)
- `GC_EXCLUDE`: `node_modules,.git,target,dist,build,out,__pycache__,.venv,vendor,.claude,*.lock`

## Step 2: Dispatch root worker

Spawn a single gather-context-worker in directory mode at the project
root. It recursively spawns children for the entire tree.

```bash
bash "$LAUNCHER" "$CONFIG" "Task: $GC_TASK
mode: directory
directory: ." \
  > /tmp/gc_root_result.json 2>/tmp/gc_root_error.log
```

The launcher handles `env -u CLAUDECODE`, `< /dev/null` (via config),
schema, output format, and env defaults automatically.

## Step 3: Validate

```bash
if [ ! -s /tmp/gc_root_result.json ]; then
  echo "ERROR: Root worker returned empty result" >&2
  cat /tmp/gc_root_error.log >&2
  exit 1
fi

# Verify valid JSON
jq -e '.result' /tmp/gc_root_result.json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: Root worker returned invalid JSON" >&2
  exit 1
fi
```

## Step 4: Format final output

Parse the root worker's aggregated findings and structure the final
context payload.

The root worker returns:
```json
{"result": "{\"findings\":[...]}"}
```

Transform into the final output:

```json
{
  "task": "implement user authentication",
  "summary": "Executive summary synthesized from aggregated findings...",
  "findings": [
    {
      "file_path": "src/auth/handler.ts",
      "relevance": "high",
      "summary": "JWT validation and session management",
      "key_content": "export async function handleAuth..."
    }
  ],
  "file_map": {
    "src/auth/handler.ts": "JWT validation and session management",
    "src/auth/types.ts": "Auth type definitions"
  },
  "suggested_reading_order": ["src/auth/types.ts", "src/auth/handler.ts"],
  "gaps": ["No auth-related test files found"]
}
```

Building this output:

1. **findings**: All findings from the root worker, sorted by relevance
   (high first, then medium, then low). Remove "none" entries.
2. **file_map**: Dictionary of file_path -> summary for quick reference.
3. **suggested_reading_order**: Order files logically:
   - Types/interfaces first (foundations)
   - Configuration second
   - Core implementation third
   - Tests last
   Within each category, sort by relevance (high before medium).
4. **summary**: Synthesize a 2-3 sentence executive summary of what was
   found and how it relates to the task.
5. **gaps**: Note what's missing — e.g., no tests found, no
   documentation, missing configuration for a feature.

## Step 5: Cleanup

```bash
rm -f /tmp/gc_root_result.json /tmp/gc_root_error.log
rm -f /tmp/gc_*.json 2>/dev/null
```

## Output

Present the structured context payload to the user or calling agent.
If the output is large, summarize the key findings first, then provide
the full JSON.

## What happens inside

You don't manage this — the workers handle it:

1. Root worker lists project directory, filters exclusions
2. Spawns file workers (Haiku) per file — each reads, assesses, extracts
3. Spawns directory workers per subdirectory — each recurses the pattern
4. Directory workers aggregate child results, filter out irrelevant findings
5. Results bubble upward through the tree
6. Root worker returns all relevant findings as aggregated JSON
7. This skill formats the final context payload
