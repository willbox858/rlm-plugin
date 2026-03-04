# RLM -- Recursive Language Model Plugin for Claude Code

Process arbitrarily large contexts by recursive decomposition, parallel sub-agents, and result aggregation.

## What it does

RLM enables Claude Code to handle inputs that exceed its context window (100K+ characters) by recursively splitting content, delegating chunks to parallel sub-agents, and aggregating their results. The plugin ships 19 skills spanning documentation generation, planning, TDD-based implementation, and code quality analysis. Based on the paper: [Recursive Language Models](https://arxiv.org/abs/2512.24601).

## Installation

```bash
claude plugin add https://github.com/willbox858/rlm-plugin
```

## Skills

| Skill | Category | Description |
|-------|----------|-------------|
| `/rlm-process` | Core Processing | Process contexts too large for the context window via recursive decomposition |
| `/rlm-map` | Context Gathering | Recursive codebase search across files and directories with budget tracking |
| `/rlm-describe` | Documentation | Generate prose descriptions of code or architecture |
| `/rlm-diagram` | Documentation | Generate Mermaid diagrams from code or conversation |
| `/rlm-document` | Documentation | Comprehensive prose and diagram documentation |
| `/rlm-distill` | Documentation | Extract decisions, requirements, and key points from session logs or files |
| `/rlm-design` | Design & Analysis | Generate technical design documents from conversation and code |
| `/rlm-research` | Design & Analysis | Produce codebase research reports |
| `/rlm-validate` | Design & Analysis | Detect drift between code and design documents |
| `/rlm-review` | Design & Analysis | Quality and consistency review of code or documentation |
| `/rlm-diagnose` | Design & Analysis | Root cause analysis from symptoms and error traces |
| `/rlm-plan-feature` | Planning | Break a feature into implementation stories |
| `/rlm-plan-sprint` | Planning | Sprint planning from feature plans |
| `/rlm-plan-epic` | Planning | Epic planning with milestones and dependency graphs |
| `/rlm-implement` | Implementation | Execute a feature plan via TDD with iterative verification in a git worktree |
| `/rlm-update` | Implementation | Regenerate a stale derived document by re-running its original pipeline |
| `/rlm-bugfix` | Implementation | Diagnose and fix bugs end-to-end with regression tests |

## Architecture

The plugin is organized into three layers:

- **Skills** are the user-facing entry points (the slash commands listed above). Each skill prepares inputs and dispatches one or more agents.
- **Agents** do the actual work. The core RLM agents (`rlm-process` and `rlm-child`) recursively split large inputs, delegate to parallel sub-agents, and aggregate results -- no single agent ever reads the full input. Implementation agents (`implementation-orchestrator`, `implementation-worker`, `test-writer`, `verifier`) run the TDD loop.
- **Configs** drive `launch.sh`, the unified launcher that spawns all sub-agents with the correct environment, schema, and stdin behavior.

The recursive decomposition pattern: the orchestrator peeks at the first and last 1000 bytes of input, decides how to split it, spawns child agents in parallel, and merges their structured JSON results. Children at max depth process their chunk directly; children below max depth re-split and recurse.

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- `jq` (used by the launcher script)

## License

MIT
