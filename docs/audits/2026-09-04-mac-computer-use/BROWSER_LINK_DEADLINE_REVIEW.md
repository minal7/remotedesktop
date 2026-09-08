# Bound the complete link decision before publishing a choice

Source checkpoint, 2026-09-08. Previous checkpoint: `f3fa5d8`. Execution remains deferred.

## First-principles defect

A research task must keep control of in-flight work until it finishes, and it must stop requesting more work after its decision budget expires. A timeout on one HTTP request does not bound a decision consisting of token counting, completion, historical recall and another completion. The link adapter can recall up to eight earlier readings before its final choice. Before this repair, these calls each used their own request timeout, with no outer deadline over the sequence. Fresh link selection and selection during recovery of a proven-unsent navigation stage both depended on this unbounded sequence.

This was found while reviewing the route to complete research answers. The current driver still has no completed-answer path; fixing link selection does not change that. It closes a control/liveness gap on the path through earlier evidence and detail pages, including continuation after login.

## Source changes

- [The retained research owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) now starts one monotonic deadline for a link decision after its candidate reading finishes. The deadline covers the entire selector callback, including all model recall calls, and the final native reading validation. It is clamped to 30 seconds; zero/negative budgets reject before starting another reading. The preceding reading and semantic review retain their separate admission and lifecycle.
- Both fresh planning and [pending-stage recovery](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchNavigation.swift) call the same bounded selection helper. The helper checks the original goal/control state and deadline before and after selection and native validation. A selected candidate/link pair must still belong to the exact reading. A nil choice is also revalidated; it cannot turn a changed page into accepted evidence.
- A structured task group races the complete decision against the timer. The timer cancels the selector and waits for it to unwind. Late choices, including otherwise valid native references returned after cancellation, cannot publish. No new model call is started after the existing adapter observes cancellation. This applies to the production model adapter and injected selectors because the deadline is at their common owner boundary.
- [Candidate validation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultCandidates.swift) joins an already-dispatched native DOM callback on error or cancellation. The owner and any pending navigation execution lease remain held until that work joins. Unresponsive native work may still require closing/stopping its browser; the decision deadline is not a promise that cleanup always finishes within 30 seconds. Releasing authority while a callback is still running would create a different correctness failure.
- The timeout is a distinct [link-planning error](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserLinkPlanner.swift). [The driver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchDriver.swift) maps it to a resumable intervention retaining earlier findings and the original task. It cannot become a successful answer or trigger navigation. Existing page-change, authentication, Pause and journal reconciliation paths retain their behavior.
- A pending-stage deadline expires before a replacement target is prepared/saved. Its original operation ID, planned journal and no-attempt state remain available for later recovery. The outer navigation layer still owns binding replacement and persistence; a timer does not reset the effect journal or authorize a new stage.

No model, prompt/schema contract, worker, input/output token budget or installed application is changed. This is a correctness/lifecycle repair; it does not establish acceptable inference cost, whole-task latency, physical 8 GB behavior or fan load.

## Prepared verification

Seven added source methods cover:

1. Expired budgets starting no reading/selector and preserving earlier evidence.
2. The actual local planner and recall adapter stalling in the second token-count or completion call, with cancellation/join and no subsequent call or navigation. Full request/history input remains present.
3. A selector deliberately delaying cleanup after cancellation, while the owner remains busy and rejects competing work; its late valid-looking choice must be rejected.
4. A page changed during selection, including a nil choice that still requires fresh native validation.
5. Pause during the final native validation callback, followed by explicit handback and continuation without repeating the initial search.
6. Driver mapping of the deadline to a nonterminal original-task intervention retaining historical evidence.
7. A timeout while replanning an unsent navigation stage, with its execution lease held through delayed cleanup, unchanged original journal, and one eventual navigation under the original operation ID.

See [link-planning regressions](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserLinkPlannerTests.swift) and [native navigation regressions](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserDOMTests.swift). These methods are prepared source, not passing runtime evidence.

The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,143 source methods**; the [focused inventory](browser-link-deadline-inventory.json) selects **460**. Six changed Swift files pass syntax-only parsing. Both source inventories, project syntax, local documentation links and whitespace are checked. No typechecking, builds, test assertions, model execution, application/browser/computer-use activity or held-out inspection/run occurred.

## Remaining repair order

1. Connect complete research answers with source-backed offer matching, applicable dates/types/quantities, complete selection totals/fees, distinct result counts and ordering. A model declining another link, a loaded page or a positive numeric comparison cannot substitute for the requested answer.
2. Join evidence from detail pages while preserving its original goal, source, observation context and qualifications. Historical availability is not automatically current inventory; accepted answers may change applicability. Current reports still contain partial page passages.
3. Complete provider/login and changed-form reconciliation, including broader controls, POST/custom forms and durable parent recovery. This deadline preserves existing handback and journals but does not implement those missing capabilities.
4. Qualify the changed ownership/cancellation paths and complete model inputs when execution is authorized. Measure both decision cancellation and actual cleanup; a source timer alone does not prove runtime responsiveness.
5. Keep real travel/concert/movie E2E deferred until readiness and explicit permission. Alternate models/RTX 3080 adaptation remain options after failures are attributed; remote access remains unverified. Performance and 8 GB qualification remain later work.
