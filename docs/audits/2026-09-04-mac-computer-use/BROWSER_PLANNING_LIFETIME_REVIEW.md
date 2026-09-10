# Separate browser proposal delivery from model lifetime

Source checkpoint: 2026-09-09. Parent: `7a1f8c9`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

A deadline has two distinct obligations: stop the caller from accepting an overdue answer, and account for the work that may still be running. Cancelling a Swift task requests cooperation; it does not establish that the underlying model call has stopped. Racing an entire browser operation against a timer in a throwing task group still joins every child when the group exits. A suspended model that ignores cancellation could therefore keep the browser owner and driver occupied after their nominal deadline or Pause.

Goal interpretation, initial search terms and form proposals also had bare model awaits. The first text-only admission pass ran before an owner existed, so putting a deadline only inside the owner would leave this initial pass unbounded. Recreating its input on retry could additionally move the meaning of a relative date such as “tomorrow.”

The repair uses the existing [planning worker](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUsePlanningWorker.swift), whose delivery and actual-call lifetimes were separated in the [earlier review](PLANNING_DEADLINE_REVIEW.md). No worker internals change here.

## Proposal boundaries

The [browser owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) wraps only asynchronous proposal calls. Native observations, target validation, journal work, action dispatch and cleanup remain in their original orchestration.

| Proposal stage | Wait policy | Result after an overdue proposal |
| --- | --- | --- |
| Initial text-only admission | Default 30 seconds | Throws a planning failure; creates no browser owner and cannot decline into another capability as an unsupported request |
| Full-goal interpretation | Default 30 seconds | Keeps the original input; publishes no interpretation |
| Initial search terms | Default 30 seconds | Prepares no search from the late terms |
| Next action, including recalled context | Lesser of configured wait and the remaining decision deadline | Keeps the existing typed action deadline; does not offer the late action |
| Form proposal | Default 30 seconds | Dispatches no edit from the late proposal; retains existing native recovery obligations |
| Result reading and its review pipeline | Default 30 seconds for the complete proposal pipeline | Returns the existing review deadline; publishes no late reading or review |
| Link/answer/revisit selection | Lesser of configured wait and the remaining decision deadline | Returns the existing link deadline; cannot use the late selection |

The helper rejects nonfinite, nonpositive and above-worker-maximum configurations. Recalled action context does not reset the existing outer decision clock. The outer structured groups still join native work; the proposal worker is not a detached browser executor. The reviewed result planner remains one worker operation covering its reader and reviewer, without nested acquisition. Its existing internal transport task group must finish before the worker releases capacity.

The production defaults share the same process-wide permit as the previously integrated visual/native/MCP proposal routes. The [driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) passes its worker and configuration through [host preparation](../../../host-mac/RemoteDesktopHost/ComputerUse/HostComputerUseManager.swift) and [navigation ownership](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserNavigationTask.swift). Preparing or replacing an owner cannot obtain independent capacity. Controlled fixtures inject their own workers.

Timeout or cancellation returns to the waiting owner while the worker retains the actual outstanding call. A retry receives busy until that call really exits. Its late value is discarded. Successful timely values still face current-goal, control-epoch, native-page and proposal checks before becoming an action, finding or retained choice.

Pause still requires explicit handback. Releasing a proposal wait cannot return control to AI, clear an uncertain effect, mark a pending journal complete or authorize replay. In the no-effect navigation-replan path, the owner joins native cleanup and releases its execution lease while leaving the planned journal unchanged; the stalled selector continues to hold the separate model permit. Native effects have not been moved into the worker.

## Admission and retry identity

The driver retains one initial admission input with the original Date and time-zone identifier. Same-task retries must preserve the exact prompt bytes and reuse that clock. A busy competing request or invalid deadline restores the preceding admission record because it never acquired planning capacity. No late proposal can install an owner, and a timeout is never treated as an unsupported routing result.

This retention is local to the current driver and its current admission attempt. It does not add a durable pre-admission task journal or recovery of arbitrary displaced requests across process restarts. Once admitted, the existing owner remains authoritative for the complete goal and accepted clarification clocks.

## Authored verification, unrun

Eight new methods specify goal, search and initial-admission deadlines, invalid configuration, and the action/form/reading/selection boundaries. Held fixtures deliberately ignore cancellation. Assertions cover delivery before actual return, no second planner invocation while busy, no late native command or published interpretation, original-clock reuse after a changed clock and competing request, and fresh planning after actual release.

Existing cancellation and recovery fixtures now distinguish the owner operation from its retained model permit. They cover explicit handback, parent cancellation, retirement/replacement, a held result reviewer, recalled evidence and no-effect navigation replanning with an unchanged journal. They wait for actual worker release before expecting another model call. Three test identifiers were renamed to match the revised lifetime contract, with corresponding manifest references updated.

Fifteen changed Swift files pass parse-only checks. Active default/focused source inventories select 1789 / 1106 methods: eight new methods and three renames, with no removed coverage. Older manifests receive only those identifier substitutions; their historical execution status is not changed. These checks establish syntax and source registration, not Swift typechecking, assertions or native/model behavior.

## Remaining repair and qualification

1. Compile and run these controlled fixtures after the execution pause is lifted. Qualify timer/cancellation races, actor scheduling and actual transport cleanup in production composition.
2. Define whole-task elapsed and active-time limits, including time in clarification, login handoff and approval. Per-proposal deadlines do not bound a complete research request.
3. Continue capability-specific progress/repeated-state checks and native observation deadlines. A blocked synchronous call or starved main actor cannot be forcibly interrupted by this worker.
4. If a model API never returns, planning intentionally stays busy. Recovery needs an explicit transport/process-lifetime design; releasing the permit by elapsed time would allow overlapping inference again.
5. Continue the [repair checklist](../../../TODO.md), including remaining source-policy completion restrictions, provider semantics and durable recovery. Live travel, concert, movie and login scenarios remain deferred until explicit permission.
6. Evaluate alternate models or RTX 3080 adaptation against measured task failures in the later authorized stage. Model quality, 8 GB memory use and fan behavior remain unqualified by this correctness repair.

No model/SSH activity, installed-app replacement, push or generated-file cleanup occurred here.
