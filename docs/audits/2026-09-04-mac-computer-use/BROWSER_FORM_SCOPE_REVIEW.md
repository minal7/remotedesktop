# Native form scope and carried preservation

Source repair after `ef67719`. This checkpoint is implemented in source and remains unqualified. It does not establish working real-site travel, concert or movie research. The [working TODO](../../../TODO.md) remains open.

## First-principles failure

A page is a collection of interfaces, not one form. Selecting a search form must determine which native objects may be read and edited. Previously the action selector restricted editable aliases only **after** whole-document field discovery. One unrelated unlabelled field, or more than sixteen editable fields across the page, could therefore prevent a valid search form from being prepared. That also collected unrelated private values without a task need.

Simply filtering to the form’s DOM subtree would introduce two different errors. Native HTML controls can belong to a form through the `form` attribute while appearing elsewhere in the document. A user may also explicitly require a field belonging to another form, or no form, to remain unchanged. Membership and preservation are separate facts: native form ownership supplies the first; the complete user request supplies the second.

A later model response must not erase already-selected preservation merely by leaving out a row. Once a source-bound preservation reference is accepted for this stage, the host must retain it in the exact edit contract. A historical input receipt still does not prove the preserved value remains current when preparing a query.

## Source changes

1. **Choose the read scope before collecting values.** [Action input and proposals](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) now use context version 2 and schema `browser_research_action_v2`. A form alternative requires both `form` and `preserve`. Preservation contains at most sixteen distinct offered control IDs with valid outcome, condition or prohibition requirement indices. Unknown IDs, malformed references, duplicates and hybrid alternatives reject. The model sees observed metadata and the complete goal, never current field values or private destinations.
2. **Bind the selected form through current native objects.** [The DOM adapter](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) adds `formFields` under the existing current-page/native-identity validation. It resolves the observed form ID to one actual form object and validates requested preservation controls before discovery. It reads native `form.elements`, deduplicated with explicitly selected preservation objects. Unrelated editable controls are not included. Externally associated native controls are included regardless of DOM nesting.
3. **Retain that scope for re-observation.** Initial discovery records the native form and additional objects. Subsequent retained-field observations enumerate the same scope; they do not revert to a document-wide walk. Added, removed, replaced or reassigned members cannot silently become old field identities. Unrelated outside field changes do not alter this retained membership, although the separate whole-page planning-evidence check may still require a fresh observation. Document replacement clears the scope. Existing legacy whole-document discovery retains its previous behavior and limits.
4. **Carry preservation into planning and execution.** [Form input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) version 4 resolves selected control references to immutable `required_preservation` aliases. Bound outside-form controls must have one of those references; selected preserved fields are excluded from editable aliases. [Proposal decoding](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) always merges carried preservation, accepts an identical repeated reference, and rejects conflicting references or attempts to edit preserved fields. The [form planner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormPlanner.swift) uses schema `browser_form_plan_v3` and explains these rules. Exact expected private values enter the existing native text contract’s unchanged-value predicates, never model context.
5. **Use the scope in the owner’s default action path.** [Research task preparation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) passes selected form and preservation references to native discovery and then binds every returned object to its observed control. Owner, source, page and cancellation checks remain in place. The temporary guard against automatic dependent discovery on a previously edited native document remains: this checkpoint does not permit clearing earlier input receipts to start another stage.

## What this does not prove

Source provenance is not semantic correctness. The action model still has to recognize that the user requested preservation and select the right observed control. These structural checks cannot prove that a cited sentence actually means “leave this particular field unchanged,” or detect every omitted preservation requirement. Current action and form prompts have not been run or qualified. No fallback model, training job or new inference worker was started.

The native path still supports only its existing editable control kinds, including their existing label, visibility, representability and count limits. Readonly/disabled controls, unsupported widgets and controls omitted from the bounded page projection cannot be silently assumed preserved. A selected form with an unsupported or unlabelled required editable field can still decline. Whole-page observation, authentication detection and projection/context limits are separate boundaries; scoped field discovery does not remove them. This is not support for POST, custom calendar/autocomplete widgets, embedded documents or arbitrary submissions.

Preservation belongs to the current stage’s goal revision and native evidence. It is not yet an aggregate invariant across dependent stages or process reconstruction. The existing engine may retain a verified edit receipt even when a later final invariant check fails. The parent must not publish a successful stage after that failure, and native query preparation must recheck actual required values and receipts independently.

## Prepared regression coverage

Six new source methods cover:

- Automatic form preparation and input with twenty unrelated unlabelled fields excluded from the private field set.
- Native external form members and the unchanged legacy discovery decline.
- Retained membership after unrelated field changes versus added, replaced, reassigned or detached selected-form objects.
- Invalid native form/preservation references and superseded page evidence without clearing an earlier input receipt.
- Explicit preservation inside and outside the selected form, omitted later proposal rows, site changes before and after input, refusal to replay an edit and refusal to prepare a query from a broken invariant.
- Conflicting source references, unknown or duplicate preservation controls, and attempted edits to a carried preserved field.

Existing action tests now require the preservation schema, use an actual preservation request in the newsletter fixture, check carried private values stay out of context and include scoped discovery in the receipt-retirement guard. Driver fixtures use the new form alternative and can retain a per-fixture original request. Mock planner choices remain controlled fixture behavior, not evidence of model competence.

## Verification performed

Ten changed Swift files passed **syntax parsing only** with `swiftc -frontend -parse`. The production DOM script and seven newly authored fixture-script variants passed **syntax checking only** with `node --check`, through standard input; no script was executed or retained on disk. The Xcode project property list parsed. The default and [focused source inventories](browser-form-scope-inventory.json) match **1006** and **323** source method identifiers. Documentation links and whitespace were checked.

No typechecking, builds, tests/assertions, inference, app launch, computer use or live website E2E ran. The installed app, models, held-out qualification sets and performance stash remain untouched. Counts are inventory evidence, not test passes.

## Next repair order

1. Implement retained dependent-field extension without resetting existing native bindings or receipts. Distinguish newly exposed controls from replacements and legitimately changed dependent values. Retain explicit preservation and earlier required outcomes under the same complete goal.
2. Combine verified stages into an aggregate continuation for native query preparation. Preserve the original stage journals, operation identities and unresolved attempts. Remove the automatic second-stage guard only after the new recovery rules are concrete and qualified.
3. Replan changed unsent work under durable and native no-attempt proof. Finish login/provider-window and host/phone handback recovery when native documents change; do not reuse old field authority after manual navigation.
4. Persist and reconcile the parent research graph, remaining requirements, pending intent and historical evidence across process/browser loss. Complete resource lifetime and cleanup bounds.
5. Add the missing date, location, party/inventory and dynamic-widget capabilities, then finish distinct offer association, availability, fees, ranking, public source links and complete answer assembly.
6. After explicit permission, typecheck/build and run bounded native, model and later real-site scenarios. Use the authorized alternate models or RTX 3080 desktop if model qualification demonstrates a need; remote access is still unverified after the earlier SSH timeout. Retain the 8 GB Mac target and defer performance work until correctness repairs are complete, as requested.
