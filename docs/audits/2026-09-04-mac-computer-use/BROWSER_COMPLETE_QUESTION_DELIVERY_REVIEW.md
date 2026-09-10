# Complete clarification delivery

Source repair; execution pending. This follows the [native source-reference change](BROWSER_GOAL_SOURCE_REFERENCE_REVIEW.md). No build, typecheck, assertion, app, browser, model, TLS connection, login or SSH execution occurred.

## First-principles findings

A person must receive the scope they are being asked to answer. Keeping the exact source on the host does not establish that the phone received it. The former clarification ledger allowed 8,000 characters, and the shared task-update constructor shortened every response to 8,000 characters. A source of that length could not fit with its fixed question, delimiters, context and clock labels. The browser question renderer correctly refused to shorten selected source, but then could not issue the question. Source references made longer native clauses representable and exposed this independent handoff limit.

Limits also differed between delivery layers. Local RPC allowed 256 KiB message bodies, while the host mailbox allowed only 96 KiB. Rendering control characters as visible symbols can expand a near-32-KiB source beyond that mailbox bound. The broker then selected up to 32 messages without accounting for the 512 KiB encoded frame limit. Several individually valid questions could make every poll fail. Counting messages or raw text bytes is insufficient when JSON adds escaping and routing metadata.

## Repairs

The [shared protocol](../../../protocol/Swift/ComputerUseProtocol.swift) now defines clarification-text bounds of 65,536 characters and 128 KiB UTF-8, leaving room for native source, visible escaping and context. The [task ledger](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTaskLedger.swift) and existing question renderer use those same limits. The native input remains bounded at 32 KiB total, with the existing answer, turn, requirement and scope limits. This does not increase model context or generation budgets.

A task update with a matching clarification reference and intervention outcome retains the complete question. Encoding and decoding reject empty, blank or over-limit questions; they never attach the original reference to silently shortened text. Ordinary update construction keeps its 8,000-character cap, and ordinary ledger terminals keep their 4,000-character cap. No new wire fields are introduced. Older shared decoders read text directly, but cross-version runtime behavior still needs qualification.

The [local mailbox](../../../host-mac/RemoteDesktopHost/ComputerUse/LocalHostComputerUseChannel.swift) allows outbound bodies up to the existing 256 KiB RPC body bound while retaining its 96 KiB inbound bound. Before adding a message, it encodes a single-message response with maximum escaped request/acknowledgement metadata. A body that cannot fit a response frame is rejected before queue mutation. Text admission alone does not guarantee transport admission: this check covers JSON expansion and preserves the transport's independent limits. Queue counts and expiry remain bounded as before.

The [broker](../../../host-mac/RemoteDesktopHost/ComputerUse/LocalComputerUseBrokerServer.swift) selects an ordered prefix using the actual encoded response size, including accepted-envelope IDs. It stops before a candidate exceeds the frame cap. Polling neither acknowledges the selected prefix nor removes the unsent suffix; the authenticated acknowledgement path still controls removal. A first message that cannot fit produces an error rather than an apparently successful empty poll. Other validation failures are not mistaken for a size boundary.

These changes preserve question and answer ownership. They do not establish model interpretation, correct website behavior, account authentication or task completion.

## Authored verification, unrun

Six new methods specify:

- Large [native questions](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift), including eight repeated scopes near the full retained-source byte bound, visible control characters and Unicode. Complete text/reference pairs must survive ledger reopening and local RPC encoding, and an accepted answer must retain the original source and clock.
- Shared question character and UTF-8 boundaries, rejection on both encode and decode, and unchanged ordinary-response handling. Existing ledger overflow cases now use the shared limits.
- A [host-manager continuation](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift) for an 8,000-character phone request, whose rendered question exceeds 8,000 characters. The answer must continue the same owner and retain its original source. The [goal fixture](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchTaskTests.swift) has an explicit reference-response option; its default behavior is unchanged.
- [Local mailbox/broker delivery](../../../host-mac/RemoteDesktopHostTests/LocalComputerUseTransportTests.swift) for twelve questions exceeding the former 96 KiB body bound. Multiple bounded frames must preserve order, exact text, references and acknowledgements. A separate case requires an unencodable single message to be rejected without poisoning the queue. These methods use the in-memory channel and codec, not a TLS listener.
- The [phone composer](../../../ios/RemoteDesktopTests/ComputerUseClarificationClientTests.swift) receiving a long Unicode question and sending an exact answer with its original reference, without reconstructing a conversation from displayed text.

Nine changed Swift files pass parse-only checks. Source inventories select 1846 default host / 1163 focused host / 10 focused client methods: five host additions and one client addition, with no removals. No assertions, native question rendering, ledger replay, codec round trips, mailbox operations or UI flows have executed.

## Remaining checks

1. When authorized, typecheck and run the six authored methods plus existing clarification, action-evidence, local-transport and client lifecycle regressions. Exercise exact limits and Unicode on the supported macOS/iOS versions.
2. Verify complete questions on the actual phone, including scrolling, accessibility, expiry, cancellation and the transition to an answer. Plain text must remain readable and distinguish repeated source occurrences. No screenshot or UI qualification was performed here.
3. Qualify actual local TLS and CloudKit delivery, disconnect/replay, mixed small and large queues, simultaneous status traffic, action-evidence attachments and version combinations. Only local frame assembly is repaired here; CloudKit delivery has not been measured.
4. Measure encoding, queue residency and ledger size within the later 8 GB/resource qualification. Increased outbound capacity is still finite; bounded sizes and source checks do not prove acceptable sustained memory or CPU use.
5. Retain the independent model-token and semantic gates. A maximum-length phone request in a controlled fixture does not prove the local model can interpret it. Real travel, concert, movie and login scenarios still require later explicit permission.

The broader repair goal, navigation-source completion qualification, durable process recovery and real-model correctness remain open.
