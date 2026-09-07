# Owned-browser viewport scrolling — source repair

Status: implemented in source; compilation and execution remain paused. This follows the active-page observation repair at ae5d387. No model, test suite, application or computer-use session ran for this change.

## Problem and first-principles boundary

Reading a long page requires changing what is visible. The preceding executor expressed a scroll as a mouse-wheel event at a host-selected screen point. That describes an input device event, not which browser object should move. A focused number field, native menu or nested scrolling surface can react differently. Sending the event also proves neither movement nor completion of a search.

The owned browser already knows its document and can inspect layout offsets. It should use that information to name the object being moved and verify the actual result. Task authority, dispatch evidence, current geometry and whole-goal success remain different facts.

This repair does **not** broaden the English operation-word gate to make “find flights” authorize arbitrary intermediate actions. It admits a bounded family of complete page-direction requests, such as “Scroll down,” “Please scroll the page down,” and “Scroll down until the Privacy section is visible.” Direction comes from the original trusted prompt. A named list/field/frame or a compound focus-and-scroll request cannot silently become a viewport operation. Those tasks need the broader compiler and container bindings below.

## Implemented source behavior

1. Page snapshots now retain layout viewport offsets, dimensions and document scroll dimensions. Geometry stays host-side; the existing planner projection and its version are unchanged. Missing/unsupported geometry permits existing page observation but grants no viewport operation. Pinch-zoomed visual viewports are excluded from this capability.
2. Fresh page validation compares viewport geometry along with the bounded page projection, exact URL, document identity and current scrolling element. A changed offset or a newer snapshot invalidates the previous binding even if all text is unchanged.
3. The fixed isolated script validates the same evidence synchronously before calling the document viewport API. It chooses one direction and at most three quarters of the viewport, capped at 768 CSS pixels. It dispatches no wheel, key, input or change event and never selects a nested target.
4. A separate map records each attempted viewport operation before dispatch. It has a 64-operation bound and survives ordinary form discovery; form discovery cannot erase viewport replay protection. Root/document replacement invalidates the old scope. Operation IDs cannot be reused with a new snapshot or direction.
5. A typed receipt records before/after offsets. The host rejects non-finite geometry, changed dimensions, reverse movement, movement on the other axis and excessive displacement. A separate script invocation re-reads the offset and checks the retained receipt, exact URL and scrolling element. This is a local movement check, not a general proof that asynchronous page activity has settled.
6. The visual executor selects this path when it has owned-browser evidence, including explicit compatibility scroll routes. Before dispatch it checks both browser evidence and the native planning fingerprint. It records possible dispatch before entering WebKit. It does not fall back to global input if the browser operation fails.
7. Cancellation, user takeover, Stop, close and authentication invalidate completion as applicable. WebKit cannot retract an already queued script, so interruption retains uncertainty rather than promising that queued work did not run. Resuming the same executor task requires reconciliation before another planner call.
8. An unchanged offset pauses for the user. It might reflect an edge, CSS snapping or a layout that cannot scroll. It does not prove the page was exhaustively read, the requested section was found or the browsing task succeeded. A verified movement creates no navigation receipt and supplies no generic semantic-effect success claim.

The implementation uses explicit instant scrolling and the browser's document scrolling element. The CSSOM View draft specifies these APIs and distinguishes viewport scrolling from element scrolling. This informs the implementation; it does not qualify the installed WebKit version. [CSSOM View: scrolling](https://drafts.csswg.org/cssom-view/#scrolling), [document scrolling element](https://drafts.csswg.org/cssom-view/#dom-document-scrollingelement).

## Prepared verification

Six authority/DOM methods cover complete request scope, receipt boundaries, all four directions, CSS smooth scrolling, focused numeric and choice controls, nested containers, unchanged text with changed geometry, newer snapshot nonces, no movement, replay protection after form discovery, cancellation/takeover/Stop/close and an authentication barrier appearing before dispatch.

Two executor methods cover the production owned-browser path with a stub router and forbidden global input: movement remains separate from task completion; no movement pauses; a nested-container request is declined; and an interrupted dispatch cannot replan or replay on the same task.

The [focused inventory](browser-viewport-scroll-inventory.json) selects **147** source methods. The default inventory selects **657**. Both inventory checks, syntax-only parsing of seven changed Swift files, embedded JavaScript syntax and whitespace checks pass. **No assertions executed.** These checks do not establish Swift type correctness, WebKit event ordering, rendered behavior, real planner output or live-site success.

## Follow-up repair list

1. Compile whole browsing requests into source-bound roles, constraints, permitted intermediate capabilities and result predicates. This must make ordinary research prompts useful without treating website text or a model proposal as authority. Replace the narrow viewport request binder only with that task-level proof.
2. Add native link activation and form submission contracts. Bind destinations, selected controls, submitter semantics and uncertain effects; keep independently observed result pages separate from action receipts.
3. Add explicit nested-container/frame contracts and support for custom widgets where required. Do not substitute page movement for a named scrolling surface. Qualify RTL, pinch zoom, scroll snap, virtualized results and delayed lazy loading separately.
4. Preserve capability receipts and remaining-goal state through login, approval, clarification and process restart. This repair preserves the current executor's in-memory uncertainty; the viewport operation map lives in the current document and is not a durable task journal.
5. Verify complete results: identity, dates, locations, availability, counts, prices/fees and selected public sources. Movement and static text coverage do not establish exhaustive result sets or ticket availability.
6. When authorized, compile and execute the controlled regressions, then qualify actual host/browser control handoff and provider behavior. Keep the real travel/concert/movie scenarios deferred until explicit permission. Performance optimization and physical 8 GB/thermal qualification remain in their later phase.
