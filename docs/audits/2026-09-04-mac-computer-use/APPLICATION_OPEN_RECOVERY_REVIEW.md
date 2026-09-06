# Application-open interruption and recovery

Status: source implementation and regression registration only. Builds, tests, models, app launches and computer use remain paused. Performance optimization and the user's real-site scenarios remain deferred.

## Findings

All three visual app-opening paths awaited an opener without setting `effectNeedsReconciliation`: normal semantic/explicit actions, delivery browser preflight, and escape from an unrelated authentication screen. An opener can change the desktop and then fail, be cancelled, or return a process whose identity fails validation. An error does not establish that no effect occurred.

The pure-open path also returned before recording action history and progress. If cancellation arrived after the app opened, the outer loop discarded its completed result. A later call with the same task identity could open the app again. Intermediate opens needed their successful progress retained before the next cancellable delay.

The native Launch Services callback wait had no cancellation handler or deadline. Stopping the model did not end that wait. Merely making the wait cancellable would be insufficient: the OS operation could still finish later, so interrupted state must survive the early return.

## Implemented behavior

- Each visual app-open dispatch marks an attempted effect before awaiting the opener. A shared synchronous recorder writes the opened identity, exact history marker and action count, resets the per-effect planning state, then clears uncertainty. Pure-open tasks use the same recorder before returning completion.
- Terminal results are retained immediately after the loop returns, before cancellation is honored. The cancelled call still throws cancellation and joins its runtime cancellation. A later unchanged task can return the retained result without activating a model or repeating the effect.
- A failed or interrupted open whose success was not recorded retains the existing reconciliation requirement. Same-task resume asks for the current state before observation, activation or another action. Authentication-escape failure still pauses at the sign-in boundary; it no longer leaves ambiguous opening outside recovery state.
- The native callback bridge has one result slot protected by a lock. Completion, error, cancellation and the 30-second deadline compete to fill that slot once. Late or duplicate callbacks cannot resume the waiter again or replace its result. A successful callback that wins before cancellation remains available for the executor to record.
- A process-local native-open lease remains occupied until the exact OS callback settles, even after cancellation or timeout ends the wait. Every host-tool action gate includes that lease, preventing a new task from typing or opening another app while an old activation can still arrive. Stale callbacks cannot release a newer lease.
- Cancellation and the action gate are checked during admission and immediately before the production Launch Services call, after static application identity validation. These checks do not retract an operation already dispatched to macOS.

## Source regression coverage

One executor method covers four paths (pure open, an open followed by typing, delivery preflight and authentication escape) under four outcomes: success returned after cancellation, failure after cancellation, ordinary late failure, and cancellation of the production callback bridge before its native callback arrives. The 16 combinations assert the exact open/input prefix, retained progress or reconciliation, and no new observation/inference for a retained terminal or uncertain result.

Four host-tool methods cover cancellation before/during admission, takeover before dispatch, completed effects during cancellation, prompt cancellation without a native callback, success winning before cancellation, duplicate/late callbacks, deadline expiry, callback/start failures and invalid deadline bounds. Their assertions also check that cancellation retains the native-open lease, both existing and newly created host tools reject new input/opening until settlement, stale callbacks cannot release a replacement lease, and settlement cannot reopen the user's closed gate. They use intercepted callbacks and synthetic values; they do not open real applications.

The [focused inventory](application-open-recovery-inventory.json) selects 29 methods, including existing lifecycle, identity-spoofing, app-routing and authentication tests. It and the 437-method default inventory match source. `git diff --check` passes. None of the new code or tests has been compiled or executed.

## Remaining repairs and qualification

This preserves state within the retained visual executor. It is not a durable receipt across host termination, nor a complete step/target contract. The existing opener's process/code identity checks remain the definition of a successful open here; native focus and window behavior still need qualification.

The deadline bounds the callback wait, not the earlier synchronous bundle/code verification. The OS can finish an already dispatched open after cancellation or timeout. Automation remains paused until that callback settles; an indefinitely missing callback cannot be safely treated as completion. The executor deliberately retains uncertainty in that case rather than retrying or claiming that Stop undid the operation. An opaque pre-dispatch failure may also require reconciliation until adapters provide reliable no-dispatch evidence.

Whole-goal compilation, repeated inputs/submissions, target-bound receipts, browser result predicates and durable recovery remain open. These repairs do not qualify travel, concert or movie workflows, fan behavior or the 8 GB target.
