# Read native search settings within the declared scope

Source checkpoint following `21ef0b8`. The [field-intention repair](BROWSER_FORM_FIELD_INTENTS_REVIEW.md) exposed a gap: an untouched writable date, count, selection or checked state could affect a query, but the explicit reader excluded those native controls. Meanwhile an explicit text/composite reading still collected other writable scalar/selection/checked values automatically. This checkpoint makes those native settings explicitly readable and makes an explicit scope restrictive for every available value.

## First principles

The current value of a search control is evidence of a setting. Its native editability does not determine whether observing it is useful. A date can matter while writable, readonly or disabled. Conversely, being writable does not give a neighboring control permission to collect its value.

A query must account for settings it will send, including values the agent never edited. A checked flag is not a ticket count; selected options are not inventory; a native date value is not an offer date. Reading these properties allows the planner to assess a query, but neither the reading nor its source reference certifies suitability or provider results.

Recovery must retain both the original meaning of the target and its original reading. Matching a control ID after manual control is insufficient if its type, label, options or owning form changed. Restoring a scope should check those facts before collecting another value, then compare the full observed baseline before effects. A cancellation must join native completion and preserve the pending operation rather than inventing another edit or query.

## Source changes

- [Read-scope eligibility](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserReadingScope.swift) and [native eligibility](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) now admit supported writable date, datetime-local, month, week, time, number, select, checkbox and radio controls. Named text/search and supported readonly/disabled/declared/composite capabilities remain. Protected account, identity, contact and payment fields remain ineligible through the existing native metadata checks. These checks are bounded heuristics, not universal semantic classification.
- Every explicit native scope now returns `unavailable` for an unselected value-bearing control, including writable scalars, selections and checked states. A scoped text read cannot silently collect neighboring dates or counts. The Swift snapshot validator likewise rejects an available value outside a nonempty declared scope. Stateless action metadata is not a value read. General result reading with an empty explicit scope retains its existing native writable-setting capability; this checkpoint does not redefine all general research reading as per-control authorization.
- Selection observations still expose selected option IDs/labels instead of private submission codes. Native property readers preserve existing bounds, checked/indeterminate distinctions and ordered multiple selection. No new setter, click, form alias, submission route or provider predicate is added by these readers.
- [Form scope planning](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) can defer supported value-only native form members for later observation, including checkboxes and multiple selects. That permits an earlier declared text/edit stage without reading those deferred values. It does not create editable aliases, preserve a value or discharge a query criterion. Earlier verified obligations and explicit user preservation cannot be deferred. Unsupported required preservation remains unsupported.
- Normal query review can now extend its read scope to these untouched values, then return the complete current reading to the planner for a final explicit query decision. Existing potentially-submitted-value checks still forbid calling such an unresolved setting unrelated. Unknown, protected or unavailable required values cannot gain query authority merely because another field was verified.
- [Completed scope review](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserEffectControlReview.swift) restores original read IDs and requirement references for both form and query retries. A new [metadata fingerprint](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserObservedCriteria.swift) compares original controls before another read, including exact UTF-8 labels, flags, constraints, option IDs/codes and form metadata. Same control IDs with changed meaning cannot inherit the old read scope. The existing full baseline digest retains its serialization order and version.
- [Unsent form validation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormStage.swift) now restores that original scoped reading, binds the original native fields and compares full page/control states plus the exact baseline fingerprint. A form selected after examining a dropdown/query reading no longer refreshes against a metadata-only page. This applies before initial unsent execution and after manual handback. Changed unedited settings prevent the original edit; they do not become new defaults. Attempted input still follows the existing native receipt/outcome reconciliation.
- [Query recovery](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormNavigation.swift) uses the shared restoration helper and retains its original value comparison, operation identity and no-replay behavior. Restoring observations is internal reconciliation, not a new model decision or a replacement query.

## Prepared coverage and source evidence

Fourteen methods in [NativeSettingScopeTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserNativeSettingScopeTests.swift) cover:

1. Explicit observations of all ten supported writable native kinds, including multiple selection.
2. Excluding every neighboring writable value from an explicit text scope.
3. Rejecting protected writable settings in both proposed and native scopes.
4. Invalidating readings after property-only date/count/select/checkbox/radio/multiple-selection changes.
5. Rejecting a snapshot that injects an available value outside its declared scope.
6. Reading untouched native query defaults before the final decision and one GET.
7. Returning an indeterminate setting for a model decision that can leave the query unresolved.
8. Restoring all query readings after Pause without another decision or repeated edit.
9. Rejecting a changed default after query handback.
10. Restoring observations before the first edit of a form selected from a reading.
11. Joining a cancelled form-scope restoration and resuming the same pending plan after handback.
12. Rejecting an unedited setting changed during that handback.
13. Rejecting changed read metadata before collecting another value.
14. Distinguishing canonically equivalent Unicode label bytes in the metadata fingerprint.

The existing readonly-flag transition case now expects the newly writable native date to remain explicitly readable; its old reading still invalidates. New cases use authored fixture decisions, not an actual model. Pause/handback coverage is prepared native-fixture coverage, not a live account-login demonstration.

The [default inventory](../../../host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json) selects **1,321** source methods and the [focused inventory](browser-control-state-inventory.json) selects **638**, fourteen additions with no removals from the prior checkpoint. Ten changed/new Swift files are syntax-parsed only. The assembled DOM, four embedded script fragments and nine distinct fixture scripts receive `node --check` without execution. The metadata helper extraction preserves the prior baseline serialization in source. The new test file has four Xcode registrations; project syntax, source inventories, documentation links and whitespace are checked.

No build, typecheck, runtime assertion, app/browser/computer-use launch, inference, SSH retry, held-out inspection/run or installed-app replacement occurs. Source checks do not establish that these cases pass or that the model's prompts fit its token budget. No scratch artifact is retained.

## Remaining repair order

1. Implement explicit readonly/custom preservation using native predicates checked through the effect, without inventing editable aliases. A reader or deferred intention is not a preservation contract. Resolve each user's negative/preservation clause against the full request; source references alone cannot prove the model chose the right disposition.
2. Unify criterion lifetimes across an effect, later stages, navigation, document changes and account return. Restored readings now constrain unsent form/query recovery, but this is not a universal cross-effect dependency graph. Intentional changes, disappearance/replacement of deferred fields and website reactions need explicit reconciliation. Do not claim that a pre-effect snapshot proves post-effect or backend behavior.
3. Finish durable parent/browser/account-session recovery, independent provider-result predicates and broader supported website workflows. Hidden server fields, POST/custom submissions, virtualized widgets and remote side effects remain outside this checkpoint's guarantees.
4. Qualify exact context/tokenizer fit and actual lightweight-model judgments after execution is explicitly authorized. Keep travel, concert and movie research, real login takeover/handback, changing defaults, mixed states, dates/count units and result independence in the acceptance scenarios. Alternate models and the authorized RTX 3080 desktop remain options after measured failures; no model substitution, pruning or distillation is justified by this source-only checkpoint. Whole-app 8 GB memory and thermal qualification remain deferred. Continue the [repair TODO](../../../TODO.md).
