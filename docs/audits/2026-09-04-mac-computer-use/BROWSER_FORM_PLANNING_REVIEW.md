# Plan research form values under the complete goal

Parent: `4e8cdad`. This checkpoint adds source implementation for form proposals, typed payload preparation, native preflight and shared-runtime access. The default research driver does not yet execute these form stages. Current compilation, model accuracy and runtime behavior are unqualified.

## First-principles findings

The previous checkpoint established which editor field corresponds to an observed page control. It did not establish what should be entered. Three additional distinctions are necessary:

1. **Source text versus derived values.** A city or search phrase can use the user's exact text. A native date input cannot accept “tomorrow”; it needs a civil date derived from the task's original clock and time zone. A model-generated date string would discard that provenance.
2. **Party size versus result quantity.** “Find three options for two people” contains two different counts. The existing scalar vocabulary only represented results/options/flights/concerts/movies/tickets and sent every bound quantity to result-set assessment. Treating the number of result cards as evidence for two travelers is incorrect.
3. **Option identity versus option label.** Separate optgroups can contain the same visible label with different meanings and submission values. The text contract previously resolved every select edit by label, rejecting duplicate labels. A bound option reference needs its own operation; an ordinary text string must not become an option ID merely because its spelling resembles one.

An intermediate form edit also does not fulfill the whole research request. The original constraints, evidence requirements and prohibitions must remain attached after search fields are filled.

## Source changes

- Form context version 2 adds a host-derived normalization catalogue. Exact single-day predicates become native `date` values using the original reference clock. Exact `people`, `adults` and `children` counts become native `number` values with their units retained. Desired result counts, ticket counts, maxima/minima, ambiguous dates and multi-day ranges do not become exact party/date values.
- The scalar parser recognizes the existing bounded count language for people/adults/children and an optional “for”. Party counts now require semantic verification of the offer/party relationship; they are not classified as missing result-set counts. The quantity question explicitly distinguishes results, tickets and people.
- `ComputerUseBrowserFormProposal` accepts one strict alternative: an ordered edit proposal, a scoped typed question, or unavailable. Each field may occur once, up to eight edits; explicit preservation names disjoint fields and their motivating user requirements. Text edits retain the existing exact source-term provenance and Unicode/order checks. Normalized values must be offered by the host and match the native control kind. Select references must belong to that exact field and be available. Extra keys, invented values, hybrid alternatives, repeated fields, prohibited payload sources and invalid question scopes are rejected.
- A proposed text contract retains the original root task and hashes the full goal/page context. Only user-scoped preservation becomes an unchanged-value invariant. Unedited fields receive no direct edits, but may react to legitimate website events; dependent later edits still need fresh evidence. Source-bound text, normalized values and option references stay distinct until contract construction. The contract is preparation data, not an attempted or completed task.
- A separate `selectChoice` operation allows the native contract to select a specific retained option, including duplicate labels. Existing literal/copy behavior still resolves labels and cannot reinterpret a literal as an option ID. Hidden/disabled/foreign options remain invalid. The frozen text-model acceptance adapters explicitly reject this new operation; their fixtures and model contracts were not changed or run.
- The local form planner uses authenticated loopback requests, strict schema, the full unchanged planning context, exact input token counting and the existing 4096-context/1024-output/64-reserve limits. It neither truncates the goal nor starts an additional model worker. The shared runtime applies its existing lease, resource checks, endpoint identity and cancellation cleanup.
- The research owner's `planForm` retains exclusive operation ownership through actual planning, revalidates native form evidence before and after the model response, checks exact proposal/input identity, performs native representability preflight and revalidates again before publication. No edit or submission is dispatched. Failure or interruption invalidates the speculative form input; explicit handback must prepare a fresh input under the original goal.

Native correspondence, literal provenance, normalization and representability do not prove a model's semantic field assignment. “Origin” could still be interpreted incorrectly, a choice could be semantically wrong, or a prior requirement split could misrepresent negation. The complete source remains available and no completion certificate is produced. These judgments still require qualification and task/result verification.

## Prepared regression coverage

Fourteen methods in `ComputerUseBrowserFormPlannerTests` cover exact date conversion across a daylight-saving boundary; party/result/ticket/bound/range distinctions; native result assessment; source text/date/count/select contract construction; explicit unchanged-field constraints versus legitimate site updates; actual identified select dispatch and receipt checking; duplicate-label and literal-ID separation; strict proposal decoding; Unicode and source ordering; foreign page/clock rejection; native representability failure; cancellation and explicit handback; value drift during planning; scoped questions; exact context budgets; and transport cancellation boundaries.

All browser/model behavior in that sentence describes prepared fixture cases, not executed results. Native select execution is authored as a future test. Transport fixtures do not run a model. Existing held-out qualification data was neither inspected nor executed; only two source adapters gained exhaustive handling of the new enum case.

## Remaining repair order

1. Retain the proposed contract as a parent research stage with a stable stage identity, original goal, remaining requirements, exact adapter and preconditions. Persist before dispatch. Reconcile native receipts and uncertain attempts before any replay; do not rediscover fields to recover an attempted stage.
2. Execute the retained edits through the existing transaction engine, then prepare a native GET query from the verified continuation and exact submitter. Keep page/source checks and the original task across navigation. Form fields with dependencies need staged re-observation without losing proven effects.
3. Connect form decisions and retained-stage recovery to the default driver, alongside current link reading/selection. Route scoped questions through the existing host/phone continuation. A no-form decision must preserve the research goal and permit other supported progress.
4. Complete blocked sign-in redirect/provider-window handoff and explicit resume. Reconcile the pending form/navigation stage after fresh authenticated observation without reading credentials or repeating uncertain effects.
5. Extend typed planning for ticket/inventory quantity, singular/plural and richer party language, date/time ranges, budgets/fees, native scalar formats and supported location/airport transformations. Do not confuse a constraint operand with an exact requested value. Add separately contracted autocomplete, calendar/custom widgets, POST/dynamic submission and embedded controls.
6. Finish offer association, distinct qualifying counts, prices/fees/availability, ranking, public source links and answer assembly. A form plan, typed scalar match or selected option remains intermediate evidence.
7. When authorized, typecheck/build and execute bounded native and actual-model qualification before deferred travel/concert/movie website E2E. Exact token admission and the shared process are source architecture, not measured thermal or 8 GB performance evidence. Keep model adaptation separate from app defects and held-out qualification.

## Verification performed

Thirteen changed Swift sources passed syntax parsing only. Two fixture JavaScript snippets passed `node --check`, and their temporary files were removed. Xcode project plist syntax and new source registration were checked. Default and focused manifests match **970** and **287** source methods respectively; see the [focused inventory](browser-form-planning-inventory.json). Local documentation links and whitespace were checked.

No typechecking, builds, assertions/tests, model inference, app launch, computer use or live website tasks ran. No installed app, model or remote desktop was modified. No generated build/syntax artifacts were retained. The complete repair goal remains open.
