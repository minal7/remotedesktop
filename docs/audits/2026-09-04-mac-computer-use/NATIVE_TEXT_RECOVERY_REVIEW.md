# Recovering the original form task after storage failure

Source checkpoint after `3b5cd41`. The [working repair list](../../../TODO.md) remains open. Mac execution, model work and real-site E2E remain paused.

## First principles

A task has several independent facts: the user's complete request, the immutable plan, the exact native field objects, evidence that an input was delivered, its current outcome, and the last acknowledged durable progress. Neither an equal field value nor a journal flag can replace all of those facts.

The current-form executor retained its task across interruptions, which preserved native AX delivery evidence and avoided repeated model planning. But its callbacks also retained a single journal store and captured saved-state expectation. A failed write poisons that store because a replacement may be visible without a confirmed directory commit. Every subsequent Resume therefore reused an unusable writer. Rebuilding the task around a new writer would discard its private local delivery receipts and risk changing field identities or the original plan.

Cancellation exposed a separate ownership boundary: WebKit can still be executing a dispatched script after the Swift await returns cancellation or timeout. Releasing the task's execution lease at that early return would let another runner inspect unfinished work. Holding only the public executor's busy flag would not exclude another store or executor.

## Source repair

1. [The current-form executor](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseNativeTextExecutor.swift) retains the same `ComputerUseTextTask`, browser target and clarification origin. A journal session creates a fresh store for each run, loads its exact state, acquires the matching execution lease and confirms recovered progress. Callbacks use only that active session; a failed store is discarded after its lease releases.
2. First acquisition requires absent history. A new session cannot adopt a journal that appeared during planning. An executor without retained task authority rejects an existing journal before field discovery, browser-provider invocation or model planning, including corrupt history. A storage-open failure after compilation leaves the exact task available for retry.
3. [The shared runner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTaskExecution.swift) reloads progress only after acquiring execution exclusion. It requires exact task, prompt, contract and ordered step identities, a canonical verified prefix followed by at most one attempted/uncertain step and a planned suffix, and forward-only movement from acknowledged in-memory states. Missing history cannot reset a known attempt. Retirement markers cannot become executable plans. Existing native evidence and outcome checks remain required.
4. [The text adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTextTask.swift) converts the exact saved text contract to its already compiled generic contract. It keeps the same local input receipts and effect identities; recovery does not rebuild the task, rebind fields or replay its `perform` callback.
5. [The store](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseTextStepStore.swift) now confirms recovered unretired progress under the exact caller-owned execution lease, journal comparison and directory synchronization. Merely loading a visible verified replacement cannot establish durable completion. The earlier pending-native-tail confirmation delegates to this boundary after requiring an attempted/uncertain state.
6. [The browser text target](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) offers a completion-joining boundary. The current-form runner wraps reads, input and receipt calls inside its execution lease. Its existing pending-change operation already joins. Public execution and clarification also join failed precontract observations before clearing their busy flag. A never-returning native call still requires the browser to return or close before exclusion releases.
7. Query preparation acquires a fresh journal session and requires exact equality with the retained task's verified history. It retains that lease and the executor's busy flag until the native call finishes, then rechecks cancellation, ownership and the action gate. Preparation remains distinct from navigation and whole-goal completion.

## Prepared regression coverage

Twelve new methods are registered in source:

- Nine [native recovery methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseNativeTextRecoveryTests.swift) specify failed verified writes with retained local delivery evidence, initial storage-open failure, conservative handling of a visible failed attempt, missing/rewound/foreign/retired journals, replacement-executor admission, a journal appearing during planning, competing execution leases, exact clarification answer recovery and recovered-progress confirmation authority. Native field/input fixtures use the executor's existing adapter seam; they do not exercise actual AX or inject desktop events.
- Two [browser methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserPendingChangeTests.swift) specify login interruption, failed pending-change verification, fresh recovery without repeated input, query gating against unreconciled progress, query-time execution exclusion, and cancellation during fields/preflight/read/edit/receipt/query calls. Native DOM callbacks record event counts independently. Cancellation after a durable attempt but before input remains uncertain in the current-form runner; it cannot claim completion or replay.
- One [shared-runner method](../../../host-mac/RemoteDesktopHostTests/ComputerUseTaskExecutionTests.swift) specifies ten invalid recovery states and refusal before any observation, persistence or effect, including reload without a lease. Each refusal must release exclusion.

The [focused inventory](native-text-recovery-inventory.json) selects **399** source methods. The default inventory selects **1082**. These are source registrations, not passing assertions, runtime discovery results or model qualification.

## Checks and limits

Eight Swift files passed syntax parsing only. The Xcode project property list, new test-source registrations, both source inventories, documentation links and whitespace were checked. This change adds no JavaScript; the fixture scripts are unchanged.

No typecheck, build, tests/assertions, model inference, app launch, browser/computer-use run or installed-app replacement occurred. No held-out set was read or run. Only source/documentation was created, with no obsolete generated runtime output to remove. Approximately 15 GiB was available at the source checkpoint.

## Remaining repair order

1. **Unsent current-form recovery.** A failed attempt write or cancellation before input can leave attempted history with no native dispatch. The browser research adapter has a separately proved no-input retirement path; the general current-form executor does not yet expose that capability. Preserve uncertainty until original-ledger absence can be proved and revoked under a durable retirement transition. Native AX needs its own independent proof; equal values are insufficient.
2. **Other incomplete native phases.** Failure before an input handler returns, or after a change attempt begins, cannot use the pending-change completion path. Retain exact delivery-phase evidence and define explicit reconciliation before permitting any new action.
3. **Delivered work whose outcome changed.** Preserve original delivery history separately from current goal satisfaction. A source-backed correction needs new, explicitly justified intent under the complete goal, without misrepresenting the first action as unsent. Required-object replacement, obsolete criteria and changed preservation need explicit correspondence and revision rules.
4. **Lifecycle ownership before target acquisition.** The executor cannot join a browser target provider that fails before returning a target. Review that provider and its owner separately. General parent-task reconstruction, process restart and independent native AX receipts are still missing; a journal alone cannot recreate them.
5. **Whole browsing and handback.** Continue document/provider transitions and full remaining-goal retention through account login; qualify explicit user takeover and handback. Complete custom date/location/party controls, JavaScript/POST form behavior, travel/concert/movie result requirements, availability, fees, ranking and public source links. Form edits alone do not prove a research answer.
6. **Qualification and models.** After development readiness and explicit permission, compile and run controlled suites before model/provider E2E. Separate application failures from model interpretation failures. The RTX 3080 desktop is authorized for later alternatives/distillation/pruning when justified, but SSH access and hardware remain unverified. Keep the held-out sets unused and the 8 GB Mac resource target intact; performance work remains deferred.
