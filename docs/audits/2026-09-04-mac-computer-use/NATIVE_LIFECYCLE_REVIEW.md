# Native AX lifecycle observation

Parent source: `26c6f0a`. Status: source implementation and regression registration only. No build, tests, inference, app launch or computer-use action ran. Performance work and real-site acceptance remain deferred.

## Why another snapshot is insufficient

An AX object can still answer with the same value and label after its context changed and returned. Snapshot equality only establishes equality at the observed times. The preceding native reference and clarification repairs retired changes discovered during reads; they had no event source to retain evidence of changes between reads.

The adapter now owns a lifecycle monitor for its current application identity. Switching the observed application, losing it, or releasing the adapter cancels that monitor and retires its references. A new application scope cannot consume the old monitor's callbacks. Fresh value/selection reads and explicit expected-reference setters remain mandatory.

## Event source and ownership

`ComputerUseAXLifecycleMonitor` creates an application-specific AX observer, registers on its application root and attaches its source to the main run loop's common modes. Workspace activation/deactivation events also invalidate context; termination/hide events are filtered to the observed process. Registration results and observer-creation errors remain available as explicit state instead of being converted into proof that nothing changed.

The installed Apple SDK documents application-root subscriptions as receiving notifications from the application's elements, including elements not yet discovered. Registration can return unsupported or transport errors; successful registration alone does not prove complete event delivery. See [Apple's notification registration API](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification) and the installed SDK's `HIServices.framework/Headers/AXNotificationConstants.h`.

The C callback uses a nil `refcon`. A locked registry maps the live observer's object identity to a retained, bounded inbox. It does not dereference an unowned pointer into the adapter. Registrations carry a separate nonce so stale cleanup cannot remove a replacement entry. Cleanup removes the registry entry and closes its inbox before removing/releasing the observer source and unregistering workspace callbacks. A callback that already copied the inbox also encounters its closed state. The monitor owns no adapter, preventing an observer/adapter retention cycle. Apple documents removal of the source when an observer is released, and explicit source removal is supported. See [observer run-loop lifetime](https://developer.apple.com/documentation/applicationservices/1459139-axobservergetrunloopsource).

## How events affect authority

| Event | Reference behavior |
| --- | --- |
| Application/window context, creation, layout or row-structure change | Retire the application's current bindings. A changed form cannot reuse a former plan. |
| Title change | Retire bindings mentioning that element, window, document root, ancestor or label object; an application-root event retires all. |
| Value change on a label object | Retire fields whose meaning depends on that label reference, even if the label has already returned to its old bytes. |
| Value change on a bound enclosing context | Retire fields mentioning that window/document/ancestor; an application-root event retires all. A context value is not treated as an edit to the field itself. |
| Ordinary editable-field value change | Keep the field identity; the existing exact value/selection preconditions determine whether the edit is still valid. |
| Focused text control or selected text change | Do not subscribe as identity changes. The native editor already validates focus/selection, and its own focus/selection operations must remain possible. |
| Destruction | Retire bindings mentioning the object and retain its handle only as a local tombstone. No subsequent AX read, settable check, timeout or write may use it. |
| Lost event coverage through queue/tombstone overflow | Retire bindings and stop AX observation in that application scope. A drain cannot erase the loss. |

Every AX boundary drains delivered events before calling the system. Reads and capability queries also drain afterward. Observation revisions reject a snapshot or discovered field set assembled across an event. The final write boundary rechecks that its exact binding remains live. New explicit observations can create new IDs after ordinary invalidation; destroyed handles cannot regain authority by exposing restored attributes.

The review also corrected label-source ownership. Explicit title, description and placeholder labels are checked in order. A title object's value is read and its reference retained only when that object actually supplies the planning label. Otherwise an unused title object could invalidate a field unnecessarily, including a self-referential title object making the field's own text edits appear to change its meaning. Protected/editable title-object values remain excluded.

The destruction rule follows Apple's SDK warning: a destroyed object's local reference can be compared with `CFEqual`, but must not be passed back to accessibility APIs. Event handling makes no AX query on a destruction payload. The pending inbox is bounded to 256 events, and destruction tombstones to 1,024 per observed application scope. Overflow stops that scope because silently discarding a destruction event could permit an invalid later AX query.

## Prepared verification

Eight new methods exercise the actual adapter, event mapping, callback registry and inbox through the injected AX graph:

- Six structural/context notification variants retire old IDs despite identical current attributes; a fresh explicit observation remains usable.
- Destruction of the destination, label, ancestor group, window or application produces no subsequent AX boundary call on the destroyed handle, including after restoring fixture attributes.
- Ordinary value, focus and text-selection events preserve valid field identity; a label-value event retires its dependent field while preserving an unrelated field, and a window-value event retires both fields.
- An unused or self-referential title object cannot invalidate a field with its own explicit label, and the unused object's value is never read.
- Events during value/title/identifier observation or a settable query stop before input and cannot produce a snapshot with old authority.
- Production native task planning and scoped clarification reject lifecycle changes before journaling, input or answer planning.
- Application scope replacement cancels its monitor, late old callbacks cannot affect the new scope, and event overflow prevents further AX queries.
- Registry replacement, stale cleanup, ignored notification types, post-close delivery and persistent overflow are checked independently of adapter return values.

The fake graph records reads, capability checks, timeouts and writes; it does not invoke system AX operations. Local opaque CF handles identify fixture objects. The registry fixture uses an `NSObject` callback source rather than creating a system observer. These methods have not compiled or run.

Lightweight checks: `git diff --check` passes; `plutil -lint` accepts the Xcode project containing the new source; the [139-method focused inventory](native-lifecycle-inventory.json) and 457-method default inventory match exact source identifiers. SwiftPM already includes the computer-use source directory. These checks do not establish Swift compilation, native observer installation, callback timing, app compatibility or runtime correctness.

## Remaining qualification and repairs

1. **Notification coverage remains incomplete evidence.** Apps may reject registrations, omit events or deliver them late. Unreported role, identifier, document or label reuse still requires capability-specific qualification; no universal same-object-generation guarantee is claimed. The current monitor supplements snapshot checks when coverage is partial. It does not mark unsupported subscriptions as successful or claim to make them reliable.
2. **Main-run-loop delivery is not an atomic barrier.** Only delivered events are drained. An OS event can still be queued or occur after validation and before/during a write. Real app fixtures must qualify ordering, reentrancy and late events. Exact readback, uncertainty and non-replay remain required, and independent native input receipts remain open.
3. **Actual lifecycle cleanup is unexecuted.** Qualify system observer registration, workspace notifications, adapter deinitialization, window switching, permission revocation, process restart and callback cleanup once execution is authorized. The registry fixtures do not substitute for those checks.
4. **Conservative invalidation needs app qualification.** Layout and creation events retire the current form, including events that ultimately leave the same controls visible. Ordinary text state does not. Real AppKit/WebKit behavior must determine whether normal input emits structural notifications that require a more precise proven mapping.
5. **Resource measurements are deferred.** Registration time, observer/inbox/tombstone residency and AX observation cost need measurement in the later performance phase. No fan, thermal or 8 GB qualification follows from this source repair.
6. **Whole-product work continues.** Complete semantic plans, visual step receipts, future controls, browser submissions/results, mobile transport and travel/concert/movie workflows remain open. No live-site testing is authorized by this checkpoint.
