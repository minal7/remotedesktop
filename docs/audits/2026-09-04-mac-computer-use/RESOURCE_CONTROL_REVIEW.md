# Resource control repair review

Status: source review and implementation in progress. No build, test, inference, app launch or computer-use interaction was performed for this review. The user's real flight, concert and movie scenarios remain deferred until development readiness is established and the user explicitly permits execution. This review does not identify the cause of the reported fan spike.

## What the observation establishes

The immediate read-only process snapshot after the fan report found no `xctest`, running `xcodebuild` build/test or `llama-server`. The installed `/Applications/RemoteDesktopHost.app` process was at 0.0% CPU. WindowServer was approximately 77% CPU and the Codex computer-use service approximately 23% in that snapshot. `pmset -g therm` reported no recorded warning/status. These observations cannot reconstruct earlier CPU/GPU load, establish fan RPM, or prove that the machine had cooled. They also do not qualify the app under sustained inference.

## First principles

Useful work is a user-requested change or an observation needed to decide or verify that change. Compute spent polling for work, repeatedly rediscovering unchanged state, keeping unused workers active or retrying without new evidence increases cost without improving completion. Thread count and memory ceilings constrain particular resources; neither is a thermal or energy budget. GPU work, observation and system rendering must be accounted for as well.

Runtime residency must be separate from task ownership. A model can be unloaded while the goal, verified effects and pending clarification remain durable. Reloading a model cannot authorize replaying an effect, reusing stale screen coordinates or reviving an old approval. Cancellation must close the action gate immediately and then finish bounded cleanup of the exact owned worker generation.

## Source findings and repair order

Paths below are relative to `host-mac/RemoteDesktopHost/ComputerUse/` unless otherwise stated. Items describe the reviewed source; implementation is not proof of a performance result.

| Order | Evidence and consequence | Required repair / acceptance |
|---|---|---|
| 1 | `OSAtlasLlamaLaunchConfiguration.arguments` and `OSAtlasLlamaRouterPreset.contents` set four CPU threads but did not override worker polling. The pinned runtime defaults to busy-wait level 50. | Implemented in this candidate: `poll = 0` and `poll-batch = 0` for native, direct visual and both router model presets. The four-thread limit remains. Build and existing configuration checks are pending; later measure active latency and idle CPU. |
| 2 | `HostComputerUseManager.init` calls `refreshModelState`; an installed native package enters `beginNativeTextActivation` and the default loader activates the model. `stop()` deliberately retains a warm model after disconnect. No bounded idle retirement policy was found. | Separate verified package/capability availability from resident model state. Load on actual demand, except explicitly requested setup qualification. Retire idle workers under a bounded policy without discarding task state or claiming setup is missing. |
| 3 | Runtime `resourceProfileForLaunch` and `validateResources` use physical/reclaimable memory. `FoundationOSAtlasLlamaServerProcess` enforces resident memory and worker-count ceilings. No thermal-state or low-power policy was found in the host source. | Add injectable resource admission and pressure transitions. Define behavior for elevated pressure, user cancellation and cooldown; prevent automatic retry loops during sustained pressure. Preserve typed task outcomes. |
| 4 | Native launch uses GPU offload (`--n-gpu-layers 99`). CPU pools capped at four threads do not bound GPU utilization. | Measure CPU time, GPU/energy where available, thermal state, memory and task latency together. Select an operating policy from those measurements. Do not interpret low CPU alone as low load or reduce GPU use blindly by moving work to the CPU. |
| 5 | The owned-process memory monitor takes a process-tree snapshot every 100 ms. The Darwin implementation enumerates system PIDs and parent links to establish membership. | Measure monitor overhead separately. Consider cheaper identity-preserving membership tracking and state-dependent scheduling; retain exact-process identity and the resource ceiling. Do not weaken the guard merely by stretching its interval without evidence. |
| 6 | `ComputerUseObservationWorker` serializes synchronous Vision work. Cancellation stops delivery, but cannot forcibly interrupt an already-running native operation; its capacity stays occupied until return. | Keep the no-overlap guarantee. Measure cancellation-to-return separately from cancellation-to-action-gate closure. Avoid repeated observation of unchanged state and bound the observation area before invoking Vision. |
| 7 | `acquireModelAccessLease` suspends queued callers in continuations. A cancelled queued waiter currently resumes only when the current lease releases. | Make waiting cancellation-responsive without cancelling another caller's lease or allowing overlapping model access. Cover cancellation before enqueue, while queued, at handoff, and during shutdown. |
| 8 | There are per-request/model bounds and a ten-step structured executor limit, but these do not establish a whole-task energy or meaningful-progress budget. | Account for activation, tokenization, inference, capture, OCR, verification and recovery in the same task trace. Bound repeated-state recovery and total expensive calls; stop with an honest incomplete outcome. |

The first change uses the pinned upstream behavior: [argument definitions](https://github.com/ggml-org/llama.cpp/blob/6eddde06a4f25d55d538b5d15628dcc2b6882147/common/arg.cpp#L1257) accept zero polling for both pools; [CPU parameter defaults](https://github.com/ggml-org/llama.cpp/blob/6eddde06a4f25d55d538b5d15628dcc2b6882147/common/common.h#L61) use level 50; [worker scheduling](https://github.com/ggml-org/llama.cpp/blob/6eddde06a4f25d55d538b5d15628dcc2b6882147/ggml/src/ggml-cpu/ggml-cpu.c#L2975) falls through from the polling loop to a condition-variable wait. This removes that polling budget, not all runtime CPU use or GPU work. Wake-up latency may change and must be measured.

## Idle retirement contract to implement next

1. The manager owns a generation-scoped activity lease covering setup, execution, approval continuation and teardown. Merely seeing `.idle` at one await boundary cannot authorize shutdown of newer work.
2. An idle deadline captures its generation. New admitted work invalidates the deadline synchronously. Expiration rechecks ownership before starting runtime cleanup, and new activation joins that cleanup barrier.
3. Retain exact goal, verified step state and clarification references independently of model residency. Do not clear the executor or task journal solely to reclaim model memory.
4. Native planning already activates its inputs before each proposal. Normal visual execution also reactivates before its loop, but `PendingVisualApproval` retains an endpoint, semantic router and grounded action. Review that continuation explicitly: after retirement, a previous endpoint or grounding cannot silently become authority for a new effect. Require fresh validation and any resulting approval renewal.
5. Distinguish idle retirement from user cancellation and explicit application shutdown. Preserve the existing generation-bound cleanup and poison-on-unproven-process-exit rules.
6. Test with controllable lifecycle doubles before a real model: expiration during activation, admission during expiration, cancelled waiters, disconnection with a paused task, delayed approval after retirement and cleanup failure. No double launch, lost goal or repeated effect is permitted. These tests have not been run for this proposed contract.

## Current change and deferred validation

The candidate edits `OSAtlasLlamaRuntime.swift` and updates the four existing launch/preset checks in `OSAtlasComputerUseExecutorTests.swift`. No model, executable, prompt contract, input/output token limit, installed app or runtime artifact was replaced. Test identifiers and inventories are unchanged. `git diff --check` passes; compilation and test execution remain pending during the current pause.

When testing is authorized, first check the signed candidate's launch/preset behavior and idle/cancellation policy in a bounded run with process cleanup and predeclared resource/latency budgets. Sample process metrics without continuous GUI scraping. Stop on the user's intervention or exceeded budget. A passing functional test alone does not close the resource finding.

Only after the development prerequisites in `TODO.md` are supported by evidence should the app receive real flight, concert and movie searches. The user's explicit permission is still required. Keep those tests separate from controlled form qualification, verify the app's answers against the actual pages and stop before booking or purchase.
