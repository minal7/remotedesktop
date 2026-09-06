# Bound asynchronous semantic planning without accepting late proposals

Parent source: `1faf48a`. Status: source implementation and fixture registration only. No build, XCTest execution, model inference, application launch or computer-use activity ran. Performance optimization and real-site acceptance remain deferred.

## First-principles problem

A step-count limit cannot bound a task that never receives its next planning result. The visual executor has finite step/retry limits, observation work has a deadline and native application opening has a bounded callback wait. Its typed semantic routing await could still remain suspended indefinitely. This await can include Apple planning and a local fallback or candidate selection.

Cancellation alone is insufficient: it requests cooperation from an asynchronous API. A task-group race also does not solve a non-cooperative child, because leaving the group waits for its children. Conversely, returning a timeout and immediately releasing capacity permits retries to accumulate obsolete model calls.

The new `ComputerUsePlanningWorker` separates result delivery from ownership of the underlying call. It is restricted to proposal-only operations; it must never wrap input dispatch or other effectful tools.

## Result and lifetime rules

The production wait bound is 120 seconds for one complete semantic-routing call. This is a correctness ceiling, consistent with the existing local completion request's timeout value, not a measured responsiveness target. Tests inject short deadlines. Non-finite, non-positive and greater-than-maximum configuration is rejected before acquiring capacity.

After acquiring one permit, the worker installs a deadline on a Dispatch queue and starts an unstructured asynchronous proposal task. The task inherits task-local context, including Foundation Models provenance. No additional model prompt is introduced.

The first delivered success, failure, timeout or cancellation wins under a lock. Completion can precede continuation installation or task registration. Registration after cancellation/deadline immediately cancels the task, and a task that starts after delivery has finished declines before invoking the operation. The worker never resumes a continuation twice. It also checks the monotonic deadline before invoking the operation and again when the call returns. A delayed timer callback cannot start an already-expired call or admit an overdue response.

Timeout and cancellation cancel the underlying proposal task and return to the waiting caller without requiring that model API to cooperate. They do **not** release the permit. The permit is released exactly once, only when the operation actually returns or exits before starting. A late value is discarded. On normal success/error, the permit is released before waking the caller, allowing the next legitimate planning step to proceed without a false busy result.

Production visual executors share one process-wide worker. Recreating an executor cannot bypass an outstanding call. Test executors use isolated workers by default and can explicitly share one to exercise replacement behavior. This boundary covers visual semantic planning, not every planner in the product.

## Executor integration

Both routing awaits now use the worker:

- The ordinary per-step semantic route, including the existing deterministic continuation and paired-candidate/local fallback path.
- The restricted application-opening route used to leave an unrelated authentication screen. Its timeout propagates as a planning failure instead of being swallowed as an ordinary unavailable route. Authentication context still cannot authorize a late app opening.

An advisory availability check runs before replacing retained task progress, retiring paused state or activating a runtime. Atomic acquisition still occurs at the actual planning boundary. A busy replacement cannot activate another endpoint. A verified cached terminal result remains replayable without consulting the worker.

After a timely route returns, all existing task-binding, state revalidation, literal/target authorization, grounding, approval, editable-focus and outcome checks still apply. The original route's task-local provenance still reaches its ordinary consumer. After timeout or cancellation, no route reaches those effect paths, no history entry is added, and an obsolete completion cannot become a retained terminal result.

The worker does not reset action limits, clear effect uncertainty or automatically retry the task. Existing generation-scoped runtime cancellation and reconciliation remain in force. A cancelled operation that never returns leaves planning unavailable; retaining this state is intentional rather than accumulating more calls.

## Prepared verification

Six new worker methods specify:

1. A deadline delivered while an intentionally non-cooperative planner remains suspended, retained busy capacity, discarded late value and eventual fresh admission.
2. Cancellation delivered before that suspended planner returns, with no late result replacing cancellation.
3. Task-local context propagation and capacity release after ordinary success and planner failure.
4. Cancellation before admission, with no operation invocation or occupied permit.
5. A concurrent new caller rejected without cancelling or stealing capacity from a healthy owner.
6. An overdue response rejected by the monotonic clock even when the timer callback has not yet run.

Three new production-executor methods specify:

1. A stalled route times out with no effect; an executor replacement sharing the worker fails before runtime activation; a later stale pointer causes neither visual grounding nor input; a fresh exact typing task can run after actual planner return.
2. Stop interrupts the waiting executor despite a non-cooperative router; a busy replacement cannot erase earlier typed input; a late completion cannot terminate the checkpoint; resuming the same request presses Return without repeating that input.
3. A stalled authentication-escape route times out, and a late application-opening proposal never reaches the app opener or input tools.

The tests use controlled continuations, fake runtime transports and intercepted input. They do not invoke installed models or the desktop. Existing observation, application-open, ownership, approval and provenance methods are included in the [18-method focused inventory](planning-deadline-inventory.json). The default inventory grows from 473 to 482 methods. Project source references include both the worker and its test file; SwiftPM and project.yml already include their directories.

Source validation passes for all 482 default and 18 focused method identifiers. The Xcode project parses with `plutil`, and `git diff --check` passes. These establish registration, project syntax and whitespace consistency only.

## Remaining repairs and qualification

- Compile and execute the new fixtures after the test pause is lifted. Source registration and project parsing cannot establish Swift compilation, runtime races or actual model cancellation behavior.
- Add a whole-task elapsed/active-time policy that defines time spent paused for approval, clarification or manual takeover. A per-route deadline and step limit are not that policy.
- Review other stages, including runtime activation, native/MCP planning, visual generation, capture and synchronous native calls. Existing request timeouts do not establish a universal wall-clock deadline.
- Add capability-specific meaningful-progress and repeated-state detection. The executor can still spend its finite step budget on ineffective operations; a timeout does not prove progress.
- Qualify late callbacks, model API cancellation, cleanup and blocked executor behavior in production composition. Main-actor starvation or a blocked synchronous OS call cannot be forcibly preempted by this Swift worker. Process isolation may be needed for APIs that do not cooperate.
- Preserve dispatch uncertainty and native-open leases when adding any future deadline around effectful stages. Never treat an expired wait as proof that an input or open did not happen.
- Measure latency, model lifetime, memory and thermal behavior in the later performance phase. No 8 GB, fan-load or actual-model natural-language qualification follows from this patch. Travel, concert and movie real-site tests remain subject to the user's explicit permission.
