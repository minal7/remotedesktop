# Observe browser controls before compiling browsing actions

Parent source: `7121a7a`. Status: source implementation and prepared regressions only. No type checking, build, test execution, model run, app launch, computer use or real-website task ran.

## First-principles findings

The broader goal remains blocked in the implementation by missing whole-browser capability contracts: the visual policy often requires intermediate target words to occur in the user's request. A request to find flights cannot generally name every departure field, search control and result navigation in advance. Removing that policy without another authority model would let page text or model suggestions widen the task. Supported intermediate operations need a contract bound to the actual document, controls, values and requested results.

The current page snapshot lacked a prerequisite for that contract. It retained rendered text and link destinations but omitted form ownership, submission destinations, choice values, control constraints and native control identities. A form's action, a submitter override or a select option's underlying value could change while the page text and pixels stayed the same. Existing page revalidation therefore could not detect those changes before a planned or approved input.

## Source repair

The fixed isolated-world observer now includes a bounded native-control catalog. It records text/search fields, textareas, date/time/number controls, checkboxes/radio buttons, selects and buttons, with labels, structural groups, disabled/read-only/required/multiple metadata and declared constraints. This is an observation of native HTML controls; it does not implement new input actions for those types.

Each control retains its actual form owner, including ownership through a `form` attribute outside the form's ancestor tree. The host-private metadata includes submission field names, form method/action/target/encoding, validation mode and submitter overrides. A select retains option identities, labels, option-group labels, disabled/hidden state and underlying choice values. Current input values, checked state and selected options are not read by this catalog. HTML form association and submitter overrides are defined independently of ancestor layout in the [HTML form infrastructure](https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#association-of-controls-and-forms); choices have their own identity and availability in the [select-element specification](https://html.spec.whatwg.org/multipage/form-elements.html#the-select-element).

Form properties are read through native IDL getters: named controls can otherwise shadow properties such as `action` and `method`. Native button fallback labels use the already collected rendered text, excluding hidden captions; missing browser-localized submit/reset captions are not invented in English.

Weak object-identity maps assign control, form and option references across reads. A same-looking replacement is distinguishable from the original object, while an unchanged control retains its identity. These references are observation data, not executable authority. The existing snapshot comparison now covers the catalog automatically at ordinary planning, final input validation and visual approval boundaries.

The catalog has at most **64 controls**, **64 options per select** and **128 inspected options per read**, under the existing combined page-data budget. A separate bounded element scan discovers controls that the rendered-text walker deliberately excludes. Hidden controls are omitted; unsupported custom widgets and incomplete catalogs set an explicit `omittedControls` flag. Oversized controls/choice sets are omitted as units, with truncation recorded. Swift validation independently checks identifiers, kinds, constraints, per-field limits, aggregate option counts and the combined data budget. Legacy snapshots without the new fields still decode; present-but-null catalogs are rejected.

Browser planning context is now **version 2**. It includes native control descriptions and visible choice labels before potentially long results text, while keeping submission names, destinations and underlying choice values host-side. A control and its choices remain one whole reduction unit. The existing 64-record/8,192-byte projection bound, JSON escaping and coverage markers remain in force. The new control-omission marker survives even when every planner record is removed for budget. System prompts, offered actions, model artifacts and runtime token caps are unchanged; this browser prompt variant remains unqualified.

## Prepared regressions and source checks

Four methods are added:

1. Controlled native dates, select choices, disabled fields, an externally owned search input, submitter overrides and form-property clobbering. The fixture checks private-value omission, hidden captions, stable object references and no input/change/submission events.
2. Nine changes invalidate retained evidence: form destination, submitter destination, submission name, date minimum, option value, disabled option group and identical-looking replacement of an input, option or whole form. Fresh evidence can be validated afterward.
3. Large choice sets, the control-count bound, shadow-root controls, concealed inputs, a protected saved-password display and unsupported widgets retain explicit omission flags and stay within projection limits.
4. Decoder/projection checks reject malformed kinds/identifiers/constraints, invalid option placement, aliased option references, per-control/aggregate choice overflow, combined byte overflow and null catalogs. Quoted choice labels stay JSON data; internal option values and destinations are absent from the planner projection.

The existing host approval regression adds form-action and submitter-action changes under an unchanged native fingerprint: old approval cannot post input, and the fresh card remains required. The existing executor context regression now checks that the production routing request contains the observed search-control kind without importing page-authored typing authority. The reduction fixture follows the explicit context version.

The default source inventory selects **629** methods. The [focused inventory](browser-form-evidence-inventory.json) selects **119**. Both source inventory checks, syntax-only parsing of six changed Swift files, embedded JavaScript syntax checking and `git diff --check` pass. No assertions ran. These controlled fixtures still require later compilation and execution; they do not qualify actual UI delivery, model behavior, provider compatibility or travel/concert/movie results.

## Remaining repair sequence

1. Compile whole browsing intent into supported intermediate capabilities and complete result requirements. The current word-matching authority restriction remains; control metadata is a prerequisite, not its replacement.
2. Add document/control-bound focus, option/date selection and search submission. Bind actual values and applicable constraints immediately before dispatch and independently verify the effect. Preserve attempted/verified/uncertain steps and remaining goals across login, approval and restart.
3. Support custom comboboxes/date pickers, virtualized options and other widgets through explicit adapters. Native control metadata is not a complete accessibility tree. The bounded catalog can omit relevant controls; it must not be treated as exhaustive or as permission to execute an unobserved target.
4. Retain the distinction between declarative form metadata and arbitrary page behavior. Event listeners can intercept submission or change after an observation. This catalog does not prove the complete effect of a click, an atomic target operation, current field values or account login success. Existing native/text checks and future capability-specific receipts remain necessary.
5. Complete result extraction, result identity/constraint checking and selected public source links. Compile and execute prepared composition when authorized; keep live website scenarios deferred until explicit permission. Qualify the whole 8 GB and thermal budget in the later performance phase.
