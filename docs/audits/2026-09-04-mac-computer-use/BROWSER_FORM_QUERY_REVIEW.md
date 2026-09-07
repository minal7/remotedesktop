# Native form queries — source capability

Status: source implementation after 61b9914. The normal natural-language router does not yet select this capability. Compilation, test execution, models, apps, computer use and real websites remain paused.

## First-principles finding

A form is a collection of values and submission rules, not merely the visible fields near a Search label. Two submit buttons can use different destinations or methods. Checked state, selected options, hidden server fields, controls outside the form element and the order of repeated names all change the resulting request. An unchanged page-text projection cannot prove these values are unchanged.

Reading a prospective request must also be separate from executing site code. Constructing a native `FormData` object can fire a page event. Calling `requestSubmit` can validate fields, fire events and invoke handlers that change the request or perform other effects. Those operations are unsuitable as supposedly effect-free observation. The HTML Standard defines both the entry list and these events. [Constructing the entry list](https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#constructing-the-entry-list).

## Implemented source behavior

1. `prepareFormQuery` accepts an observed submit control ID and its exact page evidence. It reads native form ownership, submitter overrides and the complete bounded native member collection without constructing `FormData`, calling validation methods or firing events. Named controls such as `action` and `elements` cannot shadow the native form getters used by the adapter.
2. This capability represents a UTF-8 HTTP(S) GET query in the current browser and the source page's origin. It supports native text/scalar controls, checked checkbox/radio values, selected enabled options, duplicate names, hidden server state and externally associated native members in native collection order. Disabled controls contribute no values; unnamed controls and other submit buttons contribute no entries. Fieldsets and outputs do not become entries.
3. Password/file/image inputs, credential or payment autocomplete metadata, unsupported custom members, `dirname`, hard-wrapped textareas, non-UTF-8 encoding, POST/dialog methods, cross-origin actions and other target contexts decline. These cases remain on the repair list; they are not reinterpreted as a smaller valid query. A visible authentication barrier still triggers the existing handoff error before value inspection.
4. Native validity flags are read without firing `invalid` events. An invalid form cannot become a query target unless its observed `novalidate`/`formnovalidate` rule explicitly bypasses client validation. That bypass does not prove that the user's values or goals are correct; the task driver must verify them separately.
5. Names and string values receive CRLF normalization and URL encoding. Hidden `_charset_` matching is ASCII case-insensitive. GET replaces the action's query, preserving its fragment and an explicitly empty query; its encoding does not use the form's POST enctype. These details follow the standard's GET branch and entry-list rules. [Form submission algorithm](https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#form-submission-algorithm), [entry-list construction](https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#constructing-the-entry-list).
6. A private prepared query binds actual form/member objects, submission metadata, current state, selected options, the exact encoded destination and the current snapshot nonce. Revalidation repeats the complete read. Property-only changes to values or selections cannot hide behind an unchanged public page projection. Removed/reinserted members, changed association/attributes and superseding observations retire the reference.
7. Page snapshots now also retain exact native control/form object bindings. Existing page-validation callers compare these identities, complementing the previous link-object repair. This does not turn page metadata into value authority.
8. `ComputerUseBrowserNavigationTarget` and `ComputerUseBrowserNavigationReceipt` now cover both links and form queries. Their payload identities include the source kind. A link and a form query with equal destination URLs are distinct bindings and cannot reuse one operation ID as a second effect. Host tools expose preparation and the common `openObservedDestination` path; model input remains unchanged.
9. Opening a prepared query uses the existing native loader and its ownership/presentation checks, persist-before-dispatch callback, bounded in-memory attempt map, exact navigation receipts and late-confirmation handling. Interrupted or uncertain operations cannot silently replay. Confirmed historical navigation remains separate from task completion and current document state.
10. Query destinations can include private input and server state. They stay in the adapter and its private target; standard descriptions expose only site identity. The planner still receives the existing bounded metadata projection, with no current values or encoded query. The query reply decoder checks bounded IDs, URL size, supported scheme and absence of embedded credentials; the host checks origin again.

The bounds are 128 native members, 128 options per select, 128 entries, 64 KiB of retained state, 8 KiB of encoded destination and eight prepared queries per current snapshot. Collections are bounded before copying. New snapshots clear prepared query references. These are implementation limits, not performance qualification.

## Explicit semantic boundary

This opens a captured native query destination. It does not execute DOM submit, click, `formdata` or `invalid` events and does not implement a website's JavaScript-driven submission behavior. Native navigation is not proof that site handlers, client-side state transitions or form-specific CSP/referrer behavior occurred. Those need separate execution contracts and qualification. GET alone also does not establish that a server operation is harmless; the task compiler must authorize the selected action and exact values.

Preparation binds the state that was observed. It does not establish that the state matches every clause of the user's request. Before using this capability, the whole-task driver must compare the query's fields with the task's intended final values, preserve other constraints, journal the operation and verify the returned results. This integration remains unfinished.

## Prepared verification

Seven new fixture methods cover:

- Exact request entry order, duplicate selected options, disabled-fieldset handling, hidden encoding/server fields, external members, DOM named-property collisions, submitter overrides and absence of form events during preparation/navigation; confirmed replay sends no second request.
- Changed text/hidden values, selected/checked state, replaced/reinserted fields, changed names/destination and a superseding snapshot, all blocked before native dispatch.
- Unsupported method, context, encoding and protected controls, without producing an executable target.
- Validity inspection without `invalid` events and a separately observed no-validation override.
- Authentication or lost user control after preparation, before dispatch.
- A shared no-replay boundary for different source kinds with equal destination URLs.
- Empty query preservation and malformed/oversized private reply bindings.

The existing eight link methods now use the common navigation target/receipt path, retaining coverage for Pause, Stop, close, cancellation while loading and late receipts. The [focused inventory](browser-form-query-inventory.json) selects **162** methods. The default source inventory selects **691**, seven more than the previous 684.

Five changed Swift files pass syntax-only parsing. Embedded JavaScript syntax, both source-inventory checks and whitespace checks pass. **No assertions ran.** Type correctness, actual WebKit event ordering and installed behavior remain unverified.

## Remaining repair sequence

1. Integrate the whole-browser compiler and driver around the complete original request. Bind desired values, available capabilities, intermediate authority, required results and user approvals. Neither a GET form nor a query target can supply this task authority.
2. Bind prepared query state to the exact form-edit contract, then journal and reconcile navigation through the generic durable task engine. Nonpersistent browser references cannot substitute for restart recovery or preserved remaining goals.
3. Implement DOM submission and site-driven behavior separately, including POST bodies, validation events, submitter semantics, custom fields/widgets, cross-origin approvals and CSP/referrer qualification. Preserve uncertain effects instead of silently switching transports.
4. Continue the same task after visible login takeover and explicit handback, with fresh page/account evidence and complete result verification.
5. Verify travel, concert and movie results against dates, locations, availability, counts, prices/fees and selected public sources. A completed query navigation is only an intermediate fact.
6. After explicit permission, compile and run controlled regressions before the deferred real-site scenarios. Installed host/phone behavior, local model quality and 8 GB/thermal qualification remain open.
