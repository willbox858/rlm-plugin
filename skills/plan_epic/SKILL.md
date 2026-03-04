---
name: plan-epic
description: "Create an epic-level plan with milestones, dependencies, and phasing strategy. Use when the user says 'plan the epic', 'roadmap for X', 'milestone planning', 'plan-epic', 'epic plan', 'project plan', 'phasing strategy', 'what are the milestones', or wants to organize features into milestones with a dependency graph and critical path analysis."
---

# Plan Epic — Milestones, Dependencies, and Phasing

Generates an epic-level plan by broadly discovering all existing
artifacts (plans, designs, descriptions, reports) and gathering a
high-level codebase overview, then synthesizing into milestones with a
mermaid dependency graph. Dispatches artifact discovery and broad code
context gathering in parallel, then uses RLM for the final epic plan.
Output is a draft derived document.

## When to use

- Creating a roadmap or epic-level plan across multiple features
- User says "plan the epic", "roadmap for X", "milestone planning"
- Need milestones, phasing strategy, and dependency graph
- Organizing multiple feature plans into a sequenced epic
- User says "project plan" or "what are the milestones"
- Planning a major initiative that spans multiple sprints

## When NOT to use

- User wants to plan a single feature (use `/plan-feature`)
- User wants sprint-level planning (use `/plan-sprint`)
- User wants a design doc (use `/design`)
- User wants to explore a topic (use `/research`)
- The project is small enough for a single sprint — use `/plan-sprint` instead
- Context is trivially small — just write the milestones directly

## Step 0: Determine input mode and epic vision

### Input mode

Ask or infer which mode applies:

**Mode A — Specific scope**: User provides specific features, plans,
or constraints for the epic. Use those files directly as input.

**Mode B — Broad discovery**: User states a vision or says "plan the
epic" without specifying scope. Auto-discover ALL existing artifacts —
do NOT ask the user for file paths. This is the most common mode.

**Mode C — Current conversation**: The relevant context is already
small and present in the conversation. Process inline — no file
gathering, discovery, or RLM dispatch needed. Skip to Step 4.

### Epic vision

Capture the epic vision explicitly. This is the overarching objective
of the epic — what the end state looks like.

```bash
EPIC_VISION="<the epic's vision/objective>"     # e.g. "Build a complete auth system with SSO, MFA, and API keys"
EPIC_SLUG="<slugified-vision>"                  # e.g. "auth-system-epic"
```

## Step 1: Gather inputs IN PARALLEL

Run artifact discovery and code context gathering concurrently. They
are independent and their results are merged in Step 2.

### Branch A: Broad artifact discovery

Scan ALL of `derived/` and `docs/` for existing artifacts. Epic
planning needs scope, not details — use `head -c 2000` per file if
too many artifacts:

```bash
ARTIFACTS=""
ARTIFACT_COUNT=0

# Scan all of derived/ recursively
if [ -d "derived" ]; then
  for f in $(find derived -name '*.md' -type f 2>/dev/null); do
    ARTIFACTS="$ARTIFACTS $f"
    ARTIFACT_COUNT=$((ARTIFACT_COUNT + 1))
  done
fi

# Scan all of docs/ recursively
if [ -d "docs" ]; then
  for f in $(find docs -name '*.md' -type f 2>/dev/null); do
    ARTIFACTS="$ARTIFACTS $f"
    ARTIFACT_COUNT=$((ARTIFACT_COUNT + 1))
  done
fi

echo "Found $ARTIFACT_COUNT total artifacts across derived/ and docs/"
```

Graceful degradation when no artifacts are found:

```bash
if [ "$ARTIFACT_COUNT" -eq 0 ]; then
  echo "No existing artifacts found in derived/ or docs/."
  echo "Epic plan will be based on code context + stated vision."
  echo "Consider running /design → /plan-feature first to build up artifacts."
fi
```

### Branch B: Broad gather-context for high-level codebase overview

Run gather-context with a broad task focused on high-level structure:

```bash
export GC_TASK="Provide a high-level overview of the codebase for epic-level planning. Focus on: overall project structure, major modules and their responsibilities, key configuration files, test coverage, documentation state, and any README or project description files. I need the big picture, not implementation details."

# Resolve config and launcher
if [ -n "$RLM_ROOT" ]; then
  GC_CONFIG="$RLM_ROOT/configs/gc.json"
  LAUNCHER="$RLM_ROOT/launch.sh"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  GC_CONFIG="$CLAUDE_PLUGIN_ROOT/configs/gc.json"
  LAUNCHER="$CLAUDE_PLUGIN_ROOT/launch.sh"
else
  GC_CONFIG="$(find . -path '*/.claude/RLM/configs/gc.json' -print -quit 2>/dev/null)"
  if [ -z "$GC_CONFIG" ]; then
    GC_CONFIG="$HOME/.claude/RLM/configs/gc.json"
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
  > /tmp/gc_plan_epic_result.json 2>/tmp/gc_plan_epic_error.log
```

Validate the result:

```bash
if [ ! -s /tmp/gc_plan_epic_result.json ]; then
  echo "ERROR: Gather-context returned empty result" >&2
  cat /tmp/gc_plan_epic_error.log >&2
  exit 1
fi

jq -e '.result' /tmp/gc_plan_epic_result.json > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: Gather-context returned invalid JSON" >&2
  exit 1
fi
```

## Step 2: Merge artifact discovery + code overview

Combine both inputs into a single context file with three sections:
epic vision as preamble, existing artifacts, and codebase overview.

For artifacts, use `head -c 2000` per file when more than 20 are
found — frontmatter and the first section is enough for scope at the
epic level.

```bash
CONTEXT="/tmp/epic_context_$(date +%Y%m%d_%H%M%S).txt"

# Section 1: Epic vision as preamble
echo "===== EPIC VISION =====" > "$CONTEXT"
echo "$EPIC_VISION" >> "$CONTEXT"
echo "" >> "$CONTEXT"

# Section 2: Existing artifacts
if [ "$ARTIFACT_COUNT" -gt 0 ]; then
  echo "===== EXISTING ARTIFACTS ($ARTIFACT_COUNT files) =====" >> "$CONTEXT"
  for f in $ARTIFACTS; do
    echo "===== FILE: $f =====" >> "$CONTEXT"
    if [ "$ARTIFACT_COUNT" -gt 20 ]; then
      head -c 2000 "$f" >> "$CONTEXT"
      echo "" >> "$CONTEXT"
      echo "[... truncated for epic-level overview ...]" >> "$CONTEXT"
    else
      cat "$f" >> "$CONTEXT"
    fi
    echo "" >> "$CONTEXT"
  done
else
  echo "===== NO EXISTING ARTIFACTS FOUND =====" >> "$CONTEXT"
  echo "Building epic plan from code context and stated vision." >> "$CONTEXT"
  echo "Consider running /design → /plan-feature to build artifact base." >> "$CONTEXT"
  echo "" >> "$CONTEXT"
fi

# Section 3: Code overview (high relevance only)
GC_RESULT=$(jq -r '.result' /tmp/gc_plan_epic_result.json)
echo "===== CODEBASE OVERVIEW =====" >> "$CONTEXT"
echo "$GC_RESULT" >> "$CONTEXT"
echo "" >> "$CONTEXT"

# Only include HIGH relevance files — epic needs big picture, not details
for f in $(echo "$GC_RESULT" | jq -r '.findings[]? | select(.relevance == "high") | .file_path' 2>/dev/null); do
  if [ -f "$f" ]; then
    echo "===== FILE: $f =====" >> "$CONTEXT"
    cat "$f" >> "$CONTEXT"
    echo "" >> "$CONTEXT"
  fi
done

FILE_COUNT=$(grep -c "^===== FILE:" "$CONTEXT" || echo 0)
CONTEXT_SIZE=$(wc -c < "$CONTEXT")
echo "Prepared context: $CONTEXT_SIZE bytes from $FILE_COUNT files ($ARTIFACT_COUNT artifacts)"
```

## Step 3: Size check

```bash
echo "Context size: $CONTEXT_SIZE bytes"
```

If under 80,000 characters: read the context file directly and produce
the epic plan inline. Skip Step 4 and go straight to Step 5.

If 80,000+ characters: continue to Step 4 for RLM dispatch.

## Step 4: Set RLM_TASK and dispatch

Build the epic-plan-generation prompt:

```bash
export RLM_TASK="Produce an epic-level plan for: $EPIC_VISION

Use the existing artifacts (plans, designs, descriptions, reports) and codebase overview to create a comprehensive epic plan with milestones and dependencies.

Structure the plan with these 7 sections:

1. **Vision & Scope** — What is the epic about? What is the end state? What is explicitly out of scope? Define the boundaries clearly.
2. **Milestones** — 3-6 milestones, each representing a meaningful deliverable. For each milestone:
   - **Name** — Short, descriptive name (e.g., 'M1: Core Auth Infrastructure')
   - **Goal** — What this milestone achieves. What is true after completion?
   - **Key Features** — Major features or capabilities delivered in this milestone
   - **Success Criteria** — How to verify the milestone is complete
   - **Estimated Duration** — Rough timeframe (e.g., '2-3 sprints', '1 month')
   - **Prerequisites** — Which milestones must complete first (use milestone numbers)
3. **Dependency Graph** — A Mermaid diagram showing milestone dependencies:
   \`\`\`mermaid
   graph TD
     M1[M1: Core Infrastructure] --> M2[M2: Feature A]
     M1 --> M3[M3: Feature B]
     M2 --> M4[M4: Integration]
     M3 --> M4
     M4 --> M5[M5: Polish & Launch]
   \`\`\`
   Include a brief prose explanation of the graph below the diagram.
4. **Critical Path** — Which milestones form the critical path (longest dependency chain)? What is the minimum time to completion? Where are the bottlenecks?
5. **Phasing Strategy** — How to sequence the work. What can be parallelized? Where should resources be concentrated? What are the key decision points between phases?
6. **Risks & Mitigations** — Epic-level risks: technical, resource, scope, and external. For each: likelihood, impact, mitigation strategy, and contingency plan.
7. **Success Criteria** — How to know the epic is complete. Measurable outcomes, not vague goals.

Rules:
- Ground milestones in existing feature plans and designs where they exist
- Reference specific artifacts by file path when drawing from them
- The mermaid graph must be valid syntax and accurately reflect the milestone dependencies
- Duration estimates should be ranges, not single numbers
- Identify work that can be parallelized across milestones
- If existing artifacts cover only part of the epic, note gaps and suggest which skills to run
- Be explicit about assumptions — what is assumed to be available or decided
- Each milestone should be independently valuable — partial epic completion should still deliver value"
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

Write the epic plan to a file:

```bash
OUTPUT_DIR="derived/drafts"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$OUTPUT_DIR/$EPIC_SLUG-epic-$TIMESTAMP.md"

cat > "$OUTPUT" <<EOF
---
generated: $(date -Iseconds)
type: plan
plan_type: epic
vision: $EPIC_VISION
artifacts_found: $ARTIFACT_COUNT
input_size: $CONTEXT_SIZE bytes
---

# Epic Plan: $EPIC_VISION

EOF

# Append the result from RLM or inline processing
echo "$RESULT" >> "$OUTPUT"

echo "Saved to: $OUTPUT"
```

## Step 6: Present and cleanup

1. Show the user the epic plan (or a summary if it is long)
2. Tell them where the file was saved
3. Display the mermaid dependency graph
4. Note that this is a draft in `derived/drafts/` — to promote it to
   a base document, review and move to `docs/plans/`
5. Highlight the critical path and milestone count
6. Clean up temp files:

```bash
rm -f "$CONTEXT"
rm -f /tmp/gc_plan_epic_result.json /tmp/gc_plan_epic_error.log
rm -f /tmp/gc_*.json 2>/dev/null
```

## What happens inside

This skill orchestrates two parallel input-gathering phases, then
synthesizes them into an epic plan with an inline mermaid dependency
graph:

1. **Parallel input gathering:**
   - **Broad artifact discovery** — ALL of `derived/` and `docs/` are
     scanned recursively for `.md` files. When more than 20 artifacts
     are found, each is truncated to `head -c 2000` (frontmatter +
     first section is enough for epic-level scope, not details). When
     no artifacts are found, the skill gracefully degrades and suggests
     running `/design` followed by `/plan-feature` to build up an
     artifact base.
   - **High-level codebase overview** — gather-context workers discover
     relevant code files with a broad task focused on project structure,
     major modules, configuration, test coverage, and documentation
     state. Only HIGH relevance files are included in the merged
     context (not medium) — epic planning needs the big picture.

2. **Merge** — the epic vision, discovered artifacts, and codebase
   overview are combined into a single context file. The artifacts
   provide the "what has been planned and designed," while the code
   overview provides the "what exists today and how it is structured."

3. **Epic plan generation** — the merged context is processed (via RLM
   if large) with an epic-planning prompt that produces a 7-section
   plan: Vision & Scope, Milestones (3-6), Dependency Graph (valid
   Mermaid syntax), Critical Path, Phasing Strategy, Risks &
   Mitigations, and Success Criteria. The mermaid dependency graph is
   part of the RLM prompt template, not a separate generation step.

For small input (under 80K), everything is processed inline — no
sub-agents.
