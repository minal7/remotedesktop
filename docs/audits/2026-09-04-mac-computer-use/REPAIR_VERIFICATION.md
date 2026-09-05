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
| Test inventory | Exact identifier source/result validator; 108 Python tests pass; reviewed selection expanded from 167 to 202 tests | Wrong tests with the same total, skipped cases, duplicates, and inventory drift are rejected. A signed 35-method text-core subset passed exact-ID validation against a real xcresult. The full OCR-dependent selection remains failing. |
| Text transaction | Latest focused run: 23 tests pass (0.145 s), covering Unicode/whitespace, long literals, insert/replace/append, dropped/changed input, changed targets, synchronized input ownership, and worker cancellation/deadlines | Controlled unit tests, including the production host dispatch seam. |
| Native AX and Unicode edits | Separate AppKit fixture passed long exact text through both AX and real Unicode CGEvents, replacement, append, and second-field entry. Combined native/unit run: 23 tests pass (4.945 s) | Final values were independently read from fixture app state and compared as exact UTF-8. The fixture contains only test data and performs no external actions. |
| Apple local model | Read-only tool proposal passed using the installed model (1.962 s) | A real inference with no tool execution. |
| Apple semantic routing | Initial run failed three cases. Corrected host-identity fixtures and app-selection instruction; all 16 cases passed on rerun (12.222 s) | Real local-model routing over supplied screen context. Does not prove grounding, execution, or whole-task completion. |

The earlier signed expanded selection built and ran all 190 methods: 104 passed and 86 failed, with 98 assertions/errors (89 unexpected), concentrated in the OCR-dependent executor suite. Unit, native-component, and routing results remain distinct from the full production-package gate.

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

## Signed host and OCR follow-up

- Checkpoint `4a524d6` built and launched with the valid Apple Development identity and development profile generated during the earlier provisioning attempt. The installed app was not replaced.
- The signed 190-method run failed in 56.401 s. The first OCR operation exceeded its 10 s caller deadline; subsequent operations reported bounded-worker busy state or Vision/E5RT code 13 with missing compiled ANE bundle resources. The 14 text editor methods all passed.
- The original acceptance script removed its xcresult directory on failure. That behavior is repaired: future owner-only result bundles are retained and their location is printed. The first run's complete text log remains at `/tmp/remotedesktop-signed-repair-acceptance.log`; its bundle is unavailable.
- Disk free space was approximately 2.1 GiB. Cleaning a task-generated Swift build cache increased it to about 3.2 GiB. The empty host Vision cache was moved aside. A single signed OCR test still failed with the same missing ANE resource; evidence is retained at `/tmp/remotedesktop-vision-cache-recheck.xcresult`. Cache regeneration did not repair OCR.
- Explicit supported compute-device probes completed blank-image accurate OCR in 49.232 s (CPU) and 49.420 s (GPU). Both are too slow for the interactive path and neither has been adopted. These differ from the earlier deprecated `usesCPUOnly` probe.
- A new native-form natural-language corpus was frozen at checkpoint `4a524d6` before implementing its planner. It records expected field values, scope exclusions, and interruption faults; unrun cases remain pending.

## Verified native and browser text repair checkpoint

- `host-mac/scripts/run_text_edit_acceptance.sh`: **37 passed, no skips or failures**, 53.566 s. Log: `/tmp/remotedesktop-text-stroke-hold-final.log`. The native fixture took 26.656 s and the WebKit fixture 26.747 s; both include a deliberately forced 2,000-character Unicode fallback in addition to the preferred AX path. No local model was substituted for these component checks.
- The browser reports its application state from `input` events separately from raw DOM values. Leading/trailing whitespace, line breaks, combining marks, emoji, selection replacement, append, and a second field are checked independently of production AX readback.
- WebKit's writable AXSelectedText path returned without changing the tested textarea. The adapter now uses AXValue for structurally identified web content, with exact readback and no fallback after any invoked setter. This follows the separate capabilities exposed in [WebKit's accessibility wrapper](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/accessibility/mac/WebAccessibilityObjectWrapperMac.mm); the actual installed-framework behavior was determined by the fixture.
- Synchronous Unicode event bursts dropped characters. Pacing only between batches, and then only between key pairs, failed subsequent runs despite an isolated pass. The verified repair gives each grapheme a key-down/hold/key-up interval, tracks its release ownership, clears inherited modifiers for exact text, and yields to cancellation. A takeover releases the active stroke once; a later resumed callback cannot release another stroke. No dropped character is automatically resent.
- Signed app-host text-core: **35 passed**, 1.350 s. Result: `/tmp/remotedesktop-signed-text-tasks.xcresult`; log: `/tmp/remotedesktop-signed-text-tasks.log`. `verify_test_inventory.py` confirmed exactly the 35 reviewed IDs from `/tmp/remotedesktop-text-verified-inventory.json`. The full reviewed source manifest contains 202 tests.
- Python contract suite: **108 passed**, 0.860 s. Source inventory and `git diff --check` pass. The project was regenerated using pinned XcodeGen 2.45.3.

## Native goal candidate — not enabled

The new text-task engine represents ordered operations over retained AX field references, expected before/after values, dependencies and final predicates. Its owner-only atomic journal stores step IDs and attempted/verified/uncertain statuses, not values or payloads, and is fsynced before effects. Seven task and three journal tests pass, including same-value edits in two fields, post-delivery interruption without replay, partial delivery, changed earlier outcomes, journal write failure, reopening, malformed state and symlinks.

The new native goal executor is used only by opt-in tests and is **not connected to normal computer use**. An earlier proposal-only tool candidate completed a real native two-field natural-language task. Its whole-goal scope is not qualified: the current 10-case actual Apple-model run passes nine cases but incorrectly proposes only the field edit for `Fill Origin with Boston, and send the form.` Such a result must not become a whole-task completion. Log: `/tmp/remotedesktop-text-goals-scope-context-current.log` (38.497 s). Forced structured-output and earlier tool candidates had additional failures. A second scope inference reduced some errors but still missed the compound action; it has not established a safe product architecture.

The frozen corpus is now a regression set because it has been used during development. New held-out phrasing and complete intent/outcome qualification are still required. Exact token counts include instructions, prompt, tool/output schemas, response budget and framing reserve on macOS 26.4+; this budgeting currently applies to the candidate, not every existing planner.
