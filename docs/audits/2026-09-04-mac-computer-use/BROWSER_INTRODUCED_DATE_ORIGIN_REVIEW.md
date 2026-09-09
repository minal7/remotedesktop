# Dates introduced by clarification answers

Source repair; execution pending. No build, typecheck, assertion, app, browser, model or account-login execution occurred. This is a prerequisite for explicit goal correction, not an implementation of supersession.

## First-principles defect

A requirement needs an origin independent of the model's current labels. An answer can supply a missing date, confirm an existing date, resolve an ambiguity or contradict a previous requirement. Those cases have different meanings. Neither a new model interpretation nor an ordinary clarification question authorizes replacing a conflicting user constraint.

The native date resolver previously excluded date-answer rows from its initial target list, then skipped a missing-date answer scoped to an outcome without registering a target. A first answer could therefore look bound only because its current model label happened to be `condition/date`. A later confirmation scoped to that answer could not find the original date. Splitting or relabeling the answer also lost native meaning or produced separate fragments where there was one date unit.

A missing-date answer of “Friday” exposed the same problem earlier: it was treated as an unusable answer rather than a new, still-ambiguous date origin. Conversely, selecting only one endpoint of a range could issue a question that no subsequent answer could safely apply.

## Source-bound origins

The [scalar resolver](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserScalarRequirements.swift) now registers a whole recognized date answer as its own origin when it supplies a genuinely missing date under one outcome. The broad outcome remains separate and subject to complete-goal semantic review. A missing-date question cannot combine several outcomes, or combine a missing outcome with an existing date target.

Every current requirement row covering that answer belongs to the same source group. Concrete dates and ranges bind the entire group to one native predicate. Weekday language retains an unresolved native date origin. A later model's role, field or partition cannot discard an endpoint, modifier or source fragment. Historical native identities are retained where available; a newly introduced answer does not invent a historical requirement.

Confirmation scopes are checked against the original answer's UTF-8 byte intervals. Selected intervals must cover the complete recognized native date unit without overlapping. Whitespace gaps and the parser's supported boundary punctuation do not authorize dropping internal date text. The whole answer must be recognized; a literal date followed by an unrelated instruction remains unsupported by this narrow compiler.

Subsequent confirmations trace through accepted answer turns to their original targets. They may confirm an identical concrete date/range or resolve a bare weekday to a compatible civil day. A conflicting date, a range endpoint offered in place of the range, or a concrete answer that discards `next`/`this` remains unresolved. Original root-date comparator and modifier checks remain in force. Earlier clarification bindings are still invalidated when their target becomes contradictory.

## Question admission and fallback

[Goal proposals](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalPlanner.swift), [action proposals](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift), [form proposals](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) and [live question issuance](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalClarification.swift) now share topic/source admission. It requires current proposal membership, distinct references and the existing one-to-eight scope bound. A question about a recognized date answer must cover the whole native unit, even when its text occupies several rows.

The shared check performs read-only native interpretation for date and quantity topics. It does not change the actual proposal's disposition, create an executable interpretation or grant action/completion authority. Existing native missing-unit quantity eligibility is now available consistently in all three proposal decoders as well as live issuance.

Eligibility to ask about a date is separate from needing an automatic question. A confirmed date does not trigger another fallback because its labels changed. An introduced bare weekday does need disambiguation; the [task owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) now carries every row of its source group into that question. It never truncates the group to the first ID. If the group exceeds the existing question bound, no partial fallback is emitted.

Planner instructions describe missing-date scope, full-answer coverage, confirmation versus conflict and the absence of a need to re-ask resolved dates. Login, passwords, MFA and account permissions remain on the manual-control handoff path.

## Form provenance

[Form normalizations](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) now emit one exact civil-day value per native date source group and cite every contributing requirement index. The existing multi-source `requirements` context field supplies that full list; `requirement` remains the first index. Distinct date origins are not merged merely because their values match.

The existing form proposal check compares the normalized value's complete source list with the reviewed field intent. A plan that names only a fragment cannot use the whole date's normalized value. Ranges, unresolved weekdays and conflicting answers do not become exact date values. Entering a date still establishes only a search criterion, not provider field meaning, availability or goal satisfaction.

## Authored verification, unrun

Ten new methods are registered in the active source inventories:

- Six [clarification cases](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserGoalClarificationTests.swift) cover introduced origins, confirmation after relabeling, repartitioned/punctuation rows, one normalization with all sources, bare-weekday fallback, incompatible civil dates, full ranges, relative-week modifiers and ambiguous missing-outcome scope.
- Three [form/planner cases](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormPlannerTests.swift) cover full versus partial date scope through all three decoders, native quantity-unit question parity, and complete reviewed date-source provenance through a native form stage. Partial field intents are expected to reject the normalized value before input.
- One [driver case](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResultAssessmentTests.swift) follows missing date → split/relabelled “Friday” → whole-scope date question → compatible civil date → one search and fresh native candidate assessment. It checks that no search occurs while the weekday remains ambiguous and that original request ancestry survives.

Eleven changed Swift files pass parse-only checks. Default/focused source inventories select 1728 / 1045 methods, with ten additions and no removals. These checks establish syntax and source registration only; the authored assertions and native workflows have not executed.

## Remaining repair sequence

1. Define explicit user correction and supersession separately from ordinary clarification. Identify the exact earlier date occurrence or source unit, preserve unrelated conditions and previous answers, and keep the correction history visible.
2. Compile replacement semantics before releasing old form criteria. A changed desired value does not erase preservation/read duties, earlier receipts, pending operations or uncertainty about dispatched input.
3. Extend date semantics deliberately: relative-week language, trip-leg roles, provider field meaning, date ranges and multiple outcomes still need complete-goal interpretation. This patch does not infer them from row labels.
4. Address bounded conversation/history handling without truncating user intent. The existing turn and question-size limits remain; splitting a date into too many rows is not permission to drop sources.
5. Qualify the prepared cases and then the real travel, concert and movie scenarios only at the explicitly authorized execution stage. Native source lineage is necessary but does not prove model competence, successful browsing, account identity or exact natural-language completion.

The [repair checklist](../../../TODO.md) remains active. Global navigation-source completion is still restricted. Alternate models, desktop distillation/pruning, resource measurements and the 8 GB Mac target remain later qualification work; no model replacement or remote inference occurred here.
