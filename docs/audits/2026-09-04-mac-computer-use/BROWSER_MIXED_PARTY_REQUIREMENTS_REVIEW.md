# Retain mixed adult/child requirements through clarification, forms and result assessment

Source checkpoint: 2026-09-09. Parent: `f320c7e`. Source repair and prepared coverage only. Builds, typechecking, assertions, app/browser execution and inference remain paused.

## First-principles findings

“2 adults and 1 child” describes two categories in one party. Replacing it with “3 people” loses the composition. Independently checking only one component also loses part of the request. The [quantity clarification repair](BROWSER_QUANTITY_CLARIFICATION_BINDING_REVIEW.md) handled a count and one unit but could not represent this mixed requirement.

The same meaning must survive three boundaries: a scoped answer must retain earlier counts; a form needs independently addressable adult and child values; a result needs sufficient capacity in each requested category. Entered search criteria, a purchase limit or a package size cannot provide that availability evidence.

## Source changes

The [scalar compiler](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) now has a canonical `PartyComposition` with exact adult and child counts, each bounded from 0 to 999. Its identity includes both counts in a stable category order. The literal grammar accepts one adult and one child clause, in either order, separated by “and,” a comma, “&” or whitespace, with optional initial “for” or “exactly.” It uses the existing numeric and one-through-ten word counts. Duplicate categories, disjunctions, ranges, ages, infants and additional trailing meaning remain unparsed.

A scoped mixed-party answer can refine an exact total people count, an exact unitless count with the same total, or an exact adult/child count with the same corresponding component. It cannot replace a different count, ticket quantity or bounded comparison. An already known composition can be confirmed as a whole; a compatible literal component or total confirmation retains the entire composition rather than replacing it with the shorter answer. Unit-only and count-only replies cannot erase known categories.

An answer to a missing-detail question under an outcome receives its own exact source condition. Existing source-scope, atomic binding, historical retention and native scalar meaning rules apply. New model source/prohibition labels cannot remove a retained party composition. A full typed answer must still reconcile to one complete current clause; this does not implement arbitrary split/merge recovery.

[Form input normalization](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) exposes separate adult and child values with distinct IDs and units under the same requirement index. Zero child counts remain explicit. It emits no booking value for a result count and does not replace the two category values with an aggregate. The [form planner instructions](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPlanner.swift) retain both category obligations across stages. Existing native control type, representability, ownership, preservation and actual-input checks still apply. The original source identifies the purpose of each edit; entering one field is not proof that the entire party criterion is satisfied.

[Result assessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) can parse a compound quantity quotation or collect separate adult/child quantity quotations for a single reviewed offer. All proposed availability literals must parse. Every requested nonzero category needs capacity evidence. An additional people-capacity quote must also cover the requested total; a total alone cannot substitute for missing category evidence. Duplicate category quotes are ambiguous and are not summed. Unrelated ticket/result units, unknown meanings, selected counts, purchase limits and package sizes cannot satisfy the mixed-party condition.

Compound quotations also participate in single-category checks. They cannot be silently discarded when another quotation reports the same category, and cannot be converted into ticket inventory. This prevents the newly parseable literal from hiding a conflict that was previously held as unparsed. Capacity status remains arithmetic conditional on the existing offer/availability review; it does not prove provider age definitions, simultaneous bookability, current purchase selection or whole-task completion.

Answer eligibility consumes the resulting complete-party capacity status. An offer reporting one adult and two children cannot satisfy a two-adult/one-child request merely because both totals are three. Navigation-history completion gates and account handoff controls are unchanged.

## Prepared coverage and permitted checks

Eleven new methods are authored and unrun:

- Two [scalar methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserScalarRequirementsTests.swift) cover grammar/order, bounds, unsupported meanings, exact composition comparison, partial capacity and total ceilings.
- Three [clarification methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) cover compatible total/component refinement, conflicting replacements and a new mixed answer followed by a scalar confirmation under changed model labels.
- Three [assessment methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResultAssessmentTests.swift) cover missing categories, compound/separate quotations, total ceilings, duplicates, incompatible units and non-availability meanings.
- Two [form methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPlannerTests.swift) cover distinct normalization IDs and the actual native owner path for two number fields followed by one verified query.
- One [answer method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift) covers eligible versus insufficient compositions with the same total. Its fixture now supports a compound party-capacity quotation and the existing availability qualifier.

Nine changed Swift files pass parse-only syntax checks. Default/focused source inventories select 1680 / 997 methods, with eleven additions and no removals or renames. These source checks do not establish type correctness or assertion outcomes. No browser fixtures, app launches, local models, computer-use sessions or remote GPU jobs executed.

## Remaining work

Party meaning must still be reconciled across separately partitioned requirements, trip/offer scopes and answer turns. Independent adult/child predicates are not a certificate that the complete party was jointly assessed, and this change does not apply an aggregate ceiling across arbitrary independent clauses. Do not fix this by globally summing unrelated parties or trip legs. Source partition reconciliation, component-specific criterion coverage across form stages, provider age categories, ages/infants, group bounds, aggregate-only passenger controls and intent replacement remain open.

Runtime/model qualification, account/document recovery, 8 GB resource qualification and the complete natural-language travel/concert/movie scenarios also remain open. Continue the [repair checklist](../../../TODO.md); live tests await explicit permission.
