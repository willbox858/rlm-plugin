---
name: plan-sprint
description: "Create a capacity-aware sprint plan by consolidating stories from multiple feature plans into a prioritized backlog. Trigger when: 'plan the sprint', 'sprint planning', 'what should we work on next', 'prioritize stories', 'sprint backlog', or user wants to organize multiple /plan-feature outputs into an ordered sprint."
---

# Plan Sprint — Sprint Planning from Feature Plans + Code State

Generates a sprint plan by discovering existing feature plans and
design docs, gathering current codebase state, then synthesizing into
a prioritized, capacity-aware sprint backlog. Dispatches artifact
discovery and code context gathering in parallel, then uses RLM for
the final sprint plan. Output is a draft derived document.

## When to use

- Organizing existing feature plans into a sprint backlog
- User says "plan the sprint", "sprint planning", "what should we work on next"
- Need to prioritize, order, and estimate stories across multiple features
- Preparing sprint commitment with capacity analysis
- User says "sprint backlog" or "next sprint"
- Multiple `/plan-feature` outputs exist and need to be consolidated

## When NOT to use

- User wants to break a single feature into stories (use `/plan-feature`)
- User wants epic/roadmap-level planning (use `/plan-epic`)
- User wants a design doc (use `/design`)
- User wants to explore a topic (use `/research`)
- No feature plans exist yet — suggest running `/plan-feature` first
- Context is trivially small — just write the sprint plan directly

## Step 0: Determine input mode and sprint goal

### Input mode

Ask or infer which mode applies:

**Mode A — Specific plans**: User provides specific plan files or
feature names to include. Use those files directly as input.

**Mode B — Discovery**: User states a sprint goal or says "plan the
sprint" without specifying which plans. Auto-discover all existing
plans and designs — do NOT ask the user for file paths. This is the
most common mode.

**Mode C — Current conversation**: The relevant context is already
small and present in the conversation. Process inline — no file
gathering, discovery, or RLM dispatch needed. Skip to Step 4.

### Sprint goal

Capture the sprint goal explicitly. This is the objective of the
sprint — what will be true at the end that is not true now.

```bash
SPRINT_GOAL="<the sprint's objective>"        # e.g. "Complete auth system and start API v2"
SPRINT_SLUG="<slugified-goal>"                # e.g. "auth-and-api-v2"
```

## Step 1: Gather inputs IN PARALLEL

Run artifact discovery and code context gathering concurrently. They
are independent and their results are merged in Step 2.

### Branch A: Discover existing plans and design docs

Direct file scan — no GC needed, known directories, all files
potentially relevant:

```bash
PLAN_FILES=""
DESIGN_FILES=""
PLAN_COUNT=0
DESIGN_COUNT=0

# Scan derived/drafts/ for feature plans
if [ -d "derived/drafts" ]; then
  for f in derived/drafts/*-plan-*.md; do
    if [ -f "$f" ]; then
      PLAN_FILES="$PLAN_FILES $f"
      PLAN_COUNT=$((PLAN_COUNT + 1))
    fi
  done
fi

# Scan derived/drafts/ for design docs
if [ -d "derived/drafts" ]; then
  for f in derived/drafts/*-design-*.md; do
    if [ -f "$f" ]; then
      DESIGN_FILES="$DESIGN_FILES $f"
      DESIGN_COUNT=$((DESIGN_COUNT + 1))
    fi
  done
fi

# Scan docs/design/ for approved design docs
if [ -d "docs/design" ]; then
  for f in docs/design/*.md; do
    if [ -f "$f" ]; then
      DESIGN_FILES="$DESIGN_FILES $f"
      DESIGN_COUNT=$((DESIGN_COUNT + 1))
    fi
  done
fi

echo "Found $PLAN_COUNT feature plans, $DESIGN_COUNT design docs"
```

Graceful degradation when no artifacts are found:

```bash
if [ "$PLAN_COUNT" -eq 0 ] && [ "$DESIGN_COUNT" -eq 0 ]; then
  echo "No existing plans or design docs found."
  echo "Sprint plan will be based on code context + stated goal."
  echo "Consider running /plan-feature first for individual features."
fi
```

### Branch B: Gather code context for codebase state

Run gather-context to discover relevant code and assess project state:

```bash
export GC_TASK="Assess the current state of the codebase for sprint planning. Focus on: recently changed files, work in progress, test coverage gaps, incomplete features, and overall project structure. I need to understand what exists and what needs work to plan the next sprint."

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
  > /tmp/gc_plan_sprint_result.json 2>/tmp/gc_plan_sprint_error.log
```

Validate the result:

```bash
if [ ! -s /tmp/gc_plan_sprint_result.json ]; then
  echo "ERROR: Gather-context returned empty result" >&2
  cat /tmp/gc_plan_sprint_error.log >&2
  exit 1
fi

jq -e '.result' /tmp/gc_plan_sprint_result.json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: Gather-context returned invalid JSON" >&2
  exit 1
fi
```

## Step 2: Merge artifact discovery + code context

Combine both inputs into a single context file for the sprint plan
generation step:

```bash
CONTEXT="/tmp/sprint_context_$(date +%Y%m%d_%H%M%S).txt"

# Section 1: Sprint goal as preamble
echo "===== SPRINT GOAL =====" > "$CONTEXT"
echo "$SPRINT_GOAL" >> "$CONTEXT"
echo "" >> "$CONTEXT"

# Section 2: Existing plans and design docs
if [ "$PLAN_COUNT" -gt 0 ] || [ "$DESIGN_COUNT" -gt 0 ]; then
  echo "===== EXISTING PLANS AND DESIGN DOCS =====" >> "$CONTEXT"
  for f in $PLAN_FILES $DESIGN_FILES; do
    echo "===== FILE: $f =====" >> "$CONTEXT"
    cat "$f" >> "$CONTEXT"
    echo "" >> "$CONTEXT"
  done
else
  echo "===== NO EXISTING PLANS OR DESIGNS FOUND =====" >> "$CONTEXT"
  echo "Deriving stories from code context and sprint goal." >> "$CONTEXT"
  echo "" >> "$CONTEXT"
fi

# Section 3: Code context
GC_RESULT=$(jq -r '.result' /tmp/gc_plan_sprint_result.json)
echo "===== CODE CONTEXT =====" >> "$CONTEXT"
echo "$GC_RESULT" >> "$CONTEXT"
echo "" >> "$CONTEXT"

# Include full content of high/medium relevance files
for f in $(echo "$GC_RESULT" | jq -r '.findings[]? | select(.relevance == "high" or .relevance == "medium") | .file_path' 2>/dev/null); do
  if [ -f "$f" ]; then
    echo "===== FILE: $f =====" >> "$CONTEXT"
    cat "$f" >> "$CONTEXT"
    echo "" >> "$CONTEXT"
  fi
done

FILE_COUNT=$(grep -c "^===== FILE:" "$CONTEXT" || echo 0)
CONTEXT_SIZE=$(wc -c < "$CONTEXT")
echo "Prepared context: $CONTEXT_SIZE bytes from $FILE_COUNT files ($PLAN_COUNT plans, $DESIGN_COUNT designs)"
```

## Step 3: Size check

```bash
echo "Context size: $CONTEXT_SIZE bytes"
```

If under 80,000 characters: read the context file directly and produce
the sprint plan inline. Skip Step 4 and go straight to Step 5.

If 80,000+ characters: continue to Step 4 for RLM dispatch.

## Step 4: Set RLM_TASK and dispatch

Build the sprint-plan-generation prompt:

```bash
export RLM_TASK="Produce a sprint plan for: $SPRINT_GOAL

Use the existing feature plans, design docs, and current code context to create a prioritized, capacity-aware sprint plan.

Structure the plan with these 7 sections:

1. **Sprint Goal** — Clear, concise statement of what this sprint aims to achieve. What will be true at the end of the sprint that is not true now?
2. **Committed Stories** — Ordered list of stories for this sprint. For each story:
   - **Source** — Which feature plan or design doc this story comes from (file path), or 'Derived' if created from code analysis
   - **Title** — Concise, imperative (carried forward from feature plan where applicable)
   - **Description** — What this story delivers
   - **Acceptance Criteria** — Specific, testable criteria
   - **Size** — XS / S / M / L / XL (carried forward or re-estimated based on code state)
   - **Priority** — P0 (must have) / P1 (should have) / P2 (nice to have)
   - **Dependencies** — Other stories in this sprint that must complete first (use story numbers)
3. **Dependency Map** — Prose description of the dependency graph between stories. Identify the critical path and any parallelizable work streams.
4. **Capacity Analysis** — Total story points/sizes committed. Highlight if the sprint looks overcommitted or has slack. Note any stories that are blocked on external factors.
5. **Risks & Mitigations** — What could go wrong? For each risk: likelihood, impact, and specific mitigation strategy. Include technical risks from the code context.
6. **Definition of Done** — What criteria must every story meet to be considered complete? (Tests passing, code reviewed, docs updated, etc.)
7. **Stretch Goals** — Stories that are ready but not committed. If the sprint goes faster than expected, these are next. Ordered by priority.

Rules:
- Pull stories from existing feature plans where available — do not reinvent them
- Re-assess sizes based on current code state (a story might be smaller if groundwork exists)
- Order committed stories to minimize blocked work (dependencies-first)
- Be realistic about capacity — better to commit to fewer stories and finish them
- If a feature plan story is too large (XL), break it down for the sprint
- Reference specific code files when they affect estimation or ordering
- If no feature plans exist, derive stories from code context + sprint goal"
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

## Step 5: Save output

Write the sprint plan to a file:

```bash
OUTPUT_DIR="derived/drafts"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$OUTPUT_DIR/$SPRINT_SLUG-sprint-$TIMESTAMP.md"

cat > "$OUTPUT" <<EOF
---
generated: $(date -Iseconds)
type: plan
plan_type: sprint
goal: $SPRINT_GOAL
feature_plans_found: $PLAN_COUNT
design_docs_found: $DESIGN_COUNT
input_size: $CONTEXT_SIZE bytes
---

# Sprint Plan: $SPRINT_GOAL

EOF

# Append the result from RLM or inline processing
echo "$RESULT" >> "$OUTPUT"

echo "Saved to: $OUTPUT"
```

## Step 6: Present and cleanup

1. Show the user the sprint plan (or a summary if it is long)
2. Tell them where the file was saved
3. Note that this is a draft in `derived/drafts/` — to promote it to
   a base document, review and move to `docs/plans/`
4. Highlight committed story count, total capacity, and any
   overcommitment or slack noted in the capacity analysis
5. Clean up temp files:

```bash
rm -f "$CONTEXT"
rm -f /tmp/gc_plan_sprint_result.json /tmp/gc_plan_sprint_error.log
rm -f /tmp/gc_*.json 2>/dev/null
```

## What happens inside

This skill orchestrates two parallel input-gathering phases, then
synthesizes them into a sprint plan:

1. **Parallel input gathering:**
   - **Artifact discovery** — `derived/drafts/` and `docs/design/`
     are scanned directly for existing feature plans
     (`*-plan-*.md`) and design documents (`*-design-*.md`). Their
     full content is included in the merged context. This is a
     direct file scan, not a gather-context invocation — the
     directories and naming patterns are known.
   - **Code context** — gather-context workers discover relevant
     code files and assess the current state of the codebase:
     recently changed files, work in progress, test coverage gaps,
     incomplete features, and overall project structure.

2. **Merge** — the sprint goal, discovered plans/designs, and code
   context are combined into a single context file. The plans
   provide the "what stories exist," the designs provide the "what
   was formally proposed," and the code context provides the "what
   exists today and what needs work."

3. **Sprint plan generation** — the merged context is processed (via
   RLM if large) with a sprint-planning prompt that produces a
   7-section sprint plan with committed stories, dependency mapping,
   capacity analysis, risks, and stretch goals.

This skill discovers outputs from `/plan-feature` and `/design`
rather than re-distilling session logs. It reads those skills' output
files directly from known directories. When no existing plans or
design docs are found, the sprint plan gracefully degrades to deriving
stories from code context and the stated sprint goal, with a note
suggesting the user run `/plan-feature` first for individual features.

For small input (under 80K), everything is processed inline — no
sub-agents.
