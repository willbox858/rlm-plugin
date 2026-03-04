# RLM -- Recursive Language Model Plugin for Claude Code

Process arbitrarily large contexts by recursive decomposition, parallel sub-agents, and result aggregation.

## What it does

RLM enables Claude Code to handle inputs that exceed its context window (100K+ characters) by recursively splitting content, delegating chunks to parallel sub-agents, and aggregating their results. The plugin ships 19 skills spanning documentation generation, planning, TDD-based implementation, and code quality analysis. Based on the paper: [Recursive Language Models](https://arxiv.org/abs/2512.24601).

## Installation

```bash
claude plugin add https://github.com/YOUR_USERNAME/rlm-plugin
```

## Skills

| Skill | Category | Description |
|-------|----------|-------------|
| `/rlm` | Core Processing | Process contexts too large for the context window via recursive decomposition |
| `/gather-context` | Context Gathering | Recursive codebase search across files and directories with budget tracking |
| `/describe` | Documentation | Generate prose descriptions of code or architecture |
| `/diagram` | Documentation | Generate Mermaid diagrams from code or conversation |
| `/document` | Documentation | Comprehensive prose and diagram documentation |
| `/distill` | Documentation | Extract decisions, requirements, and key points from session logs or files |
| `/design` | Design & Analysis | Generate technical design documents from conversation and code |
| `/research` | Design & Analysis | Produce codebase research reports |
| `/validate` | Design & Analysis | Detect drift between code and design documents |
| `/review` | Design & Analysis | Quality and consistency review of code or documentation |
| `/diagnose` | Design & Analysis | Root cause analysis from symptoms and error traces |
| `/plan-feature` | Planning | Break a feature into implementation stories |
| `/plan-sprint` | Planning | Sprint planning from feature plans |
| `/plan-epic` | Planning | Epic planning with milestones and dependency graphs |
| `/implement` | Implementation | Execute a feature plan via TDD with iterative verification in a git worktree |
| `/update` | Implementation | Regenerate a stale derived document by re-running its original pipeline |

## Architecture

The plugin is organized into three layers:

- **Skills** are the user-facing entry points (the slash commands listed above). Each skill prepares inputs and dispatches one or more agents.
- **Agents** do the actual work. The core RLM agents (`rlm-orchestrator` and `rlm-child`) recursively split large inputs, delegate to parallel sub-agents, and aggregate results -- no single agent ever reads the full input. Implementation agents (`implementation-orchestrator`, `implementation-worker`, `test-writer`, `verifier`) run the TDD loop.
- **Configs** drive `launch.sh`, the unified launcher that spawns all sub-agents with the correct environment, schema, and stdin behavior.

The recursive decomposition pattern: the orchestrator peeks at the first and last 1000 bytes of input, decides how to split it, spawns child agents in parallel, and merges their structured JSON results. Children at max depth process their chunk directly; children below max depth re-split and recurse.

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- `jq` (used by the launcher script)

## License

MIT
