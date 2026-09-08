# Earlier research evidence must inform the next capability

Source checkpoint, 2026-09-08. Previous checkpoint: `cad289d`. Execution remains deferred.

## First-principles finding

A useful next step depends on both the original request and what has already been learned. Before this change, the result-link selector could recall earlier observations, but the planner choosing between a form, query, page reading or clarification saw only navigation/form counts and its current page. A count cannot explain an unresolved fee, route or date. This split could leave the capability decision blind to evidence that the application had already retained. The production runtime also returned `read_results` immediately on pages without form choices, so adding recall only to the local planner would not fix the shipped composition.

The complete answer path remains unfinished. This repair connects existing evidence to the earlier capability decision; it does not turn a historical reading or model judgment into proof of a complete answer.

## Source implementation

- [The archive](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchEvidence.swift) now supplies a capability-selection catalog before a fresh candidate reading exists. It validates the exact original goal/accepted-answer prefix and the current native browser session. Another task or another session with the same visible prompt cannot supply this history.
- [Action contract v6](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) includes the catalog, offered recall ordinals and fully recalled observations. `{"reading":N}` is a distinct no-effect proposal. It accepts only offered integers, requires a closed object and rejects duplicates, mixed alternatives, unknown IDs and repeated recalls. Every input binds the archive digest as well as the complete current interpretation/page and recalled order.
- Recall reuses the existing complete historical projection, candidate fields, semantic review/citations and original requirement assessment. References use the existing `rN/` namespace. Earlier goal revision and accepted-answer count stay explicit. Original source text is not rewritten, historical judgments are not silently recomputed as current facts, and private native destinations/session authority are not added to model context. Existing whole-projection bounds and omission flags remain in force.
- [The owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) resolves recalls inside one serialized action-selection operation. All requested readings remain in the next prompt. At most eight distinct readings can be recalled, followed by one final capability decision: at most nine planner calls. Native page/source validation follows every reply, including recall. The archive must stay unchanged. Only a final current input-bound action is retained for later preparation.
- Selection, observation, recall, counting and model calls share a single monotonic deadline capped at 30 seconds. A structured task group cancels the losing work and joins cleanup. Pause, page change, cancellation, context failure or deadline expiry cannot publish a late choice. Native observation and post-observation error paths join outstanding DOM callbacks. The operation remains owned until cleanup returns; this relies on cooperative transport/native cleanup rather than forcibly abandoning work. The driver reports deadline expiry as a resumable intervention under the original task.
- Both the local planner and [production runtime adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/OSAtlasLlamaRuntime.swift) skip inference only when there are neither form/query choices nor retained/recalled readings. Recall uses the existing native-text worker, model-access lease and cancellation path. No additional model, concurrent worker or installed application was introduced.
- The existing token counter still receives each complete request, with unchanged 4,096 context / 1,024 output / 64 framing budgets. A recalled input that does not fit fails without truncating the original goal or historical projection. Prompt growth and the deadline can limit recall in practice; actual-model/context qualification remains required. This source change does not establish a performance improvement or 8 GB suitability.

## Prepared verification

Ten new methods in [action recall regressions](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserActionRecallTests.swift) cover:

1. Recalling a price passage, choosing a current form, preserving its native edit receipt and opening its verified query without another initial search/result read.
2. Historical requirement meaning under a later accepted answer, with original task clock retained.
3. Unknown/fractional/boolean/repeated/hybrid recalls, changed archive identity and historical IDs rejected as current forms.
4. Foreign roots and another browser session with the same original request.
5. Eight retained recalls plus one final decision, without silently dropping requested pages.
6. The local planner's no-form recall path, exact full-request counting and later context failure before another completion.
7. Pause during recall, joined operation ownership, explicit handback and retained findings.
8. Zero-budget work before observation, cancellation of a stalled later reply and joined cleanup.
9. A native page replacement during recall invalidating its old action while preserving historical readings.
10. The research driver's resumable response to an action deadline.

An eleventh method in [runtime regressions](../../../host-mac/RemoteDesktopHostTests/OSAtlasComputerUseExecutorTests.swift) composes the actual runtime action adapter and owner with existing fake process/transport dependencies. It specifies a zero-worker no-history shortcut, then two recall/final-decision requests through one shared fake worker on a page without forms. This would catch a shortcut remaining only in the production adapter. Existing action tests expect v6 and explicitly construct no-history input for their shortcut checks.

The [default source inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,123** methods and the [focused source inventory](browser-action-recall-inventory.json) selects **440**. Eight changed/new Swift files pass syntax-only parsing. The new test source has four expected Xcode project entries, project lint passes and whitespace checks pass. Both inventories match source and 151 local documentation links resolve. None of these checks compiles the code or executes an assertion. No build/typecheck, XCTest/model run, application/browser/computer-use activity, installed-app replacement or held-out inspection/run occurred.

## Remaining work

- Complete research-answer construction and task-wide result predicates: required dates/locations/routes, party/ticket quantities, availability, full prices/fees, distinct options, requested count/order and usable sources. Current passages and semantic support judgments still do not constitute complete answers.
- Qualify current action/review/link prompts with their complete goals and page histories. Verify useful recall decisions, exact context fit, reliable cancellation and the common deadline on the actual local model after authorization. Larger requests still require a deliberate staged strategy that preserves all requirements.
- Finish changed-form/login remaining-goal reconciliation, provider acquisition lifetime, broader custom/POST interactions and durable parent/evidence/report recovery. Historical recall does not restore account access or bypass visible manual login and explicit handback.
- Keep real-site travel/concert/movie tests deferred until development readiness and explicit permission. Alternate models or RTX 3080 adaptation remain options after evidence identifies model shortcomings; desktop SSH access and hardware are still unverified. Thermal/performance and physical 8 GB qualification remain deferred.
