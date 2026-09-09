# Retained preparation for later form stages

Status: source repair only. Native behavior, type correctness, model decisions and real website workflows remain unqualified.

Follow-up: [goal review during retained preparation](BROWSER_PREPARATION_GOAL_REVIEW.md) permits fresh interpretation and further clarification questions after an accepted answer. Revised form-scope reconciliation and execution remain pending.

## Problem and invariant

A task can set a search term, verify the input, and then prepare another field such as Category. The first stage's values, native objects and operation receipts are still obligations of the task. Pause can cancel the second preparation's caller after WebKit has already extended the retained field catalogue or captured an additional preservation scope. Losing that result would invite rediscovery, a changed baseline or an attempt to resume with the wrong scope.

The first principle is that completion of a native callback and successful return to its caller are separate facts. A later stage must retain both its own first observations and the exact verified predecessor. A cached reply records what was observed; it does not prove the current page is still valid or authorize another input.

## Source repair

- [DOMReadCapture](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOMReadCapture.swift) now also accepts `extendFormFields`. Its original document, command and argument digest remain fixed. Earlier requirements, preservation identity, selected controls and repairable field IDs cannot change on reuse. Only the observation nonce may differ. Unknown failures remain terminal; the existing empty-authentication retry rule still requires a reply with no private result.
- [The native adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) forwards that capture through extension. Decoding a retained extension still requires every earlier criterion to retain its original native target mapping. The existing native requirement checks enforce earlier values and receipts before extension; subsequent binding and original-input validation compare current state to the captured baseline.
- [ResearchFormPreparation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift) accepts a verified parent stage, retains its exact continuation, and borrows its original adapter before private preparation begins. It chooses extension for a later stage and discovery for an initial stage. Both paths retain field, correspondence and preservation results through cancellation. Prepared input carries the original continuation, including earlier criterion sources and operation receipts.
- [The parent stage](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) lends its context only for the same form and document under a continuing research goal. Every suspended preparation boundary checks that the parent remains verified, unretired and unchanged. Additive native preservation may strengthen the active guard; that does not rewrite the predecessor's historical receipt or permit dropping its obligations.
- [The task owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) publishes the retained preparation before extension begins. The existing pending-preparation branch therefore handles later stages too. Explicit handback is required before resume, and [the driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) resumes preparation and completes its stage before requesting another action. Retirement prevents a late callback from publishing a new stage. Repeated execution of the verified predecessor is rejected while later preparation is pending, as are predecessor resume, unsent retirement and prefix recovery. None can clear the preparation or disturb its parent through a competing public API.
- A clarification answer cannot discard a later preparation just because it lacks an explicit readonly predicate or retained research reading. Its earlier verified criteria are preservation obligations too. The frame is retained, and continuation under a changed goal is rejected until reconciliation can carry those obligations explicitly. This is an intentional incomplete path, not successful clarification recovery.

## Prepared regression coverage

Nine added methods in [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift) cover:

1. Pause at extension, correspondence binding, preservation capture and final original-input validation; explicit handback; the same adapter, source obligations and prior receipts; one extension and one later edit.
2. A changed newly captured value or previously verified criterion rejecting resume without a new extension or replay of the first edit.
3. A changed readonly baseline after native scope extension rejecting resume.
4. Replaced new and previously edited objects rejecting recovery even when their markup matches.
5. Driver ordering that completes the retained later stage before selecting another action.
6. Retirement during extension preventing publication or input for a new stage.
7. A clarification answer retaining earlier criteria even without explicit readonly preservation.
8. A cached extension rejecting changed prior requirements, guard identity, selected controls and repairable objects.
9. Repeated execution, resume, retirement and prefix requests for the predecessor rejecting before native work, with later preparation still resumable both before and after interruption.

These methods have **not run**. Six changed Swift files passed `swiftc -frontend -parse` only. The assembled DOM, five fragments and eight distinct fixture scripts/snippets passed `node --check` only. The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) now selects **1,370** source methods and the [focused inventory](browser-control-state-inventory.json) selects **687**, with nine additions and no removed identifiers. Project syntax, source inventories, documentation links and whitespace are checked separately. No test count is a passing-test count.

No build, typecheck, assertion run, app/browser/computer-use launch, inference, SSH retry, held-out inspection or installed-app replacement was performed. No generated scratch artifact was retained.

## Next repairs

1. Reconcile invariant-bearing preparation with accepted clarification answers and revised goal interpretation. Carry original observations and receipt history; prove which criteria remain required or are explicitly superseded. A new answer alone cannot erase earlier effects.
2. Complete ownership transfer and durable parent/browser/account-session recovery. These captures are in memory. After a process or document loss, hashes cannot recreate native objects or establish whether an unknown effect completed. Keep visible login takeover and explicit handback in the recovery design.
3. Extend criterion lifetimes across composite controls, popup/selection effects and navigation. Separate meaningful changes from unrelated dynamic page content while retaining original identity and value obligations.
4. Verify independently observed travel/concert/movie results against the complete request. Model selection or adaptation must follow measured model failures after execution is authorized; it cannot repair missing ownership or evidence invariants. Alternate models and the authorized RTX 3080 remain options for that later phase. The 8 GB Mac target and thermal qualification remain pending.

Continue the [repair TODO](../../../TODO.md). Live website testing still requires the user's later explicit permission.
