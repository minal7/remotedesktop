# Question-specific answer admission

Source repair; execution pending. This follows the [complete-question delivery repair](BROWSER_COMPLETE_QUESTION_DELIVERY_REVIEW.md). No build, typecheck, assertion, app, browser, model, login or SSH execution occurred.

## First-principles findings

Input rules must agree where the user composes an answer and where the host admits it. The phone's generic answer bound was 8,000 characters / 32 KiB. Browser retention allows only 8 KiB per answer, or less when the complete retained conversation approaches 32 KiB. The phone could therefore accept a draft that the browser owner necessarily rejected. Browser answers must also be nonblank; literal text-editing questions can legitimately accept whitespace alone.

Native answer admission already preserves a question when an answer cannot be appended. However, the [host manager](../../../host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift) converts a failed continuation into a generic terminal response telling the user to start a new request. The phone then lacks an explicit way to restore that question. This change prevents known-invalid drafts from being transmitted by a current client. It does **not** repair recovery after transmission; that is the next recorded lifecycle repair.

## Implemented behavior

The [shared protocol](../../../protocol/Swift/ComputerUseProtocol.swift) adds optional `clarificationAnswerPolicy` metadata to a task update, containing a positive bounded UTF-8 allowance and a nonblank requirement. It is valid only alongside a matching clarification reference. Encoding and decoding reject unscoped or malformed policies. Existing global prompt/answer bounds still apply.

The [browser clarification transport](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserClarificationTransport.swift) derives this metadata from the exact live native question and `nextAnswerByteLimit`. It requires the retained owner, input revision, question, controller, session, execution identity and expiry to remain valid. Foreign, consumed, retired or expired references cannot supply a policy. The manager includes the policy when sending that question, including a replay while its native owner is still live.

The policy does not change the opaque reference or appear in an answer's reference. Existing reference identity checks and native input admission remain authoritative. Older clients can ignore the new field without changing their reference encoding, but they will not gain the new pre-send checks. The metadata is derived from a live owner rather than separately persisted in the ledger; process recovery of an absent browser owner remains open.

The [phone session model](../../../ios/RemoteDesktop/ComputerUse/ComputerUseSessionModel.swift) applies the policy only in the scoped answer composer. UTF-8 overflow and disallowed blank input return a validation message before persistence, transmission, a new user bubble or consumption of the question. Validation never trims or normalizes the submitted answer. A new question installs its own policy; new-request, expiry and composer reset clear the prior policy. Questions without metadata retain the existing generic behavior, including exact whitespace answers for text editing.

Source inspection of the [composer view](../../../ios/RemoteDesktop/ComputerUse/ComputerUseView.swift) confirms that it uses this validation to enable Send and clears the draft only after `sendPrompt` succeeds. This is source evidence, not a rendered UI check.

## Authored verification, unrun

Four new methods are registered:

- Two [host transport methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserClarificationTransportTests.swift) specify the normal 8 KiB allowance and a seven-byte remaining allowance, exact Unicode boundaries, nonblank behavior, rejection without native input mutation, disappearance of policy after consumption, foreign references/controllers, bounded wire decoding and unchanged reference fields.
- Two [phone methods](../../../ios/RemoteDesktopTests/ComputerUseClarificationClientTests.swift) specify invalid drafts preserving the question and sending no new message, a valid exact-byte answer, independent rules on the following question, clearing on a new request and compatibility when a subsequent question omits policy metadata.

The existing [maximum-length host question fixture](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift) now also checks that its task update carries the native browser policy. All fixtures remain unrun.

Seven changed Swift files pass parse-only checks. Active source inventories select 1848 default host / 1165 focused host / 12 focused client methods, with two host and two client additions and no removals. These checks do not establish type correctness, actual native/controller execution, model fit or website competence.

## Remaining repair sequence

1. Repair **post-transmission rejection recovery**. Keep the rejected answer attempt distinct from an accepted source turn. Correlate an explicit recovery reply with the phone's submitted answer and the still-live original question. Preserve the original root, accepted history, scope, nonce and expiry; reject foreign, expired, consumed or retired questions. Define duplicate/durable replay, cancellation and capability/version behavior before adding a new retry wire contract. The current generic failure path is still insufficient.
2. Qualify policy delivery and composer behavior on the supported macOS/iOS versions, including multi-byte text, combining marks, changing question limits, expiry while editing, reconnect and valid transport retries. Verify that the displayed draft remains intact.
3. Keep native validation independent of the hint. A missing or modified client hint must never increase native capacity or authorize a continuation. Older clients still need the post-transmission recovery or an explicit fallback path.
4. Retain the larger semantic, model-token, durable recovery, navigation-source and 8 GB qualification work. Real travel, concert, movie and account-login scenarios still require later explicit permission.
