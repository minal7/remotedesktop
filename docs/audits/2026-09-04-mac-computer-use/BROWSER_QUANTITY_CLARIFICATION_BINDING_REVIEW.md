# Preserve counts and units through scoped quantity questions

Source checkpoint: 2026-09-09. Parent: `0ac7e1e`. Source repair and prepared coverage only. Builds, typechecking, assertions, model inference and browser execution remain paused.

## First-principles findings

A quantity contains a count, a comparison and a unit. “At least 2” already states two of these. Rejecting it as wholly unrecognized loses information needed to interpret a later “tickets.” Conversely, treating a bare “2” as a complete requirement invents what is being counted. Result counts, ticket inventory and party size have different meanings and must remain separate.

The existing [scalar compiler](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) had no quantity-answer binding. A standalone answer could not reliably finish its earlier clause. Singular forms such as “1 ticket” and “1 adult” also failed the literal grammar, including in native page quotation parsing.

The [historical weekday repair](BROWSER_HISTORICAL_WEEKDAY_RECOVERY_REVIEW.md) separated native scalar meaning from successful binding. Quantity answers need the same distinction: a conflicting “3 tickets” remains a quantity answer even if a model labels it as a website condition. A changed field or role must neither satisfy a missing unit nor prevent a successfully bound literal from being assessed according to its native meaning.

## Source changes

The quantity parser now represents an otherwise complete count/comparator without a unit as `missingQuantityUnit`. The bounded grammar retains numeric counts from 0 through 999 and word counts one through ten, with the existing supported comparators. A model-supplied relation that contradicts the literal comparator remains unresolved. Singular/plural unit aliases normalize to the existing units and scopes; no conversions between people, tickets and result counts are introduced.

Accepted question-time interpretations retain unitless quantity clauses as `historicalQuantityUnit`, using the exact turn and normalized byte occurrence from the [historical scalar repair](BROWSER_HISTORICAL_SCALAR_REVIEW.md). New model labels cannot discard the earlier count or comparator. Merged or split historical clauses remain unresolved rather than acquiring a predicate on a broader outcome.

The native quantity binder consumes only whole supported quantity answers to a sealed quantity question. A unit-only answer fills an existing count. A count-only answer confirms the count but leaves a missing unit unresolved. A full count/unit answer preserves the earlier comparator unless an explicitly stated matching comparator confirms it. Changed counts or comparators conflict. Known units remain fixed, except an explicit answer may refine a people count to adults or children while retaining the same count and comparator. Sibling age categories, reversed refinement and inventory/party/result changes conflict.

Questions bind exact source occurrences. A broad scope containing multiple counts is ambiguous. Separately selected counts can receive the same unit while retaining their individual numbers. Application to multiple selected targets is atomic: a conflicting count answer cannot partially update the selection. Follow-ups on a previously bound quantity answer return to its original targets; earlier answer bindings stay unresolved until all their targets have units.

A missing count asked under an outcome receives its own answer condition. It does not replace “Find concerts” with a numeric predicate. The whole normalized answer must correspond to one exact current source clause. “2” can therefore receive a second native quantity question, followed by “options,” while the root request, clock and answer turns remain retained. Genuinely new native answer conditions do not invent historical model source IDs.

The [question boundary](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalClarification.swift) accepts native missing-unit eligibility for the exact current requirement despite a changed model field or role. The [research owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) adds one missing-unit question after its existing explicit-model, source and date question priorities. Existing controller/session ownership, input identity, scope and question lifetime checks still apply.

[Result assessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) keeps partial and conflicting quantities uncompiled. A typed but unbound scalar answer cannot enter semantic review as an unrelated condition. Native quantity quotations share the singular/plural unit aliases; quoted counts still require digits. Capacity comparison continues to require the existing offer association and availability review rather than equating a number on a page with available inventory.

[Answer eligibility](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchAnswer.swift) uses native meaning for successfully bound scalar clauses and parameter answers, including an erroneous source/prohibition label. Incomplete or conflicting answers receive no such completion authority. Result-set quantities still constrain the number of distinct qualifying options selected. Existing navigation-history completion gates remain in place.

## Prepared coverage and permitted checks

Ten new methods are authored and unrun:

- One [scalar method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserScalarRequirementsTests.swift) covers singular units, missing-unit states, relation conflicts and unsupported compound/fractional/large quantities.
- Seven [clarification methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) cover count/comparator preservation, party refinement, conflicting changes, new answer conditions, partial-answer follow-ups, repeated occurrences, broad ambiguity, atomic multi-target binding and historical relabel/split/merge handling.
- One [driver/assessment method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResultAssessmentTests.swift) prepares a native quantity question before any search, scoped answer continuation under the original goal, and sufficient adult versus insufficient singular-ticket capacity quotations.
- One [answer-selection method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift) prepares the complete “2,” then “options” question sequence with incorrect navigation-source/prohibition labels. It requires two qualifying results, rejects a one-result selection, and retains one search under the original root and clock.

Nine Swift files pass parse-only syntax checks. Default/focused source inventories select 1669 / 986 methods: ten additions and no removals or renames. These checks do not establish type correctness, assertion outcomes or runtime behavior. No fixtures, app launches, local models, computer-use sessions or remote GPU work executed.

## Remaining work

Mixed adult/child compositions, ages, infants, provider passenger categories, changes to an earlier count, comparator narrowing and general intent replacement remain unresolved. A native fallback still depends on a research-classified proposal or an admissible explicit question; this is not general model classification correction. Location/time/count associations, form criteria across revisions and account/document recovery still need repair and qualification. Continue the [repair checklist](../../../TODO.md). Real travel, concert and movie tasks remain deferred until explicit permission.
