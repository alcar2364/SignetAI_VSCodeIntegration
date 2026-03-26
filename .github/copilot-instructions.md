# Signet Workspace Instructions

This workspace uses Signet through workspace-scoped VS Code hooks registered in `.github/hooks/*.json`.

## Runtime context rules

- Treat `.github/Generated/signet-session-start-context.md` as the startup memory surface for the current session.
- Treat `.github/Generated/signet-live-context.md` as the rolling memory surface refreshed by `UserPromptSubmit`.
- Prefer startup context on the first turn.
- Starting with the second user prompt, always read `.github/Generated/signet-live-context.md` before answering and treat its contents as active session memory until the session is compacted or ended.
- If either generated file contains a Signet diagnostic instead of memory content, continue the task normally and do not treat that diagnostic as a hard failure.

## Harness behavior

- `SessionStart` injects initial Signet context and resets live context to a placeholder.
- `UserPromptSubmit` skips the first refresh for each session, then rewrites live context on later prompts.
- `PreCompact` is metadata-only in the current implementation; it signals Signet that compaction is happening and records local state.
- `Stop` performs the final session-end upload and includes transcript content when it is available.

## Working expectations

- Prefer the freshest Signet-generated context when it is relevant, but do not assume it is complete.
- After the first prompt, do not assume live context was injected automatically; read the generated live-context file explicitly.
- If workspace files and Signet context disagree, trust the repository state first and use Signet as supporting context.
- Do not edit files under `.github/Generated/`; they are hook outputs and diagnostics.
