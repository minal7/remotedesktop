# Review changed preconditions of an unexecuted form edit

Source checkpoint: 2026-09-09. Parent: `6486c78`. Source repair and authored regressions only. Compilation, assertions, inference, computer-use activity and live qualification remain paused.

## First-principles finding

A captured value is a precondition for one proposed edit. It is not necessarily a task outcome or a user instruction to preserve that value forever. For example, Query and Category may already be verified while City has only been captured for an intended Seattle search. If City changes before the next input, the old proposal must become stale. However, a fresh review can still justify entering Seattle into that same field under the original request.

The preceding repair correctly held newly captured fields to their exact values and carets while recovering earlier criteria. It did not yet provide a way to replace those unexecuted edit preconditions deliberately. That could trap preparation after manual interaction or a website update, even when the field was explicitly selected for editing and no input to it had occurred.

Recovery must distinguish three cases: previously verified values that need repair; earlier unverified invariants that must remain unchanged; and new edit fields that need a fresh scope, snapshot and proposal. Treating all three as earlier verified criteria would create false history. Treating all three as disposable would lose real obligations.

## Source repair

[Preparation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormPreparation.swift) now identifies refreshable fields from the original sealed edit scope. A field must be new relative to the preceding continuation's entire captured-value map, not merely absent from its verified-target set. Read scopes, preserved controls and earlier invariants cannot enter this path. The existing requirement for a same-form, complete preceding continuation remains; first-stage preparation without that continuation is still open.

[The adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) keeps the original capture and reports a separate set of changed new edit preconditions. It still checks earlier native origins before and after binding. New-field changes include value and caret differences; metadata, choices, security/editability flags, native identity and reviewed page checks remain exact. Binding returns the historical fields, not replacement values. A record can now request review when only a new edit field changed, even if every earlier criterion still matches.

The recovery record separates changed verified targets from refreshed edit targets. It does not add a verified value, input operation, form receipt or state proof. The original capture and prior continuation remain retained. Changed targets with preservation or read duties accepted during an unfinished review cannot be turned into fresh edit requirements.

The preparation review context adds mandatory fresh edit control IDs. These survive propagation through unstarted answered revisions and accepted intermediate preservation duties. A new scope must explicitly choose edit for all of them, with current user requirement sources; deferral, retention or preservation cannot consume the replacement baseline. No new user answer is required merely to replan an already authorized edit. Conflicting goal changes still require separate semantic reconciliation.

## Native replacement and execution

The distinct `refreshable-planned-form-v1` requirements format carries the historical field capture. Native revision receives two separate bounded exception sets. Earlier criterion exceptions must still belong to earlier verified origins. Refreshed field IDs must be submitted fields in the capture, absent from every field in the preceding native requirements, and explicitly selected by the current revision. The original ledger, complete operation-ID set, no-pending-change condition and preservation are rechecked. Object replacement still fails.

Only preparation accepts this format. It cannot authorize a query or a state proof. Revision uses a separate cache shape and version-6 ID, keeping the existing rule that a started or failed callback cannot silently choose another baseline. Fields outside both exception sets stay exact. A successful revision returns strict new snapshots and a version-8 baseline that requires every refreshed target to remain editable.

[Form input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) includes refreshed aliases among fields that require a current proposal. Its `refreshed_edit_fields` projection distinguishes them from earlier verified criteria; private values remain absent. A source-backed desired value must still be compiled and checked. If the new snapshot already matches that value, the ordinary state-verification path can create a fresh proof without input. The recovery observation itself cannot establish that proof.

[Action planning](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) explains the mandatory fresh scope using version-23 context. [Form planning](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPlanner.swift) distinguishes refreshed fields from historical repair rows using version-17 context. Historical contexts without the new fields keep their existing versions and projections. Earlier sources, accepted answers, receipts and observation origins remain unchanged.

## Prepared coverage and allowed checks

Nine methods were added in [ResearchPreservationTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserResearchPreservationTests.swift). Two earlier boundary cases were renamed and revised. All are authored and unrun:

1. New-field value changes after completed capture or interruption at field extension, binding and preservation; old preparation stays stale, omitting the mandatory fresh edit fails, and a new scope/proposal enters only the remaining field.
2. New-field refresh combined with an earlier verified criterion reset, with actual-input and observation-only native histories kept distinct.
3. A refreshed field already matching the requested value receives a fresh state proof without unnecessary typing or a fabricated retention stage.
4. A field previously carried as an unverified invariant cannot be relabeled as a new field, even if a later scope offers it for editing.
5. Pause during binding or final origin inspection prevents review publication and further native work until handback.
6. Lost native origins after review prevent replacement capture, including observation-only history.
7. The newly prepared snapshot becomes strict again before execution; another change cannot consume the stale proposal.
8. Driver recovery after a stale model reply requests a second form proposal and completes the controlled query with only the needed input.
9. An accepted answer and an unstarted revision retain the required fresh edit, original history and answer context.

The revised earlier cases retain rejection of replaced new objects and changed preservation, while caret-only changes now require a fresh reviewed input instead of permanently blocking the preparation.

Six changed Swift files passed `swiftc -frontend -parse`. The assembled DOM, five embedded fragments and 53 distinct fixture scripts passed `node --check`. Source inventories select 1563 default / 880 focused methods: nine additions and exactly two reviewed renames each. These checks establish syntax and source selection only. They do not establish compilation, assertion results, model behavior or browsing correctness.

## Remaining repair order

Follow-up: the [initial-preparation refresh checkpoint](BROWSER_INITIAL_PREPARATION_REFRESH_REVIEW.md) supports a first form with no preceding continuation by checking the actual empty native input/proof history before review publication and native revision. It creates no dummy stage or origin. Execution remains pending.

- Support first-stage edit refresh without a preceding continuation, using its actual empty native history rather than manufacturing a preceding stage or origin.
- Reconcile changes around unknown or failed native revision captures without discarding a started callback or replaying a capture under changed arguments.
- Continue explicit goal supersession, conflicting answers and justified removal of preservation/read duties. Earlier invariant values and immutable readings are not refreshable new-field preconditions.
- Complete document transitions after login, required-object replacement and dependent-control reconciliation. This checkpoint preserves same-document evidence; it does not reconnect old controls to a new login-return document.
- Continue independent research-result verification and the full [repair checklist](../../../TODO.md). Real travel/concert/movie tasks, provider login qualification, alternate-model comparisons, desktop adaptation and 8 GB resource qualification remain deferred until the required execution permission and readiness checks. No inference, browser/app execution, assertions, SSH retry, push or installed-app replacement occurred here.
