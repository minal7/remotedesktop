# Retained field constraints at text dispatch

Date: 2026-09-06. Parent source: `8cb458a`. Status: implemented in source; compilation and execution deferred under the user's test pause. This review covers a correctness repair under F05/F06/F26, not performance optimization or general browser-task readiness.

## First-principles failure

“Leave this field unchanged” and “the previous edit is still correct” are requirements on the state in which the next action happens. Observing either condition earlier does not preserve it. A durable journal write and asynchronous target/source reads separate the task engine's preconditions from the eventual input.

The browser already rechecked the destination and copy source synchronously in its isolated JavaScript world before the native value setter. Other required fields were checked through separate host reads. If an unchanged field or an earlier completed field changed between those reads and the edit, the next input could still happen. Final verification could reject completion afterward, but it could not undo that input.

## Repair

1. Each compiled text step captures explicit unchanged values and the latest result of each earlier edit. Unrelated observed fields are not implicitly frozen. Destination value/selection and copy-source value remain separate explicit requirements.
2. Step identity now includes the sorted retained target/value pairs under `text-input-required-values-v3`. A different constraint changes the input identity as well as the complete contract digest. Old journals cannot silently inherit the new authority or authorize replay.
3. Literal and copied operations share one `ComputerUseTextInputDispatch` callback carrying the edit, expected destination, shared-engine operation ID, optional copy source and required values. The production native executor passes this object to the browser adapter without reconstructing the step from the operation ID.
4. After the durable attempt, the task adapter rereads retained values and rechecks cancellation/ownership around every asynchronous read. Drift stops both native and browser dispatch. Byte comparisons preserve the existing exact-text contract.
5. The browser resolves every required host target to its retained DOM binding and sends a bounded array of requirements. Unbound references are rejected rather than omitted. Its fixed isolated script validates all requirements in the same synchronous invocation as the destination/copy-source checks and setter, before selection changes, operation-receipt insertion or page input events. Replaced, relabeled, unavailable or value-changed retained controls reject the edit.
6. A retained-state rejection reports an incomplete outcome. The task journal keeps the attempted step uncertain, so Resume does not dispatch it again. Rejection creates no DOM input receipt; successful input still requires independent readback and dispatch evidence.

The journal still contains identities and statuses, not field values. No model prompt, model selection, resource configuration, installed application or permission setting changed.

## Regression coverage prepared

Six new methods are registered:

| Test class and method | Boundary and required evidence |
|---|---|
| `ComputerUseTextTaskTests/testRetainedValuesChangingDuringDurableAttemptStopLiteralAndCopyAdapters` | Four combinations of literal/copy and unchanged/earlier-edited fields; mutation during attempt persistence must stop the destination adapter, retain earlier work and prevent replay. |
| `ComputerUseTextTaskTests/testRetainedValueReadHonorsCancellationAndTakeoverBeforeDispatch` | Cancellation or ownership loss during the final retained read must start no input. |
| `ComputerUseTextTaskTests/testIdentifiedDispatchCarriesLatestConstraintsWithoutFreezingUnrelatedFields` | Replace, copy and two identical appends carry the correct intermediate constraints; unrelated changes remain allowed; each step executes once. |
| `ComputerUseBrowserDOMTests/testRetainedFieldDriftAtDOMDispatchPreventsLiteralAndCopiedInputWithoutReplay` | A controlled page changes after all host reads and before real DOM dispatch. Cases cover changed values, an identical replacement control, relabeling and canonically equivalent but byte-distinct Unicode. Check destination value/selection, independent page events, missing input receipt and non-replay. |
| `ComputerUseBrowserDOMTests/testDOMDispatchRejectsUnboundOrChangedConstraintsWithoutConsumingInputIdentity` | Unknown references and a known field with a mismatched value cause no mutation/event/receipt. A separate low-level adapter check demonstrates that rejection did not reserve the DOM operation ID; the task-level cases independently prohibit automatic retry. |
| `ComputerUseBrowserDOMTests/testProductionDOMDispatchPreservesLatestConstraintsAcrossCopiesAndRepeatedEdits` | Production capability coordinator/native executor/browser wiring with a fixture planner: four ordered inputs, complete form values, a permitted unrelated-field change, retained constraint, verified journal and replay without another model call or input. Page event sequence numbers establish order independently of HTTP arrival. |

Existing literal/copy receipt, cancelled callback, uncertain input and browser recovery tests now use the unified dispatch object. Recovery coverage additionally requires per-step identities to change when retained constraints change.

Lightweight validation completed:

- `git diff --check` passes.
- The default manifest matches **416 exact source methods**.
- The [focused manifest](retained-text-dispatch-inventory.json) matches **77 exact source methods** across the text task, browser DOM and shared transaction engine classes.

These are source checks only. No compiler, test runner, local model, app launch, computer-use session or real website test ran. The new cases have no execution result. Previous signed results do not qualify these edits.

## Remaining limits and next work

- Native AX reads, focus and text changes cross process/control boundaries. The added reread narrows a known gap but cannot make those operations atomic. Native generation tracking and consistency across focus/input remain open; this patch does not close F05 or F06 for native apps.
- A page's input handler can change other fields after the setter. Existing postconditions, invariants and outcome checks must continue to report divergence. There is no claim of rollback or an atomic multi-field form transaction.
- This repair establishes no browser submission, date-picker interaction, search-result extraction or ticket/travel/movie outcome verification. Whole-goal planning and per-step visual TYPE/ENTER authority remain separate required repairs.
- When execution is permitted, compile and run the reviewed deterministic inventory before model/browser qualification. Real-site end-to-end scenarios remain gated on the user's explicit future permission. Performance work remains deferred until correctness repairs are complete.
