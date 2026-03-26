# VS Code Signet Harness Index

## Purpose

Use this index to find the canonical artifacts involved in the VS Code custom
agent harness for Signet AI.

## In-Repo Canonical Artifacts

| Artifact               | Path                                                                                        | Why it matters                                                                                               |
| ---------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Workspace instructions | [.github/copilot-instructions.md](../../../../.github/copilot-instructions.md)              | Defines how agents should consume session-start and live-context files.                                      |
| Custom agent           | [.github/agents/signet-codex-vscode.agent.md](../../../agents/signet-codex-vscode.agent.md) | Defines the VS Code agent behavior and points it at the workspace runtime-context rules.                     |
| Session-start hook     | [.github/hooks/signet-session-start.ps1](../../../hooks/signet-session-start.ps1)           | Starts the Signet lifecycle, injects initial context, and writes the startup-context and live-context files. |
| Prompt-submit hook     | [.github/hooks/signet-user-prompt-submit.ps1](../../../hooks/signet-user-prompt-submit.ps1) | Refreshes Signet context per user prompt and updates the generated fallback file after the first prompt.     |
| Pre-compaction hook    | [.github/hooks/signet-pre-compaction.ps1](../../../hooks/signet-pre-compaction.ps1)         | Sends lightweight pre-compaction metadata to Signet and records local transcript state.                      |
| Session-end hook       | [.github/hooks/signet-session-end.ps1](../../../hooks/signet-session-end.ps1)               | Reports session shutdown to Signet and forwards transcript content when available.                           |
| Transcript helpers     | [.github/hooks/signet-transcript-state.ps1](../../../hooks/signet-transcript-state.ps1)     | Stores per-session transcript state and converts VS Code transcript content to a simpler conversation form.  |
| Generated live context | [.github/Generated/signet-live-context.md](../../../Generated/signet-live-context.md)       | Holds the freshest Signet context when prompt-submit refresh is implemented through a file fallback.         |

## Recommended Signet Docs Entry Points

Start with the Signet docs folder the user provided:

- Repo docs root:
  [Signet-AI/signetai/docs](https://github.com/Signet-AI/signetai/tree/main/docs)

These files are the most relevant for harness work:

| Doc                                                                                         | Why it matters                                                                     |
| ------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| [WHAT-IS-SIGNET.md](https://github.com/Signet-AI/signetai/blob/main/docs/WHAT-IS-SIGNET.md) | High-level product and mental model before wiring integrations.                    |
| [QUICKSTART.md](https://github.com/Signet-AI/signetai/blob/main/docs/QUICKSTART.md)         | Fast path for bootstrapping a working local Signet environment.                    |
| [ARCHITECTURE.md](https://github.com/Signet-AI/signetai/blob/main/docs/ARCHITECTURE.md)     | System boundaries and responsibilities worth preserving in the adapter layer.      |
| [HARNESSES.md](https://github.com/Signet-AI/signetai/blob/main/docs/HARNESSES.md)           | Naming, attribution, and harness registration model.                               |
| [HOOKS.md](https://github.com/Signet-AI/signetai/blob/main/docs/HOOKS.md)                   | Lifecycle hook behavior and hook contract expectations.                            |
| [DAEMON.md](https://github.com/Signet-AI/signetai/blob/main/docs/DAEMON.md)                 | Daemon endpoints, runtime expectations, and failure modes.                         |
| [API.md](https://github.com/Signet-AI/signetai/blob/main/docs/API.md)                       | Request and response details if you need to reason about hook payloads.            |
| [MEMORY.md](https://github.com/Signet-AI/signetai/blob/main/docs/MEMORY.md)                 | Memory model context for deciding what the harness should and should not do.       |
| [SKILLS.md](https://github.com/Signet-AI/signetai/blob/main/docs/SKILLS.md)                 | Useful when the harness needs to cooperate with Signet skills or memory workflows. |
| [MCP.md](https://github.com/Signet-AI/signetai/blob/main/docs/MCP.md)                       | Relevant if the harness also exposes Signet through MCP or tool surfaces.          |

## Artifact Dependency Order

1. Design the harness contract.
2. Wire the custom agent to lifecycle hooks.
3. Implement session-start injection.
4. Implement prompt refresh and decide whether direct injection is viable.
5. Implement pre-compaction and session-end reporting.
6. Validate and audit adjacent artifacts.

## Adjacent-Artifact Audit Targets

- Prompt file if the harness should expose a repeatable setup or repair command.
- Instruction file if the whole repo should follow a common Signet harness rule.
- Additional reference docs if the hooks require debugging or extension guidance.
- Generated artifact hygiene if live context or debug payloads should be ignored,
  documented, or consumed by the agent body.
