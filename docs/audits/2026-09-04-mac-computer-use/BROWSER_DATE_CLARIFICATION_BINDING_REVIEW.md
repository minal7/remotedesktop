# Bind a date answer to the date occurrence it clarifies

Source checkpoint: 2026-09-09. Parent: `74e00e0`. Source changes and prepared coverage only. Builds, typechecking, test assertions, inference and browser execution remain paused.

## First-principles findings

The [question boundary](BROWSER_SCOPED_QUESTION_PRESENTATION_REVIEW.md) retained and displayed an exact scope, but the scalar compiler applied only currency, price-basis and fee answers to earlier clauses. A literal date answer could become an independent condition while the original weekday remained ambiguous. The app therefore had no native link from “2026-10-16” back to the particular “Friday” being clarified.

The [result assessment](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResultAssessment.swift) also routed an unresolved scalar entry by its current model field. Relabeling a conflicting answer as location or category could move it from the native unresolved path into semantic review. A model's label does not erase the native reason an answer could not be applied.

## Source behavior

The [scalar compiler](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) now binds whole date answers to their selected earlier date occurrences. A bare weekday, optionally prefixed by “on” or “for”, can be resolved to a single civil date with the same weekday. Weekday calculation uses proleptic Gregorian arithmetic consistent with the existing civil-date validator. An already concrete date, comparison or range can be confirmed only by an equivalent range; this path cannot replace or narrow it silently. Relative literal answers such as “tomorrow” use the retained original clock and time zone.

The entire answer must fit the existing date grammar. Negation, alternatives, additional instructions, invalid dates and unsupported expressions cannot be reduced to a matching substring. “This Friday” and “next Friday” remain unresolved because their relative-week meaning has not been compiled here. Repartitioning a known date clause cannot remove its modifier or comparator before binding the shortened clause.

One selected scope must identify one date occurrence. Separately selected scopes can share an answer only if every target accepts it; application is atomic. An explicit follow-up through a previously bound date answer retains the original target. A conflict invalidates that target and earlier answer bindings, rather than restoring an initial predicate or using the latest answer unconditionally. Date-answer rows are excluded from the original-target catalogue so that a follow-up cannot become an unrelated new date constraint.

If a question selected an outcome with no date clause, a valid answer continues through the existing new-condition path and still needs complete-goal scope review. This does not manufacture an earlier date predicate or prove association with a trip leg. Mixing such missing-detail scopes with existing date targets is unresolved. Original user/answer bytes, question-time interpretations, task root, transport ownership and native effect history remain retained.

The [research owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) can request the first natively resolvable weekday occurrence when a research-classified proposal omitted a question. Existing explicit model questions and unresolved source questions keep their precedence. This adds no inference stage or browser action. The normal live-question/controller/session boundary still issues and consumes the answer reference.

Date answers use the existing typed clarification resolution, now with a date-range parameter and scalar-binding identity version 2. Source compilation recognizes these bound literals as parameters even if the model labels them as websites. Result assessment distinguishes `clarificationApplied` from actual page evidence and requires the original target's predicate to be evaluated. Native ambiguous, conflicting and invalid-scope answer states remain uncompiled regardless of the latest field label. Planner instructions describe these rules; wire schemas are unchanged.

## Prepared coverage and permitted checks

Seven new [clarification methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) cover repeated outbound/return occurrences, all weekdays and Gregorian century cases, retained-clock/range confirmation, wrong dates and compound answers, atomic scope application, follow-up conflicts, modifier/field resegmentation and genuinely missing dates. Two new [native assessment methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResultAssessmentTests.swift) prepare owner-question/answer/fresh-reading coverage without a repeated search and date/price conflicts under changed answer labels.

Nine Swift files pass parse-only syntax checks. Source inventories select 1648 default / 965 focused methods, with nine additions and no removals or renames. These checks do not establish compilation, passing assertions or model behavior. No test fixture, app, browser, model or remote training job executed.

## Remaining work

General location/time/quantity answer binding, explicit replacement of earlier intent, correction of model classifications, relative-week/calendar conventions, compound answers and recovery from earlier unresolved answers remain open. Scalar agreement still does not prove offer association, availability, itinerary semantics or whole-goal completion. Parent-form/document recovery through login and full route/source qualification also remain open. Continue the [repair checklist](../../../TODO.md); live travel, concert and movie qualification awaits explicit execution permission.
