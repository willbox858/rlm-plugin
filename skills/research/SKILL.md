---
name: research
description: "Produce a structured research report with findings, patterns, gaps, and recommendations by gathering broad codebase context and synthesizing via RLM. Prefer this over the Explore subagent or manual searches when the user needs analysis and synthesis, not just search results. Trigger when: 'how is X done in this codebase', 'what's the state of X', 'investigate', 'analyze', 'audit', 'survey', 'find all patterns of', user asks about cross-cutting concerns, or any question requiring codebase-wide analysis with structured conclusions."
---

# Research — Codebase Research Summary

Produces a structured research report by broadly gathering context from
the codebase, optionally running a targeted follow-up pass to fill gaps,
then synthesizing findings via RLM. Output is an analytical derived
document with findings, patterns, gaps, and recommendations.

## When to use

- User wants to understand the state of something across the codebase
- User says "research X", "investigate how X works", "audit X usage"
- Need a thorough survey: "how is error handling done?", "what patterns exist for Y?"
- Exploring a problem space before designing or implementing
- User says "analyze", "survey", "find all patterns of", "codebase analysis"
- Preparing context for a design doc or planning session

## When NOT to use

- User wants to describe a specific module (use `/create-description`)
- User wants a design doc from conversation (use `/design`)
- User wants a quick file search (use grep or `/gather-context`)
- User wants to extract decisions from past sessions (use `/distill`)
- The answer is obvious from a single file — just read it and answer directly
- User wants a code change (use implementation tools)

## Step 0: Determine input mode and formulate research question

### Input mode

Ask or infer which mode applies:

**Mode A — Specific scope**: User provides file paths or directories
to research within. Use those as the search scope.

**Mode B — Concept/topic**: User names a topic ("error handling",
"how caching is used", "authentication patterns") without specifying
files. Cast a wide net with gather-context. This is the most common
mode.

**Mode C — Current conversation**: The relevant context is already
small and present in the conversation. Process inline — no file
gathering or RLM dispatch needed. Skip to Step 5.

### Research question

Formulate an explicit research question — not just a topic, but a
specific question or objective that guides the investigation.

```bash
RESEARCH_TOPIC="<topic from user>"                     # e.g. "error handling"
RESEARCH_QUESTION="<specific question or objective>"   # e.g. "How is error handling implemented across the codebase? What patterns are used, are they consistent, and where are the gaps?"
RESEARCH_SLUG="<slugified-topic>"                      # e.g. "error-handling"
```

If the user gives a broad topic, expand it into a question that
covers: current state, patterns, consistency, and gaps.

## Step 1: Run broad gather-context pass

Cast a wide net to discover relevant files across the codebase.
The GC_TASK is deliberately broad — we want implementations, configs,
tests, docs, and patterns.

```bash
export GC_TASK="Find all files relevant to: $RESEARCH_TOPIC. Cast a wide net — I need to understand implementations, configurations, tests, documentation, and patterns related to this topic. Include files that use, configure, test, or document this topic. Err on the side of including more rather than fewer files."

# Resolve config and launcher
if [ -n "$RLM_ROOT" ]; then
  GC_CONFIG="$RLM_ROOT/internal/gc-worker.json"
  LAUNCHER="$RLM_ROOT/launch.sh"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  GC_CONFIG="$CLAUDE_PLUGIN_ROOT/internal/gc-worker.json"
  LAUNCHER="$CLAUDE_PLUGIN_ROOT/launch.sh"
else
  GC_CONFIG="$(find . -path '*/.claude/RLM/internal/gc-worker.json' -print -quit 2>/dev/null)"
  if [ -z "$GC_CONFIG" ]; then
    GC_CONFIG="$HOME/.claude/RLM/internal/gc-worker.json"
  fi
  LAUNCHER="$(dirname "$(dirname "$GC_CONFIG")")/launch.sh"
fi

# Load defaults, user env vars override
export GC_MAX_AGENTS="${GC_MAX_AGENTS:-$(jq -r '.env_defaults.GC_MAX_AGENTS // "50"' "$GC_CONFIG" 2>/dev/null || echo 50)}"
export GC_EXCLUDE="${GC_EXCLUDE:-$(jq -r '.env_defaults.GC_EXCLUDE // "node_modules,.git,target,dist,build,out,__pycache__,.venv,vendor,.claude,*.lock"' "$GC_CONFIG" 2>/dev/null || echo 'node_modules,.git,target,dist,build,out,__pycache__,.venv,vendor,.claude,*.lock')}"
export GC_MAX_FILE_SIZE="${GC_MAX_FILE_SIZE:-$(jq -r '.env_defaults.GC_MAX_FILE_SIZE // "512000"' "$GC_CONFIG" 2>/dev/null || echo 512000)}"
```

Dispatch the root gather-context-worker:

```bash
bash "$LAUNCHER" "$GC_CONFIG" "Task: $GC_TASK
mode: directory
directory: ." \
  > /tmp/gc_research_result.json 2>/tmp/gc_research_error.log
```

Validate the result:

```bash
if [ ! -s /tmp/gc_research_result.json ]; then
  echo "ERROR: Gather-context returned empty result" >&2
  cat /tmp/gc_research_error.log >&2
  exit 1
fi

jq -e '.result' /tmp/gc_research_result.json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: Gather-context returned invalid JSON" >&2
  exit 1
fi
```

## Step 2: Analyze findings and optionally run targeted follow-up

Review the first-pass findings to identify significant gaps. A gap is
significant if it represents an area that should clearly exist for this
topic but was not found (e.g., "no test files found for a module that
should have tests", "no configuration files found for a configurable
feature").

```bash
GC_RESULT_1=$(jq -r '.result' /tmp/gc_research_result.json)

# Analyze the findings for gaps
# Look for missing categories: tests, configs, docs, error handling, etc.
# If the findings mention gaps or if obvious areas are missing, formulate
# a targeted follow-up query
```

If significant gaps are identified, run ONE targeted follow-up pass
(at most — never more than 2 total GC passes):

```bash
# Only if significant gaps were found
TARGETED_TASK="Find files related to: $RESEARCH_TOPIC that were missed in the initial scan. Specifically look for: <identified gaps>. Search in directories and file patterns that the first pass may have missed."

bash "$LAUNCHER" "$GC_CONFIG" "Task: $TARGETED_TASK
mode: directory
directory: ." \
  > /tmp/gc_research_targeted.json 2>/tmp/gc_research_targeted_error.log

# Validate and merge with first pass results
if [ -s /tmp/gc_research_targeted.json ]; then
  GC_RESULT_2=$(jq -r '.result' /tmp/gc_research_targeted.json 2>/dev/null)
fi
```

If no significant gaps are identified, skip the follow-up pass.

## Step 3: Build comprehensive context

Combine all gather-context findings and full file contents into the
research context:

```bash
CONTEXT="/tmp/research_context_$(date +%Y%m%d_%H%M%S).txt"

# Research question as preamble
echo "===== RESEARCH QUESTION =====" > "$CONTEXT"
echo "$RESEARCH_QUESTION" >> "$CONTEXT"
echo "" >> "$CONTEXT"

# First pass findings
echo "===== GATHER-CONTEXT FINDINGS (PASS 1) =====" >> "$CONTEXT"
echo "$GC_RESULT_1" >> "$CONTEXT"
echo "" >> "$CONTEXT"

# Second pass findings (if any)
if [ -n "$GC_RESULT_2" ]; then
  echo "===== GATHER-CONTEXT FINDINGS (PASS 2 — TARGETED) =====" >> "$CONTEXT"
  echo "$GC_RESULT_2" >> "$CONTEXT"
  echo "" >> "$CONTEXT"
fi

# Read each high/medium relevance file in full from both passes
for PASS_RESULT in "$GC_RESULT_1" "$GC_RESULT_2"; do
  if [ -n "$PASS_RESULT" ]; then
    for f in $(echo "$PASS_RESULT" | jq -r '.findings[]? | select(.relevance == "high" or .relevance == "medium") | .file_path' 2>/dev/null); do
      if [ -f "$f" ]; then
        # Avoid duplicates
        if ! grep -q "^===== FILE: $f =====$" "$CONTEXT" 2>/dev/null; then
          echo "===== FILE: $f =====" >> "$CONTEXT"
          cat "$f" >> "$CONTEXT"
          echo "" >> "$CONTEXT"
        fi
      fi
    done
  fi
done

FILE_COUNT=$(grep -c "^===== FILE:" "$CONTEXT" || echo 0)
GC_PASSES=1
if [ -n "$GC_RESULT_2" ]; then GC_PASSES=2; fi
echo "Prepared context: $(wc -c < "$CONTEXT") bytes from $FILE_COUNT files ($GC_PASSES gather-context passes)"
```

## Step 4: Size check

```bash
CONTEXT_SIZE=$(wc -c < "$CONTEXT")
echo "Context size: $CONTEXT_SIZE bytes"
```

If under 80,000 characters: read the context file directly and produce
the research report inline. Skip Step 5 dispatch and go straight to
saving (Step 6).

If 80,000+ characters: continue to Step 5 for RLM dispatch.

## Step 5: Set RLM_TASK and dispatch

Build the research synthesis prompt:

```bash
export RLM_TASK="Produce a structured research report answering: $RESEARCH_QUESTION

Analyze the gathered codebase context (findings from $GC_PASSES gather-context passes plus full file contents) and synthesize a comprehensive report.

Structure the report with these 7 sections:

1. **Executive Summary** — 2-3 paragraph overview of key findings. What is the answer to the research question? What are the most important takeaways?
2. **Current State** — How does the codebase currently handle this topic? What exists today? Reference specific files, functions, and patterns.
3. **Findings** — Detailed findings organized by sub-topic. Each finding should reference specific code locations (file:line or file:function). Include code snippets where they illustrate a point.
4. **Patterns & Consistency** — What patterns emerge? Are they consistent across the codebase? Where do implementations diverge? What conventions exist (documented or implicit)?
5. **Gaps & Risks** — What is missing? What should exist but doesn't? What is fragile, under-tested, or poorly documented? What could break?
6. **Recommendations** — Specific, actionable recommendations. Prioritize by impact. Reference the findings that support each recommendation.
7. **Further Investigation** — What questions remain unanswered? What would require deeper analysis? What adjacent topics should be researched?

Rules:
- Ground every finding in specific code references — file paths, function names, line numbers
- Include short code snippets (5-15 lines) where they illustrate a pattern or problem
- Quantify where possible: 'used in 12 files', 'tested in 3 of 8 modules', 'no error handling in 4 endpoints'
- Distinguish between facts (observed in code) and assessments (your analysis)
- Be direct about problems — do not hedge or soften findings
- Recommendations must be specific enough to act on, not generic advice
- If something is unclear or ambiguous in the code, say so explicitly"
```

Dispatch to rlm-orchestrator:

```
Use the rlm-orchestrator agent:
RLM_TASK is set in the environment.
Process the context at $CONTEXT
Task: $RLM_TASK
```

If the Agent tool is unavailable, fall back to CLI:

```bash
env -u CLAUDECODE \
  RLM_DEPTH=0 \
  RLM_TASK="$RLM_TASK" \
  claude -p "$RLM_TASK" \
    --agent rlm-orchestrator \
    < "$CONTEXT"
```

## Step 6: Save output

Write the research report to a file:

```bash
OUTPUT_DIR="derived/reports"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$OUTPUT_DIR/$RESEARCH_SLUG-$TIMESTAMP.md"

cat > "$OUTPUT" <<EOF
---
generated: $(date -Iseconds)
type: research
topic: $RESEARCH_TOPIC
question: $RESEARCH_QUESTION
gc_passes: $GC_PASSES
input_size: $CONTEXT_SIZE bytes
---

# Research: $RESEARCH_TOPIC

EOF

# Append the result from RLM or inline processing
echo "$RESULT" >> "$OUTPUT"

echo "Saved to: $OUTPUT"
```

## Step 7: Present and cleanup

1. Show the user the research report (or a summary if it is long)
2. Tell them where the file was saved
3. Highlight the most important findings and recommendations
4. Clean up temp files:

```bash
rm -f "$CONTEXT"
rm -f /tmp/gc_research_result.json /tmp/gc_research_error.log
rm -f /tmp/gc_research_targeted.json /tmp/gc_research_targeted_error.log
rm -f /tmp/gc_*.json 2>/dev/null
```

## What happens inside

This skill uses a multi-pass research pattern:

1. **Broad discovery** — gather-context workers cast a wide net across
   the codebase, looking for anything related to the research topic.
   The GC_TASK is deliberately broad to avoid missing relevant files.

2. **Gap analysis** — the first-pass findings are analyzed for
   significant gaps (missing tests, configs, docs, etc.). If gaps
   are found, one targeted follow-up pass is run to fill them
   (at most 2 total GC passes).

3. **Context assembly** — findings from all passes plus full contents
   of high/medium relevance files are assembled into a comprehensive
   context file.

4. **Synthesis** — the assembled context is processed (via RLM if
   large) with a research-synthesis prompt that produces a 7-section
   report: Executive Summary, Current State, Findings, Patterns &
   Consistency, Gaps & Risks, Recommendations, Further Investigation.

The research question (not just a topic) guides the entire process.
A broad topic like "error handling" is expanded into a specific
question like "How is error handling implemented across the codebase?
What patterns are used, are they consistent, and where are the gaps?"

For small input (under 80K), everything is processed inline — no
sub-agents.
