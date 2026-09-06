# Bound native and MCP proposals and join MCP cancellation

Parent source: `f4f66a0`. Status: source changes and fixture registration only. No build, XCTest execution, model inference, application launch or computer-use activity ran. Performance optimization and real-site acceptance remain deferred.

## First-principles problem

A proposal has no authority after its caller has timed out or stopped. Returning to the caller also does not mean the underlying model call has finished. The preceding [visual planning repair](PLANNING_DEADLINE_REVIEW.md) separated those two events, but native text and structured MCP planning still awaited their planners directly.

There are two distinct ownership problems after interruption:

- An exact clarification answer must retain its original task, form and expiry if only planning was interrupted. Discarding it makes an otherwise valid retry impossible; accepting a different answer or renewing its expiry invents authority.
- MCP helper cleanup is asynchronous. Starting cleanup without retaining and joining it lets an executor report itself idle before its own cleanup finishes. The real client pool already rejects cancellation for a stale process generation; this repair does not claim that old cleanup was proven to kill a newer generation. It makes ownership and completion of that cleanup explicit within an executor.

A third problem appears when Stop invokes `cancelMCPWork()` without independently cancelling the surrounding Swift task. Task cancellation checks alone then do not invalidate a late proposal. An expired helper generation must not publish an approval or request visual fallback merely because the model eventually returns.

## Proposal boundary

Native text planning and each MCP planning step now use the existing `ComputerUsePlanningWorker`. Production native, MCP and visual executors share its process-wide permit. Each proposal has the same 120-second ceiling. That ceiling is a correctness bound, not a measured response-time target or a whole-task budget.

The worker returns a timeout or task cancellation without waiting for a non-cooperative planner, discards its eventual response and retains capacity until that exact call exits. It preserves task-local context. No AX write, browser edit, helper operation or approved action is placed inside this worker.

MCP checks planning availability before starting its structured helper session and discovering tools. Atomic acquisition still occurs at the proposal itself; the early check is advisory. A planning timeout, occupied permit or invalid deadline propagates explicitly and cannot enter the generic Mail or visual fallback handlers.

Existing fully specified native text, browser navigation, app opening and deterministic Mail routes still follow their ordinary capability-specific paths. They do not require a new model proposal. In particular, a complete native text command can execute while an obsolete native proposal is still blocked, because that obsolete result can no longer reach the edit path. This does not bypass target, journal, approval or action checks.

## Clarification ownership

A native clarification answer remains prepared after `busy` or `timedOut`, as it already does after cancellation or manual interruption. Only the exact answer task, originating task and full goal can retry. The previous question remains consumed.

Retry does not extend the original expiry, replace the form scope or reuse old field values. It checks expiry and scope, observes current fields and invokes a new proposal only when the worker is actually available. Existing checks after planning and before execution still apply. A changed field purpose, expired question or invalidated reference cannot regain authority through a timeout. A completed retained task still replays its result without writing again.

## MCP cleanup and execution ownership

`MCPGenerationCancellationJoin` stores one asynchronous cancellation task for an exact helper process generation. Its lock makes concurrent calls from Stop and a Swift cancellation handler idempotent. The executor retains this join instead of scheduling an untracked cleanup task on each request.

Ordinary execution, approved MCP continuation and approved visual continuation reject overlapping entry on the same executor. An ordinary new request and a visual continuation wait for already-started helper cleanup before continuing. The current owner stays active while its cleanup is awaited. Fresh helper generations receive their own join; existing client-pool generation validation remains in force.

Structured work checks both Swift task cancellation and whether its helper generation has been stopped: before tool discovery, after discovery, before and after proposals, after preparing an approval and after reading a tool result. A stopped generation cannot publish that preparation, turn a late response into completion or use a late failure to enter fallback. Cleanup is joined on this cancellation path even if the caller did not separately cancel the Swift task.

An approved operation stays outside the proposal worker. Its prepared approval is consumed once. If the helper returns a successful result despite concurrent cancellation, the executor preserves that result and joins cleanup before returning it. Turning an already-returned effect result into an apparent unperformed action would encourage duplication. This preserves existing process-local approval behavior; it does not add a durable dispatch receipt or infer success when the helper supplies no successful result.

## Prepared regression coverage

Three new native methods specify:

1. A non-cooperative proposal times out without writes or a task journal; another model request is rejected as busy; a later exact compiled command succeeds; the obsolete proposal cannot overwrite it.
2. An answer timeout retains exact ownership, rejects an answer under a different task ID, refuses another planner while occupied, observes fresh values after release and replays a completed result without another edit.
3. Neither elapsed clarification expiry nor changed form scope is repaired or renewed by retrying after a planning deadline.

Five new MCP methods specify:

1. Timed-out ordinary and incomplete-Mail planning cannot execute a call, prepare a late approval or enter visual fallback; a busy retry does not start another helper.
2. Swift task cancellation and Stop share one helper cleanup, reject overlapping execution and retain planning capacity until the old planner returns.
3. A new request waits for synchronous Stop cleanup before starting another helper. The fixture records starts during cancellation at the helper boundary as well as observing the waiting request.
4. Stop alone rejects a late visual-fallback proposal and joins cleanup even without separate Swift task cancellation.
5. A successful approved result remains returned after concurrent cancellation, cleanup is joined and the consumed approval cannot execute twice.

The new methods use controlled continuations, AX fixtures and a stub MCP pool. They do not establish real model behavior, helper process termination or desktop correctness. The stub pool uses a fixed process-generation value; actual pool generation checks are separate existing behavior.

The [27-method focused inventory](capability-planning-deadline-inventory.json) also includes the six worker methods, earlier visual deadlines, native clarification ownership and MCP activation/approval fixtures. The default source inventory grows from 482 to 490 methods. No new source files need project registration.

## Validation and remaining work

Source inventory verification matches all 490 default and 27 focused identifiers. `git diff --check` passes. These checks establish selection and whitespace consistency only; this patch is uncompiled and unexecuted.

- Compile and execute these methods after the test pause is lifted. Validate cancellation-handler scheduling, main-actor reentrancy, actor isolation and the real pool's generation transitions.
- Qualify the public coordinator's Stop path. Swift task cancellation can interrupt the proposal wait; calling only the synchronous helper Stop API does not itself cancel the model call, though its late result is rejected. This patch does not establish immediate Stop response in every composition.
- Bound runtime activation, helper startup/cleanup and effectful operations separately. Joined helper cleanup can itself remain suspended. A timeout on an effectful stage must preserve uncertainty about what actually happened.
- Define whole-task time and progress policies across approval, clarification, takeover, repeated reads and executor replacement. Per-proposal deadlines do not prevent ineffective sequences of timely proposals.
- Extend durable dispatch evidence and recovery across MCP, visual input and native AX work. Process-local ownership and a successful helper response are not crash-safe exactly-once execution.
- Qualify natural-language completion and actual target outcomes independently of deadlines. Travel, concert and movie scenarios remain reserved for explicit user-authorized real-site testing. The 8 GB and thermal requirements remain for the later performance phase.
