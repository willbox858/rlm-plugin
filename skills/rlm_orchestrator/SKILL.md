---
name: rlm_orchestrator
description: "Use Recursive Language Model (RLM) techniques to process contexts that are too large for the context window, or where dense processing of every part is needed. Trigger when the user asks to process very large files (100K+ chars), analyze entire codebases, summarize huge documents, search through massive text corpuses, count or aggregate across many items, or any task where the input is much larger than what fits comfortably in context. Also trigger when the user explicitly mentions 'RLM', 'recursive language model', or asks to 'process this recursively'. Based on the paper: https://arxiv.org/abs/2512.24601"
---

# RLM - Dispatch to Orchestrator

When a task involves more context than fits in your window, delegate it
to the **rlm-orchestrator** agent. You stay clean -- prepare the input,
dispatch once, read one result.

## When to use

- Context exceeds 100K characters
- Task requires dense processing of every part of the input
- Aggregating information across many files or sections
- User explicitly asks for RLM / recursive processing

## When NOT to use

- Context fits comfortably in your window
- A quick grep/search answers the question
- The user just wants a summary of a short document

## Step 1: Prepare the context file

Gather everything the orchestrator needs into a single file:

```bash
# Single large file -- just note its path
CONTEXT="/path/to/huge.txt"

# Multiple files -- concatenate with markers
CONTEXT="/tmp/rlm_context.txt"
for f in src/*.cs; do
  echo "===== FILE: $f =====" >> "$CONTEXT"
  cat "$f" >> "$CONTEXT"
done
```

## Step 2: Set RLM_TASK

**This is critical.** Before dispatching, capture the user's original
request verbatim into `RLM_TASK`. This env var is the "guiding light"
that every agent in the tree checks to stay aligned to the same goal.
Do not paraphrase, summarize, or omit any part of the user's request.

```bash
export RLM_TASK="<the user's original request, verbatim, unmodified>"
```

## Step 3: Dispatch to the orchestrator agent

The orchestrator handles all other config loading internally (reads
`internal/rlm-child.json` from its plugin directory, exports remaining
env vars). You do NOT need to parse config or set any env vars
besides RLM_TASK.

The user can request overrides verbally:
- "Use sonnet for sub-agents" -> mention it in the task description
- "Allow 5 levels deep" -> mention it in the task description

Invoke the rlm-orchestrator agent. It has the rlm_agent skill
preloaded, bypassPermissions mode, and access to Read, Bash, Grep,
and Glob.

If the context is a file path, tell the orchestrator where it is.
Always include RLM_TASK in both the prompt AND as an env var:

```
Use the rlm-orchestrator agent:
RLM_TASK is set in the environment.
Process the context at /tmp/rlm_context.txt
Task: $RLM_TASK
```

The agent spawns as a subagent with its own context window. All the
chunking, sub-agent delegation, and aggregation happen there -- not
in your conversation.

If the agent tool is unavailable, fall back to CLI:

```bash
env -u CLAUDECODE \
  RLM_DEPTH=0 \
  RLM_TASK="$RLM_TASK" \
  claude -p "$RLM_TASK" \
    --agent rlm-orchestrator \
    < "$CONTEXT"
```

Note: `--agent rlm-orchestrator` replaces manual `--model`,
`--max-turns`, and `--dangerously-skip-permissions` flags since those
are now in the agent's frontmatter.

## Step 4: Present the result

The orchestrator returns its final answer. Summarize it for the user.
If the result is large, peek with `head`/`tail` first.

## What happens inside

You don't manage this -- the orchestrator handles it:
1. Loads config from `internal/rlm-child.json`, exports env vars
2. Explores context with `wc`, `head`, `tail`, `grep`
3. Filters with standard tools
4. Chunks and delegates to rlm-child agents via `launch.sh`
5. Sub-agents receive "Root task: $RLM_TASK" for alignment
6. Validates child results (detects errors/empty outputs)
7. Aggregates results; recurses if needed (up to RLM_MAX_DEPTH)
8. Cleans up temp files
9. Returns the final answer
