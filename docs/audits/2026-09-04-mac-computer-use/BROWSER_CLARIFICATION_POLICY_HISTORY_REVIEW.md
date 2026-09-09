# Preserve question-time interpretation and concrete source policy

Source checkpoint: 2026-09-09. Parent: `5a2cbe7`. Source repair and authored regressions only. Compilation, assertions, inference, app/browser execution and live qualification remain paused.

## First-principles finding

An answer changes the task's interpretation, but it does not erase either the original user words or what earlier planning understood those words to mean. Correct replacement needs both: an immutable history and an explicit account of which current criterion changes.

The accepted clarification previously stored the question's selected source spans but omitted the complete interpretation that produced them. Requirement IDs included classification in their hashes, but a hash cannot reconstruct the old role, field, relation or value hints. Clauses outside the question's selected scope had no semantic snapshot in the goal input at all.

This exposed a concrete browsing-policy failure. The source compiler rebuilt navigation and answer-source restrictions only from the latest model interpretation. A source-covered response could merge an earlier exclusion into an outcome, change its field or omit one domain hint. All user bytes remained present, yet the resulting source policy could widen after an unrelated answer.

## Source repair

[The clarification boundary](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalClarification.swift) now stores the complete proposal digest and ordered requirement records in the live question. Consumption carries them into the immutable accepted turn. The snapshot preserves each requirement's ID, source turn, UTF-8 range, role, field, relation and verbatim value hints, including requirements outside the question's scope.

Question and answer digests use version 2 and bind the prior interpretation digest. The original root, user bytes, question scope, task/controller ownership, expiry, turn/byte limits and continuation-prefix checks remain in force. The added records are flat requirement snapshots, not recursive copies of earlier goal inputs. They stay host-side; planner context and the answer wire are unchanged, and diagnostic descriptions do not expose their values.

[Source compilation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserSourceRequirements.swift) now combines current concrete source constraints with concrete navigation/answer constraints retained in those snapshots. Earlier allow lists still intersect, exclusions still accumulate, and navigation versus answer-source scope remains distinct. Original domain/origin parsing and standalone-reference checks apply to historical values too; a substring or invalid origin cannot supply a constraint.

The compiler recovers each historical source from its original UTF-8 range in the unchanged user turns. It maps that range onto current requirement IDs for diagnostics, so resegmentation does not replace old source identity with a matching label. Multiple accepted turns preserve all earlier concrete constraints. Current host-bound price parameters keep their separate interpretation path.

An ambiguous old `source` classification is not converted into a concrete historical restriction. Existing source clarification can still resolve that ambiguity in the complete new interpretation. Conversely, an already concrete restriction does not disappear merely because a new answer has source scope. Conflicting concrete sets remain unresolved until explicit replacement is justified. This patch does not implement that replacement.

## Prepared coverage and allowed checks

Five methods were added to [SourceRequirementsTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserSourceRequirementsTests.swift). All are authored and unrun:

1. An unrelated date answer and complete resegmentation cannot erase an earlier navigation or answer-source exclusion. The case includes decomposed Unicode before the retained byte range and checks the full snapshot outside the selected question scope.
2. Earlier allow lists still choose a permitted provider or restrict reported sources after resegmentation.
3. A source-scoped answer that conflicts with an earlier concrete restriction stays unresolved, with diagnostics using current requirement IDs.
4. Dropping one excluded domain from the latest value hints cannot remove its earlier restriction.
5. Two accepted answers retain each interpretation snapshot and the first source restriction even when the intermediate model has already relabeled it.

The existing source-question scenario still describes clarification of an ambiguous source clause into an answer-only restriction while allowing auxiliary browsing. No assertion was executed to qualify that behavior here.

Three changed Swift files passed `swiftc -frontend -parse`. Source inventories select 1594 default / 911 focused methods: five additions each, with no removed or renamed identifiers. No JavaScript changed. These checks establish syntax and reviewed source identifiers only; compilation, assertions and actual browsing remain unverified.

## Next implementation steps

1. Define explicit replacement provenance: the prior interpreted clause and exact source range, the accepted answer or correction evidence, and the new clause/value. Retain both old and new user text.
2. Distinguish a change in user intent from correction of an earlier model classification. These snapshots record an interpretation, not user confirmation that every role or field was correct. An old model guess must not become an unchangeable instruction.
3. Separate current required criteria from historical actions and observations. Superseding Seattle with Portland must change the current destination without rewriting an earlier Seattle input receipt or treating that receipt as completion of the new goal.
4. Reconcile pending work before replacing its criteria: retire only proven unsent effects, preserve completed effects, and keep uncertain native attempts held for their existing reconciliation path.
5. Apply replacement consistently in goal review, source policy, form purposes, preservation/read duties, result predicates and completion checks. A model-facing inactive flag alone cannot implement this boundary.
6. Preserve the distinction between navigation and reported-result sources when changing a site restriction; revalidate any existing browser/document against the resulting policy.
7. Author correction, additive-answer, conflicting-answer, resegmentation, model-misclassification, pause and stale-proposal cases across native form history and the driver. Real travel/concert/movie and login qualification stays deferred to explicit execution permission.

Continue the full [repair checklist](../../../TODO.md), including login document transitions, process/account recovery, dependent controls, result verification, alternate-model comparison and later 8 GB resource qualification. No assertions, app/browser execution, inference, SSH retry, push or installed-app replacement occurred here.
