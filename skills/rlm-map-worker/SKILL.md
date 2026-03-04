---
name: rlm-map-worker
description: "Shared methodology for map workers. Covers file-mode assessment, directory-mode orchestration, exclusion filtering, agent budget tracking, batch-mode fallback, aggregation strategy, and output format specifications."
---

# Gather-Context Worker Methodology

You are a gather-context worker. You assess files for relevance to a task
and recursively traverse directories to build a structured context map.

# Environment Variables

These are set by your parent. Pass them to any children you spawn.

- GC_TASK: The user's original task, verbatim. This is what you assess
  relevance against. Pass unmodified to every child.
- GC_EXCLUDE: Comma-separated list of patterns to skip (e.g.,
  `node_modules,.git,dist,*.lock`). Match against file/directory names.
- GC_MAX_AGENTS: Maximum total agent spawns. 0 = unlimited. When the
  estimated spawn count would exceed this, switch to batch mode.
- GC_MAX_FILE_SIZE: Maximum file size in bytes to assess. Files larger
  than this are skipped as likely generated. 0 = no limit. Default: 512000 (500KB).

# File Mode

When your prompt contains `mode: file`, you are a leaf worker processing
a single file.

## Step 1: Read the file

```bash
# Get the file path from your prompt
FILE="<path from prompt>"

# Check if readable and text
file "$FILE" 2>/dev/null
wc -c < "$FILE" 2>/dev/null
```

If the file is binary (images, compiled files, archives), unreadable, or
empty, return immediately with relevance "none".

Skip files larger than GC_MAX_FILE_SIZE (default 500KB) — they are likely generated or binary:
```bash
SIZE=$(wc -c < "$FILE" 2>/dev/null || echo 0)
MAX_SIZE="${GC_MAX_FILE_SIZE:-512000}"
if [ "$SIZE" -gt "$MAX_SIZE" ]; then
  # Too large, likely generated
fi
```

## Step 2: Assess relevance

Read the file content using the Read tool. Evaluate against GC_TASK:

- **high**: Directly implements, configures, or tests the feature/area
  mentioned in the task. Contains key logic, types, or interfaces.
- **medium**: Related but not central. Utility functions used by relevant
  code, adjacent configuration, related documentation.
- **low**: Tangentially related. Mentions relevant terms but isn't
  directly involved.
- **none**: Unrelated to the task. Boilerplate, unrelated features,
  generated files.

Be selective. Default to "none" unless there is a clear connection.

## Step 3: Extract key content

For relevant files (high/medium/low), extract the most useful content:
- Function/method signatures
- Type/interface definitions
- Key logic blocks
- Relevant comments or documentation
- Configuration values

Maximum 2000 characters of key_content. Focus on what would help someone
understand this file's role in the task.

Include line_range (e.g., "45-120") for the most relevant section.

## Step 4: Return result

```json
{"result": "{\"file_path\":\"<path>\",\"relevance\":\"high\",\"summary\":\"<1-line description>\",\"key_content\":\"<extracted content>\",\"line_range\":\"<start>-<end>\"}"}
```

For irrelevant files:
```json
{"result": "{\"file_path\":\"<path>\",\"relevance\":\"none\"}"}
```

# Directory Mode

When your prompt contains `mode: directory`, you orchestrate traversal
of a directory subtree.

## Step 1: List contents

```bash
DIR="<directory from prompt>"
ls -1 "$DIR" 2>/dev/null
```

## Step 2: Filter exclusions

Parse GC_EXCLUDE into an array and filter out matching entries:

```bash
EXCLUDE="$GC_EXCLUDE"
# For each item in ls output, check against exclusion patterns
# Skip if the name matches any pattern in EXCLUDE
```

Exclusion matching rules:
- Exact name match: `node_modules` matches `node_modules`
- Glob patterns: `*.lock` matches `package-lock.json`, `yarn.lock`
- Case-sensitive matching
- Only match against the basename, not the full path

Also always skip:
- Hidden files/directories starting with `.` (except `.env` files which
  may be relevant for configuration assessment)
- Files with no extension that are larger than 100KB (likely binary)

## Step 3: Check agent budget

Count files and subdirectories that passed filtering. Estimate total
agents needed (1 per file + 1 per subdirectory).

```bash
FILE_COUNT=<number of files>
DIR_COUNT=<number of subdirectories>
NEEDED=$((FILE_COUNT + DIR_COUNT))
MAX="$GC_MAX_AGENTS"
```

If MAX is 0 (unlimited), proceed normally.

If NEEDED > MAX, activate **batch mode**:
- Read files in this directory directly (inline) instead of spawning
  per-file agents. Assess each file yourself following the file-mode
  methodology above.
- Still spawn agents for subdirectories (they will also budget-check).
- Pass a reduced budget to subdirectory workers:
  `GC_MAX_AGENTS=$((MAX - DIR_COUNT))`

## Step 4: Spawn workers

### Normal mode (within budget)

```bash
# Resolve launcher and config — RLM_ROOT is exported by the launcher
if [ -n "$RLM_ROOT" ]; then
  LAUNCHER="$RLM_ROOT/launch.sh"
  CONFIG="$RLM_ROOT/internal/gc-worker.json"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  LAUNCHER="$CLAUDE_PLUGIN_ROOT/launch.sh"
  CONFIG="$CLAUDE_PLUGIN_ROOT/internal/gc-worker.json"
else
  CONFIG="$(find . -path '*/.claude/RLM/internal/gc-worker.json' -print -quit 2>/dev/null)"
  LAUNCHER="$(dirname "$(dirname "$CONFIG")")/launch.sh"
fi
TMPDIR="/tmp/gc_$(echo "$DIR" | md5sum | cut -c1-8)"
mkdir -p "$TMPDIR"

# File workers
for f in <filtered_files>; do
  SAFE_NAME=$(echo "$f" | tr '/' '_')
  bash "$LAUNCHER" "$CONFIG" "Task: $GC_TASK
mode: file
file: $DIR/$f" \
    > "$TMPDIR/file_${SAFE_NAME}.json" 2>/dev/null &
done

# Directory workers
for d in <filtered_subdirs>; do
  SAFE_NAME=$(echo "$d" | tr '/' '_')
  bash "$LAUNCHER" "$CONFIG" "Task: $GC_TASK
mode: directory
directory: $DIR/$d" \
    > "$TMPDIR/dir_${SAFE_NAME}.json" 2>/dev/null &
done

wait
```

The launcher handles `env -u CLAUDECODE`, `< /dev/null` (via config),
schema, output format, and env defaults automatically.

### Batch mode (over budget)

For files, process inline:
```bash
for f in <filtered_files>; do
  # Read file, assess relevance, build JSON result directly
  # Follow file-mode Steps 1-4 yourself
done
```

For subdirectories, still spawn agents but with reduced budget.

## Step 5: Collect and validate results

```bash
for r in "$TMPDIR"/*.json; do
  if [ ! -s "$r" ]; then
    echo "WARNING: Empty result from $r" >&2
    continue
  fi
  # Parse the JSON, extract the result field
  # The result field contains a JSON-encoded string of findings
done
```

## Step 6: Aggregate

1. Parse all child results
2. Filter out findings with `relevance: none`
3. Collect all remaining findings into a single array
4. Return as aggregated JSON

```json
{"result": "{\"findings\":[{\"file_path\":\"...\",\"relevance\":\"high\",...},{...}]}"}
```

The findings array contains every relevant file discovered in this
subtree. Directory workers bubble up their children's findings — they
do not add their own entries.

## Step 7: Cleanup

```bash
rm -rf "$TMPDIR"
```

# Output Format

All workers return JSON matching this schema:
```json
{"type":"object","properties":{"result":{"type":"string"}},"required":["result"]}
```

The `result` field is a JSON-encoded string containing either:

**File worker result:**
```json
{
  "file_path": "src/auth/handler.ts",
  "relevance": "high",
  "summary": "JWT validation and session management",
  "key_content": "export async function handleAuth...",
  "line_range": "45-120"
}
```

**Directory worker result (aggregated):**
```json
{
  "findings": [
    {"file_path": "...", "relevance": "high", "summary": "...", "key_content": "...", "line_range": "..."},
    {"file_path": "...", "relevance": "medium", "summary": "...", "key_content": "...", "line_range": "..."}
  ]
}
```

# Relevance Assessment Guidelines

When assessing relevance against GC_TASK, consider:

1. **Direct keyword matches**: Does the file contain terms from the task?
2. **Structural relevance**: Is this file in a directory that relates to
   the task? (e.g., `src/auth/` for an auth task)
3. **Dependency relevance**: Does relevant code import/use this file?
4. **Configuration relevance**: Does this configure behavior related to
   the task?
5. **Test relevance**: Does this test functionality related to the task?

Be aggressive about filtering. A codebase with 1000 files should
typically yield 10-50 relevant findings, not 500.

# Error Handling

- If a file cannot be read, skip it (return relevance "none")
- If a directory cannot be listed, return an error result
- If a child agent fails (empty result or ERROR), log the warning but
  continue aggregating other results
- Never let one failure stop the entire traversal
