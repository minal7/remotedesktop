# Keep MCP startup bound to its own lifecycle request

Parent source: `2470061`. This is a source repair with uncompiled, unexecuted fixtures. Builds, model runs, computer-use activity, real-site acceptance and performance optimization remain paused or deferred under the current user instructions.

## Failure mechanism

An actor protects synchronous access to its properties, but each `await` permits another operation to change them. `MCPClientPool.start` previously treated multiple startup stages as though they retained one uninterrupted ownership claim.

Three concrete interleavings were possible in source:

1. Request A waits for binary validation. Request B validates and starts successfully, or Stop invalidates the pool. A's validator returns later; A then increments the lifecycle epoch and replaces B or undoes Stop. Ownership was claimed after the first suspension instead of before it.
2. A clears the old pool slots and awaits the old session's `stop()`. B starts and publishes a new identity/session. A resumes, assigns its own candidate into the session slots and only checks its epoch after starting it. The late epoch check rejects A, but A has already overwritten B's session references. B's identity can remain published alongside A's stopped session.
3. A's primary candidate is still starting when Stop or a newer request invalidates it. When the primary returns, A starts its embedded Mail candidate before checking the epoch. A cancelled Swift task can also return readiness if the underlying startup API does not cooperate, because there were no explicit task cancellation checks in these stages.

The prior generation-scoped cancellation checks and the executor's joined cleanup remain useful. They do not prevent these writes inside a suspended pool startup.

## Repaired ownership rules

The pool now checks Swift cancellation and claims its lifecycle epoch before invoking binary validation. Validation still must succeed before retiring active sessions or creating candidates. A pre-cancelled request never starts validation and leaves an existing healthy session intact.

After each stage, `requireCurrentStart` checks both the calling task's cancellation and the exact lifecycle epoch:

- After binary validation, before allocating a generation or retiring anything.
- After stopping both captured old sessions, before constructing or assigning candidates.
- After the primary candidate starts, before starting the embedded candidate.
- After the embedded candidate starts, before publishing readiness.

The primary identity's server, generation and binary path are also validated before embedded startup. An invalid primary cannot activate the next capability.

Cleanup uses the exact candidate references captured by that attempt. A failed attempt clears pool slots only if its generation is still the last allocated generation. This distinction matters when a newer request claims an epoch but its validation fails before allocating a replacement: the old candidate is still obsolete and must be removed, even though the lifecycle epoch has changed. Conversely, a newer allocated generation's slots must survive the old attempt's cleanup. The generation counter remains monotonic across Stop.

Identity failures now enter the common catch cleanup once, instead of stopping both candidates in the guard and then stopping them again in the catch. Another lifecycle owner can still independently retire those same old sessions; session stop implementations must remain idempotent.

## Prepared regressions

Seven new XCTest methods define fifteen controlled scenarios:

| Suspended stage or condition | Intervention | Required result |
|---|---|---|
| Binary validation | Task cancellation, Stop, newer start | No obsolete candidate allocation; a newer valid session remains usable |
| Retirement of the previous primary | Task cancellation, Stop, newer start | Finish retiring the captured sessions without publishing an obsolete candidate |
| Primary startup | Task cancellation, Stop, newer start | No embedded startup from the obsolete attempt; no stale readiness |
| Embedded startup | Task cancellation, Stop, newer start | No stale readiness or damage to the replacement's primary/embedded sessions |
| Already-cancelled new request | Existing healthy session | No extra validation, construction or retirement |
| Mismatched primary identity | Ordinary startup | Embedded startup count remains zero; common cleanup runs once |
| Newer validation fails while old primary is suspended | Release the old primary, then retry fresh | Old attempt stays superseded, its stopped session is removed from pool slots, and a fresh start does not retire it again |

The validators and sessions deliberately ignore cancellation while suspended on a controlled continuation. Assertions inspect construction/start/stop counts and the pool's public tool inventory. The replacement must expose both tools under its current generation and have no stop recorded before final fixture cleanup. No real helper, model, desktop, permission prompt or mutation is involved in these new fixtures.

The [19-method focused inventory](mcp-startup-ownership-inventory.json) includes these seven methods, four existing pool approval/mutation/cancellation methods and eight executor/capability cleanup methods. The default source selection grows from 490 to 501: seven new methods plus four existing pool regressions newly selected for the default gate. No project source references change.

## Verification and remaining work

Source inventories match all 501 default and 19 focused identifiers. `git diff --check` passes. This is registration and whitespace evidence only, not Swift compilation or execution evidence.

- Compile and run the fixtures when the test pause is lifted. Exercise the real validator, primary MCP session, embedded Mail session and installed composition separately from the controlled fixtures.
- Establish bounded startup and cleanup waits. This patch checks ownership when asynchronous stages return; it does not forcibly interrupt a non-cooperative validator, session start or session stop, and it does not prove a takeover latency bound.
- Review lifecycle overlap across distinct executors sharing a pool. A newer request can still proceed while another request retires its captured old sessions; the ownership checks prevent stale publication, not all overlapping process lifetimes.
- Extend executor cancellation handling into deterministic Mail preparation. That path still performs startup, discovery and approval preparation outside the joined generation wrapper used by structured planning. It needs the same cancellation and late-result rules without losing its model-independent behavior.
- Carry completed approved-action evidence through the outer capability executor and host manager. Their post-await cancellation checks can still discard the successful result preserved by the inner MCP executor. Repair must retain evidence for the exact old task without letting its stale execution token modify a newer task or replay the action.
- Continue whole-task progress, dispatch uncertainty and recovery work. A healthy helper lifecycle does not establish natural-language interpretation, correct target selection or all requested outcomes. Live travel, concert and movie scenarios remain deferred until explicit permission; no 8 GB or thermal qualification follows from this repair.
