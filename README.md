# SignetAI_VSCode_Integration

This repository documents a working Signet integration for VS Code custom agents using a shared harness and a small set of PowerShell hooks.

The core idea is simple: let VS Code own the agent session lifecycle, and let thin hook adapters translate those lifecycle events into Signet daemon calls. Signet stays responsible for retrieval, memory, and synthesis. The VS Code side only passes session metadata, prompt text, and transcript references at the right moments.

## What I built

I wired a custom VS Code agent to a shared Signet harness named `vscode-custom-agent`.

The main runtime artifact is:

- `.github/agents/signet-codex-vscode.agent.md`

That agent delegates Signet integration to workspace hooks under `.github/hooks/`:

- `signet-session-start.ps1`
- `signet-user-prompt-submit.ps1`
- `signet-pre-compaction.ps1`
- `signet-session-end.ps1`
- `signet-transcript-state.ps1`

The hooks talk to a local Signet daemon at `http://127.0.0.1:3850`.

## Why the harness exists

VS Code custom agents give you lifecycle events, but they do not natively know how to hydrate a session with Signet memory or keep that memory fresh on every turn. The harness fills that gap.

I used a shared harness name instead of a per-agent harness so multiple VS Code agents can participate in the same Signet memory model if needed. The hook layer stays intentionally thin:

- VS Code emits lifecycle events.
- The PowerShell scripts normalize the event payloads.
- The scripts call the Signet daemon.
- Signet returns injected context or accepts session/transcript data.
- The chat continues even if Signet is unavailable.

That last point matters. Hook failures should degrade to diagnostics, not break the user turn.

## Runtime flow

### 1. Session start

When the agent session begins, `signet-session-start.ps1` does four things:

1. Reads the incoming hook payload from stdin.
2. Calls `POST /api/hooks/session-start` with the harness name, agent ID, project path, and any session identifiers VS Code provided.
3. Writes the returned Signet context to `.github/Generated/signet-session-start-context.md` for debug purposes and to see the context being auto-injected.
4. Returns `hookSpecificOutput.additionalContext` so VS Code can inject startup context directly into the first turn.

At the same time, it resets `.github/Generated/signet-live-context.md` to a placeholder message and creates a per-session prompt-refresh marker under `.github/Generated/prompt-refresh-state/`.

That marker is what prevents the first prompt from immediately overwriting the startup context.

### 2. User prompt submit

On each prompt, `signet-user-prompt-submit.ps1` reads the richest available prompt field from the hook payload, then calls `POST /api/hooks/user-prompt-submit`.

This hook is deliberately conservative:

- The first prompt refresh for a session is skipped.
- Starting with the second prompt, the freshest Signet context is written to `.github/Generated/signet-live-context.md`.
- The hook returns `{"continue": true}` instead of relying on prompt-submit context injection.

That fallback exists because session-start injection is reliable, while prompt-submit injection is not always guaranteed to become model-visible in the same way. Writing the refreshed memory to a generated file gives the agent a stable, debuggable surface to read from on later turns.

The agent-side rule is explicit: after the first prompt, the agent should always read `.github/Generated/signet-live-context.md` before answering and treat what it read as active session memory until the file is refreshed again.

For debugging, the raw normalized hook input is also written to `.github/Generated/signet-last-user-prompt-input.json`.

### 3. Pre-compaction

Before VS Code compacts a long conversation, `signet-pre-compaction.ps1` fires.

In the current implementation this hook is lightweight. It does not upload transcript content. Instead it:

1. Reads the session key and transcript path from the hook payload.
2. Calls `POST /api/hooks/pre-compaction` with session metadata and the transcript path.
3. Records local state in `.github/Generated/transcript-state/` so the Stop hook has per-session compaction history.

This keeps compaction soft and low-risk. If Signet is down, compaction still proceeds.

### 4. Stop

When the session ends, `signet-session-end.ps1` performs the final Signet reporting step.

It sends the harness, agent identity, session metadata, and transcript path to `POST /api/hooks/session-end`. If the transcript file is available, it also reads it, converts the NDJSON-style VS Code transcript into a simpler `User:` / `Assistant:` conversation format, and includes that converted transcript in the request body.

If Signet accepts the session-end request, the hook clears the local transcript state. If Signet fails, the hook swallows the failure so shutdown is never blocked.

## Generated artifacts

The integration relies on a few generated files under `.github/Generated/`:

- `signet-session-start-context.md`: the context returned at session start.
- `signet-live-context.md`: the rolling memory surface refreshed after the first prompt.
- `signet-last-user-prompt-input.json`: a debug capture of the last prompt-submit payload.
- `prompt-refresh-state/*.json`: per-session markers used to skip the first prompt refresh.
- `transcript-state/*.json`: per-session state used by compaction and stop handling.

These files make the integration easier to debug because you can inspect exactly what Signet last returned without reverse-engineering the hook exchange from logs alone.

## Smoke test

Use this smoke test to verify three separate behaviors:

1. `SessionStart` auto-injects startup context into the first turn.
2. `UserPromptSubmit` refreshes `.github/Generated/signet-live-context.md` starting on the second prompt.
3. The agent reads `.github/Generated/signet-live-context.md` before answering after the first prompt.

### Preconditions

- The Signet daemon is running on `http://127.0.0.1:3850`.
- You start a brand new chat session with the custom agent.
- You do not manually open either generated context file before the first prompt, or you will no longer be testing auto-injection behavior.

### Step 1: Confirm session-start auto injection

Start a fresh chat with the custom agent and use a first prompt like:

```text
Without opening any files, tell me the current date and time from Signet session-start context and whether live context is active yet.
```

Expected result:

- The agent answers with the Signet-provided date/time from the injected startup context.
- The agent indicates that live context is not active yet on the first prompt.
- `.github/Generated/signet-session-start-context.md` contains the startup context written by the hook.
- `.github/Generated/signet-live-context.md` still contains the placeholder written by `SessionStart`, because the first prompt refresh is intentionally skipped.

### Step 2: Confirm live-context refresh on the second prompt

Send a second prompt like:

```text
Before answering, use the live context for this turn and tell me the Signet recall query you see there.
```

Expected result:

- `.github/Generated/signet-live-context.md` is rewritten by `UserPromptSubmit` before the answer is produced.
- The file now contains a fresh `UserPromptSubmit` timestamp and a `[signet:recall ...]` block for the second prompt.
- `.github/Generated/signet-last-user-prompt-input.json` shows the second prompt payload and the active session identifier.

### Step 3: Confirm the agent actually read live context

The second prompt above is also the read check.

Expected result:

- The agent's answer references information that exists in `.github/Generated/signet-live-context.md` for that turn.
- A strong signal is that it can quote or paraphrase the recall query or one of the returned memory summaries without you manually pasting that file into chat.
- If the file updated but the answer ignores it, the hook refresh is working but the agent is not actually consuming live context.

### Failure triage

- If the first prompt lacks Signet startup details, `SessionStart` injection is failing.
- If the second prompt does not rewrite `.github/Generated/signet-live-context.md`, the prompt-refresh skip marker or session-key normalization is broken.
- If the live-context file updates but the answer does not reflect it, the runtime instructions are not being followed or the agent did not read the file before answering.

## Design choices

### Thin adapters, not smart hooks

The PowerShell scripts do not try to implement memory logic themselves. They normalize VS Code hook input, call the daemon, and write small local state files when needed. Retrieval and memory decisions stay inside Signet.

### Shared harness name

The harness name is fixed as `vscode-custom-agent` so Signet can attribute activity consistently even if more than one custom VS Code agent uses the same integration pattern.

### File-based live context fallback

Instead of assuming every hook can inject model-visible context directly, only SessionStart does direct injection. Later prompt refreshes update a generated markdown file. That gives a deterministic fallback path and a visible debugging artifact.

### Runtime tuning that made memory visible

The Signet runtime also needed budget tuning outside this repository.

The key change was that increasing the general memory budget alone was not enough. Live context generated by `UserPromptSubmit` is also constrained by hook-specific limits in the Signet runtime config.

The working configuration was:

- `memory.pipelineV2.guardrails.contextBudgetChars: 120000`
- `hooks.userPromptSubmit.maxInjectChars: 120000`
- `hooks.userPromptSubmit.recallLimit: 10`

What each setting does:

- `memory.pipelineV2.guardrails.contextBudgetChars` raises the overall memory-context ceiling available to Signet's pipeline.
- `hooks.userPromptSubmit.maxInjectChars` raises the maximum number of characters the `UserPromptSubmit` hook is allowed to inject into live context.
- `hooks.userPromptSubmit.recallLimit` caps recall output at 10 memories so the live-context surface stays bounded and predictable.

Without the hook-specific `maxInjectChars` increase, the live-context file could still truncate even if the general pipeline budget was much larger.

### Soft failure behavior

Every hook is written so Signet outages do not kill the chat session. Startup falls back to a short diagnostic, prompt refresh keeps the turn moving, pre-compaction is best-effort, and Stop never blocks shutdown.

## Repository layout

```text
.github/
  copilot-instructions.md
  agents/
    signet-codex-vscode.agent.md
  hooks/
    signet-session-start.ps1
    signet-user-prompt-submit.ps1
    signet-pre-compaction.ps1
    signet-session-end.ps1
    signet-transcript-state.ps1
  Generated/
    signet-session-start-context.md
    signet-live-context.md
    signet-last-user-prompt-input.json
  skills/
    vscode-signet-agent-harness/
```

## Practical notes

- This repo assumes a local Signet daemon is running on port `3850`.
- The hook scripts are written for PowerShell on Windows.
- The current behavior separates startup context from ongoing live-context refresh on purpose.
- `.github/copilot-instructions.md` tells the agent to read startup context on turn one and to explicitly read rolling live context on every later turn.
- The reference docs under `.github/skills/vscode-signet-agent-harness/` describe the intended harness pattern, but the PowerShell hooks are the source of truth for the exact runtime behavior in this repository.

## Summary

The integration works by treating VS Code as the lifecycle host and Signet as the memory engine. A custom agent triggers small PowerShell adapters at `SessionStart`, `UserPromptSubmit`, `PreCompact`, and `Stop`. Those adapters call the Signet daemon, write local generated context when direct hook injection is not the safest option, and preserve the chat flow even when Signet is unavailable.
