# SignetAI_VSCode_Integration

This repository captures the current Signet integration pattern for VS Code custom agents using workspace-scoped PowerShell hooks.

The scripts under `.github/hooks/` are the canonical implementation. If this README and the scripts ever disagree, trust the scripts.

## Overview

The integration uses a shared Signet harness named `vscode-custom-agent` and four VS Code hook events:

- `SessionStart`
- `UserPromptSubmit`
- `PreCompact`
- `Stop`

Each hook is a thin adapter. It reads VS Code hook input from stdin, normalizes the payload, calls the local Signet daemon, and returns a VS Code-compatible JSON response. Retrieval, ranking, recall, and memory synthesis stay inside Signet.

The hooks are registered through:

- `.github/hooks/signet-session-start.json`
- `.github/hooks/signet-user-prompt-submit.json`
- `.github/hooks/signet-pre-compaction.json`
- `.github/hooks/signet-session-end.json`

The active PowerShell implementations are:

- `.github/hooks/signet-session-start.ps1`
- `.github/hooks/signet-user-prompt-submit.ps1`
- `.github/hooks/signet-pre-compaction.ps1`
- `.github/hooks/signet-session-end.ps1`
- `.github/hooks/signet-transcript-state.ps1`

All daemon calls target `http://127.0.0.1:3850`.

## Current Runtime Model

The current model is hook-driven injection, not file-driven context loading.

- `SessionStart` injects initial Signet context directly through `hookSpecificOutput.additionalContext`.
- `UserPromptSubmit` injects refreshed Signet context the same way after the initial skip.
- Files under `.github/Generated/` are debug mirrors and local state, not the authoritative live context channel.
- Hook failures are soft. The chat should continue even when Signet is unavailable.

That means the generated markdown files are there so you can inspect what the hooks last sent or attempted to send. They are not the canonical source of session memory.

## Hook Flow

### 1. SessionStart

`signet-session-start.ps1`:

- Accepts `sessionKey`, `sessionId`, `session_key`, or `session_id`.
- Calls `POST /api/hooks/session-start` with `harness`, `agentId`, `project`, and optional session metadata.
- Wraps the returned payload in an auto-injection header:

```text
[signet:auto-inject source=SessionStart session_key=<key> generated_at_utc=<timestamp>]
```

- Writes debug summaries to:
  - `.github/Generated/signet-session-start-context.md`
  - `.github/Generated/signet-live-context.md`
- Creates a one-shot prompt-refresh state file under `.github/Generated/prompt-refresh-state/`.

That prompt-refresh state is important: it causes the next prompt-submit refresh to be skipped once so the initial session-start injection is not duplicated immediately.

If the daemon call fails or returns no injection, the hook still succeeds and injects a short diagnostic string instead.

### 2. UserPromptSubmit

`signet-user-prompt-submit.ps1`:

- Writes the raw normalized hook payload to `.github/Generated/signet-last-user-prompt-input.json`.
- Checks the per-session prompt-refresh state file.
- If the skip marker exists, removes it and returns `{ "continue": true }` without calling Signet.
- Otherwise reads the richest available user prompt field from the hook payload.
- Normalizes transcript input when `transcriptPath` or `transcript_path` is present.
- Calls `POST /api/hooks/user-prompt-submit` with prompt text, session metadata, project metadata, and transcript context when available.
- Returns the Signet payload through `hookSpecificOutput.additionalContext`.

This hook also has three implementation details worth knowing:

1. VS Code transcript normalization

VS Code custom-agent transcript files are JSONL. The helper module converts `user.message` and `assistant.message` records into a plain text conversation format before passing a compatibility transcript to Signet when needed.

1. Memory-feedback contract surfacing

If the injected Signet payload contains a `<memory-feedback>` block, the hook prepends a normalized contract telling the agent to call `mcp_signet_memory_feedback` before answering.

1. Audit logging

The hook appends compact audit entries to `.github/Generated/signet-user-prompt-submit-audit.jsonl` and keeps the last five entries.

The script can also run a controlled injection experiment when `.github/Generated/live-context-injection-experiment.json` exists and enables it. Experiment results are written to `.github/Generated/live-context-injection-results.jsonl`.

On failure, the hook still returns `{ "continue": true }`, writes a diagnostic debug snapshot, and records the failure in the audit log.

### 3. PreCompact

`signet-pre-compaction.ps1` is now a lightweight continuity hook.

It:

- Resolves the current session key.
- Reads optional `sessionContext` and `messageCount` values from the hook payload.
- Calls `POST /api/hooks/pre-compaction`.
- Returns `{ "continue": true }` regardless of Signet availability.

What it does not do anymore:

- It does not upload transcript deltas through the session-end path.
- It does not maintain transcript offsets as the active compaction mechanism.
- It does not block compaction when Signet is down.

### 4. Stop

`signet-session-end.ps1` handles final session reporting.

It:

- Resolves session metadata and transcript input.
- Uses `signet-transcript-state.ps1` helpers to normalize VS Code JSONL transcripts when a transcript path is available.
- Writes normalized compatibility transcripts to `.github/Generated/normalized-transcripts/` when conversion is needed.
- Calls `POST /api/hooks/session-end` with `harness`, `agentId`, session metadata, and either `transcriptPath` or fallback inline transcript content.
- Clears any legacy transcript-state file after a successful Signet response.

Like the other hooks, it always returns `{ "continue": true }` and never blocks shutdown on Signet failure.

## Generated Files

The scripts currently create or update these artifacts under `.github/Generated/`:

- `signet-session-start-context.md`
- `signet-live-context.md`
- `signet-last-user-prompt-input.json`
- `signet-user-prompt-submit-audit.jsonl`
- `live-context-injection-results.jsonl` when experiments are enabled
- `prompt-refresh-state/*.json`
- `normalized-transcripts/*.txt` when transcript normalization is needed
- `transcript-state/*.json` as legacy cleanup state

These files are useful for debugging and inspection, but they are not the active session-memory contract.

## Transcript Handling

`signet-transcript-state.ps1` is shared helper code used by prompt-submit and session-end.

Its important responsibilities are:

- Computing stable per-session state file paths.
- Resolving transcript paths from hook payloads.
- Normalizing VS Code JSONL transcripts into plain `User:` and `Assistant:` conversation text.
- Cleaning up legacy transcript-state files.

This matters because Signet's generic transcript handling does not natively understand the VS Code custom-agent JSONL record shape.

## Signet Endpoints In Use

The current implementation calls these daemon endpoints:

- `POST /api/hooks/session-start`
- `POST /api/hooks/user-prompt-submit`
- `POST /api/hooks/pre-compaction`
- `POST /api/hooks/session-end`

## Behavior Guarantees

The scripts are written around a few explicit guarantees:

- Hooks fail soft.
- Session-start injection is immediate.
- Prompt-submit refresh is skipped once, then resumes on later prompts.
- Generated files are diagnostic mirrors, not live context sources.
- Memory-feedback instructions are surfaced when Signet emits them.
- VS Code transcript JSONL is normalized before being handed to Signet when compatibility conversion is required.

## Practical Verification

If you want to verify the integration quickly:

1. Start a fresh VS Code custom-agent session and confirm `SessionStart` injects Signet context.
2. Send a first prompt and confirm no prompt-submit refresh occurs because the skip marker is consumed.
3. Send a second prompt and confirm `UserPromptSubmit` calls Signet and updates the debug artifacts.
4. End the session and confirm a normalized transcript file is written when the original transcript is JSONL.

Useful artifacts to inspect during validation:

- `.github/Generated/signet-session-start-context.md`
- `.github/Generated/signet-live-context.md`
- `.github/Generated/signet-last-user-prompt-input.json`
- `.github/Generated/signet-user-prompt-submit-audit.jsonl`
- `.github/Generated/normalized-transcripts/`

## Repository Layout

```text
.github/
  agents/
    signet-codex-vscode.agent.md
  hooks/
    signet-session-start.json
    signet-session-start.ps1
    signet-user-prompt-submit.json
    signet-user-prompt-submit.ps1
    signet-pre-compaction.json
    signet-pre-compaction.ps1
    signet-session-end.json
    signet-session-end.ps1
    signet-transcript-state.ps1
    SIGNET-LIFECYCLE.md
  Generated/
    signet-session-start-context.md
    signet-live-context.md
    signet-last-user-prompt-input.json
    signet-user-prompt-submit-audit.jsonl
    normalized-transcripts/
```

## Summary

This repository is a working VS Code-to-Signet harness built around thin PowerShell adapters and daemon-backed hook injection. The canonical behavior is in the scripts: direct auto-injection on session start and later prompt submits, a deliberate one-turn skip after session start, transcript normalization for VS Code JSONL, compact prompt-submit auditing, and best-effort continuity and shutdown reporting that never breaks the chat session.
