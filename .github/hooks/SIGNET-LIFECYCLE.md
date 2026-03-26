# Signet Session Lifecycle — VS Code Workspace Hooks

This document describes the Signet lifecycle that is currently implemented in
the workspace hook registrations and PowerShell scripts under
`.github/hooks/` and `.agentic/hooks/`.

It is intentionally implementation-first. If this file disagrees with a design
note, treat the scripts and hook registrations as the source of truth.

## Active Runtime Shape

The workspace currently uses four Signet hook events:

1. `SessionStart` via `.github/hooks/signet-session-start.json`
1. `UserPromptSubmit` via `.github/hooks/signet-user-prompt-submit.json`
1. `PreCompact` via `.github/hooks/signet-pre-compaction.json`
1. `Stop` via `.github/hooks/signet-session-end.json`

Two details matter:

- `SessionStart` and `UserPromptSubmit` use the daemon-backed HTTP injection
  path.
- `PreCompact` is currently wired to
  `.agentic/hooks/signet-pre-compaction.ps1`.

## Current Principles

- Hooks fail soft. If Signet is unavailable, the conversation continues.
- Hook-delivered injection is the live source of truth.
- Generated files under `.agentic/generated/` are diagnostic mirrors, not active
  context sources.
- Prompt refresh is intentionally skipped on the first prompt after
  `SessionStart` so the initial injection is not duplicated immediately.
- Pre-compaction now follows Signet's dedicated `pre-compaction` endpoint for
  continuity checkpoints rather than treating compaction as a synthetic
  session-end transcript upload.
- VS Code custom-agent JSONL transcripts are normalized into plain conversation
  text before being handed to Signet on the prompt-submit and session-end
  paths.

## Lifecycle Flow

### 1. SessionStart (`signet-session-start.ps1`)

**Trigger:** A new VS Code custom-agent session starts.

**Registration:** `.github/hooks/signet-session-start.json`

**What the script does:**

- Reads hook input from stdin and accepts any of `sessionKey`, `sessionId`,
  `session_key`, or `session_id`.
- Calls `POST http://127.0.0.1:3850/api/hooks/session-start` with:
  - `harness = "vscode-custom-agent"`
  - `agentId`
  - `project`
  - `sessionKey` and `sessionId` when present
  - `context` when the hook input provides it
- Wraps the returned injection in an auto-injection header of the form:

```text
[signet:auto-inject source=SessionStart session_key=<key> generated_at_utc=<timestamp>]
```

- Writes two debug-only markdown mirrors:
  - `.agentic/generated/signet-session-start-context.md`
  - `.agentic/generated/signet-live-context.md`
- Creates a prompt-refresh state file under
  `.agentic/generated/prompt-refresh-state/` with
  `skipNextPromptRefresh = true`.

**Failure behavior:**

- On daemon failure or timeout, the hook still returns successfully and injects
  a short failure message instead of blocking the session.

**Outcome:**

- Signet provides the initial session context.
- The next `UserPromptSubmit` refresh is intentionally skipped once.

### 2. UserPromptSubmit (`signet-user-prompt-submit.ps1`)

**Trigger:** VS Code fires the prompt-submit hook before a user prompt is
processed.

**Registration:** `.github/hooks/signet-user-prompt-submit.json`

**What the script does:**

- Reads the prompt from the first non-empty supported field, including
  `promptText`, `userPrompt`, `userMessage`, `prompt`, `message`, `text`,
  `input`, `chatSessionInput`, `request`, or `user_input`.
- Writes the raw hook payload to
  `.agentic/generated/signet-last-user-prompt-input.json` for debugging.
- Checks the prompt-refresh state file created by `SessionStart`:
  - If the skip marker exists, it deletes that marker and returns
    `{ "continue": true }` without contacting Signet.
  - This means the first prompt after session start does not trigger an extra
    refresh.
- If live-context experiment config exists at
  `.agentic/generated/live-context-injection-experiment.json`, the script can
  short-circuit into a controlled experiment response and log the result to
  `.agentic/generated/live-context-injection-results.jsonl`.
- Otherwise it calls
  `POST http://127.0.0.1:3850/api/hooks/user-prompt-submit` with:
  - `harness = "vscode-custom-agent"`
  - `agentId`
  - `project`
  - `cwd`
  - `userMessage`
  - `userPrompt`
  - `sessionKey` and `sessionId` when present
  - `lastAssistantMessage` when present
  - `transcriptPath` when the hook payload provides one, using a normalized
    compatibility file for VS Code JSONL transcripts when needed
  - fallback inline `transcript` when the hook payload provides one
- When the hook payload includes a transcript path, normalizes VS Code JSONL
  transcripts into a generated plain conversation transcript before forwarding
  the path to Signet.
- Wraps the returned injection in the same auto-injection header used by
  `SessionStart`.
- If the Signet payload contains a `<memory-feedback>` block, prepends a
  normalized `mcp_signet_memory_feedback` contract before the injected payload.
- Writes a debug mirror of the injected payload to
  `.agentic/generated/signet-live-context.md`.
- Appends a compact audit record to
  `.agentic/generated/signet-user-prompt-submit-audit.jsonl` and keeps only the
  last five entries.

**Failure behavior:**

- On failure, the hook still returns `{ "continue": true }`.
- The debug live-context file is updated with a failure snapshot, and the audit
  log records the error.

**Outcome:**

- Signet can refresh memory context on each prompt after the initial skip.
- Memory-feedback instructions are surfaced to the model when present.

### 3. PreCompact (`signet-pre-compaction.ps1`)

**Trigger:** VS Code is about to compact the conversation.

**Registration:** `.github/hooks/signet-pre-compaction.json`

**Important:** The active hook currently targets
`.agentic/hooks/signet-pre-compaction.ps1`.

**What the active script does:**

- Reads stdin JSON and resolves the active session key from the supported VS
  Code hook fields.
- Calls `POST http://127.0.0.1:3850/api/hooks/pre-compaction` with:
  - `harness = "vscode-custom-agent"`
  - `sessionKey` and `sessionId` when present
  - `sessionContext` when the hook payload provides one
  - `messageCount` when the hook payload provides one
- Relies on Signet's daemon-side continuity handling to create the
  pre-compaction checkpoint and any summary guidance.
- Returns a `PreCompact` response with `continue = true`.

**What it does not do:**

- It does not upload transcript deltas through the `session-end` path anymore.
- It does not maintain local transcript offsets as the compaction boundary.
- It does not persist a transcript-state checkpoint file as part of normal
  runtime behavior.

**Operational implication:**

- Pre-compaction is now a Signet continuity event, not a transcript extraction
  event.
- Compaction-time continuity comes from Signet's checkpointing model, while
  transcript retention stays attached to the live session key.

### 4. Stop (`signet-session-end.ps1`)

**Trigger:** The session ends.

**Registration:** `.github/hooks/signet-session-end.json`

**What the script does:**

- Loads helper functions from `.agentic/hooks/signet-transcript-state.ps1` for
  session identity resolution, transcript-path handling, VS Code transcript
  normalization, and legacy state cleanup.
- Resolves transcript input from `transcript_path` or `transcriptPath`.
- Calls `POST http://127.0.0.1:3850/api/hooks/session-end` with:
  - `harness = "vscode-custom-agent"`
  - `agentId`
  - `sessionKey` and `sessionId` when present
  - `cwd` when present
  - `reason` when present
  - `transcriptPath` when the VS Code hook payload provides one
  - fallback inline `transcript` from hook input when no path is available
- When the hook payload includes a VS Code JSONL transcript path, writes a
  normalized plain conversation transcript under `.agentic/generated/normalized-transcripts/`
  and forwards that compatibility file path to Signet.
- Clears any legacy local transcript-state file if Signet reports `queued =
true` or returns a non-negative `memoriesSaved` count.
- Always returns `{ "continue": true }`.

**Operational implication:**

- Shutdown now preserves Signet's full-session transcript lineage by handing the
  daemon the transcript file path instead of a locally sliced tail.
- Pre-compaction checkpoints and final transcript retention no longer compete
  for ownership of the session transcript.

## Files and Roles

| File                                           | Current role                                                                                                                                                                                   |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.github/hooks/signet-session-start.json`      | Registers the active `SessionStart` hook.                                                                                                                                                      |
| `.github/hooks/signet-user-prompt-submit.json` | Registers the active `UserPromptSubmit` hook.                                                                                                                                                  |
| `.github/hooks/signet-pre-compaction.json`     | Registers the active `PreCompact` hook.                                                                                                                                                        |
| `.github/hooks/signet-session-end.json`        | Registers the active `Stop` hook.                                                                                                                                                              |
| `.agentic/hooks/signet-session-start.ps1`      | Fetches initial context, writes debug mirrors, and creates the one-shot prompt-refresh skip marker.                                                                                            |
| `.agentic/hooks/signet-user-prompt-submit.ps1` | Refreshes live context per prompt after the initial skip, normalizes VS Code transcript JSONL when a transcript path is present, writes audits, and surfaces memory-feedback contracts.        |
| `.agentic/hooks/signet-pre-compaction.ps1`     | Active compaction hook that calls Signet's `pre-compaction` endpoint.                                                                                                                          |
| `.agentic/hooks/signet-session-end.ps1`        | Active shutdown hook that normalizes VS Code transcript JSONL when needed, hands the resulting transcript path to the daemon, and clears legacy local transcript-state when shutdown succeeds. |
| `.agentic/hooks/signet-transcript-state.ps1`   | Shared helper module for hook session identity, transcript-path parsing, VS Code transcript normalization, and cleanup of older transcript-state files.                                        |

## Signet Endpoints in Use

The current implementation now uses daemon HTTP endpoints consistently:

| Path                                 | Used by                         | Purpose                                                                         |
| ------------------------------------ | ------------------------------- | ------------------------------------------------------------------------------- |
| `POST /api/hooks/session-start`      | `signet-session-start.ps1`      | Initial context injection.                                                      |
| `POST /api/hooks/user-prompt-submit` | `signet-user-prompt-submit.ps1` | Per-prompt context refresh.                                                     |
| `POST /api/hooks/pre-compaction`     | `signet-pre-compaction.ps1`     | Compaction-time continuity checkpointing.                                       |
| `POST /api/hooks/session-end`        | `signet-session-end.ps1`        | Final transcript retention and session-end extraction through the local daemon. |

## Generated Artifacts

The scripts currently write these generated files under `.agentic/generated/`:

- `signet-session-start-context.md`
- `signet-live-context.md`
- `signet-last-user-prompt-input.json`
- `signet-user-prompt-submit-audit.jsonl`
- `live-context-injection-results.jsonl` when experiments are enabled
- `prompt-refresh-state/*.json`
- `normalized-transcripts/*.txt` when VS Code JSONL transcripts are normalized
  for Signet compatibility
- `transcript-state/*.json` only as legacy cleanup state from older hook runs

These files are for debugging, experiments, or local state. They are not the
authoritative live context channel.

## Error Handling

- `SessionStart` and `UserPromptSubmit` emit a short Signet status message on
  failure instead of breaking the hook.
- `PreCompact` always returns `continue = true` after attempting the daemon
  `pre-compaction` call.
- `Stop` runs with `SilentlyContinue` semantics and never blocks shutdown on
  Signet errors.

## Practical Summary

The current lifecycle is now consistent with Signet's current daemon contract.

- Context injection runs through `SessionStart` plus `UserPromptSubmit`.
- Prompt submit forwards transcript metadata when the VS Code hook payload
  exposes it, normalizing VS Code JSONL transcripts into a plain conversation
  compatibility file before daemon handoff when needed.
- Pre-compaction records continuity through Signet's dedicated checkpoint path.
- Stop performs the final session-end handoff using the full transcript path,
  or a generated normalized compatibility transcript when the source file is VS
  Code JSONL that Signet cannot parse directly.
