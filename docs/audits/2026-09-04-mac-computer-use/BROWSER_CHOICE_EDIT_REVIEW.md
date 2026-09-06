# Native dropdown choices in complete form tasks

Parent source: `d4406db`. Status: source implementation and prepared regressions only. No type checking, build, test execution, model run, app launch, computer use or real-website task ran.

## First-principles findings

A dropdown is not a text field. The user's requested label, the selected option object and the website's submitted value are separate facts. A website can give two options the same submitted value, repeat a visible label, disable an option through its group or replace an option without changing its appearance. Assigning `select.value` or verifying only that value could therefore choose or confirm the wrong object.

The [HTML select specification](https://html.spec.whatwg.org/multipage/form-elements.html#the-select-element) distinguishes a selected index from a submitted value. Setting a value selects the first matching option, whereas an index identifies an option in the current ordered collection. The adapter must retain object identity before dispatch, resolve that object to its current index, and verify its identity again afterward. An empty selection must also remain distinct from a selected option with an empty label or submitted value.

This belongs in complete form-task compilation. A valid early text edit must not run if a later choice is unavailable, ambiguous or unsupported. Copying from a dropdown should use its displayed label while preserving the selected object's identity as source authority.

## Source repair

The bounded browser form catalog now includes native single-select controls. Each field carries a choice catalog with opaque option IDs, visible labels and disabled/hidden flags. Its host-private current value is the selected option ID, or an empty string for no selected option. Submission values remain inside the isolated DOM observer; they are not planner payloads, copied text or completion output.

Retained control shape includes option object IDs, exact labels and submission values, group labels, availability and default selection metadata. The observer retires bindings when option metadata or membership changes, including a change followed by restoration. A same-looking replacement gets a new option ID. There are at most 64 options per field and 128 options in a form discovery. Oversized catalogs cannot authorize a partial form edit. Swift independently checks the choice schema, IDs, bounds and selected membership; present null/incomplete choice metadata cannot silently become a legacy text reply.

The form contract resolves a requested label to exactly one enabled, visible option. It compiles the option ID into a `browser.choice.select` step with the existing durable attempted/verified/uncertain states and retained-value predicates. Selection has an explicit identity marker in the step digest. Existing ordinary text-step identities remain unchanged. Append and insertion into a select are rejected. Ordinary `Set "Cabin" to "Premium"` commands can target a dropdown; the complete quoted-command compiler also supports `Choose` or `Select` a quoted label `in`, `from` or `for` a quoted field. The latter verbs require an actual choice field. Parsing still consumes the entire request before binding any operation.

Copy compilation converts the selected source option ID to its displayed label, then to a unique destination option ID if the destination is also a dropdown. It retains the original source snapshot independently. Immediately before a copy effect, the isolated dispatcher rechecks the source object/selection and this conversion against both retained controls. A changed selection cannot supply a replacement value after host reads have passed. Ordinary text copies still require byte equality.

Dispatch checks the chosen option's availability, sets the native selected index, and uses the input/change commit sequence introduced for scalar controls. The check between events catches changed objects, metadata, selected identity, document context and authentication. Authentication propagates to the existing login-handoff error path. A complete event receipt is still insufficient by itself: the task independently verifies the resulting option ID and all retained requirements. Uncertain attempts are not replayed. Mixed tasks retain earlier selections while subsequent text, date and copy steps execute; their completion copy describes form changes.

## Prepared regressions and source checks

Nine new methods cover:

1. Contract compilation of repeated choices and copies into text and another select, with distinct operation IDs and original selected-object source authority. Selecting an option in an ordinary text field is unsupported, and an additional booking clause prevents partial compilation.
2. Contract rejection of ambiguous, disabled, hidden or missing labels, attempted use of an internal ID as a label, and append/insertion modes before any earlier edit.
3. Strict decoding of choice metadata, including null, missing-pair and unknown-kind rejection, with legacy text replies retained.
4. A five-step production compiler/coordinator sequence combines a choice, displayed-label copy, date, text and another choice. Equal submitted values and a disabled duplicate label must not select the wrong option. Same-task replay adds no events.
5. Four whole-plan failures reject unavailable/ambiguous labels and submitted-token requests before an earlier ordinary edit or journal creation, without visual fallback.
6. Six option changes invalidate prior preflight: submission value restoration, label restoration, group disabled-state restoration, object replacement, movement between groups and hidden-state restoration.
7. An event handler selects a different option with the same submitted value, mutates option metadata, or reveals login. Completion remains unproven, event tails stop where applicable, and replay adds no effects.
8. A source selection changes after host reads but before copied input. The synchronous dispatcher rejects it without touching the destination.
9. No selection remains distinct from an empty-label option; per-field and combined catalog limits prevent incomplete discovery from authorizing edits.

The earlier authentication fixture also includes a username/account select, which must block discovery before any field values are returned. The shared controlled audit helper records select indices and event order alongside ordinary field values.

Default source inventory: **644** methods. The [focused inventory](browser-choice-edit-inventory.json) selects **134**. Both inventories, syntax-only parsing of six changed Swift files, embedded JavaScript syntax and whitespace checks pass. No assertions ran. These checks do not establish compilation, actual WebKit event behavior, model quality, provider compatibility or user-visible login continuation.

## Remaining repair sequence

1. Compile whole browsing intent and result requirements. Exact form commands do not yet fulfill general flight, concert or movie research tasks. Add bound link navigation, search submission and result extraction/verification without weakening the task-authority checks.
2. Extend choice intent beyond exact labels, including group-qualified ambiguity resolution, multiple selection, custom comboboxes and virtualized lists. This source path handles native single selects. It conservatively rejects more than one available matching label; it does not invent an option from page or model text.
3. Preserve remaining goals and uncertain effects across login, approval, navigation and restart. Authentication during a selection reaches the existing handoff, but provider/window behavior and complete post-login continuation still need qualification. A value that looks correct after handback cannot manufacture a missing commit receipt.
4. Qualify synthetic events and framework behavior when runtime work is authorized. Framework-driven catalog/default-selection changes can retire a retained binding; this conservative uncertainty is not permission to retry. The in-flight WebKit event sequence does not establish instantaneous cross-process interruption.
5. Run controlled composition and later real travel/concert/movie scenarios only after the user's explicit permission. Keep resource optimization and the 8 GB/thermal qualification in the deferred performance phase.

The storage check found approximately 17 GB free. No obsolete generated files needed removal; this source work created no build or runtime artifact.
