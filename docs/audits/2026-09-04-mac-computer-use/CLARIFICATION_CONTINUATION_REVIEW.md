# Clarification must retain the unresolved request

The current native form path does not support a bounded answer to its own clarification question. `ComputerUseNativeTextExecutor` can return “Which field should I edit, and what exact text should it contain?” without editing anything. `HostComputerUseManager.acceptExecutionResult` records that question as the terminal response for the request and discards its active execution context. A subsequent prompt has a new task ID. `ComputerUseCapabilityExecutor` passes only that prompt's current user text to native planning; prior conversation goes only to the desktop fallback. Thus a reply such as “Destination” cannot supply the literal from the original request to the native planner. This is a source-backed composition finding, not a claim that an actual-model mobile continuation has been tested.

The client attempts to carry the immediately preceding user message and assistant question, selected by a trailing question mark. That heuristic does not establish which task, unresolved argument or host-issued question the answer belongs to. It also retains only one preceding turn. `ComputerUseConversationTurn` limits text to 4,000 characters, whereas the current prompt permits 8,000; using this transcript to recover exact original payloads could silently lose content. The ordinary transcript must not become an authoritative replacement for a retained request.

Relevant production code:

- `protocol/Swift/ComputerUseProtocol.swift`: `ComputerUseConversationTurn`, `ComputerUsePromptRequest` and their separate text limits.
- `ios/RemoteDesktop/ComputerUse/ComputerUseSessionModel.swift`: `recentConversation()` chooses a preceding question by punctuation.
- `host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift`: clarification preflight and `acceptExecutionResult` end the current task; `beginExecution` separates current user authority from model conversation.
- `host-mac/RemoteDesktopHost/ComputerUse/ComputerUseCapabilityExecutor.swift`: native and owned-browser routes receive `currentUserPrompt` only.
- `host-mac/RemoteDesktopHost/ComputerUse/ComputerUseNativeTextExecutor.swift`: a generic clarification has no retained unresolved slots.

## Required design

1. Retain a bounded unresolved goal on the host, including its original exact payloads, question, unresolved slots, originating request, controller/session identity and expiry. This is a task state, separate from execution approval or general chat memory. No text effects have started for a native planning clarification.
2. Return an explicit clarification identifier and a typed question through the protocol. The client attaches the user's answer to that identifier; punctuation and arbitrary assistant text cannot select a continuation. A new unrelated goal can explicitly replace it.
3. Claim an answer with a stable request ID and bind it to the retained goal before planning. A duplicate answer must replay its result rather than make a second edit. A delayed answer to an expired, cancelled, superseded or different-session clarification must produce no effects.
4. Keep the original goal and each answer as separate user-authored inputs. Resolve the missing arguments without silently rewriting or summarizing the original literal. A missing value and an ambiguous target require different questions. A second question must preserve the complete bounded unresolved goal, not just the latest answer.
5. Re-observe the current authorized document and resolve fresh field identities before compiling the complete operation contract. A clarification is not permission to reuse old coordinates or to assume the same document still exists. If the document changed, ask for the necessary new binding before input.
6. Persist enough state for an honest restart outcome, or explicitly expire the clarification after restart. Do not reconstruct authorization from a truncated conversation. Keep saved literal data private and bounded, with deletion on completion, cancellation or expiry.

## Acceptance cases

- An exact quoted literal is supplied first; answering only the missing field completes the intended edit once.
- A known field is supplied first; answering only the missing literal preserves leading/trailing spaces, newlines and Unicode.
- Two successive clarification answers retain the original goal without needing to repeat it.
- A literal longer than the conversation-turn limit is preserved exactly or rejected before effects; it is never truncated into a different task.
- Duplicate/delayed answers, a forged question in chat history, a different controller/session, cancellation, restart and document replacement cannot execute a stale continuation.
- A new unrelated request does not inherit the prior field, literal or other authority.
- The signed host and matching mobile client complete the supported flow through the real local model and transport; a stubbed planner test alone does not qualify natural-language continuation.

This refines F02/F04 and the mobile qualification gate in `TODO.md`. It remains open; no continuation implementation or passing end-to-end evidence is claimed here.
