# Verify native Unicode input between strokes

Parent source: `f64243d`. Status: source changes and regression registration only. No build, test execution, inference, app launch, computer-use activity or installed-app replacement ran. Performance optimization and live travel/concert/movie acceptance remain deferred.

## First-principles findings

Typing is a sequence of effects on a particular value and selection. Remaining in the same field does not prove that the next character still belongs at the same caret or that the preceding character was accepted.

The editor verified its complete value after a chunk of up to sixteen extended graphemes. Production fallback delivery, however, sent those graphemes as separate CGEvent strokes with suspensions between key-down and key-up. The native executor checked focused identity and required surrounding fields during that stream; standalone visual-tool typing checked focused identity. A same-field caret or value change could therefore redirect subsequent characters before chunk readback discovered the mismatch. A field becoming protected or read-only had the same gap.

There was also a final verification gap: ownership and time were checked before reading the value, but a synchronous context/AX read could consume the remaining budget or coincide with Stop. The verifier could then return an exact value as success without checking those conditions again.

These defects need repair before input receipts can support a larger sequence of repeated typing and submission steps. Counting successful event posts or clearing the task-wide TYPE/ENTER guard would not repair them.

## Source changes

- `ComputerUseTextEditor` now gives its Unicode provider exactly one complete extended grapheme at a time. It verifies the exact resulting UTF-8 value, target and editable/non-secure state before another stroke. Before a subsequent character, the caret must also be the expected UTF-16 position. It never resends a possibly delivered stroke, including one whose value has not yet appeared through AX.
- Removed the configurable multi-character fallback chunk size. A provider cannot assume that one callback containing several characters is one indivisible application effect.
- Added `InputInjector.applyTextStroke`, which refuses empty or multi-grapheme input. Its full-state admission callback runs inside the existing input lock before key-down. The existing general paced-text helper composes this stroke primitive. Key-up retains its separate release ownership and is emitted even after cancellation; it does not require the old value to remain unchanged after typing.
- Both the native form executor and standalone visual host tools use the stroke primitive. They compare the complete expected snapshot immediately before posting, then recheck cancellation/ownership and the deadline after that read. Existing focused-identity and external-field checks remain around the held stroke. Full old-value equality is deliberately not required after key-up, when the intended effect has changed it.
- Every verification read now checks required context and rechecks ownership/cancellation/time after the read, before accepting a result. A confirmed field value observed after Stop or after the deadline cannot report task success. The underlying attempted effect remains subject to the existing task journal and reconciliation rules; this patch adds no automatic retry.
- Host tools accept the existing `ComputerUseNativeTextTarget` interface for fixtures. Production still constructs the same AX adapter. The new cases exercise the real host-tool editor and real injector with intercepted events.

Qualified whole-value/selected-text setters retain their existing preferred path and exact readback. Payload/value limits, the total text deadline and the current per-value verification attempt limit remain. No model configuration changes.

## Prepared regressions

Five new methods in `ComputerUseTextEditorTests` cover:

1. Same-field caret, content, secure and read-only changes after the first key through both the production native executor and visual host tools. Each case requires one key-down/up pair only. Native replay must emit nothing further and retain an uncertain journal without replanning.
2. A state change or cancellation inside stroke admission, empty/multi-grapheme rejection, and preservation of a compound emoji in exactly one down/up pair.
3. Exact whitespace, decomposed accents, supplementary Unicode, a compound emoji, Japanese and newline input in insert/replace/append modes through both production adapters. Native task replay must add no events. The independent captured Unicode stream and resulting field values/caret must match the requested edit.
4. A whole-value result whose read expires the deadline, loses ownership, cancels the executing child task, or loses required context. The effect remains in the fixture while success is rejected and no fallback runs.
5. Delayed application acceptance: another Unicode event cannot start until the previous exact value and caret have been read back. Verification waits do not create an input retry.

Six existing editor methods were updated for the smaller attempted prefix: context drift, exact long Unicode input, dropped input, autocorrection, Pause and deadline. Existing focus/source/unchanged-field interruption cases and held-key release coverage remain selected.

Two existing opt-in native integration methods now call the same stroke admission API with an expected snapshot. The cancellation fixture uses one interrupt watcher across the full edit instead of waiting for several key events within a single provider callback. Those methods remain execution-gated; their source edits do not establish native app behavior.

The [95-method focused inventory](unicode-stroke-verification-inventory.json) covers the editor, text-task/shared transaction engine and native AX adapter. The default selected source inventory grows from 524 to 529 methods. All changed sources were already registered in the project.

## Source checks and remaining repair order

Source inventory checks match 529 default and 95 focused identifiers; `git diff --check` passes. These are registration/whitespace checks only. No Swift compiler, XCTest method or real input path ran.

1. Compile and execute the focused cases when permission resumes. Then qualify actual AX/CGEvent behavior in supported native apps, including delayed readback, IME/autocorrection, multiline fields, Unicode event size limits and application callbacks during input.
2. AX reads and event posting cross process boundaries. State can still change after the last read and before or during one event's handling. This patch stops later strokes after detectable divergence; it does not provide atomic mutation of arbitrary applications or prove native dispatch across a crash.
3. Retain durable native/visual effect receipts, document generations and interruption reconciliation. An exact current value alone does not prove which attempt produced it or justify repeating an uncertain action.
4. Continue complete visual/structured task contracts with stable step/target identities, future entities, repeated TYPE/Return, submission receipts and independent outcome verification. The task-wide visual repeat guards remain until that authority exists. This is not browser search or ticket-finding qualification.
5. Measure fallback read/notification cost and throughput during the deferred performance phase. More frequent value verification may cost time; preferred setters remain the first route. No 8 GB, latency or thermal claim is supported by these source changes.

During documentation, filesystem writes failed with ENOSPC. The task's temporary DerivedData `info.plist` identified this exact host project, and the process snapshot found no active compiler/test runner. Removed only its 449 regular, singly-linked `.o` build intermediates (101.7 MiB logical size) under `/private/tmp/remotedesktop-repair-derived-data/Build/Intermediates.noindex`. Logs, xcresults, built products, source and installed applications were retained. Free space rose from 116 to 221 MiB; that unblocks small source writes, not a build or test run.
