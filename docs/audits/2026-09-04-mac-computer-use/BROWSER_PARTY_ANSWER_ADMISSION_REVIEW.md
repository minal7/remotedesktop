# Recover whole-party corrections before consuming their question

Source repair; execution pending. This extends [component answer admission](BROWSER_COMPONENT_ANSWER_ADMISSION_REVIEW.md) to [whole-party replacement](BROWSER_PARTY_REPLACEMENT_REVIEW.md). No build, typecheck, assertion/test run, app/browser launch, inference, live-site task or SSH connection ran for this repair.

## First-principles finding

A question that replaces both adult and child counts cannot accept only `3 adults` and guess what happens to the children. Previously the whole-party path retained that incomplete answer, consumed the question and only then marked the replacement uncompiled. The user could lose the immediate correction path even though the app had not applied a usable change.

Admission now establishes the supported whole change before consuming its question. Incomplete categories, totals without a breakdown, repeated categories, unsupported comparators and added instructions are rejected while the original question, scope, accepted turns and root date context remain. A corrected answer uses the same reference and a new attempt ID. The existing active-work allowance and original question expiry are not renewed.

## One literal grammar

The [shared answer policy](../../../protocol/Swift/ComputerUseProtocol.swift) adds a whole-party format requiring both adult and child categories. It accepts either category order, numeric counts from 0 through 999 and English words zero through ten. Existing `for`/`exactly` framing and category separators remain supported. Answer normalization permits the existing leading `and` and one trailing punctuation mark, while literal source parsing consumes its complete source without trimming or rewriting it.

The [native scalar compiler](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) uses the same literal grammar and number parser. Native category-span extraction uses the shared pattern, retaining exact byte ranges for each category even when model rows split the answer. The zero spelling is recognized in whole-party sources as well as single-category corrections. Guards against extracting a smaller party from a three-component clause use the same expanded component grammar.

The [native question](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalClarification.swift) derives whole-party admission from its own `replaceParty` topic. Its direct consume path checks the format before creating an accepted turn. The existing bridge derives its complete policy from that live question, rejects before owner continuation and checks full policy equality before replay. Phone validation, persisted drafts, retry capability checks and deadlines use the existing shared policy path.

## Compatible format extension

Adding another raw value to the original optional `format` enum would break older phones: their decoder would reject the entire question on seeing an unknown enum value. New whole-party metadata therefore uses the separate optional `extendedFormat` field. The original adult/child format encoding remains unchanged. A whole-party policy never emits both fields or puts its new value in the old field.

Older phones ignore the additional advisory field and can still read the complete question and send a correctly formed answer. They do not advertise format-retry support for a format they have not recognized. Current phones recognize `partyCounts` and negotiate the existing answer-only format-retry capability. The host retains the generic fallback for an invalid answer without that capability while leaving the native question intact.

Current decoding also ignores bounded, syntactically valid future extension kinds. Such an unknown advisory format cannot activate local format validation or opt into format retry. Existing byte/nonblank checks and native admission still apply. Malformed extension metadata, conflicting legacy/extended declarations and attempts to place the whole-party value in the legacy field are rejected. A format-mismatch retry still requires a recognized format and the actual submitted answer, reference, deadline and live native policy.

## Prepared verification

Five new methods are authored and unrun. The existing invalid whole-party answer method now requires admission failure with the exact question/input retained, followed by a successful correction. The component manager method shares its fixture with the new whole-party method.

- [Wire and grammar coverage](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserClarificationTransportTests.swift) specifies both category orders, zero spelling, count bounds, complete-answer rejection, literal-versus-answer boundaries, older enum decoding, unchanged legacy encoding, unknown extension handling and malformed/conflicting metadata.
- [Native clarification coverage](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) specifies rejected answer recovery and fresh whole-party sources across reversed categories and split answer rows, retaining the original budget and exact component provenance. Three-component clauses cannot become a smaller bound party.
- [Manager coverage](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift) specifies no retry support, older basic retry and current format retry, durable replay and corrected continuation under the original question.
- [Phone coverage](../../../ios/RemoteDesktopTests/ComputerUseClarificationClientTests.swift) specifies retention of an incomplete draft, a corrected full party under the original reference/deadline and readable unknown future metadata without advertising unsupported format recovery.

Seven Swift files pass parse-only checks. Source inventories select **1876 default host / 1193 focused host / 34 client core** methods. The [focused whole-party admission inventory](browser-party-answer-admission-inventory.json) selects four host methods, including the revised invalid-answer method. These checks establish syntax and registration only, not passing assertions, type correctness, serialized runtime behavior or model competence. Local documentation checks cover 210 Markdown files and 1,712 local targets with no broken targets. Whitespace checks are clean, and the effective hook directory contains no executable non-sample hooks.

## Remaining repair sequence

1. Keep execution deferred until authorized. Then compile and run host/client cases and their serialized composition, including old/current client combinations, saved question recovery and delayed/replayed replies.
2. Apply the same admission/recovery review to generic quantity, date, budget, location and source-policy questions. Previously accepted invalid histories still need a recovery strategy; this change only prevents new unsupported whole-party turns from consuming their question.
3. Support broader conversational correction and explicit multi-change steering without dropping new requirements. A rejected draft is preserved but its unsupported instructions are not applied. Provide a deliberate transition from such a draft to a revised complete request.
4. Continue conflicting/shared parties, multiple trips/events, ages/infants and provider category semantics. Both zero counts remain syntactically representable under the existing party contract; satisfying a particular ticket/travel task still requires its complete constraints and provider evidence.
5. Continue durable native browser/account/process recovery, progress limits and whole-goal verification. Global navigation-source completion remains restricted pending qualification.
6. After correctness repairs, qualify supported lightweight models, total 8 GB Mac memory and thermal behavior. Keep the authorized RTX 3080 desktop and alternative models in the evaluation plan; remote access remains unverified after the earlier timeout.
7. Retain real flight, concert, movie and login-handoff scenarios for later explicit authorization. This repair supplies no live-site or local-model qualification.
