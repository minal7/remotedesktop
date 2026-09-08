# Quantity meaning before capacity arithmetic

Source checkpoint, 2026-09-08. Previous checkpoint: `9c7407a`. Execution remains deferred.

## First-principles defect

The number and unit do not identify what a count describes. `3 tickets` can be selected in a form, included in a package, imposed as a purchase limit or offered as remaining stock. Those meanings require different decisions. Even after separating tickets from result counts and adults, the previous review contract could not express that distinction. The native assessment therefore retained all ticket counts as unresolved inventory work.

For a request for two tickets, three *available* tickets can be numerically sufficient. Three selected tickets can instead be an incorrect form state; a package of three can violate the intended purchase; a limit of three says nothing about stock. Literal equality must remain distinct from capacity arithmetic. Neither comparison establishes dates, ticket type, seating, selection, price, eligibility or bookability.

## Source changes

- [The review input and closed decoder](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultReview.swift) use contract v3 when the selected reading contains quantity fields. Every field then carries a quantity meaning: `availableQuantity`, `selectedQuantity`, `purchaseLimit`, `packageSize`, `unknown` or `notQuantity`. Quantity fields cannot use `notQuantity`; other fields must use it. Missing, null, invented or extra values are rejected. Inputs without quantity fields retain their existing v1/v2 shapes and omit this member.
- `availableQuantity` requires single-offer association, offer scope, a complete projected text/structure reading and at least one observed supporting qualifier. Citations cannot borrow another selected candidate's subtree or cut a selected field into partial records. These rules validate the proposal's structure and references; they do not independently verify the model's interpretation of those records.
- [The local reviewer](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultReviewPlanner.swift) receives instructions to distinguish stock from selected counts, limits and packages, and to retain ambiguity for mixed, conditional, negated or control-dependent quantities. The complete request, scoped answers, page, candidate fields and requirement ledger remain in each request. Quantity requirements still cannot receive a candidate-level `supports` judgment.
- [Partitioned review](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserReviewParts.swift) carries the same meanings through part contract v2. Its conservative canonical output bound includes the added member on every field. The exact ordered assembly must pass the ordinary full-review decoder before publication. Existing 896-byte output planning, 32-part ceiling, full-input token admission and one 30-second cancellation deadline remain. There is no additional inference stage or worker.
- [Native scalar comparison](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) adds arithmetic conditional on a proposed available-capacity meaning. Exact and minimum requests compare `available >= requested`; a strict lower bound uses the next integer with overflow rejection. Upper bounds remain unresolved because they do not establish an exact/minimum selection. Different units, result counts, negative values and non-quantity literals cannot pass. Existing literal equality is unchanged.
- [Assessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) retains separate statuses for selected quantities, limits, packages and unresolved meanings. Only proposed available counts enter `quotedCapacitySufficient` or `quotedCapacityInsufficient`. All available-count quotes must parse completely; multiple matching units remain ambiguous, and ticket/adult/child/person units cannot be substituted for one another. Parsed quantities of different units can be compared separately. Result-set counts remain separate work. Incomplete readings cannot receive a capacity comparison.
- [Current link planning](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserLinkPlanner.swift) and [action planning with recalled readings](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) receive the meanings and conditional-status limitations. The full review participates in native candidate identity; changing a meaning changes its digest. Historical qualifiers retain their reading namespace and cannot authorize current inputs, navigation or completion.

The quantity literal grammar remains deliberately narrow: a whole count of one to three digits followed by an existing plural unit, with whitespace normalization. This change adds people/adults/children to that grammar. It does not parse a number out of ranges, stock phrases or conditional text. Broader grammar needs source-bound normalization with complete qualification handling, not substring extraction. The assessment context keeps its v3 structure and adds the new status values.

## Prepared verification

Seven added source methods cover:

1. Exact/minimum capacity arithmetic, strict bounds, unsupported upper bounds, unit mismatches, negative counts and unchanged literal equality.
2. Full quantity review contract admission and preservation of legacy v1/v2 review shapes.
3. Missing/wrong meanings, scope/association failures, incomplete readings, partial citations, duplicated references and references borrowed from another candidate.
4. Partition output bounds, unchanged full input, complete assembly, final semantic admission, qualifiers and digest changes.
5. Actual local whole and partitioned planner paths with a fake transport, matching token-count/completion request bodies, full context and the existing 1,024-token output limit.
6. Native driver/assessment/link/history composition for available, selected, limited, packaged, unknown, incompatible and unparsed count proposals. The driver must return partial research progress rather than a completed answer.
7. Multiple conflicting capacity counts and separate ticket/adult quantities, without dropping unparsed competing capacity evidence.

See [quantity contract tests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserQuantityReviewTests.swift), [scalar tests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserScalarRequirementsTests.swift) and [native assessment tests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResultAssessmentTests.swift). Deliberately wrong semantic proposals in negative fixtures test native rejection; they do not simulate or qualify model understanding.

The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,136 source methods**; the [focused inventory](browser-quantity-review-inventory.json) selects **453**. Ten changed Swift files pass syntax-only parsing. Source inventories, Xcode project syntax/registration, local documentation links and whitespace are checked. These checks do not typecheck the implementation or execute assertions. Fake token counts are not evidence that the actual full prompt fits the model budget.

No builds, test assertions, model runs, application launches, browser/computer-use activity, installed-app replacement or held-out inspection/run occurred. About 15 GiB of disk space was available; no obsolete generated files needed removal in this checkpoint.

## Remaining repair order

1. Bind the proposed count to the actual requested date, ticket/fare/age category, location, seating and current page/control state. Omitted controls and stock freshness remain unresolved. The review's completeness flag covers projected text/structure, not all omitted controls. Require further evidence when applicability depends on them.
2. Preserve simultaneous package, policy, selection and capacity constraints. A passing capacity comparison cannot erase a purchase minimum, selected-count mismatch or another original requirement. Add deliberate handling for multiple offers/events, per-person counts, age breakdowns, alternatives and revised scoped answers.
3. Compile complete selection prices and fees. Multiplying a per-ticket price by the requested count does not prove availability, final total or payable fees.
4. Connect source-backed complete research answers, distinct qualifying result counts and requested ordering. The current driver still produces partial progress and cannot certify a completed travel/concert/movie research task.
5. Qualify the changed contracts, full-context fit, latency and cancellation on the actual model after execution is authorized. Separate application failures from model errors before changing models or using the RTX 3080 desktop for adaptation. SSH access and remote hardware/toolchain remain unverified.
6. Continue provider/login handback, remaining-form reconciliation and durable parent recovery. Preserve the original goal and explicit user handback throughout.
7. Keep real-website scenarios deferred until readiness and explicit permission. Performance and physical 8 GB Mac qualification remain later work.
