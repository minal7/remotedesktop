# Align handback regression coverage with accepted page observations

Source checkpoint: 2026-09-09. Parent: `809842a`. Test-source repair only; no assertions, build, inference or browser execution.

## Finding

The existing `testFailedOrAutomationTimePageChangesCannotBeAdoptedOnHandback` expected both an HTTP 404 during user control and an HTTP 200 during active automation to fail native handback. The latter expectation contradicts the current [native handback implementation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift): a successfully observed active-page change can be adopted after explicit handback and retains `.activePageObservation`. It does not become an automated navigation receipt. Other existing active-link and same-document history scenarios already assert this contract.

This was found by source review. It is a conflicting expected outcome, not an observed XCTest failure. No application behavior was changed to accommodate a test.

## Repair

The method in [OwnedBrowserTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift) is now `testHandbackAcceptsSuccessfulPageObservationsAndRejectsFailedLoads`. Its four rows cover HTTP 200 and HTTP 404 while the control gate is either active or paused at navigation start.

Every row checks that a closed control gate rejects native handback and that opening the gate alone does not adopt the changed page. Successful handback retains the original observation source and creates a fresh document reference without an automated receipt. Failed loads remain unavailable. The original automated receipt and single native dispatch remain intact, and neither handback path reloads a fixture URL.

The source category describes the observed control state; it does not prove that a person or automation initiated a script. This native fixture does not establish authentication success or completion of the outer research workflow. Those remain separate checks.

The exact reviewed method identifier is renamed in both [default](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) and [focused](browser-control-state-inventory.json) inventories, including the focused selector. Counts remain 1633 / 950. No test is removed or excluded.

## Allowed verification and remaining work

The changed Swift test file passes parse-only syntax checking; both inventories agree with the source. These checks do not establish compilation or passing assertions. Execution remains deferred to explicit user permission.

The [navigation-episode review](BROWSER_NAVIGATION_EPISODE_RECONCILIATION_REVIEW.md) still leaves native observed-page admission/adoption history and control-interval reconciliation open. This test correction does not qualify that history, route compliance, WebKit callback coverage, real account login or the live travel/concert/movie scenarios in the [repair checklist](../../../TODO.md).
