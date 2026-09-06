# Cancel deterministic Mail preparation across helper startup and approval

Parent source: `a12cb5a`. Status: source implementation and fixture registration only. No compilation, XCTest execution, model inference, app launch or computer-use activity ran. Real-site testing and performance optimization remain deferred.

## First-principles problem

A complete Mail request can be compiled directly into an exact approval without asking a model. This useful route still has asynchronous stages: start the helper, discover the embedded Mail tool and prepare the fingerprinted approval. Previously these stages ran outside the generation cancellation wrapper used for structured planning. A stopped request could finish discovery or preparation and publish a late approval.

There is also an interval in which the executor has called `start` but has not received the new helper's generation. Stop can cancel the earlier generation, or find no active generation at all. Checking only an already-returned generation's cancellation task cannot detect that this new startup was also interrupted. The pool startup ownership repair handles the real pool's internal state, but the executor must independently reject an obsolete successful startup return and clean up precisely the returned generation.

## Execution and helper ownership

An active execution now records the executor's cancellation epoch. `cancelMCPWork()` increments that epoch even if no active helper generation is published, then invalidates pending approval and starts any known generation's existing cleanup. Overlapping ordinary execution and approval continuation remain rejected until the active owner exits.

The new `withNewHelperGeneration` boundary is shared by structured planning and deterministic Mail preparation:

1. Join already-started cleanup and check task cancellation and the execution epoch before starting another helper.
2. Await helper startup. If it fails, join any earlier cleanup that Stop started during that await, check cancellation again and propagate the failure. A typed helper cancellation is treated as cancellation, so it cannot enter the ordinary fallback handlers.
3. If startup returns an identity, join any earlier generation's pending cleanup before storing a separate owner for the returned generation. A cancelled caller still owns this returned resource and must retire it.
4. Enter the existing generation cancellation wrapper and check both the execution epoch and the generation before discovering tools or planning. A late returned helper from a stopped request is cleaned up and cannot proceed to those stages.

This keeps cleanup tasks for an earlier helper and a newly returned helper distinct. Joining the earlier task cannot substitute for cancelling the newly returned generation. Cleanup remains generation-scoped; no unscoped `cancelAll` is introduced in the executor.

The generation wrapper now recognizes the execution epoch and typed MCP cancellation as well as Swift and planner cancellation. Its existing successful approved-result preservation remains limited to the approved-action path. Returning an approval preparation after Stop is not a successful effect and is rejected.

## Deterministic preparation

Mail preparation now enters the shared startup boundary, discovers the exact embedded Mail tool, checks cancellation, constructs its exact call, prepares the approval and checks cancellation again before publishing it. A cancelled or stopped request cannot set the executor's pending approval state from a late preparation. The cancellation wrapper joins cleanup and clears pending state before releasing execution ownership.

The request parser, recipient/body/subject handling, fingerprint, policy and separate explicit approval boundary are unchanged. This route still performs no send or draft creation while preparing. Complete requests still need no model or planning permit. A fresh user request after cleanup gets a new execution epoch and helper generation; Stop does not permanently disable the capability.

## Prepared regressions

Six new methods define ten scenarios:

- Task cancellation and Stop alone during deterministic startup. The earlier load uses generation 1; a late startup returns generation 2. Stop during startup records cleanup of both generations, while task cancellation retires the returned generation. Discovery does not proceed for the cancelled new helper.
- Both interruptions during deterministic discovery. No approval is prepared.
- Both interruptions during deterministic approval preparation. A late prepared value is rejected and cannot be resumed as an approval.
- Both interruptions during structured startup. The shared boundary retires the late helper before invoking the planner or discovering tools.
- An exact deterministic Mail request reaches approval while an unrelated proposal occupies the shared planning permit, with no planner/fallback invocation and no action performed.
- Startup fails after Stop has started cleanup of the earlier helper. The executor joins that cleanup and returns cancellation without presenting a Mail clarification or visual fallback.

The first eight cases hold the returned generation's cleanup on a controlled continuation. They require overlapping execution to be rejected, verify zero performed calls before approval and then exercise a fresh request after cleanup. A fresh deterministic request prepares generation 3 and performs exactly one fixture action only through its approval continuation.

The test pool now optionally advances generations and supplies controlled startup/discovery/preparation/cancellation gates. Existing tests retain their fixed-generation behavior by default. No real helper, Mail application, email, model or desktop is involved in these new fixtures.

The [22-method focused inventory](mail-preparation-cancellation-inventory.json) includes these six new methods and existing pool/executor startup, cleanup, exact-Mail and approval regressions. Three previously existing Mail methods are also newly selected in the default inventory, which grows from 501 to 510. No project source references change.

## Verification and remaining work

Source inventory checks match all 510 default and 22 focused identifiers. `git diff --check` passes. This establishes source registration and whitespace consistency only; Swift compilation and runtime behavior remain unverified.

- Compile and execute the fixtures after the test pause is lifted, then qualify the real helper and coordinator composition. Controlled continuations do not establish production cancellation scheduling or process termination.
- Bound helper startup and cleanup waits. This repair rejects late returns and joins cleanup; it cannot force a non-cooperative startup or cleanup stage to return. A newly returned helper may remain retained while an earlier cleanup is still blocked, though it cannot begin tool discovery through this request.
- Preserve completed approved-action evidence through the capability executor and host manager. Their outer cancellation/token checks can still discard the result preserved by the inner executor. A fix must record the exact old task's outcome without allowing its stale token to mutate a newer task, send a contradictory terminal outcome or repeat an action.
- Qualify stage failures separately from user cancellation, including invalid helper identity, missing tools, Mail automation permission changes and helper disconnection around approval.
- Continue whole-task interpretation, progress, outcome verification and durable recovery. This repair does not establish successful natural-language travel, concert or movie searches, 8 GB support or acceptable fan load. Those qualifications remain explicitly deferred.
