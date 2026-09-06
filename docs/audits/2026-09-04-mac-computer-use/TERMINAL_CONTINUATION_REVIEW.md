# Continue supported work after a premature terminal proposal

Parent source: `47f4e36`. Status: source implementation and regression registration only. No build, XCTest execution, model run, app launch or computer-use activity ran. Performance optimization and real-site acceptance remain deferred.

## First-principles problem

A planner's declaration of success is a proposal. The host must compare it with both the requested work and observed results. The previous prerequisite repair prevented a visible result from concealing a missing explicit step, but immediately returned inability after rejecting the proposal. For a request such as “type this query, press Return, then report the result,” the next missing action can sometimes be derived exactly without asking the model to invent another plan.

This repair uses the existing shared ordered-command matcher to return that pending action. It does not accept the proposed answer as evidence that an action occurred, add an extra model loop, clear prior progress or reset retry limits.

## Recovery boundary

Only a typed `COMPLETE` with no argument, or an `ANSWER`/`REPORT` carrying ordinary visible-answer evidence, is eligible. The executor validates the original route arguments before considering recovery. Questions, host-verified obstacle reports and non-terminal proposals are preserved. A malformed proposal cannot be concealed by replacing it with a syntactically valid effect.

The resolver reads the original trusted task and full raw host history. The history inside the model request and visible text cannot supply task authority or step progress. Unknown or terminal history entries prevent recovery. A transient-overlay diagnostic is a no-effect observation. Changed input bytes, reordered or extra effects, unsupported earlier commands, intermediate information clauses and uncompiled repeat syntax cannot be skipped.

The supported replacement routes are:

- Task-derived click, double-click or right-click family and target hint.
- A reviewed, explicit application opening/scope clause. Only an authoritative current application identity can satisfy an already-current app clause.
- Exact quoted input from the pending clause. Short text remains byte-exact. A long or whitespace-only payload uses the existing literal reference only when resolving that reference against the whole original request produces exactly the pending bytes.
- An explicitly requested Return/Enter key step.

The route must be available in the current action contract. Dragging, scrolling, shortcuts, waits, generated text and intermediate information results do not gain synthesized routes from this recovery path. Their direction, target, amount, timing, data or outcome semantics need reviewed capability contracts. Long payloads with multiple quoted objects remain unsupported by the visual single-literal reference catalog. Broader search and navigation goals are not compiled by this narrow grammar.

## Execution and progress

A replacement enters the existing executor path before post-router state revalidation. Pointer actions still require task binding, grounding and target checks. Input still requires the exact authorized payload/Return intent, stable application/window/focus, an editable non-secure target, approval when required, final revalidation and verified dispatch. Cancellation and uncertain-effect handling remain unchanged. The task-wide repeated TYPE/ENTER guards remain in place; this repair does not make repeated visual input safe.

The matcher now treats incidental `WAIT` observations consistently during terminal checking and pointer/input authorization. They consume no requested effect. An explicit wait clause still needs its own wait entry. Extra real effects still reject at the ordered match boundary. The old preliminary history-length comparison was redundant for effects and incorrectly counted settling observations as extra operations; the per-entry order and exhaustion checks remain authoritative.

Each accepted replacement uses an ordinary executor step. The existing total step limit, planning-state retry limit, approval continuation and effect reconciliation state still bound the run. A proposal alone does not advance history. Only the ordinary performed-action path records its action; a later success proposal is checked against that updated history and independent fresh outcome evidence.

The original Foundation Models route provenance is consumed, but a host-derived replacement is recorded as `non-foundation`. An incorrectly proposed completion must not be credited as a model-planned click. This also carries through an approval continuation. No attestation schema or model-history privacy boundary changes.

## Prepared verification

Five new pure matcher methods cover each pending step in an app/click/type/Return sequence; all eligible terminal variants; pointer families; exact raw history and signed app scope; unavailable directives; long, Unicode, whitespace and marker-looking literals; unsupported payload roles; questions and obstacles; unknown/terminal history; unsupported earlier actions and repeat syntax; and agreement between action and terminal matching after settling observations.

Five new production-executor fixture methods cover:

1. An always-premature answer router: exact query input and Return must happen before independently visible submitted-result evidence is accepted. Existing signed app/focus and caret-change fixtures remain in use.
2. A premature Foundation completion corrected to a task-bound click: exactly one independently grounded click is expected, and its attestation must be non-Foundation.
3. Ordered distinct inputs and retained repeated TYPE/ENTER suppression even when every proposal says complete.
4. Rejection of non-editable, secure, missing or changed focus through the same checks used by ordinary semantic typing.
5. Malformed terminal arguments rejected before grounding or effects.

Four existing executor methods now share their fixture bodies with the new recovery variants while retaining separate test identifiers. The prior premature-click rejection fixture now requests uncompiled `twice` syntax; it still expects inability with no input. Its historical inventory is preserved.

Source validation passes for the [35-method focused inventory](terminal-continuation-inventory.json), updated 473-method default inventory and unchanged 21-method historical prerequisite inventory. `git diff --check` passes. These checks establish source registration and whitespace consistency, not compilation or execution. The historical prerequisite inventory is not regenerated.

## Remaining repairs and qualification

1. Compile complete visual/structured task contracts with actual step and entity IDs, constraints and future targets. The bounded English grammar cannot establish every requirement in an arbitrary request.
2. Replace raw action-family history with durable target/payload/observation-bound dispatch receipts. A recorded click does not independently establish the intended application outcome.
3. Extend supported recovery through reviewed capabilities for higher-level search, submissions, date/location widgets, scrolling, generated text and intermediate information. Continue preserving obstacles and clarification.
4. Compile visual repetitions before relaxing global TYPE/ENTER suppression; qualify interruption and resume at each dispatch boundary.
5. Build and execute the registered deterministic and production-composition fixtures when the test pause is lifted. Runtime errors, model interpretation, real AX events and OCR remain unqualified at this source checkpoint.
6. Address measured resource use in the later performance phase. Then obtain the user's explicit permission before flight, concert and movie real-site scenarios. This patch makes no 8 GB, thermal, latency or general natural-language success claim.
