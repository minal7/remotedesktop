# Repair verification — in progress

The original audit describes main at `603e79e9f877a4a1c9a0b462d8db4da06dc46cf2`. Repairs are on `codex/repair-natural-language-computer-use`; the authoritative task list is [TODO.md](../../../TODO.md). This is a working evidence record, not release approval or a claim of complete natural-language task success.

## Environment and build boundary

- Mac14,6, 32 GiB RAM, 12 logical CPUs; macOS 27.0 beta, build 26A5406e.
- Xcode 26.6 and Swift 6.3.3. The generated project uses the repository's pinned XcodeGen 2.45.3, with its published archive hash checked before execution.
- Root SwiftPM package compiles the actual Mac computer-use sources. It uses the same dependency pins as the application project and does not launch a privileged app host or install a model.
- PR workflow now includes the Swift core suite. Its full local result is not yet green. Signed host tests, current production model-package acceptance, mobile transport, and supported physical memory tiers remain separate outstanding gates.
- The installed application is `/Applications/RemoteDesktopHost.app`, version 0.2.0 (17), Developer ID signed and notarized in July. It has not been replaced. Its Developer ID profile does not by itself provide the development profile/private signing identity needed to build a new host.

## Verified changes

| Area | Evidence | Scope of the result |
|---|---|---|
| Test inventory | Exact identifier source/result validator; 108 Python tests pass; reviewed selection expanded from 167 to 190 tests | Wrong tests with the same total, skipped cases, duplicates, and inventory drift are rejected. Signed xcresult execution is still pending. |
| Text transaction | Latest focused run: 23 tests pass (0.145 s), covering Unicode/whitespace, long literals, insert/replace/append, dropped/changed input, changed targets, synchronized input ownership, and worker cancellation/deadlines | Controlled unit tests, including the production host dispatch seam. |
| Native AX and Unicode edits | Separate AppKit fixture passed long exact text through both AX and real Unicode CGEvents, replacement, append, and second-field entry. Combined native/unit run: 23 tests pass (4.945 s) | Final values were independently read from fixture app state and compared as exact UTF-8. The fixture contains only test data and performs no external actions. |
| Apple local model | Read-only tool proposal passed using the installed model (1.962 s) | A real inference with no tool execution. |
| Apple semantic routing | Initial run failed three cases. Corrected host-identity fixtures and app-selection instruction; all 16 cases passed on rerun (12.222 s) | Real local-model routing over supplied screen context. Does not prove grounding, execution, or whole-task completion. |

The signed expanded deterministic selection has not yet run. Unit, native-component, and routing results remain distinct from the full production-package gate.

## Failures retained for investigation

- A selected 182-test core run finished with 179 passing, two opt-in skips, and one unexpected OCR failure in `testRenderedFinishedChecklistVisionEvidenceCompletes` (58.956 s total). The earlier parallel process-per-test run repeatedly incurred extreme Vision latency and was stopped after diagnostic stack samples. Core compilation itself succeeds.
- A standalone accurate Vision request on a blank 640×480 image took 148.197 s. CPU-only accurate mode took 164.710 s; revision 2 took 27.614 s; revision 1 took 47.311 s. These measurements are specific to this beta OS and machine.
- Fast OCR took 0.095 s for the blank image. It recognized the checkout label and quote numbers in candidate fixtures, but changed spacing in a time and failed the system-consent detector. The candidate qualification test failed; fast OCR has **not** replaced production OCR.
- The native integration initially rejected AppKit text views because they omit `AXEnabled` and `AXEditable`. Actual inspection showed writable `AXValue` and `AXSelectedText` attributes. The adapter now accepts that positive edit capability while rejecting an explicitly disabled element, and the real AX integration subsequently passed.

## Remaining boundaries

- Pause/resume checkpoint retention is implemented in memory but still needs executor-level interruption coverage, stable step identities, and durable recovery. Interrupted edits currently require reconciliation; they are not silently replayed.
- Large exact quoted text can use a host-owned payload reference. Model-generated text retains its smaller schema limit. Multi-payload task compilation and repeated-action policy are not yet repaired.
- Text comparisons use exact UTF-8 equality. No undocumented application normalization is accepted.
- The observation worker frees the caller on cancellation/deadline. A blocked native OCR call retains the single worker permit until it exits, preventing queued retries from accumulating. This does not repair the underlying beta-OS OCR latency.
- Browser text integration, actual visual-model grounding, goal decomposition, final outcome verification, multi-display capture, and the full phone-to-Mac flow remain outstanding.

## Reproducible commands

```sh
python3 -m unittest discover -s host-mac/scripts/tests -p 'test_*.py'
python3 host-mac/scripts/verify_test_inventory.py \
  --manifest host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json --source-root .
swift test --force-resolved-versions --no-parallel
host-mac/scripts/run_text_edit_acceptance.sh
RUN_FOUNDATION_MODELS_LIVE_ACCEPTANCE=1 swift test --force-resolved-versions \
  --filter AppleFoundationMCPPlannerTests/testOptInLiveVisualRouterUnderstandsOrdinaryLanguageAcrossSemanticSurface
RUN_COMPUTER_USE_OCR_QUALIFICATION=1 swift test --force-resolved-versions \
  --filter ComputerUseOCRQualificationTests
```

The native text script briefly opens a disposable fixture window, restores the previous application, and removes its temporary bundle. Model routing and OCR qualification are deliberately opt-in; candidate failures remain evidence against adopting that candidate.
