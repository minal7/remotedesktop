# Native readonly form preservation foundation

Status: source repair; execution and parent integration pending. This checkpoint does not expose readonly preservation to the normal natural-language planner.

## First-principles problem

“Leave Reference unchanged” is an invariant over an operation. Reading Reference before typing proves only its earlier value. Treating it as an editable field grants the wrong capability, and reading it again after an interruption must not silently establish a new baseline. A website's input or change handler can also alter Reference after the host has set the intended Query value. Input delivery and successful preservation are different facts.

Existing editable-field preservation already retains native objects, private values and input receipts. [The native-setting scope checkpoint](BROWSER_NATIVE_SETTING_SCOPE_REVIEW.md) added explicit reading of supported settings and restoration of original form/query observations. Neither mechanism alone provides a private readonly predicate checked around each edit.

## Source changes

- [FormPreservation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPreservation.swift) introduces a bounded private native binding. It captures explicit noneditable text/scalar/select, checkbox/radio/multiple-select and declared toggle/range controls. Composite widgets and protected credential/account/contact/payment values remain unsupported. Ordinary editable settings use the existing editable-preservation path. No fake field alias, research-reading authority or normal planner action is added.
- The binding retains the original input ledger, selected form, exact native control objects, metadata, declared signatures, values, labels and option references. Its Swift description is redacted; the parent-facing value retains only IDs and a fingerprint. The private reply is checked against the original metadata and state schema before the adapter adopts it. [ObservedCriteria](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserObservedCriteria.swift) now accepts separate metadata and private states while preserving the existing baseline serialization.
- Native preparation is idempotent for the same active purpose and ordered controls. Additive scopes retain original records. They cannot drop a control, rebase a changed value, reactivate an earlier smaller plan or clear preservation through whole-form rediscovery. At most 16 controls, 32 plans, 4,096 pinned references per plan and 128 ancestor levels are accepted. The private observer starts only when a plan is prepared; a root replacement clears it. These bounds are not a performance qualification.
- [The DOM adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) checks the active guard before retained reads, preflight, input, retained form extension and query preparation/validation. A query with no field requirements still checks the guard. Native input/preflight must name the active guard; a caller cannot omit it and retain effect authority. Scalar pending-change records retain the original guard identity.
- The guard checks again after returned text input and scalar input/change handlers. An observed violation latches invalid even if later restored. Removed/reinserted original nodes, replaced options, relevant metadata/ARIA attribute mutations and label/control text mutations also retire the predicate. Authentication is checked before private value reads, including handlers that reveal a login challenge.
- A returned input/change remains historical dispatch evidence even when preservation fails. Value/outcome verification then stops. A scalar input that returned without its change notification cannot send that tail while its preservation guard is invalid. Existing no-replay receipt logic is retained.
- Adapter preparation and validation join outstanding native callbacks on failure. Clarification transfer rejects an active guard before changing ownership until the parent can explicitly carry its original contract. This is a deliberate foundation boundary, not completed account/clarification recovery.

## Prepared coverage and source verification

Fifteen methods in [FormPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPreservationTests.swift) prepare coverage for:

1. Supported readonly/native/declared settings, private descriptions and absence of editable aliases.
2. Requiring the active predicate before preflight.
3. Successful text delivery with the original predicate intact.
4. A property-only change before input blocking reading, preflight and delivery.
5. A text input handler violating preservation while retaining one dispatch receipt.
6. A scalar input violation withholding its unsent change tail.
7. A scalar change violation retaining the completed receipt without replay.
8. An observed property violation remaining invalid after restoration and fresh metadata.
9. Replacement, reinsertion and restored/replaced label text retiring the original binding.
10. Restored declared state/description attributes and replaced native options retiring it.
11. Stable repeated preparation and additive scopes that cannot drop earlier controls.
12. Rejecting ordinary editable and protected controls from this private capability.
13. Authentication appearing after input blocking private observations while keeping history.
14. Rediscovery and unintegrated clarification transfer failing to clear the guard.
15. A query without field requirements still checking readonly preservation.

The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,336** source methods; the [focused inventory](browser-control-state-inventory.json) selects **653**. Each adds these fifteen methods without removing prior selections. Four changed/new Swift files receive `swiftc -frontend -parse` only. The assembled DOM, five embedded fragments and thirteen distinct fixture scripts/snippets receive `node --check` only. The two new files each have four Xcode registrations. Project syntax, source inventories, documentation links and whitespace are checked.

These are prepared cases and syntax/source checks, not passing runtime tests. No build, typecheck, test assertion, app/browser/computer-use launch, inference, SSH retry, held-out inspection or installed-app replacement occurs. No scratch file is retained.

## Remaining repairs and limits

1. Carry explicit readonly preservation from full-goal interpretation through form scope, private discovery, parent contract/journal, continuation and query requirements. Bind the original purpose and fingerprint before any effect; retain them through cancellation and explicit handback. The native helper's caller-supplied scope hash is not yet durable parent authorization. Keep ordinary read permission distinct from a private “unchanged” obligation, particularly for prohibition clauses. Source references alone do not prove a model understood the clause.
2. Cover composite/custom widgets with their own semantic predicates. Focus, expansion, active descendant and selected value are different facts. Do not freeze incidental widget state or claim backend selection from ARIA alone. Other effects such as popup opening/option selection and navigation do not yet carry this new form guard universally.
3. Unify criterion lifetimes across stages, document replacement and account return. Explicitly reconcile intended changes and website reactions. This guard can detect current property changes and observed mutations; it cannot universally detect a silent native-property change and restoration wholly inside an unobserved callback, transient CSS/computed-state changes, or server-side effects. It cannot prevent a page handler's side effect by discovering it afterward, and it does not roll it back.
4. Complete durable parent/browser/account-session recovery and independent provider-result verification. Preserved frontend settings and a dispatch receipt do not establish that flight/concert/movie results satisfy the original request. Preserve the full task during visible login takeover; resume only after explicit handback.
5. After correctness readiness and explicit execution permission, qualify these cases on the real native runtime, actual lightweight-model judgments and held-out workflows. Retain travel/concert/movie and login scenarios. The user's 8 GB whole-app target includes browser, host and model memory. Alternate models and the authorized RTX 3080 desktop are available development options after measured failures; this source checkpoint supplies no model-comparison, distillation/pruning or thermal evidence. Continue the [repair TODO](../../../TODO.md).
