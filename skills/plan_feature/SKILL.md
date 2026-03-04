---
name: plan-feature
description: "Break a feature into implementation stories with acceptance criteria, dependencies, and sizing — produces a persistent plan artifact that /implement can execute. Prefer this over EnterPlanMode when the goal is a reusable implementation plan, not a one-time approach discussion. Trigger when: 'plan this feature', 'break into stories', 'implementation plan', 'what do we need to build', 'task breakdown', or after /design when moving toward implementation."
---

# Plan Feature — Implementation Stories from Design + Code

Generates a structured implementation plan by distilling conversation
history (decisions, requirements) and gathering code context, scanning
for existing design docs in `derived/drafts/` and `docs/design/`, then
synthesizing into actionable stories. Dispatches distillation and
context-gathering in parallel, then uses RLM for the final plan
generation. Output is a draft derived document.

## When to use

- Turning a design or discussion into actionable implementation stories
- User says "plan this feature", "break into stories", "implementation plan for X"
- Need acceptance criteria, task breakdowns, and sizing for stories
- Preparing work items from a technical design or RFC
- User says "what stories do we need?" or "task breakdown"
- After running `/design` and wanting to move toward implementation

## When NOT to use

- User wants sprint-level planning across multiple features (use `/plan-sprint`)
- User wants epic/roadmap-level planning (use `/plan-epic`)
- User wants a design doc, not an implementation plan (use `/design`)
- User wants to describe existing code (use `/create-description`)
- User wants to explore a problem space (use `/research`)
- Context is trivially small — just list the stories directly

## Step 0: Determine input mode and feature topic

### Input mode

Ask or infer which mode applies:

**Mode A — Specific files + topic**: User provides file paths and/or a
feature topic explicitly. Use those files directly as code context.

**Mode B — Concept/feature**: User names something ("auth system",
"the new caching layer", "API redesign") without giving file paths.
Auto-run gather-context to find relevant code — do NOT ask the user
for file paths. Also scan for existing design docs to distill.

**Mode C — Current conversation**: The relevant discussion and context
are already small and present in the conversation. Process inline — no
file gathering, distillation, or RLM dispatch needed. Skip to Step 4.

### Feature topic

Capture the feature topic explicitly. This is the subject of the
implementation plan — what is being planned.

```bash
FEATURE_TOPIC="<what the user wants to plan>"    # e.g. "user authentication"
FEATURE_SLUG="<slugified-topic>"                 # e.g. "user-authentication"
```

## Step 1: Gather inputs IN PARALLEL

Run distillation, code gathering, and design doc scanning concurrently.
They are independent and their results are merged in Step 2.

### Branch A: Distill conversation history

Find and process session JSONL logs. If no session logs exist, skip
this branch — the plan will be based on code context + design docs +
stated topic only.

```bash
# Resolve the project session directory
PROJECT_DIR="$HOME/.claude/projects"
CWD_SLUG=$(pwd | sed 's|/|--|g' | sed 's|^-*||')
SESSION_DIR="$PROJECT_DIR/$CWD_SLUG"

DISTILL_RESULT=""
SESSION_COUNT=0

if [ -d "$SESSION_DIR" ]; then
  SESSION_COUNT=$(ls "$SESSION_DIR"/*.jsonl 2>/dev/null | wc -l)

  if [ "$SESSION_COUNT" -gt 0 ]; then
    DISTILL_CONTEXT="/tmp/plan_feature_distill_$(date +%Y%m%d_%H%M%S).txt"

    for jsonl in "$SESSION_DIR"/*.jsonl; do
      echo "===== SESSION: $(basename "$jsonl" .jsonl) ====="
      jq -r '
        select(.type == "user" or .type == "assistant") |
        .message // {role: .type, content: ""} |
        {role: .role, content: (
          if (.content | type) == "string" then .content
          elif (.content | type) == "array" then
            [.content[] | select(.type == "text") | .text] | join("\n")
          else ""
          end
        )} |
        select(.content != "") |
        "[\(.role)] \(.content)"
      ' "$jsonl" 2>/dev/null
    done > "$DISTILL_CONTEXT"

    DISTILL_SIZE=$(wc -c < "$DISTILL_CONTEXT")
    echo "Distill context: $DISTILL_SIZE bytes from $SESSION_COUNT sessions"

    # Build distillation prompt (reuses /distill's tagged extraction)
    DISTILL_TASK="Focus: $FEATURE_TOPIC — prioritize content related to this topic.

Distill this conversation/document into structured findings. For every substantive point, tag it with exactly one of these prefixes:

[DECISION] — An explicit choice that was made. Include the reasoning and any rejected alternatives.
[REQ] — A constraint, specification, or must-have requirement.
[KEY] — An important insight, established fact, or key context.
[OPEN] — An unresolved question, deferred issue, or point of disagreement.
[TODO] — A task that was identified but not yet completed.
[STATE] — Where things stand at the end — current status, what's working, what's not.

Rules:
- Every point gets exactly one tag prefix
- Include enough context that the point is self-contained (someone reading just that line should understand it)
- Preserve specifics: names, numbers, file paths, exact decisions — do not generalize
- Chronological order within each tag category
- If a decision was later reversed, note both the original and the reversal
- Skip small talk, greetings, and meta-conversation about the tool itself"

    # If distill context is small enough, process inline
    if [ "$DISTILL_SIZE" -lt 80000 ]; then
      # Read and process inline — DISTILL_RESULT is set directly
      DISTILL_RESULT="<process $DISTILL_CONTEXT inline with $DISTILL_TASK>"
    else
      # Dispatch to RLM for large session history
      export RLM_TASK="$DISTILL_TASK"

      # Use the rlm-orchestrator agent to process the distill context
      # Result is an intermediate artifact — not saved separately
    fi
  fi
fi
```

### Branch B: Gather code context + scan for design docs

Two sub-tasks run in this branch: gather-context for relevant code,
and a scan for existing design documents related to the feature topic.

#### Sub-task 1: Gather code context

Run gather-context to discover relevant code files:

```bash
export GC_TASK="Find all files relevant to: $FEATURE_TOPIC. I need to understand the current implementation, architecture, configuration, and tests to create an implementation plan with stories and tasks."

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
  > /tmp/gc_plan_feature_result.json 2>/tmp/gc_plan_feature_error.log
```

Validate the result:

```bash
if [ ! -s /tmp/gc_plan_feature_result.json ]; then
  echo "ERROR: Gather-context returned empty result" >&2
  cat /tmp/gc_plan_feature_error.log >&2
  exit 1
fi

jq -e '.result' /tmp/gc_plan_feature_result.json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: Gather-context returned invalid JSON" >&2
  exit 1
fi
```

#### Sub-task 2: Scan for existing design docs

```bash
DESIGN_DOCS=""
# Check derived/drafts/ for design docs related to the topic
if [ -d "derived/drafts" ]; then
  for f in derived/drafts/*-design-*.md derived/drafts/*-plan-*.md; do
    if [ -f "$f" ]; then
      # Check if file mentions the topic
      if head -c 2000 "$f" | grep -qi "$FEATURE_SLUG\|$FEATURE_TOPIC" 2>/dev/null; then
        DESIGN_DOCS="$DESIGN_DOCS $f"
      fi
    fi
  done
fi

# Check docs/design/ for approved design docs
if [ -d "docs/design" ]; then
  for f in docs/design/*.md; do
    if [ -f "$f" ]; then
      if head -c 2000 "$f" | grep -qi "$FEATURE_SLUG\|$FEATURE_TOPIC" 2>/dev/null; then
        DESIGN_DOCS="$DESIGN_DOCS $f"
      fi
    fi
  done
fi

DESIGN_DOC_COUNT=$(echo "$DESIGN_DOCS" | wc -w)
echo "Found $DESIGN_DOC_COUNT existing design docs related to topic"
```

## Step 2: Merge distillation + code context + design docs

Combine all three inputs into a single context file for the plan
generation step:

```bash
CONTEXT="/tmp/plan_feature_context_$(date +%Y%m%d_%H%M%S).txt"

# Section 1: Distilled conversation findings (if available)
if [ -n "$DISTILL_RESULT" ]; then
  echo "===== DISTILLED CONVERSATION FINDINGS =====" > "$CONTEXT"
  echo "$DISTILL_RESULT" >> "$CONTEXT"
  echo "" >> "$CONTEXT"
else
  echo "===== NO CONVERSATION HISTORY AVAILABLE =====" > "$CONTEXT"
  echo "Plan based on code context and design docs only." >> "$CONTEXT"
  echo "" >> "$CONTEXT"
fi

# Section 2: Existing design docs (if found)
if [ "$DESIGN_DOC_COUNT" -gt 0 ]; then
  echo "===== EXISTING DESIGN DOCUMENTS =====" >> "$CONTEXT"
  for f in $DESIGN_DOCS; do
    if [ -f "$f" ]; then
      echo "----- DESIGN DOC: $f -----" >> "$CONTEXT"
      cat "$f" >> "$CONTEXT"
      echo "" >> "$CONTEXT"
    fi
  done
else
  echo "===== NO EXISTING DESIGN DOCUMENTS FOUND =====" >> "$CONTEXT"
  echo "" >> "$CONTEXT"
fi

# Graceful degradation note
if [ -z "$DISTILL_RESULT" ] && [ "$DESIGN_DOC_COUNT" -eq 0 ]; then
  echo "Note: No session logs or design docs found. Plan based on code context only." >> "$CONTEXT"
  echo "Consider running /design first to capture the design intent." >> "$CONTEXT"
fi

# Section 3: Gather-context findings + full content of high/medium relevance files
GC_RESULT=$(jq -r '.result' /tmp/gc_plan_feature_result.json)
echo "===== CODE CONTEXT FINDINGS =====" >> "$CONTEXT"
echo "$GC_RESULT" >> "$CONTEXT"
echo "" >> "$CONTEXT"

for f in $(echo "$GC_RESULT" | jq -r '.findings[]? | select(.relevance == "high" or .relevance == "medium") | .file_path' 2>/dev/null); do
  if [ -f "$f" ]; then
    echo "===== FILE: $f =====" >> "$CONTEXT"
    cat "$f" >> "$CONTEXT"
    echo "" >> "$CONTEXT"
  fi
done

FILE_COUNT=$(grep -c "^===== FILE:" "$CONTEXT" || echo 0)
CONTEXT_SIZE=$(wc -c < "$CONTEXT")
echo "Prepared context: $CONTEXT_SIZE bytes from $FILE_COUNT files + distillation + $DESIGN_DOC_COUNT design docs"
```

## Step 3: Size check

```bash
echo "Context size: $CONTEXT_SIZE bytes"
```

If under 80,000 characters: read the context file directly and produce
the implementation plan inline. Skip Step 4 and go straight to Step 5.

If 80,000+ characters: continue to Step 4 for RLM dispatch.

## Step 4: Set RLM_TASK and dispatch

Build the plan-generation prompt:

```bash
export RLM_TASK="Produce a feature implementation plan for: $FEATURE_TOPIC

Use the distilled conversation findings, existing design docs, and code context to create an actionable implementation plan broken into stories and tasks.

Structure the plan with these 7 sections:

1. **Feature Overview** — What is being implemented? Summary of the feature's purpose, scope, and key design decisions. Reference the design doc if one exists.
2. **Prerequisites** — What must be in place before implementation starts? Dependencies, infrastructure, access, decisions that must be finalized.
3. **Implementation Stories** — Each story should include:
   - **Title** — Concise, imperative (e.g., 'Add authentication middleware')
   - **Description** — What this story delivers and why
   - **Acceptance Criteria** — Specific, testable criteria (Given/When/Then or checklist)
   - **Technical Tasks** — Concrete implementation tasks with file paths where known
   - **Dependencies** — Which other stories must be completed first (use story numbers)
   - **Size** — XS (< 1hr), S (1-4hr), M (4-8hr), L (1-2 days), XL (3-5 days)
   - **Risk** — Low / Medium / High with brief explanation if Medium or High
4. **Implementation Order** — Recommended sequence for tackling the stories, respecting dependencies. Number each story for cross-referencing.
5. **Technical Decisions Required** — Decisions that need to be made during implementation. For each, state the options and a recommendation.
6. **Testing Strategy** — Overall approach to testing this feature. Unit tests, integration tests, E2E tests. What to test first, what to test most thoroughly.
7. **Open Questions** — Unresolved issues from the design or distillation that affect implementation.

Rules:
- Ground every story in specific code references — file paths, functions, modules
- Reference design doc decisions where they dictate implementation choices
- Stories should be independently deliverable where possible
- Each story's acceptance criteria must be testable (not vague)
- Size estimates should reflect actual implementation work, not idealistic estimates
- If something is unclear, create an explicit story for investigation/spike
- Order stories to minimize blocked work and maximize early validation"
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

Write the implementation plan to a file:

```bash
OUTPUT_DIR="derived/drafts"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$OUTPUT_DIR/$FEATURE_SLUG-plan-$TIMESTAMP.md"

cat > "$OUTPUT" <<EOF
---
generated: $(date -Iseconds)
type: plan
plan_type: feature
topic: $FEATURE_TOPIC
distilled_sessions: $SESSION_COUNT
design_docs_found: $DESIGN_DOC_COUNT
input_size: $CONTEXT_SIZE bytes
---

# Plan: $FEATURE_TOPIC

EOF

# Append the result from RLM or inline processing
echo "$RESULT" >> "$OUTPUT"

echo "Saved to: $OUTPUT"
```

## Step 6: Present and cleanup

1. Show the user the implementation plan (or a summary if it is long)
2. Tell them where the file was saved
3. Note that this is a draft in `derived/drafts/` — to promote it to
   a base document, review and move to `docs/plans/`
4. Suggest promoting completed stories to sprint planning via `/plan-sprint`
5. Clean up temp files:

```bash
rm -f "$CONTEXT"
rm -f "$DISTILL_CONTEXT"
rm -f /tmp/gc_plan_feature_result.json /tmp/gc_plan_feature_error.log
rm -f /tmp/gc_*.json 2>/dev/null
```

## What happens inside

This skill orchestrates three parallel input-gathering phases, then
synthesizes them into an implementation plan:

1. **Parallel input gathering:**
   - **Distillation** — session JSONL logs are filtered (user/assistant
     text only, no tool_use/thinking) and processed with the tagged
     extraction prompt from `/distill` ([DECISION], [REQ], [KEY],
     [OPEN], [TODO], [STATE]). This is an intermediate artifact — not
     saved separately.
   - **Code context** — gather-context workers discover relevant code
     files and return findings with relevance assessments.
   - **Design doc scan** — `derived/drafts/` and `docs/design/` are
     scanned for existing design documents related to the feature
     topic. Their full content is included in the merged context.

2. **Merge** — distilled findings, design documents, and code context
   are combined into a single context file. The distillation provides
   the "what was discussed and decided," the design docs provide the
   "what was formally proposed," and the code context provides the
   "what exists today."

3. **Plan generation** — the merged context is processed (via RLM if
   large) with a plan-specific prompt that produces a 7-section
   implementation plan with stories, acceptance criteria, sizing, and
   dependency ordering.

If no session logs exist, the distillation branch is skipped. If no
design documents are found, that section is omitted. In both cases,
a note is added suggesting the user run `/design` first to capture
design intent. The plan is then based on code context and the stated
topic only.

For small input (under 80K), everything is processed inline — no
sub-agents.
