# Signet Workspace Instructions

This workspace uses Signet through workspace-scoped VS Code hooks registered in `.github/hooks/*.json`.

## Runtime context rules

- Treat hook-delivered auto-injection as the active Signet context channel.
- `SessionStart` provides the initial injected context for the session.
- `UserPromptSubmit` provides refreshed injected context after the one-time post-start skip.
- Treat files under `.github/Generated/` as diagnostic mirrors and local state, not as required context sources.
- If a generated file contains a Signet diagnostic, treat it as debugging information rather than authoritative runtime context.

## Harness behavior

- `SessionStart` injects initial Signet context, writes debug mirrors, and creates the one-shot prompt-refresh skip marker.
- `UserPromptSubmit` skips the first refresh for each session, then injects refreshed Signet context on later prompts and writes debug artifacts.
- `PreCompact` is metadata-only in the current implementation and signals Signet through the dedicated `pre-compaction` endpoint.
- `Stop` performs the final session-end upload and normalizes VS Code JSONL transcripts before daemon handoff when needed.

## Working expectations

- Prefer the freshest Signet-generated context when it is relevant, but do not assume it is complete.
- Prefer repository state over injected Signet context when they disagree.
- Do not rely on `.github/Generated/` files as mandatory inputs to answer a prompt.
- If workspace files and Signet context disagree, trust the repository state first and use Signet as supporting context.
- Do not edit files under `.github/Generated/`; they are hook outputs and diagnostics.
