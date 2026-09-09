# Preserve weekday uncertainty and recover through the scoped question path

Source checkpoint: 2026-09-09. Parent: `8f20546`. Source changes and prepared coverage only. Builds, typechecking, assertions, inference and browser execution remain paused.

## First-principles findings

The [historical scalar repair](BROWSER_HISTORICAL_SCALAR_REVIEW.md) preserved already parsed predicates, but a weekday such as “Friday” had no concrete predicate to preserve. A later model could relabel it after an unrelated answer, losing both the native unresolved state and the route to a date question. Preserving uncertainty is part of preserving a requirement.

A separate issue conflated a scalar answer's meaning with its successful application. A literal “CAD” can conflict with an existing USD budget while still being a currency answer. Once binding failed, source compilation could instead treat a mistaken website label as a new source question. The conflict should remain visible in scalar evaluation without changing what kind of answer was supplied.

## Source changes

The [scalar compiler](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) retains a typed `historicalDateAmbiguity` with native historical source IDs for complete weekday clauses from accepted question-time interpretations. The existing exact turn/byte-occurrence reconciliation applies. Merged or split meanings retain `historicalScalarScope`; no shortened clause can discard an earlier modifier. These states are counted as unresolved and cannot supply a passing date comparison.

The retained weekday grammar is bounded: a weekday, optionally preceded by “on”/“for” and “this”/“next”, with the existing boundary normalization. Earlier compatible date relations are required. A bare weekday is eligible for a native date question. Relative-week modifiers remain unresolved because their calendar meaning has not been compiled here. Arbitrary unknown source text or a weekday spelling without retained date provenance does not acquire this historical authority.

The [question boundary](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalClarification.swift) accepts the native date-question eligibility for that exact current requirement even when the model's new field or role would reject a date topic. The override applies only to date questions. Current input, known unique requirement IDs, complete scope, answer bounds, lifetime and controller/session ownership checks remain in place. The existing owner selects one native weekday occurrence at a time in a research-classified proposal; explicit model questions retain their existing precedence.

A compatible answer resolves the original occurrence through the [scoped date binder](BROWSER_DATE_CLARIFICATION_BINDING_REVIEW.md) and carries its historical IDs into the concrete condition. Wrong weekdays and conflicting concrete dates remain unresolved. No question text or model interpretation is inserted as a new user instruction, and the original goal clock remains unchanged.

Native scalar source IDs are now computed separately from final binding results. They include retained complete scalar clauses, retained weekday ambiguities, and whole literal answers to the supported currency/price-basis/fees/date topics. [Source compilation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserSourceRequirements.swift) uses that meaning even when application conflicts or scope reconciliation fails. It does not grant a successful binding. Compound or otherwise unparsed answers receive no literal-source exception.

[Result assessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) reports a retained date ambiguity as `uncompiledRequirement`, after existing source-history/policy checks. Native conflicts still prevent semantic review from satisfying the affected rows. Route-history completion remains gated. Wire formats, browser input, model stages and permission controls are unchanged.

## Prepared coverage and permitted checks

Four new [clarification methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) prepare changed-label/role/relation recovery, retained relative-week modifiers, missing historical authority, split/merged source rejection and conflicting literal scalar meanings. An existing repeated-date expectation now records the retained uncertainty explicitly.

One new [driver/assessment method](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResultAssessmentTests.swift) prepares the full sequence: an initial location question, an unrelated answer followed by a falsely labeled weekday, a native date question before any search, and continuation under the original root and clock. Compatible and conflicting date answers check distinct native assessment states, one search, and no spurious website question.

Eight Swift files pass parse-only syntax checks. Default/focused source inventories select 1659 / 976 methods, with five additions and no removals or renames. These are source checks only; no assertions, browser fixtures, models, app launches, computer-use sessions or remote training jobs executed.

## Remaining work

General historical uncompiled meanings, explicit correction of model classifications, supersession, relative-week/calendar conventions and broader date/location/time/count associations remain open. A retained interpretation is not proof that every earlier model classification was correct. The complete model/host/client flow and login/document recovery still need qualification. Continue the [repair checklist](../../../TODO.md); real travel, concert and movie tests remain deferred to explicit permission.
