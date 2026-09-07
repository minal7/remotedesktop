# Observed browser link destinations — source capability

Status: source implementation after 4239b6b. The current natural-language router does not yet select this capability. Builds, tests, models, applications, computer use and live-site runs remain paused.

## First-principles finding

A link label is neither a unique target nor a navigation receipt. Two links can share a label but open different documents. A new element can copy both the old label and URL while changing its behavior. A completed navigation also does not establish that the requested tickets, dates, prices or comparison have been found.

The existing page snapshot already contained observed link IDs, labels and resolved destinations. Its freshness check compared the serialized projection, URL and viewport. It did not retain the actual anchor objects or navigation attributes. Consequently, an identical replacement, a remove/reinsert cycle, or changed target/download behavior could survive the same label-and-URL comparison used around planning and visual approval.

The browser also lacked a host-bound capability for opening a selected observed destination. Replacing a pointer click with an arbitrary model-supplied URL would lose the relationship to the page evidence. Treating native URL loading as DOM click activation would also be wrong: click handlers, downloads, form submissions, popups and fragment routers have different effects.

## Implemented source behavior

1. Page snapshots retain an internal map of observed link IDs to anchor objects, inherited target-base objects and navigation-attribute signatures. These bindings stay in the isolated script world. The model's bounded page projection and its version are unchanged.
2. Page revalidation compares those objects and signatures in addition to the existing projection, document, exact URL and viewport checks. The mutation observer retires old evidence when a retained link is removed or its observed attributes/ancestry change, including change-and-restore cycles. A new observation nonce still supersedes the old snapshot. This strengthening applies to existing page-validation callers, including visual approval.
3. `prepareLinkNavigation` selects one exact observed link ID and revalidates it without effects. It returns a host-created target whose payload digest binds the browser context, task, generation, document nonce, snapshot nonce, link ID and exact destination. Duplicate labels do not collapse into one target. Neither model-authored URLs nor fabricated target constructors enter this interface.
4. The capability opens a supported HTTP(S) document destination in the current owned browser. Download links, hyperlink pings, other browsing contexts and same-resource fragment routing are excluded. Their distinct behavior needs separate task capabilities. The prepared target and receipt use site-only standard descriptions; raw destinations remain host-side.
5. `openLinkDestination` repeats DOM validation, then checks browser ownership, presentation and source document at native dispatch. A newly observed authentication barrier returns the existing login handoff error. Pause, Stop, close or cancellation during validation prevents the native load.
6. The browser retains the operation's attempt before loading. The caller can record possible dispatch at this boundary; control and cancellation are checked again afterward. Reusing an operation with another target fails. An uncertain attempt cannot dispatch again. The adapter holds at most 64 such attempts in the current owned context.
7. Successful native loading produces a typed receipt binding the target payload to the existing exact `WKNavigation` receipt. Replaying the confirmed occurrence returns that historical fact without a second request. A subsequent page observation uses the actual loaded document. Neither fact proves whole-task completion or current login state.
8. Cancellation can arrive after `didFinish` established a navigation receipt but before document-identity observation returns. The link operation retains that receipt while still throwing the interrupted caller's error. A later reconciliation can read the retained fact; it cannot retroactively complete the stopped task.
9. The capability is forwarded through `ComputerUseBrowserNavigationTask` and host tools for use by the broader task compiler. No new English command parser or model tool has been added. Existing pointer routes continue to use their current policy, approval and grounding path.

Opening an observed destination uses the native loader. It does not dispatch link event handlers and must not be presented as proof that a DOM click or JavaScript-driven site action occurred. The destination is frozen at preparation; final validation checks the source before opening that exact URL, rather than following whatever URL the site might assign afterward. WebKit/page activity is asynchronous, so this is not a claim of an atomic browser-wide transaction.

The HTML Standard distinguishes target selection, download behavior, hyperlink auditing and referrer policy. It also makes an explicit anchor target, including the empty value, override the first document base target. The source guard preserves that distinction; the fixture includes an empty-target override under a `_blank` base. These standards inform the capability boundary without qualifying the installed WebKit implementation. [Hyperlink processing](https://html.spec.whatwg.org/multipage/links.html#following-hyperlinks), [element target selection](https://html.spec.whatwg.org/multipage/semantics.html#get-an-element's-target).

## Prepared verification

Eight new DOM fixture methods cover:

- Exact selection among duplicate labels, distinct target digests, host-only URL descriptions, native navigation, fresh result-page observation and confirmed replay without another request.
- Download/ping/target/fragment exclusions, unsupported script URLs, fabricated link IDs and another browser context attempting to use the reference.
- Identical clones, remove/reinsert, changed-and-restored URL/target/style, changed download/ping/base attributes and superseding snapshots, with no navigation attempt from stale evidence.
- Pause, Stop, close and cancellation during the final DOM validation, before a native attempt.
- Control loss at the dispatch callback, retaining uncertainty even when the subsequent control check prevents loading.
- Interruption while a local response is held, with no returned success and no request replay.
- Cancellation during post-load identity observation, retaining the truthful late receipt while the interrupted invocation still fails.
- An authentication barrier appearing after target preparation, requiring user handoff before loading the destination.

The [focused source inventory](browser-link-navigation-inventory.json) selects **155** methods, including existing owned-browser navigation, handback, page-evidence and scrolling coverage. The default inventory selects **684**, eight more than the preceding 676.

Syntax-only parsing of five changed Swift files, embedded JavaScript syntax, both source-inventory checks and whitespace checks pass. **No assertions executed.** These checks establish neither Swift type correctness nor WebKit callback ordering, real planner behavior or live-site success.

## Remaining repair sequence

1. Build and integrate the whole-browser task compiler. It must bind the original request's destinations, entities, dates/locations, permitted intermediate operations and complete result requirements. A page link is contextual data; the task supplies authority to navigate it.
2. Connect these prepared targets to the generic task execution contract, fresh predicates and durable step journal. The current in-memory attempt map protects one owned context; it does not replace cross-process recovery, persisted remaining goals or durable uncertain-effect reconciliation. The source target nonce changes on reobservation and must not become a retry nonce that grants a new effect.
3. Add separate contracts for DOM link activation, search submission, submitter overrides, custom widgets, fragments and additional browsing contexts. Do not use native URL loading as a substitute when a requested site action depends on event handlers or submitted form values.
4. Preserve verified progress across login takeover and explicit handback, then rebind page/account observations before continuing. Runtime provider compatibility and full post-login goal continuation remain open.
5. Verify complete research results: identity, dates, locations, availability, counts, prices/fees and reviewed public source links. A navigation receipt or newly loaded page supplies only an intermediate fact.
6. After explicit authorization, compile and run controlled regressions before the deferred travel, concert and movie scenarios. Installed host/phone qualification and 8 GB/thermal qualification remain outstanding.
