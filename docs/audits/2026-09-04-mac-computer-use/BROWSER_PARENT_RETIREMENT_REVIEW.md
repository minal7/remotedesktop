# Parent browser retirement and native cleanup

Source repair, 2026-09-10, following `74d497c` and the [sign-in child review](SIGN_IN_LIFECYCLE_REVIEW.md). This addresses parent Stop/Close and native window-close notification ownership. WebContent failure outside an active retirement remains unfinished. Native, test and model execution remains deferred.

## First-principles findings

Stop and Close require different resource outcomes. Stop retires task authority while retaining the native browser session; a dispatched DOM call may still be running and must keep its slot until its callback or Close. Close releases the captured browser/session and its pending DOM join. Neither operation should discover its cleanup targets again after callbacks have had a chance to replace them.

The old [browser](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) Stop sequence closed the sign-in child and failed a pending navigation before clearing task ownership. Both helpers could publish observable state. A subscriber could claim a replacement during that publication, followed by the old Stop clearing shared ownership and page state. Close then called Stop before reading the current window/browser fields for release, so a replacement admitted by Stop status could also be released by the old Close.

Moving those writes alone is insufficient when Stop retains the same native view. A native cleanup call can reenter; admitting a new claim into that view before the call returns would let old cleanup affect new work. Conversely, blocking claims indefinitely after Stop would strand the retained browser. The boundary must be limited to the synchronous native cleanup phase, followed by ordinary admission and separately scoped presentation.

The old native `windowWillClose` path also notified task controls before clearing browser state, then continued using mutable global window/browser fields. The notification's handler and displayed controls need to be retained, and that handler must not be allowed to turn the rest of old cleanup into cleanup of a new owner.

## Source changes

Parent retirement now uses a single MainActor operation with captured native view/window references. During its native cleanup phase, new claims return `busy`, browser action ownership is closed and popup admission is denied. Reentrant Stop/Close requests coalesce into that operation; Close can upgrade an in-progress Stop without starting a second cleanup or reducing a pending Close to Stop.

The first phase records and detaches the old child identity, pending navigation, observations and claim before external cleanup or status publication. Pending navigation failure has a shared logical-detachment helper, so its terminal history still precedes claim retirement. Its captured continuation is resumed through `defer`, including if later presentation admits a successor. Parent retirement does not publish an intermediate sign-in handback invitation for a task being stopped.

The second phase cleans captured child/native window objects and stops the captured parent view. Close detaches the main browser/window/observation and DOM slot before releasing their native resources. Stop preserves the browser session and the interrupted DOM slot. A real DOM callback can still finish that old slot; Close releases only the retained old capture/join. The new code does not claim that cancelling or releasing a view undoes an already-dispatched effect.

Navigation, URL and policy callbacks are suppressed or cancelled while native retirement is active, so they cannot populate a new observed page in the middle of cleanup. DOM completion remains able to join its existing slot. URL observation also rechecks its captured context after site publication, preventing a callback already in progress from continuing against a replacement after reentrant retirement. This does not solve callbacks already stale when entering the delegate.

Native parent-window closure captures its displayed controls and handler. It detaches/releases the old browser and invokes that handler while the retirement barrier still prevents reuse of the resources; nested handler cleanup joins the same operation. Programmatic cleanup removes native window delegates before closing, so it does not synthesize another user Stop. [Host control handling](../../../host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift) validates its execution/control snapshot through the retained task mapping, rather than requiring the already-retired browser's task field. That compatibility is source evidence; the real AppKit path is not yet executed.

After captured cleanup calls and resource detachment, retirement ends its admission barrier. Site/child/status projection then checks the retired epoch, generation, view and control owner/task before each later assignment. A replacement admitted by publication remains current. During an actual `windowWillClose` notification the system's outer close operation may still be returning; resource detachment is not a general native-quiescence or focus receipt.

## Prepared cases and source checks

Five methods in [ComputerUseOwnedBrowserTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift) are authored and **unrun**:

1. Create a replacement from Close's final status. Require a new retained session that old cleanup cannot release, then navigate independently.
2. Stop or Close a parent with an open child, with and without a replacement admitted by child-clear publication. Require parent authority to be retired before publication, no cancelled-task handback invitation, preservation of a replacement and a later valid navigation.
3. Stop during a dispatched DOM snapshot. Require immediate replacement admission to remain busy until the native callback joins, or until explicit Close releases that old browser. Verify retained versus replaced session identity and a subsequent independent navigation.
4. In an opt-in native-window case, observe actual parent/child close notifications. Require claims to be busy during native cleanup, coalesce nested Stop/Close, upgrade Stop to Close when the child's notification requests it, release the captured windows and reopen future admission.
5. In an opt-in AppKit `performClose` case, require one notification to the captured displayed controls after browser authority/resources detach. Nested handler cleanup must not duplicate that command; later session preparation remains possible.

The first three use controlled loopback WebKit fixtures without presenting windows. The last two live in `ComputerUseOwnedBrowserVisibleAcceptanceTests`, retain the existing explicit opt-in environment gate and remain outside default/focused deterministic selectors. They are prepared in a separate inventory and were not enabled or executed. No case supplies credentials or runs the local model. An executed headless case would still not qualify native window ordering, focus or a complete account-login workflow.

Expected names derive from HEAD plus the three reviewed headless names and two explicitly authored opt-in names. The [default host inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects 2001 and [focused browser control](browser-control-state-inventory.json) selects 1318. A [bounded parent inventory](browser-parent-retirement-inventory.json) selects 14, including prior sign-in cases and existing claim-history/host Stop-persistence cases. The [separate visible inventory](browser-parent-retirement-visible-inventory.json) selects the two new opt-in methods. Client-core and pause-acknowledgement inventories remain 113 and 110. All six inventories match source identifiers. Both changed Swift files pass `swiftc -frontend -parse`; whitespace checks are clean. Syntax and inventory checks do not establish type correctness or executed behavior.

The local documentation scan checked 245 Markdown files and 2081 local link targets with no missing files; anchors were not checked. The effective Git hooks directory contains no executable non-sample hooks. No build, typecheck, assertion/test execution, app launch, native capture, CUA interaction, model run or SSH retry occurred. The installed app and deferred performance stash remain untouched.

## Remaining repair and qualification list

1. WebContent failure outside an existing Stop/Close now has a [subsequent source repair](BROWSER_PROCESS_FAILURE_REVIEW.md). Task/attempt identity and native DOM joins remain retained through scoped failure cleanup, including coalesced child/parent failure. Real process death, stale-at-entry callbacks and uncertain-effect recovery remain unqualified; failure is not task cancellation or automatic retry permission.
2. Qualify the opt-in AppKit cases and actual host window-close persistence path after explicit permission. Include native callbacks before cleanup returns, late callbacks afterward, nested Stop/Close, control-owner changes and failure of durable Cancel persistence. Verify transient `busy` admission ends and no valid request is silently lost during handoff.
3. Continue stale-at-entry navigation/URL/response correlation. A retained WKWebView can receive later callbacks after Stop; suppressing callbacks during cleanup does not attribute all callbacks after it. Preserve claim/session history and do not count a URL/slot match as exact native correlation.
4. Review coherent presentation across reentrant setters. Checks protect subsequent assignments and resources, but cannot undo an observable setter already publishing. UI projections and actual focus/visibility still need qualification; a detached native object is not proof that the system has finished all window or WebContent work.
5. Complete concurrent direct-input takeover and already-dispatched mutating-script handling, retaining exact uncertain effects and completion joins. Close must not become an inferred success, replay permission or assertion that every old network effect was cancelled.
6. After readiness and explicit permission, qualify actual account login/Resume and complete natural-language travel, concert and movie tasks against independently checked live results. Alternative-model adaptation remains available for measured need; 8 GB/thermal qualification follows correctness work.
