# Reuse browser account state under a new research root

Source checkpoint: changes based on `b83fd45`. This is implementation plus prepared verification, not an executed browser/runtime qualification.

## Problem and first principles

The previous first-search stage could dispatch only in an unused browser. A new research request could therefore fail when a previous task's page remained open. Closing/recreating that browser would discard account/session state. Simply changing its task ID would erase evidence without establishing which page the new task actually owned.

Browser state and task authority have different lifetimes. The native view and its website data can outlive a task; that task's operation, handback and action-receipt authority cannot. A new request needs a fresh observation of the actual retained page and its own ownership epoch. A cancelled operation must finish unwinding before a replacement research owner can take its place. A fresh observation is not proof that a previous navigation succeeded or that the new goal has been completed.

## Implemented source path

The browser navigation coordinator now supplies a weak admission capability to the research owner it actually retains. Each admission is bound to that exact owner object and a private, live owner-operation identifier. The coordinator checks both before and during native admission. Equal task text, another coordinator, a fabricated identifier or a retired owner cannot acquire this capability. Replacing an owner whose operation has not unwound returns busy; the host's existing execution barrier already joins the predecessor before activating the successor's action gate.

Native admission preserves the WKWebView and website data store. For an unused view it captures the existing empty session; it does not navigate. For a populated HTTP(S) view, it requires no pending native/DOM/navigation work or loading page, and no open sign-in child. It presents that same view for the explicit new request, bounds the focus wait, and reads the actual document's isolated-world identity without reading form values.

The read is guarded by cancellation, the owner's admission identifier, native view identity, prior ownership epoch, generation, URL, presentation and a monotonic URL/navigation revision. That revision also changes when no task document exists, so a location that changes away and back cannot satisfy an earlier admission snapshot merely because its final URL matches. Stop/close/reclaim during the read invalidates it.

Only after the read passes does admission claim the new task and create `taskAdmissionObservation` evidence. The document is absent from action receipts, and changing owners clears earlier task receipts and native observed-action attempts. The loaded identity supports subsequent history observation. Cookies and session storage remain in the actual retained native browser. Admission can inspect a completed retained DOM after Stop cleared the old task's document; it makes no claim about the old task's outcome. An unavailable, invalid, still-loading or non-DOM page is not silently replaced with a new empty session.

Research planning admits an existing browser before asking the goal/query model, then runs the normal page/authentication observation. Thus an old login form hands control to the user before inference. Text-only planning with no allocated browser still creates no browser. The owner records a completed native admission before subsequent authentication can require another handback, retaining the new root and original clock.

Busy, inactive, changing or unresponsive admission raises a sealed admission-pause error. The host retains the current goal and owner for explicit Resume without requiring a session that has not yet transferred. This avoids turning temporary browser admission into a terminal failure. If Pause interrupts admission before ownership transfers, explicit Resume may retry the still-current admission through the same coordinator/owner capability. It cannot substitute an owner or overwrite a later Pause. Once a session has been captured, normal sealed same-session handback applies; admission is not a way to revive a stopped research root or replace a lost captured session.

Initial search now also accepts an admitted, observed starting document. Its durable binding includes that native document and isolated-world identity. Before dispatch it verifies the same native document and reads authentication again. It then passes the exact document prerequisite to native navigation, which rechecks after the durable attempt callback. The original unused-session path remains available.

The starting binding deliberately excludes transient page-snapshot IDs. A normal handback creates a fresh snapshot even when the actual document is unchanged. Binding the action to that read nonce would strand a legitimate planned search after Resume. The action instead retains only document identity, while reading current authentication again. A real document/location change still invalidates a planned stage; attempted/verified stages remain receipt-only recovery. Provider/query authority still comes from host selection and the full canonical goal, not page controls.

## Prepared verification and actual checks

Eleven new methods prepare:

- Successive research roots reusing a live or stopped browser, preserving cookie/session-storage state, issuing one search per root and rejecting earlier handback/receipt authority.
- An existing login form stopping before inference, followed by explicit handback and search under the same new root and clock.
- Pause during admission leaving the previous browser owner in place until explicit Resume, with replacement blocked while the actual operation unwinds.
- A busy previous load settling before explicit admission Resume continues the same new goal.
- A retired predecessor whose planner temporarily ignores cancellation remaining an exclusion barrier until it returns.
- Stop and close during the document identity read preventing ownership transfer and model invocation.
- A real location change during Pause leaving the original planned search binding intact and dispatching no request.
- Unchanged handback plus fresh snapshots continuing the same planned search and durable identity exactly once.
- Coordinator/owner/operation admission checks without allocating a browser for invalid callers.
- Host preservation of the paused goal when a previous browser is busy before admission, with no terminal answer or model invocation.
- Actual host/capability routing from a completed native page-open request to a new research request, visible login handoff under the new task's controls, and a retained goal question after explicit Resume without reloading the login page.

The [focused source inventory](browser-admission-inventory.json) selects 168 methods. The default selects 857, eleven more than the parent. The new test file is registered in the Xcode target. Seven changed Swift files pass syntax-only parsing; project syntax, five fixture scripts' syntax, both source inventories and whitespace checks pass.

**No typechecking, test/assertion execution, builds, model inference, app launches, browser/computer-use activity or live E2E ran.** Prepared cases are not runtime evidence. The installed app, model/runtime assets and historical qualification evidence remain unchanged. About 15 GiB was free; no obsolete generated-file cleanup was needed.

## Remaining repair sequence

1. Implement explicit refresh of a proven-unsent initial-search starting document after an actual login redirect/page change. Keep query/provider/goal and operation identity retained under the execution lease; attempted/uncertain actions must still reconcile rather than redispatch. An unchanged handback already has a source path in this repair.
2. Select a provider/site consistently with the complete user goal and source restrictions, then implement the concrete driver and default-loader composition. Neither this admission capability nor a first navigation establishes research relevance or completion.
3. Complete additional search/form/date/choice actions, the ordered action ledger, offer/date/availability/price/fee verification, cross-page accumulation and qualified final links/answers.
4. Qualify admission and manual-control transitions, including visible focus behavior, URL changes while reading, pending navigation, active sign-in windows, failed/non-DOM pages and login during an unanswered question. Active login children keep the existing control-scope rules; this repair does not transfer an open popup to another task.
5. After explicit permission, compile and execute controlled owner/host/driver/runtime cases, then exercise travel, concert and movie scenarios on real websites. Current model prompts, live site behavior and performance/8 GB/thermal behavior remain unqualified; performance work is deferred.

Related checkpoints: [initial search](BROWSER_INITIAL_SEARCH_REVIEW.md), [empty-session handback](BROWSER_EMPTY_SESSION_REVIEW.md), [research routing](BROWSER_RESEARCH_ROUTING_REVIEW.md), [research replanning](BROWSER_RESEARCH_REPLANNING_REVIEW.md) and [retained owner](BROWSER_RESEARCH_OWNER_REVIEW.md).
