---
name: vscode-signet-agent-harness
description: "Build or audit a VS Code custom agent harness for Signet AI. Use when creating shared harness wiring, custom agent hook adapters, session-start injection, per-prompt memory refresh, session-end reporting, or generated live-context fallbacks for VS Code custom agents."
argument-hint: "Describe the agent, harness variant, or audit target."
---

# VS Code Signet Agent Harness

Build a deterministic Signet integration layer for VS Code custom agents.

This skill packages the workflow already exercised in this repository:

- A shared Signet harness name for all VS Code custom agents.
- Thin PowerShell hook adapters for `SessionStart`, `UserPromptSubmit`, and `Stop`.
- A generated live-context file fallback for prompt-time refresh when VS Code hook
  output is not injected directly into model context.
- A final adjacent-artifact audit so the harness is not shipped with only part of
  the required wiring.

## When To Use

- Create a new VS Code custom agent that should participate in Signet memory.
- Convert an existing Codex-shaped or single-agent harness into a shared VS Code
  harness.
- Audit hook, agent, and generated-context wiring after Signet or VS Code
  behavior changes.
- Document or standardize how a repo should integrate Signet with VS Code custom
  agents.

## Outputs

- A custom agent definition wired to Signet lifecycle hooks.
- Hook scripts that translate VS Code events into Signet daemon API calls.
- A validation checklist for soft-failure behavior and dashboard attribution.
- An adjacent-artifact audit covering related prompts, hooks, agents, generated
  files, and repo docs.

## Procedure

1. Confirm the harness shape.
   - Decide whether multiple VS Code custom agents should share one Signet
     harness.
   - Default to a shared harness name when the goal is common memory behavior
     across several custom agents.

2. Define the artifact set up front.
   - Agent definition file.
   - `SessionStart`, `UserPromptSubmit`, and `Stop` hook scripts.
   - Generated live-context file path, if prompt-submit injection needs a
     fallback.
   - A design note or spec if the harness is new or materially changing.

3. Keep the adapter layer thin.
   - Pass the shared harness name, current project path, and explicit agent ID.
   - Read stdin hook metadata when available.
   - Return VS Code-compatible JSON for hook events that support contextual
     output.
   - Keep ranking, retrieval, and synthesis logic inside Signet rather than in
     the hook script.

4. Handle prompt refresh deliberately.
   - First prefer direct `additionalContext` injection where the VS Code hook
     contract supports it.
   - If prompt-submit output is not actually appended to model context, write
     the fresh Signet output to a generated markdown file and instruct the agent
     to load that file on every turn.

5. Make failures soft.
   - No Signet response: inject or write a short diagnostic.
   - Hook call failure: preserve the chat turn and return a concise failure
     message.
   - Session end failure: never block shutdown.

6. Wire the agent explicitly.
   - Reference Windows-native PowerShell scripts directly from the custom agent
     frontmatter.
   - Pass an explicit `AgentId` value from the agent file.
   - If using the generated-file fallback, instruct the agent body to load the
     live-context markdown file on every turn.

7. Validate behavior.
   - Verify `SessionStart` injects context or a clear diagnostic.
   - Verify `UserPromptSubmit` refreshes Signet state on each prompt.
   - Verify Signet dashboard attribution uses the intended harness name.
   - Verify Signet failures do not break the chat turn.

8. Run an adjacent-artifact audit.
   - Check whether the harness also needs a supporting prompt, instruction file,
     or reference doc.
   - Check whether generated artifacts should be ignored, documented, or linked
     from the agent body.
   - Check whether the design spec still matches the actual wiring.

## Decision Points

- Shared harness or per-agent harness:
  Choose shared when memory should flow across several VS Code custom agents.
  Choose per-agent only when isolation is a product requirement.
- Direct prompt injection or generated-file fallback:
  Choose direct injection only if VS Code proves that prompt-submit output is
  added to model context. Otherwise prefer the generated-file fallback.
- Rename an existing agent file or keep it:
  Keep the current file when preserving external references matters more than
  naming accuracy. Rename it when discoverability and explicitness matter more.

## Completion Checks

- The agent file, all three hooks, and the live-context strategy agree on the
  same harness name and agent ID contract.
- The agent can still operate when Signet is unavailable.
- The repo contains enough documentation to debug the harness without reverse
  engineering the whole integration.
- Any related prompt, instruction, or hook gaps have been called out in the
  adjacent-artifact audit.

## References

- [Harness index](./references/index.md)
- [Build how-to](./references/how-to.md)