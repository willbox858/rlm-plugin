---
name: rlm-core
description: "RLM core methodology for processing large contexts. Provides chunking strategies, sub-agent delegation patterns, overlap-aware splitting, and depth tracking. This skill is used by the rlm-process agent and any rlm-child sub-agents it spawns. Trigger when you are an RLM orchestrator or sub-agent processing a large context, or when you need to delegate reasoning to child agents via claude -p."
---

# RLM Agent Methodology

# Hard rules for reading and writing

These rules apply at every level of the RLM tree unless you are a
leaf node (RLM_DEPTH equals RLM_MAX_DEPTH).

RULE 1: Never read more than 1000 bytes of any input file.
  Allowed reads:
  - head -c 1000 file
  - tail -c 1000 file
  - wc -c file / wc -l file
  - grep -n "pattern" file | head -20
  That is ALL. If you need to understand more than 1000 bytes of a
  file, you MUST delegate that file to a child agent.

RULE 2: All content processing goes to child agents.
  Summarizing, analyzing, extracting, comparing, counting -- anything
  that requires understanding text is NEVER your job unless you are
  at max depth. You spawn a child agent for each piece of work.

RULE 3: 2+ files = 2+ child agents.
  If the task involves multiple files, each file gets its own child.
  You combine their results afterward.

RULE 4: Single file over half of RLM_CHUNK_BYTES = split and delegate.
  Split with split -l or split -b, then give each chunk to a
  separate child agent. The threshold is chunk_bytes / 2 (default
  40K when chunk_bytes is 80K), leaving room for prompt overhead
  and tool calls.

RULE 5: The only time you may read full content is:
  - Child agent result files (small outputs you are aggregating)
  - When RLM_DEPTH equals RLM_MAX_DEPTH (leaf node, no children)
  At max depth you process directly because you cannot delegate further.

RULE 6: Never create more than 1 output file yourself.
  If the task requires producing 2+ files, delegate each file to its
  own child agent. You only produce the final aggregated result.

# Environment

These variables are set by your parent (all defaults loaded from
`internal/rlm-child.json` by the root orchestrator):

- RLM_TASK: The user's original request, verbatim. Pass to EVERY child
  unmodified. This is the "guiding light" that keeps the entire agent
  tree aligned to the same goal.
- RLM_DEPTH: Your current recursion depth (0 = root orchestrator).
- RLM_MAX_DEPTH: Max depth before processing directly (default: 2).
- RLM_CHUNK_LINES: Lines per chunk for split -l (default: 2000).
- RLM_CHUNK_BYTES: Bytes per chunk for split -b (default: 80000).
- RLM_OVERLAP_BYTES: Overlap between chunks in bytes (default: 2000).
- RLM_MAX_PARALLELISM: Max concurrent children, 0 = unlimited (default: 0).
- RLM_ROOT: Absolute path to the plugin directory (.claude/RLM). Set automatically by the launcher.

# Launcher

All child spawning goes through `launch.sh`. Resolve the launcher and
config paths once at the start of your run:

```bash
# Resolve launcher and config — RLM_ROOT is exported by the launcher
if [ -n "$RLM_ROOT" ]; then
  LAUNCHER="$RLM_ROOT/launch.sh"
  CONFIG="$RLM_ROOT/internal/rlm-child.json"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  LAUNCHER="$CLAUDE_PLUGIN_ROOT/launch.sh"
  CONFIG="$CLAUDE_PLUGIN_ROOT/internal/rlm-child.json"
else
  CONFIG="$(find . -path '*/.claude/RLM/internal/rlm-child.json' -print -quit 2>/dev/null)"
  LAUNCHER="$(dirname "$(dirname "$CONFIG")")/launch.sh"
fi
```

The launcher handles `env -u CLAUDECODE`, schema, output format, and
env defaults. The caller constructs the prompt and passes per-invocation
overrides as KEY=VALUE args.

# Step 1: Explore (peek only)

```bash
wc -c /tmp/rlm_input.txt
wc -l /tmp/rlm_input.txt
head -c 1000 /tmp/rlm_input.txt
tail -c 1000 /tmp/rlm_input.txt
grep -n "pattern" /tmp/rlm_input.txt | head -20
```

If your input arrived via stdin, save it first:
```bash
cat > /tmp/rlm_input.txt
```

This is the ONLY step where you touch the input file directly.
3-5 bash calls maximum.

# Step 2: Plan your split

Based on what you peeked at, decide how to decompose:
- How many chunks?
- Line-based or byte-based split?
- Does continuity matter (need overlap)?
- What specific sub-task does each child get?

Do NOT read more of the file to plan. Your peek is enough.

# Step 3: Depth check

Before spawning children, verify depth allows it:

```bash
CHILD_DEPTH=$((RLM_DEPTH + 1))
if [ "$CHILD_DEPTH" -gt "$RLM_MAX_DEPTH" ]; then
  # Leaf node: read and process the chunk yourself
  cat chunk_file
else
  bash "$LAUNCHER" "$CONFIG" "Root task: $RLM_TASK
Depth $CHILD_DEPTH of $RLM_MAX_DEPTH.
If input is too large, split further. Otherwise process directly. Task: <sub-task>" \
    RLM_DEPTH=$CHILD_DEPTH \
    < "$f" \
    > "result_$f" 2>"error_$f"
fi
```

Only at max depth are you allowed to read full file content.

# Step 4: Split and delegate

```bash
mkdir -p /tmp/rlm_chunks && cd /tmp/rlm_chunks

split -l "${RLM_CHUNK_LINES:-2000}" /tmp/rlm_input.txt chunk_
# or: split -b "${RLM_CHUNK_BYTES:-80000}" /tmp/rlm_input.txt chunk_

TOTAL=$(ls chunk_* | wc -l)
COUNT=0
MAX_PAR="${RLM_MAX_PARALLELISM:-0}"
RUNNING=0

for f in chunk_*; do
  COUNT=$((COUNT + 1))
  bash "$LAUNCHER" "$CONFIG" "Root task: $RLM_TASK
Depth $((RLM_DEPTH + 1)) of $RLM_MAX_DEPTH.
Section $COUNT of $TOTAL. Your job: <specific sub-task here>" \
    RLM_DEPTH=$((RLM_DEPTH + 1)) \
    < "$f" \
    > "result_$f" 2>"error_$f" &
  RUNNING=$((RUNNING + 1))
  if [ "$MAX_PAR" -gt 0 ] && [ "$RUNNING" -ge "$MAX_PAR" ]; then
    wait -n 2>/dev/null || wait  # wait -n for bash 4.3+, fallback
    RUNNING=$((RUNNING - 1))
  fi
done
wait
```

The launcher handles `env -u CLAUDECODE`, schema, output format, and
env defaults automatically.

Children run in parallel by default. Set RLM_MAX_PARALLELISM to cap
concurrency (e.g., 4) if the machine is resource-constrained.

# Step 5: Validate child results

After all children finish, check for failures before aggregating:

```bash
FAILURES=0
for r in result_*; do
  if [ ! -s "$r" ]; then
    echo "WARNING: Empty result from $r" >&2
    FAILURES=$((FAILURES + 1))
  elif grep -q '"result":\s*"ERROR:' "$r" 2>/dev/null; then
    echo "WARNING: Child reported error in $r" >&2
    FAILURES=$((FAILURES + 1))
  fi
done
if [ "$FAILURES" -gt 0 ]; then
  echo "WARNING: $FAILURES of $TOTAL children failed or errored" >&2
fi
```

# Step 6: Aggregate

```bash
cat result_* > /tmp/rlm_combined.txt
SIZE=$(wc -c < /tmp/rlm_combined.txt)
if [ "$SIZE" -gt "${RLM_CHUNK_BYTES:-80000}" ] && [ "$((RLM_DEPTH + 1))" -le "$RLM_MAX_DEPTH" ]; then
  # Combined results still too large -- delegate again
  bash "$LAUNCHER" "$CONFIG" "Root task: $RLM_TASK
Depth $((RLM_DEPTH + 1)) of $RLM_MAX_DEPTH.
Synthesize these partial results into a final answer." \
    RLM_DEPTH=$((RLM_DEPTH + 1)) \
    < /tmp/rlm_combined.txt
else
  # Small enough to read -- synthesize your final answer
  cat /tmp/rlm_combined.txt
fi
```

# Step 7: Cleanup

After aggregation is complete and you have your final answer, clean
up temp files so /tmp doesn't accumulate stale data between runs:

```bash
rm -rf /tmp/rlm_chunks /tmp/rlm_input.txt /tmp/rlm_combined.txt
```

# Overlap-aware chunking (byte-based)

Overlap applies to byte-based splits only. Line-based splits
(`split -l`) do not use overlap since line lengths vary and bytes
are what correlate to context utilization.

When continuity matters (narrative text, code spanning boundaries):

```bash
CHUNK="${RLM_CHUNK_BYTES:-80000}"
OVERLAP="${RLM_OVERLAP_BYTES:-2000}"

split -b $CHUNK /tmp/rlm_input.txt raw_

prev=""
for f in raw_*; do
  if [ -n "$prev" ]; then
    tail -c $OVERLAP "$prev" | cat - "$f" > "overlap_$f"
  else
    cp "$f" "overlap_$f"
  fi
  prev="$f"
done
```

# Strategy guide

- **Needle-in-haystack:** `grep`. No child agents needed.
- **O(N)** (summarize each part): Split, delegate, combine.
- **O(N^2)** (compare pairs): Generate pairs, delegate, aggregate.

Chunking tips:
- Natural boundaries when possible (split -l, awk, csplit)
- Keep chunks under 80K chars
- Tell children their position ("section 3 of 12")
- Use overlap when continuity matters (byte-based only)

Cost awareness:
- Filter with grep/awk/sed first, children for reasoning only
- Don't spawn a child per line
- Simple transforms are cheaper in bash/awk

# Quoting safety

Never put claude -p calls inside python3 -c or nested bash strings.
Write a .py file to disk if you need Python. Prefer bash.
