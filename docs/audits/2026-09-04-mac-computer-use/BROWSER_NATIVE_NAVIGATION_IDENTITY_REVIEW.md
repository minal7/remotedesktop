# Native navigation identity after retirement

Source repair, 2026-09-10, following `9a15c3c` and the [process-failure review](BROWSER_PROCESS_FAILURE_REVIEW.md). Execution remains deferred.

## First-principles findings

A native navigation object identifies one load, while the WKWebView and browser task can outlive many loads. The installed WebKit SDK's `WKNavigation.h` describes that start-to-finish identity; `WKWebView.h` describes new navigation returns from load and history traversal. An old callback carrying a known native object must not be interpreted as a fresh load merely because its former pending slot is now empty.

The old [browser delegate](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) kept native objects only in the live pending/observed slots. A delayed start after completion, Stop or claim replacement could clear a newer document and install a new observed-navigation record. During another explicit load, that same stale start could fail the new pending request. Other retired callback phases could also add unbound observations to the newer operation's history. Repeating the start of a still-live observed navigation recreated its observation ID/generation and discarded its response state.

Native return ordering is a separate boundary. The adapter reserves its pending slot before calling WebKit, but cannot bind the returned WKNavigation until that synchronous call returns. A callback delivered inside that interval must wait for the return before using the slot's native identity. Nil is not an exact identity. Allowing a replacement claim or another explicit navigation during that interval would also let the old native call continue across reuse of its view.

Deferring state handling introduces a history risk: replaying the callback later must not pretend the callback arrived later or rewrite its URL/binding using later state. Arrival evidence and later state admission need separate treatment.

## Source changes

The browser now remembers known main-view navigation objects using weak references and object identity. Explicit returns are remembered even if the original reservation was retired inside WebKit. Observed starts and terminal callbacks are remembered too. A known object outside both live native slots is retired: its start, redirect, commit, finish and failure callbacks cannot alter current state or append observations to a newer claim. The registry survives Stop and claim changes; it does not expire still-live identities by time or retain every old native load strongly. Foundation may retain empty hash-table storage after weak objects disappear; no resource qualification is claimed.

A repeated start for the same live observed navigation preserves its identity, response and original control classification. Terminal callbacks without a native identity can be recorded as unbound notifications but cannot complete/fail a current native slot through nil equality. Observed start/finish also recheck their context after querying the external control gate, so a replacement admitted during that query cannot receive old observation state or readiness status.

Explicit load/history dispatch retains its view and reservation until the native call returns. Claims, new explicit navigations and popup admission are busy/closed during that synchronous interval. Identity-bearing delegate callbacks are queued for state handling. The returned native object binds only the original still-pending reservation; callbacks whose reservation has retired cannot start observations in its successor. Nil returns keep the existing navigation-failure outcome. Normal policy decisions still execute synchronously under the original owner.

Each deferred callback records its notification when it enters, with the original view URL and then-available binding. State replay adds no second callback entry and does not upgrade that historical binding after the return is known. An unbound callback therefore remains an explicit evidence limitation even if the current operation later succeeds. This is not a new proof of full route/source compliance; that completion qualification remains disabled/pending.

## Prepared cases and source checks

Five methods are authored in [ComputerUseOwnedBrowserTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift), all **unrun**:

1. Replay all six native callback forms from a completed load while a newer load is pending or completed, within the same claim and after Stop/reclaim. Require unchanged current history, task binding and page status, followed by successful independent navigation.
2. Inject nil terminal callbacks and an exact start before the native return is bound. Require successful later loads, busy claims during dispatch, immediate unbound history entries in original order and no history rewriting during replay.
3. Queue native callbacks then Stop/Close before return binding. Require the old operation to fail, immediate claims to remain busy, later replacement admission to work and the old callbacks to confer no observation authority.
4. Repeat a still-live manual navigation start. Require its original correlation ID/generation to survive, then preserve completed manual-page handback through delayed callbacks and explicit fresh reacquisition.
5. Replace the owner from the observed-start control sample. Require no old observation to be installed in the successor and allow its independent navigation.

The optional initializer hook exposes the already-returned native view/navigation just before binding for controlled fixtures; production supplies no hook. It exercises the unbound interval without asserting that WebKit actually delivered a callback inside its native load stack. These cases use loopback fixtures with window presentation disabled. They neither run a model nor qualify actual user login, real process death, native focus or real-site tasks.

Expected names derive from HEAD plus the five reviewed method names. The [default host inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects 2006 and [focused browser control](browser-control-state-inventory.json) selects 1323. The [bounded native identity inventory](browser-native-navigation-identity-inventory.json) selects 11, including existing completion, source-history and fresh scripted-navigation cases. Bounded parent, process-failure visible, client-core and pause-acknowledgement inventories remain 14, 6, 113 and 110. All seven match source. Both changed Swift files pass parse-only checks; whitespace checks are clean. These checks establish neither type correctness nor executed behavior.

The local documentation scan checked 247 Markdown files and 2095 local targets without missing files; anchors were not checked. The effective Git hooks directory contains no executable non-sample hooks. No builds, typechecks, tests/assertions, app launches, native capture/CUA, inference/training or SSH retries occurred. The installed app and deferred performance stash remain untouched.

## Remaining repair and qualification list

1. Delayed URL observation now has a [subsequent source repair](BROWSER_LOCATION_DELIVERY_REVIEW.md): reported values and delivery tickets retain their source/owner, queued changes close readiness and unordered gaps remain explicit. Actual KVO chronology, missing notifications, first-seen late events and full native qualification remain open.
2. Correlate action/response/history and process-termination callbacks that supply no native navigation identity. A first-seen navigation can also arrive already stale; this registry rejects known retired objects, not all unknowable origins. Child-page callback lifetimes need separate qualification. Do not treat same URL or same WKWebView as exact origin proof.
3. Repair coherent observable presentation. Checks protect later assignments but cannot undo a setter already publishing when a subscriber changes state. Preserve task-control ownership through those publications and qualify actual native focus/window behavior.
4. After permission, execute the authored cases and qualify true native return/callback order, history traversal, reentrant policy cancellation, Stop/Close, missing callbacks and shared-process failure. Confirm temporary busy admission ends and no valid user request is silently lost. Unbound history must remain a qualification gap rather than being promoted retroactively.
5. Complete remaining correctness work, then qualify actual login/Resume and natural-language travel, concert and movie tasks against independently checked live results. Alternate-model adaptation and 8 GB/thermal measurements remain later work; a small set of fixture outcomes cannot establish universal task correctness.
