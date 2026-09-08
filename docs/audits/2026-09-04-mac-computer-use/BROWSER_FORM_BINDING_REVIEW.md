# Bind research page controls to native editable fields

Parent: `21c559b`. This checkpoint prepares native correspondence and complete-goal form input. It does not implement semantic form actions, connect them to the default research driver, or establish runtime correctness.

## First-principles finding

A request such as “find travel tickets tomorrow for two people” requires three separate decisions: what the request means, which actual controls represent its arguments, and which effects would satisfy the request. Correct language understanding cannot repair an ambiguous target. Correct typing cannot establish that the chosen field or value means what the user intended.

The page reader exposed control references (`cN`), types, constraints and option references. The native editor retained a different set of field references (`eN`, represented outside the isolated DOM by host hashes). There was no correspondence between those sets. Joining by a label, HTML name or array position would confuse repeated labels, separate forms and replacement nodes. Passing page IDs directly to the editor would not work. Generating a new quoted typing command from the research goal would also discard the parent goal and its remaining requirements.

Option observation had a related inconsistency: the page and editor computed concealed choices differently. A choice presented as available to a planner could be rejected by the actual editor.

## Source repair

- `bindPageFields` joins references only when they point to the same retained DOM object and form. It revalidates the exact page observation, its native containers/controls/links, and the complete retained editable membership. Missing or malformed IDs cannot enter discovery and clear input receipts.
- Binding reads current values and selections only to compare them with host snapshots. It does not focus, set a value, dispatch an event, submit or navigate. Valid binding and revalidation reuse existing native input receipts.
- The Swift adapter checks document ownership, field membership, exact labels and snapshots, supported types and select choices. The resulting evidence is sealed to that adapter. A different adapter cannot adopt it by supplying equivalent labels or values.
- Page options now use the editor's existing identity, concealment and disabled-state rules, including native optgroups, inert/ARIA-hidden state and transparent options. Submission values remain excluded from model projection.
- `ComputerUseBrowserResearchFormInput` retains the exact interpretation and native evidence. Its JSON includes the full original request, fixed clock/time zone, accepted scoped answers, every interpreted requirement and the bounded page projection. Explicit field aliases map to observed controls. Current values, selections, native field hashes, document authority, HTML names, form destinations and option submission values are not projected.
- If a bound field's complete metadata does not fit the page projection, preparation fails with `contextLimit`; it never offers an alias whose type, constraints or choices were omitted. The eventual model request still needs exact token accounting for the full context.
- The retained research owner prepares and revalidates input inside its serialized operation, with source, session, presentation and control checks. It retains the same adapter for revalidation. Source changes, candidate work, navigation, questions, accepted answers, Pause and retirement invalidate speculative form input. Explicit handback requires a fresh preparation under the retained goal.

These checks establish an observed correspondence, not semantic correctness or authorization to type. Native field values can change again after a successful read; the eventual action must still validate at dispatch. Unsupported controls and omitted page content remain explicit limitations.

## Prepared regression coverage

Nine methods in `ComputerUseBrowserFormBindingTests` cover:

1. Duplicate field labels in separate forms, reversed discovery input, native scalar/search/textarea kinds, complete-goal context and exclusion of private values/identities.
2. Duplicate option labels with distinct identities, shared concealment/disabled rules and private submission values.
3. Value-only changes, caret changes, node replacement, removed fields and added editable membership.
4. Superseded page snapshots, foreign adapters and foreign root tasks.
5. Valid binding and malformed ID requests preserving actual verified input receipts and later native form-query preparation.
6. A select whose complete option metadata exceeds the bounded projection.
7. Scoped clarification retention, original clock/root, question invalidation, stale revisions and explicit handback.
8. Pause during native binding, retaining the operation slot until unwind and rejecting a late publication.
9. Lost control and an authentication challenge closing field access.

These are native browser fixture sources, not executed evidence. They use deterministic proposal fixtures and do not evaluate a local model.

## Ordered remaining repairs

1. Compile a proposal from the complete goal into exact native field references and typed values. Distinguish departure from return, origin from destination, a maximum from an exact quantity, and a date range from an exact day. Ambiguous required arguments need a scoped question; they cannot be guessed or silently dropped.
2. Normalize supported dates, times and scalar values from the fixed task clock and actual control type. Bind each derived payload to its original requirements. Resolve select options by observed identity and meaning; repeated labels must remain distinguishable. Reject unrepresentable values before touching a field.
3. Retain a parent-goal form stage with the original task, remaining requirements, exact adapter, all field preconditions, ordered effects and native receipts. Prevent new field discovery from resetting an attempted stage. Persist before dispatch and reconcile uncertainty before replay.
4. Prepare a search submission only from verified field effects and the observed submitter, using the existing native GET-query continuation where supported. Preserve the original task across navigation. Treat POST, dynamic JavaScript search, autocomplete, calendars, custom widgets and embedded controls as separate capabilities requiring their own contracts.
5. Add form planning and stage recovery to the default research driver and shared local runtime. Bound context, cancellation and inference work; do not turn each unsupported field into an unbounded retry or another model process.
6. Connect blocked sign-in redirects and account-provider windows to visible user control and explicit handback. Resume the retained stage with fresh evidence, preserving the goal and proven effects. Never read credentials as task data.
7. Finish cross-page offer comparison, required counts/ranking, price/fee/availability interpretation and public source links before allowing a completed research answer.
8. When the user authorizes execution, typecheck/build and run the focused native/model checks, then the deferred travel/concert/movie website scenarios. Keep failure evidence and held-out qualification separate from any model adaptation. Alternative models and RTX 3080 distillation/pruning remain authorized when qualification identifies a model problem; remote access is still unverified.

## Verification performed

Five changed Swift sources passed syntax parsing only. The production isolated DOM script passed `node --check`. Project plist syntax, source registration, whitespace and reviewed source inventories were checked. The default inventory selects **956** methods and the [focused inventory](browser-form-binding-inventory.json) selects **273**; counts are source discovery, not test results.

No typechecking, builds, assertions/tests, model inference, app launches, desktop control or real-site E2E ran. No installed application or model was replaced. The temporary JavaScript syntax-check file was removed. Overall computer-use repair and qualification remain open.
