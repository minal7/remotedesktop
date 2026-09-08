# Form continuation after accepted clarification answers

Source repair after `7077154`. This checkpoint remains unqualified at runtime. The [working repair list](../../../TODO.md) remains open.

## First-principles failure

An answer such as a city or fee preference adds information to the original request. It does not undo a category selection that already happened. The previous same-form continuation required an identical goal revision and interpretation, so a correctly accepted answer could strand completed native input.

Simply relaxing the revision comparison would be wrong. The next interpretation can divide the original request into different requirements, assign new roles, and generate different IDs. Earlier requirement number zero might have covered the whole request; current requirement zero might cover only the category. Reusing an old number would relabel the provenance of historical input. A later interpretation is not authority to rewrite an earlier receipt or discard a preservation constraint.

The correct separation is: exact accepted-answer lineage identifies the continuing task; original user byte spans identify why an earlier field was edited or preserved; native objects, expected values and original dispatch receipts identify the retained browser work. The current model must compare that history with the complete updated goal before choosing another edit or query. Neither source overlap nor historical success proves that an earlier criterion remains semantically appropriate.

## Source changes

1. **Verify the continuing goal.** [Goal input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserGoalPlanner.swift) adds `continues`, requiring the exact root task, original prompt bytes, fixed clock/time zone and unchanged prefix of accepted clarification turns. A shorter history, changed root or sibling answer cannot continue the old chain.
2. **Retain source spans instead of requirement numbers.** [Form sources](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) retain original turn, UTF-8 offset, exact source text and the role/field interpretation at binding. Projection validates those bytes in the current user turns and identifies overlapping current requirement indices. Splitting or merging requirements does not replace the historical text. The overlap list is explicitly not semantic equivalence. Repeated terms from the same original clause share one retained source.
3. **Keep preservation independent of renumbering.** [Form proposals](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) and combined continuations now retain each preservation source. Current action references are validated against the current interpretation; a repeated inherited preservation must reference an overlapping current requirement while its original source remains intact. Omitted proposal rows still cannot drop inherited preservation. Edited-field sources are replaced only by an actual later edit, with that edit’s own source span.
4. **Continue the same native form after answers.** [Form stages](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) retain their original goal input and permit an exact accepted-answer descendant to extend the same form/document. Native extension still checks earlier required values, object identities and original input receipts before adopting fields. Per-stage receipts and journals keep their historical goal revisions. The combined continuation’s digest now uses version 2 and retains its accepted goal; it is not rewritten when an answer merely arrives.
5. **Expose history under the complete current request.** [Action planning](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) context/schema version 3 and [form planning](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPlanner.swift) schema `browser_form_plan_v5` show exact historical sources, current overlap references and whether answers arrived after the previous stage. Form context is version 6. The prompts require re-evaluating earlier criteria against the current request and scoped answers. Private field values, native IDs and receipt digests remain outside model context.
6. **Bind a query to its current goal while retaining historical proof.** [Query intent](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormNavigation.swift) accepts a validated current descendant goal separately from its historical form receipt. Its version-2 operation identity includes the selected current revision. Native query preparation still verifies the original accumulated values and receipts. The owner records navigation under the current goal without rewriting old form history. Pending queries continue to block questions and answer consumption, preserving their original intent.
7. **Require current source policy before continuing.** [The research owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) rejects new action/form preparation and historical-form query preparation while an installed policy belongs to an earlier revision. The default driver already derives and installs a source plan for each accepted answer. Historical receipt replay does not perform another input; completed form receipts remain historical facts across valid descendants.

No DOM implementation, JavaScript fixture script, model worker or installed application changed in this checkpoint.

## Prepared coverage

Seven new methods in [the clarification tests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormClarificationTests.swift) cover:

- The default driver selecting a category, asking for a city after input, accepting the answer, continuing the same form after requirement resegmentation, and preparing the combined query without repeating the initial search or category input.
- Refusal to continue under the old source policy, followed by source-policy installation and continued input under the new revision.
- Current query intent built from an earlier input receipt, with old form history unchanged and navigation recorded under the accepted goal.
- Rejection of old actions and lost browser authority after an answer.
- Two accepted answers preserving the distinct source turns of earlier edits and the current query’s goal.
- Exact source spans across requirement splits/merges and refusal to silently normalize changed Unicode bytes.
- Goal lineage checks for siblings, shortened histories, changed task identity, clock and time zone.

The fixture goal planner can now return controlled complete interpretations to exercise resegmentation. These mock choices are not evidence of correct model behavior. No held-out data was inspected or changed.

## Remaining gaps and next repairs

1. **Reconcile genuinely changed or obsolete criteria.** An explicit later edit can revise a field while retaining other criteria. A required object replaced by a website, an earlier value reset automatically, a criterion that should no longer constrain a query, or an explicitly revoked preservation instruction still needs a deliberate reconciliation representation. Do not silently accept new objects or retain a conflicting criterion forever; preserve historical attempts and revise only the justified outstanding requirement.
2. **Replan changed unsent work.** A completed stage can now continue after an answer; a pending attempted/uncertain stage still blocks answer consumption. Preserve this boundary while adding per-step recovery for new targets and no-attempt work. Old receipts cannot be recreated from equal values.
3. **Complete document and login transitions.** This source path still requires the same selected form and native document. Finish provider-window, host/phone handback and lost-document recovery, including how task-level preservation survives changes of page. An accepted answer does not grant new native authority.
4. **Persist the parent research graph and finish browser/result capabilities.** Durable goal/step recovery, cleanup, missing date/location/widget/submission support, offer association, availability, fees, distinct result counts, ranking, source links and complete answer assembly remain open.
5. **Qualify after permission.** The prompts, native continuation and exact context limits need typechecking, builds, bounded native/model tests and later the retained travel/concert/movie website scenarios. Source lineage cannot prove semantic correctness. Alternate models and the RTX 3080 desktop remain authorized if qualification identifies a model problem; SSH access remains unverified. Keep the 8 GB Mac target and defer performance work until correctness repairs are complete.

## Verification performed

Eleven changed Swift files passed **syntax parsing only**. The Xcode project property list and new source registration were checked. The default and [focused source inventories](browser-form-clarification-inventory.json) match **1023** and **340** method identifiers. Documentation links and whitespace were checked.

No typechecking, builds, test/assertion execution, inference, app launch, computer use or live website E2E ran. No JavaScript check was needed because no script changed. The installed app, models and performance stash remain untouched. These are source checks, not runtime or product qualification.
