# Readonly preservation in research form stages

Status: source integration; runtime, model and full parent recovery qualification pending.

## Problem and implementation

A native “unchanged” predicate cannot protect a natural-language task if the planner cannot select it, private discovery treats it as editable, or the parent drops it between stages. A durable edit contract also needs to distinguish two otherwise identical plans with different original readonly values. The value itself need not enter model context or a journal.

This checkpoint connects the [native preservation foundation](BROWSER_FORM_PRESERVATION_REVIEW.md) to reviewed research forms:

- [Action planning](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) offers supported readonly/native/declared settings for explicit preservation, including settings inside the selected form. Edit and retention intentions still require an editable control. Version-18 scope planning retains the full request and the motivating outcome, condition or prohibition; selecting private preservation does not grant research-reading permission.
- [Form scope](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormEffectScope.swift) partitions native predicates from editable preservation. Selected private field discovery excludes the native predicate controls. After binding the actual editable objects, the owner prepares the original native baseline using the reviewed scope's purpose digest. Scope identity advances to version 3.
- [Form input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) requires the native binding to match that exact scope, document and ordered control IDs. Earlier preservation source bytes remain attached to their controls. Version-12 context lists `required_native_preservation` as control/source references without values or fake field aliases. Ordinary editable preservation still supplies unchanged-field requirements. A prohibition can bind a private invariant while remaining ineligible for a research read.
- [The form contract](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) includes the native fingerprint in version-4 reviewed contract identity. Identical model context with a different private baseline produces a different contract. [The stage](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) requires its retained adapter to hold that binding, validates it before unsent execution and after text-task completion, and carries it plus its original source records in the version-5 continuation. Returned native input remains historical evidence; failed preservation cannot become a confirmed research stage or permission to replay input.
- [Query requirements](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) include the native fingerprint in version-2 identity and pass the original guard ID. Verified native preservation also contributes to the query's bound control set, so it does not need an unrelated model-facing value read. Query preparation still checks current native state and the original editable values/receipts. Neither a preserved frontend value nor a GET receipt proves provider results satisfy the request.
- Additive native scopes retain their ancestor IDs and every original record. Earlier form requirements may be checked under a stronger guard that still enforces those records. Unknown guard IDs fail. Preflight and input continue to require the exact active ID. This allows later form preparation to keep earlier requirements meaningful without restoring a smaller scope or rebasing a value.
- [Owner preparation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) retains an already prepared native-preserved form through idle Pause or cancellation inside its planner/revalidation. Explicit handback is still required. The owner and stage share restoration of original observation scopes, native objects and values; changing only observation nonces cannot create new authority. A changed readonly baseline blocks resumption.

The previous unsupported-preservation fixture now uses a readonly email field, which remains outside the supported private predicate set. Readonly ordinary text is covered by the new supported path.

## Prepared regression coverage

Fifteen methods in [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift) prepare these cases:

1. Readonly preservation inside and outside the selected form without editable aliases.
2. Mixed editable and native preservation sharing the original user clause.
3. Missing or different-purpose native bindings rejected by form input.
4. Prohibition-based private preservation without research-read permission.
5. Different private baselines changing contract identity without changing model context.
6. A changed readonly value preventing the first edit.
7. Handler violations preventing stage completion and input replay.
8. Unsent Pause retaining the original baseline through explicit handback.
9. Pause after input reconciling the original receipt without another edit.
10. Idle prepared-form Pause and cancellation inside form planning retaining the same baseline.
11. Changed readonly values during handback preventing resumption.
12. Queries carrying readonly preservation without a research value read.
13. Query handback checking the original predicate before loading.
14. A later form stage retaining readonly sources and earlier input receipts.
15. Additive native scopes enforcing earlier query requirements, rejecting unknown guard IDs and retaining dispatch history after a preservation failure.

The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,351** source methods; the [focused inventory](browser-control-state-inventory.json) selects **668**. Fifteen methods are added with no prior identifiers removed. Eleven changed/new Swift files receive `swiftc -frontend -parse` only. The assembled DOM, five embedded fragments and three distinct fixture scripts receive `node --check` only. The new test file has four Xcode registrations. Source inventories, project syntax, documentation links and whitespace are checked.

No tests or fixture assertions have executed. No build, typecheck, app/browser/computer-use launch, model inference, SSH retry, held-out inspection, installed-app replacement or scratch artifact is involved. These checks do not establish actual model understanding, tokenizer/context fit, native behavior, provider correctness or resource use.

## Remaining repairs

1. Persist and retain the original preparation intent **before the first private native preparation callback**. Cancellation in that initial window can still leave a native guard without a published parent `PreparedForm`. Native idempotence protects the value baseline, but the parent does not yet fully recover that unpublished preparation. Do not clear the guard or rediscover a new baseline to hide the gap.
2. Carry unstarted preparation through goal clarification/reinterpretation and explicit task ownership transfer. Already prepared same-goal Pause now retains its adapter; question acceptance and new-owner transfer require a broader retained preparation state. The native transfer gate remains closed for guarded forms. Complete parent/browser/account recovery across process restart: a hash in a journal does not reconstruct an in-memory native predicate.
3. Extend explicit semantic preservation to composite widgets and unify criterion lifetimes across popup/option effects, navigation, document replacement and account return. Keep original source obligations when website reactions replace controls. A transient unobserved property change and restoration, CSS-only transient state or backend side effect remains outside this predicate's proof.
4. Verify independent provider results and the complete travel/concert/movie request, including dates, places, units, quantities and prices. Preserve the full goal during visible account login takeover and resume only after explicit handback. Authenticated real-site E2E is still deferred until the user authorizes it.
5. After correctness readiness and explicit execution permission, qualify native fixtures, actual lightweight-model choices, exact context/tokenizer fit, and whole-app 8 GB Mac memory/thermal behavior. Alternate models and the authorized RTX 3080 desktop remain options after measured failures; this checkpoint offers no evidence for a model switch, pruning or distillation. Continue the [repair TODO](../../../TODO.md).
