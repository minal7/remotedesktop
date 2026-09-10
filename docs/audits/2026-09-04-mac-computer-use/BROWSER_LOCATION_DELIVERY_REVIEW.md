# Delayed URL delivery and page readiness

Source repair, 2026-09-10, following `a9caf82` and the [native navigation identity review](BROWSER_NATIVE_NAVIGATION_IDENTITY_REVIEW.md). Execution remains deferred.

## First-principles findings

A reported URL change and the URL visible when its handler eventually runs are different facts. Reading the later URL cannot reconstruct an intervening A-to-B-to-A transition. A delayed handler also needs its original browser/owner identity; a reused WKWebView is insufficient to identify the task that should consume the event.

The old [URL observer](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseOwnedBrowser.swift) captured the new value for main-thread delivery but queued an off-main Task that later read `view.url`. That lost the reported URL, attributed the notification to the then-current pending slot and could invalidate a successor after Stop/reclaim. Main-thread notifications whose reported value already differed from the current view were discarded. Pending notifications were invisible to claim, document and handback readiness.

Dropping delayed events would also be wrong: an equal final URL does not restore the old page's evidence. The repair must preserve the notification values it actually received, keep unknown ordering/classification explicit, prevent obsolete deliveries from addressing successors, and allow a real native navigation to establish its eventual document separately.

## Source changes

A lock-protected inbox retains up to 64 URL values, each limited to 8192 UTF-8 bytes. Excess events or oversized values mark missing history; oversized values are retained as unknown rather than as a fabricated URL. Each native view receives a distinct source token. A delivery ticket binds that source, the owner epoch at application ingress and one queued batch. Later events coalesce into the same ticket, so only the first needs to schedule delivery. The lock never calls browser, actor or UI code.

Claims require an empty queue, including an atomic empty-check/owner transition under the inbox lock. Stop takes any queued old-owner batch and records its unordered observations before the claim retires, then changes the inbox owner. Close also retires the view's source. An old scheduled ticket cannot consume a newer batch, and an old view's source cannot enqueue into a replacement view. This scopes application delivery; it does not reveal the physical origin time of a notification first received only after an owner change.

Pending URL changes now close action/page readiness and appear as loading. Current-document validation, untouched-session checks, observed-page handback and new claims cannot use evidence while its changes are waiting. Native callbacks process queued parent changes before examining current state; if that processing publishes a replacement owner, the old callback stops. Child policy handling also checks the parent queue before continuing under the retained login owner.

Consumption records each captured value as an unordered observation with no native-operation binding, control classification or checked policy. Persistent history keeps its existing origin-only privacy format. Overflow marks history incomplete. An idle document and its observations are invalidated even if the actual view URL has returned to its original value; the queue alone creates no same-document candidate or login-success assertion. A pending or observed exact native load retains its generation so its eventual finish can establish the new document independently. Historical navigation receipts remain historical facts.

Site presentation uses the current native URL separately from the recorded notification values. Logical invalidation precedes that publication, and subsequent status rechecks the captured context. Normal main-thread notifications continue through the immediate path when they are current and have no queued predecessor; mismatched or mixed delivery enters the unordered queue. The direct same-document path now rechecks ownership after its external control sample too.

A delivery arriving during native cleanup is retained under its exact ticket and receives another scheduled turn when cleanup ends. Registration also resumes a delivery that arrived before the new view was installed. This avoids a queue remaining busy forever after its only wake-up returned early. No polling loop or automatic navigation retry is added. Retired tickets still fail their identity check when that later turn arrives.

## Prepared cases and source checks

Six methods are authored in the main [browser test class](../../../host-mac/RemoteDesktopHostTests/ComputerUseOwnedBrowserTests.swift), all **unrun**:

1. Preserve A-to-B-to-A and nil values, coalesce scheduling, consume once, bound excess events and mark oversized values as missing.
2. Refuse owner changes over pending events; retire an old batch explicitly; ensure old tickets and retired sources cannot consume/enqueue successor events.
3. Queue intervening URLs while an idle native page still shows A. Require closed readiness, no attempted request, invalidated current evidence after delivery, retained historical receipt and original captured origins with unknown binding/control.
4. Stop/Close and reclaim the same task string. Require old unordered events before claim retirement, preservation of the new page against an old delivery and preservation of a newer queued ticket until its own delivery.
5. Process queued changes from a native callback while an exact load is still pending. Require eventual native completion, retained unordered evidence and no later mutation from the already-consumed scheduled ticket.
6. Replace the task from URL site publication. Require completed old invalidation, preserved replacement identity/status and an independent subsequent navigation.

A seventh method is authored in the existing opt-in visible class. It queues a URL during the actual sign-in child's native close notification, attempts delivery while parent Stop cleanup is active, then requires a later wake-up, ended busy state and a usable replacement. It retains `RUN_OWNED_BROWSER_VISIBLE_ACCEPTANCE` and is excluded from default/focused deterministic selectors. No case has executed. The controlled queue injections do not prove actual off-main KVO chronology, contention, real login or whole-task success.

Expected names derive from HEAD and the seven reviewed names. Eight source inventories match: [default host](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) 2012, [focused browser](browser-control-state-inventory.json) 1329, [bounded URL delivery](browser-location-delivery-inventory.json) 17, [separate visible delivery](browser-location-delivery-visible-inventory.json) 7, prior native identity 11, prior process-failure visible 6, client core 113 and pause acknowledgement 110. Both changed Swift files pass parse-only checks; whitespace checks are clean. These checks establish neither type correctness nor executed behavior.

The local documentation scan checked 248 Markdown files and 2104 local targets without missing files; anchors were not checked. The effective Git hooks directory contains no executable non-sample hooks. No build, typecheck, tests/assertions, app launch, native capture/CUA, inference/training or SSH retry occurred. The installed app and deferred performance stash remain untouched.

## Remaining repair and qualification list

1. Repair coherent UI presentation across reentrant setters and overlapping failure, page-change and task-control updates. Checks cannot undo a setter already publishing. A later URL-change status can still obscure a prior process-failure/Stop message; task state and page state need distinct retained presentation authority.
2. Qualify actual KVO delivery, source registration, concurrent enqueue/retirement, native cleanup and sustained notification pressure. Verify no lost wake-up, no indefinitely busy admission and appropriate recovery after overflow. The configured bounds are implementation limits, not measured 8 GB or thermal qualification.
3. Continue native correlation for first-seen late events and callbacks without navigation identity. A notification emitted by WebKit only after claim change is still received under the then-current owner. Missing notifications, physical event order and same-view process/response attribution remain unresolved; unordered data must not become route/source completion proof.
4. Qualify queued changes during exact observed navigation, DOM mutation, explicit login handback and process failure. Preserve uncertain effects and the original task while acquiring fresh evidence. Include provider-window changes and status/readiness interaction; no automatic replay follows from queue consumption.
5. Complete correctness work before the authorized later model and live-task phase. Natural-language travel, concert and movie tasks, actual account login/Resume, alternate-model selection and 8 GB resource behavior remain unqualified.

## Source follow-up

The [presentation state review](BROWSER_PRESENTATION_STATE_REVIEW.md) separates task retirement and page failure from URL activity, replaces reentrant scalar publication, and adds a Stop-caption expectation to the existing visible delivery fixture. Its source checks do not execute or qualify native delivery.
