# Show what a browser clarification is asking about

Source checkpoint: 2026-09-09. Parent: `9e5e790`. Source repair and prepared coverage only; builds, typechecking, assertions, inference and browser execution remain paused.

## First-principles finding

A person's answer can be meaningful only if they can identify the question's subject. The [clarification owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalClarification.swift) already bound a question to exact requirement occurrences and retained the complete prior interpretation. Its displayed text nevertheless contained only the generic topic question. “Which date?” could refer to either the outbound or return date; even displaying the selected word “tomorrow” would not distinguish identical occurrences.

The [durable ledger](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTaskLedger.swift) also clipped every terminal response at 4,000 characters. A complete scoped question could be shortened while its opaque answer reference still selected the full question. Presentation and replay therefore needed a shared completeness condition before accepting an answer.

## Source changes

Each question now includes the fixed host topic, the entire selected clause inside host-owned brackets, and up to 64 Unicode scalars of adjacent context on either side. Context retains whole characters and uses ellipses when shortened. A label identifies the original request or numbered answer. Adjacent context disambiguates an occurrence; it does not enlarge the sealed answer scope. The renderer verifies exact source bytes and UTF-8 boundaries before constructing the text.

Control characters and bidirectional formatting controls receive visible display representations. User-supplied scope brackets are replaced in the display so that only the host inserts the actual scope markers. Ordinary Unicode text, combining marks and emoji remain supported. The original user turns, exact selected source and answer bytes are unchanged. Structured model context continues to carry the fixed topic and exact source scope separately; the rendered host text is not inserted as a user instruction.

The immutable question identity advances to version 3 and includes its actual display text. Construction checks the 8,000-character outgoing update limit and a 32 KiB byte limit before installing a pending question. Existing clause, scope-count and input bounds remain in force. This adds no model call, browser observation or native input.

Durable completion preserves a matching retained clarification in full only when its response is nonblank and fits both bounds. Invalid text fails before the record changes, allowing a later valid completion. An already committed terminal result still wins before these checks, including a prior Stop. Replies without a retained matching clarification keep their existing 4,000-character bound. The [wire update](../../../protocol/Swift/ComputerUseProtocol.swift) format is unchanged. Durable replay preserves presentation and reference; it does not recreate a retired in-memory research owner after restart.

## Prepared coverage and permitted checks

Three new [clarification methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) cover repeated outbound/return date occurrences, display escaping with exact source/answer preservation, and a complete question longer than 4,000 characters through ledger reload and wire serialization. The latter also prepares boundary-rejection, first-terminal precedence and ordinary-reply clipping checks. Existing [transport](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserClarificationTransportTests.swift) and [manager](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift) expectations now require the scoped question through answer and Pause/Resume continuation.

Existing planner and source-prohibition expectations also require the complete scoped presentation. All seven changed Swift files pass parse-only syntax checks. Default and browser-control source inventories select 1639 / 956 methods, with exactly three additions and no removed or renamed identifiers. These checks establish syntax and source inventory consistency only. No assertions, compilation, model runs, app launches, computer-use activity or real-site workflows executed.

## Remaining work

The model still chooses an interpretation and question topic; exact presentation does not establish their semantic correctness. Explicit replacement of earlier intent, corrections to prior classifications, conflicting answers, parent-form/document recovery through login and client UI usability remain open. Whole-route source qualification retains its existing completion gate. Follow the [repair checklist](../../../TODO.md); travel, concert and movie scenarios await explicit execution permission, and resource qualification still follows correctness work.
