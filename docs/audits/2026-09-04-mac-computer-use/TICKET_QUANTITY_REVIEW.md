# Ticket quantity is not a count of result listings

Source checkpoint, 2026-09-08. Previous checkpoint: `c2a8915`. Execution remains deferred.

## First-principles defect

Research answers need the right unit as well as the right number. Before this repair, the scalar compiler kept `tickets` distinct from `results`, but downstream assessment used a binary party/non-party test. Tickets fell into the non-party branch and were labeled `needsResultSet`. The form normalizer also offered only party quantities, leaving an exact request such as `two tickets` unavailable for a native ticket-number control. Two listings cannot establish two tickets for one event, and neither implies two adults.

This defect must be resolved before complete result predicates can be trusted. It did not already cause a terminal false-success claim: the current browser research path still has no complete answer implementation. It did misdescribe pending evidence and omit a needed form value.

## Source changes

- [The scalar quantity type](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) now exposes three scopes: `resultSet` for results/options/flights/concerts/movies, `ticketInventory` for tickets, and `party` for people/adults/children. The exact original unit remains in its predicate and identity. Arithmetic comparisons still reject differing units; no conversion from tickets to people, results or age categories is introduced.
- [Form input v9](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) provides an explicit `ticketCount` normalization for an exactly bound ticket quantity. Party values retain `partySize` and their original people/adults/children unit. Both use the original requirement index and source-bound value ID. Result counts, minimums/maximums, ranges and unsupported source grammar do not supply an exact booking quantity.
- [Form proposal admission](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) allows `ticketCount` only through the existing normalized-number path. Model-supplied numeric text or invented value IDs are not accepted. Native field constraints, representability preflight, complete source/clock identity, journaled input, post-input verification and query receipt checks remain in place. Choosing the right *meaning* among multiple number fields still depends on the complete-goal model proposal; type checking alone cannot prove that a label means tickets rather than adults.
- [Form planner contract v8](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPlanner.swift) receives the whole current input, distinguishes ticket count from party/result count and keeps date/type/price/fee requirements in scope. It does not infer an adult/child breakdown, choose an exact value from a bound, or interpret a verified count edit as inventory evidence. No additional inference call or worker is added.
- [Assessment v3](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) gives every original requirement a nullable `quantity_scope`. Bound ticket requirements remain `needsTicketInventory`; party requirements remain `needsPartyCapacity`; result quantities remain `needsResultSet`. Existing complete quantity quotations remain attached as observations, without positive availability claims. A number can describe stock, a pack size, a limit or a selected count; its spelling does not distinguish them.
- [Link planning](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserLinkPlanner.swift) and [action planning with recalled evidence](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) receive explicit instructions for those pending statuses and scopes. Historical assessment retains the original unit/goal revision. Counting more cards cannot resolve ticket availability, and a selected search quantity cannot complete the research answer.

This is a representation and capability repair. It does not prove stock, seating together, age/fare/category eligibility, dates, bookability or full totals/fees. The arithmetic `equal` comparison remains a literal count comparison; it is not changed into an available-stock test such as `available >= requested`. A separate offer-level evidence compiler must establish that meaning before using capacity arithmetic.

## Prepared verification

Six added source methods cover:

1. Every existing quantity unit's scope and rejection of arithmetic comparisons against other units, including tickets versus adults and results.
2. Distinct exact ticket/party normalizations, with result quantities, bounds and unsupported/ambiguous sources excluded from booking values.
3. A complete source-bound ticket/adult form proposal through the actual local planner with a fake transport, native edits to separate controls, and one journaled GET query. Repeating query reconciliation must return the same receipt without another input or request. The untouched result-display control retains its prior value.
4. Rejection of ticket normalization in text/date controls and native representability failure before any input when the observed maximum cannot hold the requested ticket count.
5. A full requirement assessment that retains distinct option/ticket/adult scopes even when a quoted ticket number matches, with the same pending statuses reaching link planning.
6. A scoped ticket-count answer adding ticket inventory work without replacing the original result count, root task or clock, and exposing its ticket normalization to later form planning.

See [scalar regressions](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserScalarRequirementsTests.swift), [form regressions](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPlannerTests.swift) and [assessment regressions](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResultAssessmentTests.swift). Three existing methods are updated for the repaired normalization and pending-status behavior.

The [default source inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,129** methods; the [focused inventory](browser-ticket-quantity-inventory.json) selects **446**. Ten changed Swift sources pass syntax-only parsing. Both source inventories match, whitespace checks pass and 156 local documentation links resolve. Existing files already belong to the Xcode targets; no registration change is needed. These checks neither typecheck nor execute assertions. No build, XCTest/model execution, application/browser/computer-use activity, installed-app replacement or held-out inspection/run occurred.

## Remaining repair order

1. Compile offer-level ticket/party evidence with correct date, type, category, availability and quantity meaning, then connect complete research answers. Distinct qualifying option counts and full result-set ordering remain separate work.
2. Resolve price basis and full totals/fees for the requested selection. A per-ticket price and requested ticket count alone do not establish the final payable amount or available inventory.
3. Extend compound quantity scope deliberately: multiple events, per-person/per-offer counts, age/category breakdowns, alternatives and scoped answers that actually revise an earlier count. Do not discard earlier source clauses or infer a conversion from unit labels.
4. Qualify the form/action/link/review contracts, exact full-context fit and native number/select behavior on the actual model after authorization. Keep broader custom/POST forms, provider/login continuation and durable parent recovery in the repair list.
5. Continue to defer real-site travel/concert/movie tests until development readiness and explicit permission. Alternate models and the RTX 3080 desktop remain options after evidence identifies model shortcomings; SSH access/hardware remain unverified. Performance/thermal and physical 8 GB qualification stay deferred.
