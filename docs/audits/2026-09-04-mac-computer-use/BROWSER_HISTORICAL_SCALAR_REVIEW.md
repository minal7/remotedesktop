# Retain native scalar obligations when the model relabels earlier clauses

Source checkpoint: 2026-09-09. Parent: `acdbc08`. Source repair and prepared coverage only; builds, typechecking, assertions, inference and browser execution remain paused.

## First-principles finding

Answering a location question does not remove a previously specified budget, date or ticket count. The [question-time interpretation](BROWSER_CLARIFICATION_POLICY_HISTORY_REVIEW.md) already retained every prior requirement, and concrete website policies survived later relabeling. Scalar evaluation, however, still depended on the latest model's field and role assignments. A complete price clause relabeled as a location could lose its native comparison, while a requested result count relabeled as a category could disappear from answer selection.

Retaining source bytes alone does not retain these obligations. Conversely, attaching one old predicate to a new merged clause could falsely claim that a much larger instruction was satisfied by a single number.

## Source changes

The [goal input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalPlanner.swift) supplies one bounded UTF-8 slice accessor used by current proposals and retained history. The proposal still checks membership separately. The accessor validates offset/count bounds before addition; it supplies source data rather than interpretation authority.

The [scalar compiler](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) reuses its existing strict native parser for condition clauses retained in accepted question-time snapshots. Only previously parseable, noncontradictory price, date and quantity conditions qualify. Their original text and the unchanged root clock determine the predicate; current model labels and hints cannot weaken it.

Restoration requires one current requirement covering the exact normalized scalar clause at the same turn and byte occurrence. Existing boundary normalization permits whitespace, introductory “and” and sentence punctuation to move. Comparator, amount, currency, unit and qualifier bytes remain inside the matched clause. Split or merged meanings mark all overlapping current rows `historicalScalarScope`; no larger category/outcome row receives a passing scalar condition. An unresolved overlap cannot be overwritten by a later exact history match.

Restored conditions retain the historical requirement IDs in their native identity under the current goal revision. Price/date clarification application follows restoration and preserves that lineage, so a previously supplied currency or date confirmation still applies through its existing scoped answer chain. No prior user input, answer, task identity, browser document, control permission or effect receipt is rewritten. This path does not implement intent replacement.

[Source compilation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserSourceRequirements.swift) recognizes retained complete scalar literals even if the model assigned them website fields. [Result assessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) evaluates the restored predicate and holds unresolved historical scopes against semantic review. Existing navigation-history and answer-policy obligations retain their precedence and completion gates.

[Answer eligibility](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchAnswer.swift) uses that native meaning for the same complete literal clause, including when a later label calls it a source restriction or prohibition. Retained result-set counts still constrain the number of eligible selections. Other current requirements, source policy, offer association, complete observation, quotations and semantic review retain their existing checks. A scalar match does not establish whole-goal success.

## Prepared coverage and permitted checks

Four new [clarification methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) prepare checks for unrelated answers with changed labels/roles/relations, merged and split clauses, punctuation-only boundary changes, currency binding after restoration, and a quantity first introduced by an earlier answer. Two new [answer methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchAnswerTests.swift) prepare the actual retained-owner/observed-page/review path: a relabeled budget still rejects an expensive offer, one offer cannot satisfy two requested options, and a positively reviewed merged category cannot hide old scalar obligations.

Eight Swift files pass parse-only syntax checks. Default/focused source inventories select 1654 / 971 methods, with six additions and no removed or renamed identifiers. These checks establish source syntax and inventory consistency only; the assertions and browser fixtures are unrun. No app, model, computer-use session or remote training job executed.

## Remaining work

Historical uncompiled/ambiguous meanings, general merged or split goal reconciliation, corrections to prior model classifications, explicit supersession, location/time associations and complete semantic qualification remain open. Preserving a prior native condition does not prove that the earlier model classified every surrounding clause correctly. Continue the [repair checklist](../../../TODO.md); parent-form/document recovery through login and real travel/concert/movie qualification still require further repairs and explicit execution permission.
