# How To Build A VS Code Signet Agent Harness

## Goal

Build a VS Code custom agent integration that refreshes Signet memory reliably
without letting hook failures break the chat turn.

## Default Pattern

Use a shared harness name, keep the hook scripts as thin adapters, and prefer a
generated live-context fallback for prompt-time refresh unless VS Code proves it
will append prompt-submit output directly into model context.

The current repo implementation already follows that pattern:

- A workspace-scoped `SessionStart` hook writes a dedicated startup-context file and returns
  `hookSpecificOutput.additionalContext`.
- A workspace-scoped `PreCompact` hook uploads the transcript segment accumulated since the previous
  extraction point and advances the local offset only after Signet accepts it.
- A workspace-scoped `PreCompact` hook uploads the transcript segment accumulated since the previous
  extraction point and advances the local offset only after Signet accepts it.
- A workspace-scoped `UserPromptSubmit` hook skips the first prompt for each session, then refreshes the
  generated live-context file from the second prompt onward.
- A workspace-scoped `Stop` hook uploads only the transcript tail that was not
  already handed to Signet during pre-compaction.
- A workspace-scoped `Stop` hook uploads only the transcript tail that was not
  already handed to Signet during pre-compaction.
- Workspace instructions use session-start context first, then begin reading the
  generated live-context file on the second prompt.

## Step-By-Step

### 1. Pick the harness contract

- Choose the shared harness name.
- Choose how agent identity is passed into hooks.
- Decide whether multiple custom agents should share memory through one harness.

Recommended default:

- Harness name: `vscode-custom-agent`
- Agent identity: explicit `AgentId` parameter in each hook command
- Project identity: current working directory

### 2. Create or update the custom agent file

The workspace hook files should:

- Register shared `SessionStart`, `UserPromptSubmit`, `PreCompact`, and `Stop`
  hooks so Signet lifecycle behavior runs for any active agent session in the
  workspace.

The workspace instructions should:

- Tell all agents when to ignore or consume the generated live-context files.

See:

- [.github/copilot-instructions.md](../../../../.github/copilot-instructions.md)
- [.agentic/agents/signet-codex-vscode.agent.md](../../../agents/signet-codex-vscode.agent.md)

### 3. Implement the session-start hook

The `SessionStart` hook should:

- Read stdin metadata when present.
- Call Signet daemon `session-start` with harness, agent ID, and project path.
- Fallback to a short diagnostic if no context is returned.
- Write the same content to a dedicated generated startup-context file.
- Reset the generated live-context file to a placeholder that stays inactive
  until the second prompt.
- Return VS Code-compatible JSON with
  `hookSpecificOutput.additionalContext`.

See:

- [.github/hooks/signet-session-start.json](../../../../.github/hooks/signet-session-start.json)
- [.agentic/hooks/signet-session-start.ps1](../../../hooks/signet-session-start.ps1)

### 4. Implement prompt-submit refresh

The `UserPromptSubmit` hook should:

- Skip the first prompt-submit refresh for a session.
- Read the incoming prompt from the best available stdin field.
- Forward prompt text plus session metadata to Signet.
- Treat Signet output as the freshest memory surface.
- Rewrite the generated live-context file starting with the second prompt.
- Preserve the turn even if the daemon call fails.

In this repo the hook returns `{"continue": true}` and relies on the generated
file instead of assuming prompt-submit `additionalContext` is honored.

That is the safer default for VS Code until prompt-submit injection is proven.

See:

- [.github/hooks/signet-user-prompt-submit.json](../../../../.github/hooks/signet-user-prompt-submit.json)
- [.agentic/hooks/signet-user-prompt-submit.ps1](../../../hooks/signet-user-prompt-submit.ps1)

### 5. Implement pre-compaction transcript extraction

### 5. Implement pre-compaction transcript extraction

The `PreCompact` hook should:

- Read `transcript_path` and session metadata from VS Code hook input.
- Read only the transcript segment that has not already been handed to Signet.
- Send that segment to Signet's session-extraction endpoint with a synthetic
  extraction session key so the live Signet session is not terminated early.
- Advance the stored transcript offset only after Signet accepts the upload.
- Read only the transcript segment that has not already been handed to Signet.
- Send that segment to Signet's session-extraction endpoint with a synthetic
  extraction session key so the live Signet session is not terminated early.
- Advance the stored transcript offset only after Signet accepts the upload.

See:

- [.github/hooks/signet-pre-compaction.json](../../../../.github/hooks/signet-pre-compaction.json)
- [.agentic/hooks/signet-pre-compaction.ps1](../../../hooks/signet-pre-compaction.ps1)
- [.agentic/hooks/signet-transcript-state.ps1](../../../hooks/signet-transcript-state.ps1)

### 6. Implement session-end reporting

The `Stop` hook should:

- Forward harness and session metadata to Signet.
- Upload only the transcript tail that remains after the last successful
  pre-compaction extraction.
- Clear the local transcript-offset state only after Signet accepts the final
  upload.
- Upload only the transcript tail that remains after the last successful
  pre-compaction extraction.
- Clear the local transcript-offset state only after Signet accepts the final
  upload.
- Swallow failures unless they expose a deterministic configuration issue worth
  surfacing separately.

This repo wires all Signet lifecycle hooks as workspace hooks so session-start,
prompt refresh, transcript extraction, and session-end extraction can run for
prompt refresh, transcript extraction, and session-end extraction can run for
all VS Code agent sessions.

See:

- [.github/hooks/signet-session-end.json](../../../../.github/hooks/signet-session-end.json)
- [.agentic/hooks/signet-session-end.ps1](../../../hooks/signet-session-end.ps1)
- [.agentic/hooks/signet-transcript-state.ps1](../../../hooks/signet-transcript-state.ps1)

### 7. Create generated artifact expectations

If prompt refresh uses a file fallback, standardize the generated artifacts:

- Live context markdown file
- Optional debug input capture for prompt-hook payload inspection
- Transcript-offset state files for pre-compaction and final tail uploads
- Transcript-offset state files for pre-compaction and final tail uploads

Document whether those files should be committed, ignored, or treated as
diagnostic outputs.

### 8. Validate the harness end to end

Validation checklist:

1. Confirm `SessionStart` returns `hookSpecificOutput.additionalContext` and
   that VS Code accepts it.
2. Confirm session start leaves the live-context file in an inactive
   placeholder state.
3. Confirm `PreCompact` uploads only the transcript segment accumulated since
   the previous extraction point.
4. Confirm `PreCompact` advances transcript state only after a successful
   upload.
5. Confirm the first `UserPromptSubmit` leaves the live-context file unchanged.
6. Confirm the second `UserPromptSubmit` updates the live-context file.
7. Confirm `Stop` uploads only the remaining transcript tail and clears local
   transcript state after success.
8. Confirm the custom agent starts reading generated live context on the second
   prompt rather than at session start.
9. Confirm Signet dashboard attribution uses the intended harness name.
10. Confirm hook failures degrade to short diagnostics without aborting the turn.

## Branching Logic

### If direct prompt-submit injection works

- Return `hookSpecificOutput.additionalContext` from `UserPromptSubmit`.
- The generated-file fallback may become optional.
- Keep the file fallback available if you still want a debuggable local surface.

### If direct prompt-submit injection does not work

- Keep `UserPromptSubmit` as a refresh-only adapter.
- Skip the first prompt refresh for the session.
- Rewrite the generated live-context file from the second prompt onward.
- Instruct the custom agent body to begin loading the generated file on the
  second prompt.

This repo currently follows this branch.

### If pre-compaction must preserve the live Signet session

- Do not call Signet `session-end` with the live session key during
  pre-compaction.
- Upload the transcript segment under a synthetic extraction session key.
- Keep a local offset so `Stop` can upload only the post-compaction tail.
- Do not call Signet `session-end` with the live session key during
  pre-compaction.
- Upload the transcript segment under a synthetic extraction session key.
- Keep a local offset so `Stop` can upload only the post-compaction tail.

### If an old agent file name is misleading

- Keep the existing filename if downstream references are brittle.
- Rename the file if clarity and discoverability are more valuable than
  preserving legacy references.

## Quality Bar

- The hook scripts stay adapter-thin and deterministic.
- Harness naming is explicit and consistent.
- Agent identity is passed deliberately rather than inferred implicitly.
- Signet failures are supportive diagnostics, not hard blockers.
- Startup and per-prompt refresh use separate generated files so the prompt hook
  cannot overwrite session-start diagnostics.
- The harness is debuggable from the agent file, hook scripts, and one design
  note without hidden coupling.
- The harness is debuggable from the agent file, hook scripts, and one design
  note without hidden coupling.

## Current Repo Gaps To Revisit

- Whether [.agentic/agents/signet-codex-vscode.agent.md](../../../agents/signet-codex-vscode.agent.md) should be renamed to reflect the shared `vscode-custom-agent` harness more clearly.
- Whether generated live-context and debug payload files need explicit ignore or
  hygiene documentation.
- Whether this workflow should also be exposed through a prompt or instruction
  file for faster reuse.
- Whether [.agentic/agents/signet-codex-vscode.agent.md](../../../agents/signet-codex-vscode.agent.md) should be renamed to reflect the shared `vscode-custom-agent` harness more clearly.
- Whether generated live-context and debug payload files need explicit ignore or
  hygiene documentation.
- Whether this workflow should also be exposed through a prompt or instruction
  file for faster reuse.
