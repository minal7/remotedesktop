# Exact native date, time and number edits

Parent source: `1878531`. Status: source implementation and prepared regressions only. No type checking, build, test execution, model run, app launch, computer use or real-website task ran.

## First-principles findings

Observing a departure date or passenger count does not provide an operation that can set it correctly. The owned-browser form adapter previously admitted only text-like inputs and textareas. Native scalar controls appeared in page evidence but were excluded from the verified edit path.

Simply adding their type names would also be wrong. A native setter can sanitize or normalize a value; an unchanged string can still violate a range or allowed increment. A plan with a valid final value can contain an invalid intermediate edit. Validation must cover the whole planned sequence before the first effect, then repeat against the retained control immediately before dispatch.

The HTML step base uses a valid minimum first, otherwise a valid default `value` attribute, otherwise the type's default base. The current value alone is insufficient. Time also permits ranges that cross midnight. These rules come from the [HTML input specification](https://html.spec.whatwg.org/multipage/input.html#the-step-attribute) and its [range rules](https://html.spec.whatwg.org/multipage/input.html#the-min-and-max-attributes). The adapter asks the same WebKit engine to evaluate them instead of implementing a second calendar and numeric validator.

## Source repair

The existing document-bound form adapter now admits native `date`, `datetime-local`, `time`, `number`, `month` and `week` input types when reported as those types by the engine. Replacement and append require an exact native setter/getter round trip on a detached control. There is no browser text-selection API for these inputs, so insertion at a selection remains rejected.

The detached probe copies `min`, `max`, `step` and the default `value` attribute, then reads range and step validity flags. It touches no live field and does not call the event-generating validation methods. Every intermediate result, including results resolved from copy steps, already passes through this shared preflight; the dispatcher repeats it immediately before any live setter or operation receipt. Values that would be normalized, rejected or violate those constraints fail before input. The user-facing rejection now mentions format, range and increments.

Explicit clearing remains a supported value edit even if a field is required. This adapter establishes the requested edit, not readiness to submit a complete form. It does not claim to validate custom page rules, cross-field relationships or server-side constraints.

Retained scalar bindings now include the four relevant attributes. Mutation records retire the old binding even if a changed attribute is restored before the next read. Ordinary text fields do not acquire retirement on default-value changes. Form shape uses native form property getters and a bounded JSON tuple rather than an ambiguous delimiter-joined string.

A scalar commit emits an `input` event followed by a `change` event. Between them it checks document identity/URL, retained control identity, constraints, exact value and authentication metadata. If the input handler replaces the field, changes its constraints or value, or reveals authentication, the change event is withheld. Authentication propagates through the existing typed login-handoff path. The durable attempt remains uncertain, and no complete dispatch receipt is issued. Resuming cannot repeat an unproven effect. After a complete event sequence, the existing task engine still independently reads the field and checks all required outcomes before verifying the step.

These are synthetic DOM events. A framework that demands trusted interaction or changes default-value attributes in its input handler may reject this path or make the result uncertain. The synchronous event sequence is still an in-flight WebKit operation; this repair does not establish instantaneous cross-process interruption.

## Prepared regressions and source checks

Six methods in `ComputerUseBrowserDOMTests` cover:

1. Eight accepted cases: exact date and local datetime values, time across midnight, bounded quantities, decimal append with unrestricted step, a default-value-derived step base, a minimum overriding that base, and explicit clearing. They check no selection insertion, exact readback, one ordered input/change pair and duplicate rejection.
2. Thirteen incompatible values: invalid calendar dates, locale-formatted dates, lower/upper bounds, date steps, datetime normalization, time precision/ranges, numeric step bases, number bounds and whitespace. Both preflight and direct dispatch must reject without live events, altered values or receipts.
3. Changes and restoration of each scalar constraint/default-value attribute invalidate the earlier plan.
4. Four input-handler interruptions: constraint change/restoration, object replacement, value rewrite and authentication. The prepared task must remain uncertain, with no change event, complete receipt or replay.
5. A two-field exact command uses the production text compiler, native capability coordinator and durable verified steps without a model proposal. Repeating the same task adds no events.
6. A complete command with an invalid intermediate quantity and valid final quantity rejects before an earlier ordinary text edit and before journal creation, without visual fallback.

The default source inventory now selects **635** methods; the [focused inventory](browser-scalar-edit-inventory.json) selects **125**. Both source inventory checks, syntax-only parsing of the four changed Swift files, embedded JavaScript syntax checking and whitespace checks pass. These checks do not compile the app or execute assertions. The earlier runtime evidence does not qualify this source revision.

## Remaining repair sequence

1. Compile complete browsing intent into document-bound intermediate actions and result requirements. Exact quoted field edits do not yet make a general flight, concert or movie search work.
2. Add select/option operations, link navigation and search submission with verified receipts; cover custom date pickers, comboboxes and virtualized controls separately.
3. Add typed date/number interpretation with explicit locale, timezone and user constraints. Do not silently convert an exact literal into a different value. Native month/week availability varies by engine; an engine-reported text fallback does not establish native calendar validation.
4. Complete remaining-goal reconciliation across login, approval and restart. An input-only scalar attempt that triggered login cannot be upgraded to a complete commit or replayed merely because the value looks correct after handback.
5. Compile and run controlled regressions when authorized, then qualify actual providers and the real-website travel/concert/movie scenarios with later explicit permission. Resource optimization and 8 GB/thermal qualification remain in the deferred performance phase.

Storage check during this repair found approximately 16 GB available. No obsolete generated artifact needed removal; no build or runtime artifact was created.
