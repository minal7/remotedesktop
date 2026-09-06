# Native text targets and input boundaries

Date: 2026-09-06. Parent source: `bd7eb6c`. Status: implemented in source; compilation and execution remain paused. This is correctness work under F05/F06/F08/F26. Performance optimization remains deferred.

## First-principles findings

1. Reading a field must not select the destination of a later mutation. The AX adapter stored one mutable `binding` updated by every snapshot, then used it implicitly for selection and value setters. Reading another required field between destination observation and a setter could retarget that setter. More thorough constraint checks would make this design particularly unsafe.
2. Focus is an effect and can trigger application callbacks. The text task's final retained-value check happened before the native adapter focused its destination. Other fields could change during focus or selection while the editor checked only the destination.
3. Unicode delivery suspends between individual keys. A task-level ownership gate alone did not establish that the same field remained focused throughout a chunk, or that an external copy source/unchanged field still matched. Chunk readback detected a wrong result after the remaining keys had already been emitted.

## Source changes

- Added a narrow `ComputerUseNativeTextTarget` interface with explicit expected snapshots for focus, selection and both AX text setters. Production still constructs `ComputerUseAccessibilityTextTarget`; deterministic fixtures can supply the same interface without launching or controlling an app.
- Removed the AX adapter's ambient current binding. Discovery and snapshots retain references without choosing a mutation destination. Each setter resolves the expected ID, queries its capability, then validates current focus, document-bound identity, exact value and selection before invoking that particular retained element. Cancellation is checked again after AX queries. Unsupported setters still return nil only when no setter was invoked; stale state throws.
- The editor passes the appropriate expected snapshot to every adapter, including the snapshot after a selection change and the latest verified state before each Unicode chunk. It validates the surrounding task context and rereads the destination before an effect, then checks cancellation, ownership and the deadline again after those reads.
- The production native executor now receives the same complete dispatch object as the browser executor. It preserves explicit unchanged fields, earlier completed edits and a distinct copy source through focus, selection and input. The destination's evolving value is checked by the editor rather than frozen to the task's initial value; self-copy and repeated append remain valid operations.
- Native context checks run inside the existing input gate before focus and AX setters. Paced Unicode checks other required values and exact focused identity between keys, including after each key-up. Standalone host-tool typing also checks focused identity between keys. A failed check stops the remaining stream; the existing injector still releases its pending key-up.
- The existing 60-second text budget is shared with production paced-input guards and checked before/after their reads. This prevents a long sequence of individually allowed key checks from ignoring the editor's time budget. It does not turn synchronous AX messaging into a hard real-time or interruptible transaction.

No model choice, prompt, resource configuration, permission setting or installed application changed. Browser tasks retain their existing synchronous DOM constraints and receipt path. Native callback completion still needs exact text-task verification; a stopped/partial operation is not retried from its durable attempted journal.

## Prepared regressions

Five new methods in `ComputerUseTextEditorTests` cover:

| Method | Expected evidence |
|---|---|
| `testContextDriftBetweenTextAdaptersStopsSelectionSettersAndLaterChunks` | Context changes after an unsupported whole-value probe, selection, an unsupported selected-text probe, or the first chunk. No subsequent effect begins; a delivered prefix remains detectable. |
| `testContextReadCannotRetargetAnEditOrOutliveItsDeadline` | A context read changes the destination identity/selection, expires the deadline or revokes ownership. No selection or text callback runs. |
| `testNativeFocusAndSelectionSideEffectsStopLiteralAndCopyBeforeText` | Production native executor with a fixture target: focus/selection changes an unchanged field or a distinct copy source. No text setter/event, no plan reconstruction and no replay; journal remains uncertain. |
| `testNativeUnicodeStopsAtChangedFocusOrRequirementAndReleasesThePendingKey` | Production native executor and actual paced injector with a recording event sink: after the first key, changed focus, source or unchanged field stops further key-downs and releases exactly one key-up. Replay adds no events. No events are posted to the OS by this fixture. |
| `testNativeDispatchPreservesTargetsAcrossCopiesRepeatedEditsAndUnrelatedReads` | Both qualified whole-value and selected-text fixture paths complete replace, copy, self-copy and two repeated appends on their exact targets. Unrelated fields may change; full final values and five independent recorded edits match, with no replay. |

Existing editor cases and opt-in native integration sources were updated to pass the required per-action snapshots. The new native target fixture and planner do not establish actual AX or natural-language interpretation accuracy.

Lightweight checks completed:

- `git diff --check` passes.
- Default inventory: **421 exact source methods**.
- [Focused inventory](native-text-boundary-inventory.json): **101 exact source methods** across editor, text-task, browser DOM and shared transaction-engine tests.
- Source search found no remaining ambient AX setter/focus call sites.

No compiler, tests, model inference, app launch, computer-use session or website scenario ran. These source checks are not execution evidence, and earlier signed results do not qualify this patch.

## Still open

- AX reads and mutations cross process boundaries. An application may change state between the last check and its setter, or synchronously in a setter callback. This repair removes ambiguous destination state and checks more actual boundaries; it does not provide a transaction over arbitrary applications.
- AX observer/generation invalidation for reused native objects remains needed. Matching AX objects, document metadata and current state do not prove that a field never disappeared or changed role in between observations.
- Unicode content/caret verification remains per chunk; focus and external requirements are checked between keys. Changes within the destination during a chunk can still produce a partial/uncertain edit. Existing exact readback and non-replay rules must remain.
- More AX reads may add latency. Review this cost during the deferred performance phase, with bounded observation/notification work and measured takeover latency. No thermal, fan or 8 GB claim is supported by these edits.
- Native integration, held-out model interpretation, full browser search/submission/results, mobile transport and whole-task completion remain unqualified. Real travel/concert/movie website tests still require the user's explicit future permission.
