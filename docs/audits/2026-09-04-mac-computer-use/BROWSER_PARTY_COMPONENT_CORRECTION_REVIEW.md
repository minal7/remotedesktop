# Correct one party count while retaining the other

Source repair; execution pending. This extends [whole-party replacement](BROWSER_PARTY_REPLACEMENT_REVIEW.md). No build, typecheck, assertion/test run, browser/app launch, local model invocation, account login or SSH attempt occurred.

## First-principles findings

For a request containing `2 adults and 1 child`, changing the adult count to three should produce a party of three adults and one child. The new answer need not repeat the child count, but that count still needs a source and must remain an active requirement. A total of four people does not establish the requested category breakdown.

The existing native correction only replaced both counts together. Reusing that question for `3 adults` would either reject the answer or require guessing what happened to the child. Treating the answer as a new scalar adult requirement would leave conflicting old party state, and simply erasing the old party would lose the child requirement. The correction needs an explicit category-specific question and a native derivation from one known current party.

That derivation is only valid while the unchanged count is known. If an earlier answer has made the party unresolved, a partial correction must not select whichever old value is convenient or erase the unresolved conflict. The current repair deliberately requires a fully bound party before issuing a component question.

## Native question and binding

The [question catalogue](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalClarification.swift) adds `replaceAdults` and `replaceChildren`. Both select every source row of one complete active party. They ask for an exact count with the matching category label, and the rendered question displays the native count that will remain unchanged. The normal scoped reference, owner, controller/session, expiry and original source excerpts remain in use. A model supplies neither the retained count nor replacement text.

The [scalar ledger](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) admits these questions only for one complete, currently bound party. Partial source selection, scalar totals, two different origins, shared confirmations and unresolved party conflicts cannot become a component replacement. Whole-party replacement remains available for supported whole-party conflicts.

An accepted component answer must match the bounded native grammar: one exact numeric or supported word count, an adult/child label matching the question, and optional `exactly`. Numeric zero is allowed. Bare totals, the other category, both categories, bounds, negation and additional instructions cannot compile as this correction. The normal source normalization and exact retained answer bytes remain in place.

The new bound party combines that count with the other count from the selected current native party. Every row of the old party retains a supersession record, and the new answer rows anchor the derived party through the typed question's full scope. The new answer is not misrepresented as a literal quotation of both counts. Intermediate component and whole-party corrections retain their replacement links, original source text and answer clocks. Existing whole-party supersession identities remain unchanged; the new component topics have distinct identities.

The derived party's source identity uses the complete native answer span rather than an individual model-selected row. Splitting `3 adults` into multiple rows therefore cannot create several party identities. Existing literal-party and scalar-refinement identity paths are retained.

## Form and result behavior

[Form history](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) recognizes the two component correction topics as party supersessions. The old adult, child and total field purposes remain historical. All three need current source verification before a query, including the unchanged category. An unchanged native field may be verified without another input event; its old receipt alone cannot establish the new party association.

The existing normalization path emits both categories and their derived total from the bound party. For component corrections, the full new answer scope anchors these values together with its native question lineage. The goal, form, action, search and link planner instructions explain this derivation and the requirement to preserve all unrelated constraints.

Result assessment and answer eligibility use the existing native quantity-supersession path. They must check both category capacities and the original budget. Sufficient total capacity with too few places for the retained category cannot qualify. A component correction does not establish availability, provider category meaning or task completion.

## Prepared verification

Six new methods are authored and selected by the [component-correction inventory](browser-party-component-inventory.json), all unrun:

- Four [clarification methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) specify retained-count wording; unchanged budget and ticket requirements; original and answer repartitioning; one derived identity; zero children; invalid answers; incomplete/multiple scope rejection; unresolved conflict preservation; and successive adult, child and whole-party replacements.
- One [form method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPlannerTests.swift) specifies a corrected adult or child count, fresh verification of the retained category, a changed total, preserved unrelated input, no old query and one query with the revised party. The existing whole-party scenario now shares its fixture with these cases. Its decoder method also covers all three party replacement topics through goal, action and form decoders.
- One [driver/answer method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift) specifies the explicit component question before navigation, then compares sufficient capacity, insufficient capacity for the retained category at the same total, and an excessive price. It retains the original goal and budget.

Eleven changed Swift files pass parse-only checks. Active inventories select **1870 default host / 1187 focused host** methods, six additions and no removals. The focused client core inventory remains **30**. Source registration and syntax are not passing assertions, typechecking, compiled discovery, native browser evidence or model qualification.

## Remaining sequence

1. Compile and run these cases only when execution is authorized again. Qualify actual planner selection, phone question display, native field events, query submission and result provenance. The proposed form and driver fixtures use controlled planning and pages; they do not establish real website or local-model competence.
2. Extend recovery for unresolved component conflicts and unsupported answers without discarding any newly expressed requirement. Invalid component replies remain retained and uncompiled. This repair does not promise an in-place recovery path for every such reply. A whole-party question cannot be used to erase unrelated instructions embedded in an invalid answer.
3. Continue direct user steering, broader phrasing, shared multi-origin confirmations, distinct trip/event parties, ages, infants, provider categories, eligibility and conditional clauses. Current admission requires a known bound adult/child party and a complete explicit question scope.
4. Continue location, budget and source-policy corrections, durable native browser/account/process recovery, progress detection and whole-goal verification in [the repair tracker](../../../TODO.md). Global navigation-source completion remains restricted pending qualification.
5. Qualify the added planner instructions against the existing complete-input token limit and supported lightweight models. No model variant was run or selected; 8 GB memory, thermal behavior and the reported RTX 3080 desktop remain unqualified.
6. Retain the real flight, concert, movie and account-login scenarios for the later explicitly authorized stage. None ran here.
