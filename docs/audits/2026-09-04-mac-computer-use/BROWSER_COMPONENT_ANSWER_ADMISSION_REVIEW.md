# Keep a component question open after an unsupported answer

Source repair; execution pending. This follows the [party component correction](BROWSER_PARTY_COMPONENT_CORRECTION_REVIEW.md) and [rejected-answer recovery](BROWSER_REJECTED_ANSWER_RECOVERY_REVIEW.md) work. No build, typecheck, test/assertion run, browser/app launch, inference, real-site task or SSH connection ran for this repair.

## First-principles finding

An answer is not accepted merely because it contains text and fits in memory. A category-specific correction promises to change one count while retaining the other. Before consuming its question, native code must establish that the entire reply expresses the supported change.

Previously, `replaceChildren` could accept `3 adults and 2 children` into the retained conversation. Scalar compilation then refused that shape, leaving an uncompiled correction after its question had been consumed. A later whole-party replacement could not reliably repair the history. Treating the extra text as disposable would also risk erasing a newly expressed requirement, such as a changed budget.

The repair rejects unsupported component answers before appending a turn. The exact root, accepted history, question text, reference, interpretation and question deadline remain available. A corrected answer uses the original reference with a new attempt ID. Rejection does not refill the active-work allowance or reset the root date context.

## Native and phone changes

The [shared answer policy](../../../protocol/Swift/ComputerUseProtocol.swift) now has optional `adultCount` and `childCount` formats. One bounded parser consumes the complete answer for both admission and [scalar compilation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift). It accepts numeric counts from 0 through 999 and English words zero through ten, with the matching adult/child category, existing optional `and`/`exactly` framing and one trailing punctuation mark. It does not discard unmatched prefixes, suffixes, comparators or additional instructions. Original answer bytes remain the source; parsing does not rewrite the conversation.

The [native question](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalClarification.swift) derives its format from its own topic. Direct native consumption checks it before constructing or appending an answer turn. The [transport bridge](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserClarificationTransport.swift) uses that same question to derive the complete live policy. A rejected answer does not call the research owner's continuation path.

The [phone composer](../../../ios/RemoteDesktop/ComputerUse/ComputerUseSessionModel.swift) presents a category-specific correction message and keeps the question and draft. Its existing secure question persistence retains the optional format, exact draft and original deadline. A fresh recovery probe derives the format from the current native owner; cached metadata alone cannot recreate that owner.

## Compatibility and replay

`formatMismatch` is a new typed rejection. Older clients that support only blank/length retry cannot decode a new rejection enum case, so the answer request must explicitly opt into `supportsClarificationFormatRetry` as well as existing retry support. The new capability is answer-only and defaults to false; it and absent format metadata are omitted from existing wire bodies. Current phones send the capability only after receiving a recognized formatted policy with retry support. Older hosts never advertise that format, so they do not receive the new request field through the normal composer flow.

The host sends format recovery only to a negotiated answer. Older or unnegotiated attempts retain the generic inability response while leaving the native question unconsumed. Blank/length recovery remains governed by the existing capability. A format-mismatch retry without a format is invalid.

Before retry delivery or replay, the bridge verifies actual native ownership, the exact submitted answer/reference and its negotiated capabilities. It compares the entire returned policy against the current native question, including category, byte limit and nonblank/retry rules. A different category cannot be substituted even when the submitted text would fail both categories. The phone also verifies its submitted body, reason, scope and original deadline before restoring a retry. Durable attempt identity and the existing execution-admission fence remain intact.

## Prepared verification

Five new methods are authored and unrun, with two existing native methods extended:

- The [transport tests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserClarificationTransportTests.swift) cover complete-answer grammar, count bounds, zero spelling, wrong categories, extra instructions, capability omission and invalid capability combinations; they also cover native owner/history retention, full-policy replay validation and a corrected answer without another planner call.
- The [manager test](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift) covers no retry support, older basic retry and current format retry, including a durable replay and subsequent acceptance under the original question.
- The [phone tests](../../../ios/RemoteDesktopTests/ComputerUseClarificationClientTests.swift) cover local rejection with an exact persisted Unicode draft, correction under the same deadline, a controlled stale hint reaching host rejection, separate capability negotiation and duplicate replies after correction.
- The [native clarification tests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) now require invalid answers to throw while leaving the exact question/input unchanged, then accept a correction. Existing repartitioning and retained-party checks also cover `zero children`.

Eleven Swift files pass parse-only checks. Source inventories select **1873 default host / 1190 focused host / 32 client core** methods. The [focused admission inventory](browser-component-answer-admission-inventory.json) selects five host methods, including the two extended native methods. Registration and syntax checks do not establish type correctness, passing assertions, native browser behavior or model competence. Local documentation checks cover 209 Markdown files and 1,700 local targets with no broken targets. Whitespace checks are clean; the effective hook directory contains no executable non-sample hooks.

## Remaining repair sequence

1. Keep execution deferred. When authorized, compile and run the selected host/client cases and their actual serialized composition. Qualify persistence, queued delivery, reconnect and supported app-version combinations.
2. Extend bounded conversational corrections and other question types without silently dropping unsupported clauses. The subsequent [whole-party admission repair](BROWSER_PARTY_ANSWER_ADMISSION_REVIEW.md) extends this boundary to both party counts. Generic quantity, date, budget, location and source-policy answers still need a systematic admission/recovery review. This change does not retrofit previously accepted invalid histories.
3. Provide an explicit way to turn a rejected draft containing multiple changes into a revised whole request while retaining its other requirements. The current formatted answer keeps that draft available but does not apply its unsupported instructions.
4. Continue general user steering, conflicting/shared parties, ages/infants, provider category meaning, native browser/account/process recovery, progress limits and whole-goal verification. Global navigation-source completion remains restricted pending qualification.
5. After correctness repairs, qualify real lightweight models and the total 8 GB Mac resource budget. Separate planner failures from application failures before selecting or distilling another model. The reported RTX 3080 desktop remains available in the plan; its earlier SSH timeout and unverified access are unchanged.
6. Retain flight, concert, movie and login-handoff scenarios for later explicit authorization. No real-site or model qualification is claimed here.
