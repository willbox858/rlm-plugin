---
name: update
description: "Regenerate a stale derived document from current sources. Re-runs the original skill's gathering and synthesis patterns with fresh code and conversation context, then presents a diff. Use when the user says 'update', 'refresh this doc', 'regenerate', 'update the design doc', 'this doc is stale', 'sync the docs', or wants to bring a derived document up to date with current code."
---

# Update — Regenerate Stale Derived Documents

Re-runs the original skill's gathering and synthesis patterns against
current code and conversation context. Creates a worktree for the
regenerated doc, presents old-vs-new comparison, and lets the user
decide whether to keep the update.

## When to use

- A derived doc is out of date with current code
- User says "update", "refresh this doc", "regenerate"
- User says "this doc is stale" or "sync the docs"
- After significant code changes, want to update derived docs
- Want to check if a derived doc still reflects reality

## When NOT to use

- User wants to create a new doc (use /design, /document, /create-description, etc.)
- User wants to validate code against design (use /validate)
- User wants to implement code (use /implement)
- The doc is a base document in docs/ — those are human-authored, not regenerated
- Trivially small change — just edit the doc directly

## Step 0: Input Mode Detection

**Mode A — Specific doc path**: User provides a derived doc path. Use it.

**Mode B — Topic/type**: User names a topic or doc type. Scan `derived/`
for matching docs:

```bash
UPDATE_TOPIC="<topic from user>"
UPDATE_SLUG="$(echo "$UPDATE_TOPIC" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')"

UPDATE_TARGET=""
UPDATE_CANDIDATES=""

# Search all derived directories
for dir in derived/descriptive derived/drafts derived/reports; do
  if [ -d "$dir" ]; then
    for f in "$dir"/*.md; do
      if [ -f "$f" ]; then
        if head -c 2000 "$f" | grep -qi "$UPDATE_SLUG\|$UPDATE_TOPIC" 2>/dev/null; then
          UPDATE_CANDIDATES="$UPDATE_CANDIDATES $f"
        fi
      fi
    done
  fi
done

CANDIDATE_COUNT=$(echo "$UPDATE_CANDIDATES" | wc -w)
if [ "$CANDIDATE_COUNT" -eq 1 ]; then
  UPDATE_TARGET="$UPDATE_CANDIDATES"
elif [ "$CANDIDATE_COUNT" -gt 1 ]; then
  echo "Multiple derived docs found for '$UPDATE_TOPIC':"
  for f in $UPDATE_CANDIDATES; do
    TYPE=$(head -20 "$f" | sed -n '/^---$/,/^---$/p' | grep '^type:' | sed 's/type: *//')
    echo "  - $f (type: $TYPE)"
  done
  # Ask user to choose
elif [ "$CANDIDATE_COUNT" -eq 0 ]; then
  echo "No derived document found matching '$UPDATE_TOPIC'."
  echo "Available derived docs:"
  find derived/ -name "*.md" -type f 2>/dev/null | head -20
  # STOP
fi
```

## Step 1: Read Frontmatter

Extract `type` and `topic` from the doc's YAML frontmatter to determine
which skill's pattern to replay:

```bash
DOC_TYPE=$(head -20 "$UPDATE_TARGET" | sed -n '/^---$/,/^---$/p' | grep '^type:' | sed 's/type: *//')
# Read topic — different skills use different frontmatter field names.
# Coalesce: topic > target > goal > vision > symptom
DOC_TOPIC=$(head -20 "$UPDATE_TARGET" | sed -n '/^---$/,/^---$/p' | grep -E '^(topic|target|goal|vision|symptom):' | head -1 | sed 's/^[^:]*: *//')
DOC_SUBTYPE=""

# Check for subtype fields
case "$DOC_TYPE" in
  plan)
    DOC_SUBTYPE=$(head -20 "$UPDATE_TARGET" | sed -n '/^---$/,/^---$/p' | grep '^plan_type:' | sed 's/plan_type: *//')
    ;;
  diagram)
    DOC_SUBTYPE=$(head -20 "$UPDATE_TARGET" | sed -n '/^---$/,/^---$/p' | grep '^diagram_type:' | sed 's/diagram_type: *//')
    ;;
  design)
    DOC_SUBTYPE=$(head -20 "$UPDATE_TARGET" | sed -n '/^---$/,/^---$/p' | grep '^design_type:' | sed 's/design_type: *//')
    ;;
  distillation)
    # Distillation files may not have a topic field — use session count as context
    DOC_SUBTYPE="distillation"
    ;;
esac

echo "Document type: $DOC_TYPE (subtype: $DOC_SUBTYPE)"
echo "Document topic: $DOC_TOPIC"
```

Type-to-skill mapping:

| Type | Subtype | Original Skill | Gathering Pattern |
|------|---------|---------------|-------------------|
| `description` | — | /create-description | GC + description synthesis |
| `diagram` | * | /create-diagram | GC + diagram synthesis |
| `design` | * | /design | distill + GC + design synthesis |
| `plan` | `feature` | /plan-feature | distill + artifact scan + GC + planning |
| `plan` | `sprint` | /plan-sprint | artifact scan + GC + sprint planning |
| `plan` | `epic` | /plan-epic | artifact scan + GC + epic planning |
| `validation` | — | /validate | design doc scan + GC + validation |
| `review` | * | /review | target GC + pattern GC + review |
| `diagnosis` | — | /diagnose | symptom-guided GC + design scan + diagnosis |
| `research` | — | /research | broad GC + gap analysis + synthesis |
| `document` | — | /document | GC + description + diagram synthesis |
| `distillation` | — | /distill | session log extraction + tagged synthesis |

If the type is unrecognized, fall back to a generic GC + synthesis approach.

## Step 2: Create Worktree

```bash
WORKTREE_DIR="/tmp/rlm-worktree-update-$UPDATE_SLUG-$(date +%s)"
BRANCH_NAME="update/$UPDATE_SLUG-$(date +%s)"

git worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME"
echo "Created worktree: $WORKTREE_DIR on branch $BRANCH_NAME"
```

## Step 3: Gather Fresh Context

Run the original skill's gathering pattern to get current state.
The approach varies by document type.

### Config resolution (shared by all types)

```bash
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

export GC_MAX_AGENTS="${GC_MAX_AGENTS:-$(jq -r '.env_defaults.GC_MAX_AGENTS // "50"' "$GC_CONFIG" 2>/dev/null || echo 50)}"
export GC_EXCLUDE="${GC_EXCLUDE:-$(jq -r '.env_defaults.GC_EXCLUDE // "node_modules,.git,target,dist,build,out,__pycache__,.venv,vendor,.claude,*.lock"' "$GC_CONFIG" 2>/dev/null || echo 'node_modules,.git,target,dist,build,out,__pycache__,.venv,vendor,.claude,*.lock')}"
export GC_MAX_FILE_SIZE="${GC_MAX_FILE_SIZE:-$(jq -r '.env_defaults.GC_MAX_FILE_SIZE // "512000"' "$GC_CONFIG" 2>/dev/null || echo 512000)}"
```

### For description/diagram/research types

Run GC focused on the topic:

```bash
export GC_TASK="Find all files relevant to: $DOC_TOPIC. I need current code context to regenerate a $DOC_TYPE document."

bash "$LAUNCHER" "$GC_CONFIG" "Task: $GC_TASK
mode: directory
directory: ." \
  > /tmp/gc_update_result.json 2>/tmp/gc_update_error.log
```

### For design type

Run distill + GC in parallel (same as /design Step 1):

```bash
# Branch A: Distill session history (if available)
PROJECT_DIR="$HOME/.claude/projects"
CWD_SLUG=$(pwd | sed 's|/|--|g' | sed 's|^-*||')
SESSION_DIR="$PROJECT_DIR/$CWD_SLUG"

# Branch B: Gather code context
export GC_TASK="Find all files relevant to: $DOC_TOPIC. I need current code and architecture context to regenerate a design document."

bash "$LAUNCHER" "$GC_CONFIG" "Task: $GC_TASK
mode: directory
directory: ." \
  > /tmp/gc_update_result.json 2>/tmp/gc_update_error.log
```

### For plan types

Scan artifact directories + run GC (same as the respective /plan-* Step 1):

```bash
# Scan for existing design docs and plans
DESIGN_DOCS=""
for f in derived/drafts/*-design-*.md docs/design/*.md; do
  if [ -f "$f" ]; then
    if head -c 2000 "$f" | grep -qi "$UPDATE_SLUG\|$DOC_TOPIC" 2>/dev/null; then
      DESIGN_DOCS="$DESIGN_DOCS $f"
    fi
  fi
done

# Run GC for code context
export GC_TASK="Find all files relevant to: $DOC_TOPIC. I need current code context to regenerate an implementation plan."
bash "$LAUNCHER" "$GC_CONFIG" "Task: $GC_TASK
mode: directory
directory: ." \
  > /tmp/gc_update_result.json 2>/tmp/gc_update_error.log
```

### For validation type

Scan for design docs + run GC (same as /validate Step 1).

### Build context file

Merge all gathered inputs into a single context file:

```bash
CONTEXT="/tmp/update_context_$(date +%Y%m%d_%H%M%S).txt"

# Include original doc for structural reference
echo "===== ORIGINAL DOCUMENT (for structural reference — regenerate, don't copy) =====" > "$CONTEXT"
cat "$UPDATE_TARGET" >> "$CONTEXT"
echo "" >> "$CONTEXT"

# Include fresh gathered context
echo "===== FRESH CODE CONTEXT =====" >> "$CONTEXT"
GC_RESULT=$(jq -r '.result' /tmp/gc_update_result.json 2>/dev/null || echo '{}')
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

# Include type-specific additional context (design docs, artifacts, distillation)
# ... varies by DOC_TYPE, added inline above

CONTEXT_SIZE=$(wc -c < "$CONTEXT")
echo "Prepared context: $CONTEXT_SIZE bytes"
```

## Step 4: Regenerate

Reconstruct the original skill's synthesis prompt from the `type` field.

The synthesis prompt should match the original skill's RLM_TASK prompt
(7-section structure, same rules, same output format) with an additional
instruction:

```
Note: You are REGENERATING an existing document. The original document
is included for structural reference only. Generate the document fresh
from the current code and context. Do not copy the original — derive
everything from the current sources. If the structure of the current
code suggests a different organization than the original doc, follow
the code.
```

### Size check

If under 80,000 characters: read the context file directly and produce
the regenerated document inline. Skip RLM dispatch.

If 80,000+ characters: dispatch to RLM orchestrator.

### RLM dispatch (if needed)

```bash
export RLM_TASK="<reconstructed synthesis prompt for $DOC_TYPE>

Note: You are REGENERATING an existing document. The original is included
for structural reference only. Generate fresh from current sources."
```

Invoke rlm-orchestrator:

```
Use the rlm-orchestrator agent:
RLM_TASK is set in the environment.
Process the context at $CONTEXT
Task: $RLM_TASK
```

CLI fallback:

```bash
env -u CLAUDECODE \
  RLM_DEPTH=0 \
  RLM_TASK="$RLM_TASK" \
  claude -p "$RLM_TASK" \
    --agent rlm-orchestrator \
    < "$CONTEXT"
```

## Step 5: Compare Old vs New

After regeneration, compare the old and new documents:

```bash
OLD_SIZE=$(wc -c < "$UPDATE_TARGET")
NEW_DOC="/tmp/update_new_doc.md"
# Write regenerated content to NEW_DOC (from RLM result or inline)
NEW_SIZE=$(wc -c < "$NEW_DOC")

echo "Old document: $OLD_SIZE bytes"
echo "New document: $NEW_SIZE bytes"
```

### Size check

Flag if the new document is dramatically shorter:

```bash
if [ "$OLD_SIZE" -gt 0 ]; then
  RATIO=$((NEW_SIZE * 100 / OLD_SIZE))
  if [ "$RATIO" -lt 50 ]; then
    echo "WARNING: New document is less than 50% the size of the original ($RATIO%)"
    echo "This may indicate lost content. Review carefully."
  fi
fi
```

### Section presence check

Verify major headings from the original are present in the new version:

```bash
OLD_HEADINGS=$(grep '^## ' "$UPDATE_TARGET" | sort)
NEW_HEADINGS=$(grep '^## ' "$NEW_DOC" | sort)

MISSING=$(comm -23 <(echo "$OLD_HEADINGS") <(echo "$NEW_HEADINGS"))
if [ -n "$MISSING" ]; then
  echo "WARNING: These sections from the original are missing in the new version:"
  echo "$MISSING"
fi

NEW_SECTIONS=$(comm -13 <(echo "$OLD_HEADINGS") <(echo "$NEW_HEADINGS"))
if [ -n "$NEW_SECTIONS" ]; then
  echo "New sections added:"
  echo "$NEW_SECTIONS"
fi
```

### Decision

- If clearly better (similar or greater size, all major sections present)
  → copy to worktree, commit automatically
- If questionable (dramatically shorter, missing sections) → present both
  versions to user, let them decide

```bash
# Write new doc with updated frontmatter
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
cat > "$WORKTREE_DIR/$UPDATE_TARGET" <<EOF
---
generated: $(date -Iseconds)
type: $DOC_TYPE
topic: $DOC_TOPIC
updated_from: $UPDATE_TARGET
previous_size: $OLD_SIZE bytes
input_size: $CONTEXT_SIZE bytes
---

EOF

# Append regenerated content (strip any duplicate frontmatter from RLM output)
cat "$NEW_DOC" >> "$WORKTREE_DIR/$UPDATE_TARGET"

cd "$WORKTREE_DIR"
git add -A
git commit -m "update: regenerate $DOC_TYPE for $DOC_TOPIC"
```

## Step 6: Present

Show the user:

1. **Diff summary**: Size change, sections added/removed/changed
2. **Warnings**: If doc is shorter or missing sections
3. **Branch name**: `update/<slug>-<timestamp>`
4. **Commands to review and merge**:

```bash
# Review the regenerated doc
cat "$WORKTREE_DIR/$UPDATE_TARGET"

# See the diff
diff "$UPDATE_TARGET" "$WORKTREE_DIR/$UPDATE_TARGET"

# Merge into current branch
git merge $BRANCH_NAME

# Or discard
git worktree remove $WORKTREE_DIR
git branch -D $BRANCH_NAME
```

## Step 7: Cleanup

Remove temp files. Do NOT remove the worktree — user decides.

```bash
rm -f "$CONTEXT"
rm -f /tmp/gc_update_result.json /tmp/gc_update_error.log
rm -f /tmp/gc_*.json 2>/dev/null
rm -f /tmp/update_*.md /tmp/update_*.txt 2>/dev/null
```

## What happens inside

This skill re-executes the original skill's pipeline with fresh inputs:

1. **Input resolution** — Find the target derived doc, read its frontmatter
2. **Type mapping** — Determine which skill's gathering pattern to replay
3. **Worktree creation** — Isolated branch for the regenerated doc
4. **Fresh context gathering** — Same gathering pattern as the original
   skill, but against current code/artifacts
5. **Regeneration** — Same synthesis prompt, fresh context (inline or RLM)
6. **Comparison** — Old vs new: size, section presence, quality flags
7. **Result presentation** — Diff summary, warnings, review commands
8. **Cleanup** — Temp files removed, worktree preserved

The skill is type-aware: it adapts its gathering and synthesis based on
the original document's `type` field in the frontmatter. Any derived
document from any skill can be updated — as long as it has proper
frontmatter with `type` and `topic` fields.

For small context (under 80K), everything is processed inline — no
sub-agents.
