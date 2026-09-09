# Decide form fields before reading their values

Source checkpoint following `9b06303`. The previous [form/query scope repair](BROWSER_FORM_EFFECT_SCOPE_REVIEW.md) treated supported editable members of a selected native form as covered. That let form ownership stand in for a task reason to read them. This checkpoint replaces that shortcut in the normal research owner. It is source implementation and prepared regression coverage, not runtime or model qualification.

## First principles

A form identifies a browser relationship. It does not identify which values the user needs changed, which private baselines the host needs to verify, or which fields must remain unchanged. Selecting a form must therefore precede a separate decision about each field; it cannot authorize collecting all its values.

An edit needs an original native target and a baseline so the host can detect replacement, stale input and site reactions. That private verification read has a concrete purpose only for the declared edit. Explicit user preservation needs its own original value, even when the field is inside the selected form. An earlier verified criterion needs its retained object, value, source and receipts. A dependent field can remain unread while an earlier stage runs; that deferral supplies neither a preserved value nor evidence that a query is suitable.

The model still supplies semantic judgments. A source reference proves provenance, not that “retain,” “deferred” or “edit” correctly interprets the user's words. The host can enforce that later operations stay within the declared decision; it cannot certify the decision's meaning by checking a reference number.

## Source changes

- [Form effect scope](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormEffectScope.swift) now retains explicit field intentions alongside additive user preservation. `edit` declares the exact requirement references that will supply a field's payload. `retain` keeps an earlier verified obligation. `deferred` leaves a field unread for later work or clarification. Unknown metadata remains unresolved; unrelated fields stay outside discovery. The digest includes disposition, ordered references and counts.
- [Action planning](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserActionPlanner.swift) uses version 17 for form/query scope. Selecting a form no longer covers its editable members. Ordered metadata review precedes `plan_fields`, with up to four rows per reply, eight edit intentions and sixteen total intentions/preservations. Only members of the selected actual form can receive these intentions. Retention is offered only for earlier required fields that still match their verified values. Earlier required fields cannot be declared unrelated or deferred. At least one explicit edit is required to release discovery. Every scope addition invalidates the previous remaining-control review and uses the original shared deadline.
- Explicit preservation continues to use `preserve_controls` or the initial form selection. Preserved targets and field intentions are disjoint. Neither a new intention nor another selection may silently rewrite already retained preservation.
- [Native discovery](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserDOM.swift) accepts the selected control IDs and resolves them through the current native page bindings. It checks actual `element.form` ownership; an associated control outside the form's DOM subtree remains eligible. It collects only these selected objects and explicit preservation objects. Retained observations reuse this selection instead of enumerating every editable member. Same-form extension atomically retains all required old objects and input receipts while adding the new selected objects; a failure cannot fall back to whole-form rediscovery.
- [Form input](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchFormInput.swift) requires the discovered control set to equal the reviewed private-read set. Retained intentions must correspond to earlier required native targets. Only edit intentions receive editable aliases. Version 11 exposes exact edit references and deferred metadata without private baseline values.
- [Form proposal validation](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserFormProposal.swift) requires exactly the declared edit targets and exactly each target's source-reference set. Extra edits, omitted edits and substituted references fail before effects. A question or unavailable response remains possible. Required preservation and earlier unchanged criteria still enter the compiled native contract. The reviewed form schema pins the edit count and uses its own version; legacy component inputs retain their existing behavior.
- The [research owner](../../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseBrowserResearchTask.swift) consumes intentions internally before any discovery. Normal query coverage still comes only from verified final values and explicit value readings: a deferred field gains no query coverage. The later query review must resolve its applicable current value or establish a verified edit. The full original request and accepted answers remain present throughout planning and handback.

Legacy direct component discovery APIs still allow their pre-existing broad field catalogue when no selected-ID scope is supplied. The normal reviewed research route supplies a scope. This checkpoint does not turn those lower-level component APIs into independently authorized public actions.

## Prepared coverage and source checks

Ten new methods in [FormEffectScopeTests](../../../host-mac/RemoteDesktopHostTests/ComputerUseBrowserFormEffectScopeTests.swift) cover:

1. Excluding unrelated private values inside the selected form.
2. Mandatory preservation inside that same form, with no editable alias.
3. Rejecting an omitted declared edit after baseline discovery.
4. Rejecting substituted payload requirement references.
5. Withholding discovery when no edit intention exists.
6. Rejecting unreviewed references, duplicate intentions, prohibited roles and invented retention.
7. Keeping deferred fields unread and outside later query invariants.
8. Extending discovery while retaining earlier native identities and receipts.
9. Preventing earlier verified fields from being deferred or declared unrelated.
10. Rejecting a foreign-form control at native selected discovery.

Existing authored fixtures now declare their intended edit, retained and deferred fields before discovery. This includes newly appearing dependent City fields, repeated extension, changed criteria, accepted answers, partial-stage resumption and account/unsent recovery. The shared helper uses caller-supplied fixture semantics; it does not infer that unknown fields are unrelated or automatically preserve every unedited field.

The source inventories select **1,307 default / 624 focused** methods, ten additions with no removals. Twenty-one changed Swift files are syntax-parsed only. The assembled native DOM and four embedded fragments are checked with `node --check`; no JavaScript executes. Source/project registration, inventory, documentation links and whitespace are checked. No Mac build, typecheck, runtime assertion, app/browser/computer-use launch, inference, SSH retry or held-out inspection/run is performed. No generated artifact is retained.

## Remaining repair order

1. Follow-up source implementation: [native setting scopes](BROWSER_NATIVE_SETTING_SCOPE_REVIEW.md) now support explicit writable date/count/select/checked observations, exclude neighboring values from explicit scopes and retain original form/query readings through unsent recovery. Runtime and semantic qualification remain open.
2. Add readonly/custom preservation predicates without pretending they are editable fields. Distinguish explicit preservation from broad prohibitions and qualify the model's choice of edit/retain/deferred/unrelated using the complete request. The current source does not mechanically understand every negative clause.
3. Unify criterion lifetimes across forms, dropdowns, navigation, document changes and login return. Deferred decisions are retained in the current stage proof and receive no query authority, but are not yet a durable cross-document dependency graph. Native full-form membership, earlier required values and page metadata remain separate from website handler/backend semantics. Missing or replaced dependent controls need explicit reconciliation rather than optimistic success.
4. Follow-up source implementation: [unsent form restoration](BROWSER_NATIVE_SETTING_SCOPE_REVIEW.md) now restores the original read scope, checks original metadata before values and compares the complete baseline. Execution remains unqualified; broader cross-effect criterion lifetimes remain open.
5. Finish durable parent/browser/account-session recovery and provider-result validation. Hidden server fields, POST/custom submissions, virtualized controls, transient handlers and remote side effects remain outside this checkpoint's guarantees.
6. After the user explicitly authorizes execution, qualify the exact prompt/tokenizer budgets, actual small-model field judgments, native cancellation/handback and real travel/concert/movie scenarios. Alternate models and the authorized RTX 3080 desktop remain available for measured model failures. No new model selection, distillation or pruning has been justified by this source-only work. Whole-app 8 GB memory and thermal qualification remain deferred. Continue the [repair TODO](../../../TODO.md).
