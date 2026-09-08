# Recover a known browser choice after an ambiguous replacement write

Parent source: `3a2e21e`. This checkpoint repairs source behavior and prepares regression cases. It does not qualify the app, browser driver or model at runtime.

## Finding and required behavior

The retained research-link and explicit link/form workflow paths saved a replacement destination before retaining it in memory. A storage failure after rename could leave that new binding visible while the caller kept only its old target. A subsequent attempt then failed identity checks permanently. The initial-search path already retained both known possibilities, but these paths did not.

A write error cannot tell us which version is visible. Neither inventing a third choice nor repeating the action resolves that uncertainty. The task needs its previous and proposed binding until a fresh locked read identifies the saved version. That establishes metadata only. Any subsequent action must independently prove its current page, ownership, journal state and durable dispatch boundary. An attempted action must still use receipt reconciliation.

## Source implementation

The shared observed-navigation facade now provides synchronous `resolveUnconfirmedObservedDestination`. It accepts the two retained native targets, original prompt digest and operation ID. It checks matching task/context, the caller's current authority and the native session, loads through a fresh journal store, and acquires an execution lease against that exact row. It returns only the matching known target, or the previous target if the record is absent. Unknown identities fail. Cancellation, caller ownership, lease ownership and native session are rechecked before return.

Resolution performs no DOM read, model call, journal write or navigation. It releases its short metadata lease before the caller's next open/replan operation. That operation acquires its own lease and revalidates the exact saved identity; a competing writer in between causes rejection rather than granting action authority. This extra recovery path runs only when the caller retained an unconfirmed alternative.

Research navigation now retains one proposed stage after a failed replan. It resolves the known pair before resuming that pending stage or invoking further selection, keeping the original operation ID and goal revision. A successful resumed action is recorded under the resolved selection, so its receipt can be retrieved under the choice that actually completed. A failed read or unknown binding keeps the ambiguity intact. Before another replan, the old ambiguity is resolved, bounding retention to the current and proposed stage rather than a growing collection of guesses.

Confirmed replacement still updates the retained choice before surfacing late Pause. A failed replacement also keeps the known alternative through Pause; cancellation remains the caller-visible interruption. Retirement clears both pending and alternative stages and cannot be reversed by a late callback. The research owner's existing captured session, control epoch and operation serialization continue to surround these calls.

Explicit link and form-query workflows use the same resolver for their retained destinations. Each bounded workflow stage can retain one unconfirmed proposal. Parent journal progress, original command and session remain fixed, while the child rechecks its saved binding and both durable/native attempt evidence before any new page observation. Verified form-edit requirements remain attached to query preparation. The optional observed-store fault hook now reaches these existing child paths; production continues to use the normal store.

The observed-navigation open path also checks combined native attempt history before reading or writing when its saved row is absent/planned. A raw native attempt without a source-bound observed receipt cannot be erased by planned metadata. Attempted/uncertain/verified journal recovery remains historical-receipt-only, with no effect API call.

## Prepared regression coverage

Seven new DOM methods cover:

- A failed replacement with the new, previous or missing record visible; unchanged goal and stage identity; one eventual request; receipt replay under the recovered selection.
- Repeated ambiguous writes, followed by another explicit replan and a no-selection result without dropping the stage.
- Attempted, uncertain and verified records after failed replacement stopping before reading or selection.
- Unknown bindings, Stop, close and same-root reclaim preventing recovery under lost authority.
- Pause or retirement during a failing replacement write, requiring explicit handback and never reviving a retired owner.
- A competing execution lease during metadata resolution, a lease held during the final authority check, and an intervening writer rejected before dispatch.
- Successful and failed raw native attempts beside a planned observed-navigation journal, with no repeated reading, write or request.

The existing explicit workflow test adds failed-replacement cases for both a link and a form query after login. It retains parent/child operation identity, verified edit values, no destination request during failure and one eventual destination request.

Four earlier prepared research-replanning cases are corrected to select against a fresh snapshot after handback or an intervening read. Source inspection of the isolated DOM adapter shows that `pageSnapshot` replaces the previous snapshot identity. Recovering a saved target cannot bypass that current-snapshot check. These cases now explicitly replan the proven-unsent stage before opening, retaining the original operation sequence. Shared fixture setup also joins its cancelled DOM callback before subsequent work.

## Checks actually performed

Five changed Swift files passed syntax-only parsing. One fixture script passed `node --check`. Both source inventories and whitespace checks passed. All changed Swift files were already registered in the Xcode target; no project registration or build setting changed.

The [focused source inventory](browser-binding-recovery-inventory.json) selects 188 methods, including six existing explicit workflow methods and the preceding research/initial-search recovery cases. The default selects 871, seven more than the parent. These are reviewed source identifiers, not executed or passing assertions.

**No typechecking, tests/assertions, builds, model inference, app launches, browser/computer-use activity or live E2E ran.** The temporary JavaScript syntax file was removed. Installed app, model/runtime assets and historical qualification evidence were untouched.

## Remaining work

1. Implement goal-consistent provider/site selection and the concrete research action driver/default-loader composition. The driver must choose fresh selection for proven-unsent stale targets and receipt reconciliation for attempts, retaining the full original goal through login.
2. Complete the ordered action ledger across search, forms, dates, choices and links, then verify relevant offers, availability, dates, prices/fees, public sources and complete answers across pages.
3. Qualify actual host/phone/manual-login behavior, current snapshots, durable writes and recovery with the current model/runtime. Source checks cannot establish those behaviors.
4. Use alternate models or the user-authorized desktop for model adaptation if measured model failures justify it. SSH inspection was attempted but timed out before authentication; the remote GPU, VRAM, OS and toolchain have not been verified. Do not attribute routing, stale-page or persistence faults to the model.
5. Mac tests and real travel/concert/movie E2E remain paused pending explicit permission. Performance and 8 GB/thermal qualification remain a later phase.

Related checkpoints: [initial-search recovery](BROWSER_INITIAL_SEARCH_REFRESH_REVIEW.md), [research replanning](BROWSER_RESEARCH_REPLANNING_REVIEW.md), [unsent destination refresh](BROWSER_UNSENT_REPLANNING_REVIEW.md), [workflow driver](BROWSER_WORKFLOW_DRIVER_REVIEW.md) and [research routing](BROWSER_RESEARCH_ROUTING_REVIEW.md).
