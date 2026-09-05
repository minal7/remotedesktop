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
| Test inventory | Exact identifier source/result validator; 112 Python tests pass; reviewed selection expanded from 167 to 228 tests | Wrong tests with the same total, skipped cases, duplicates, and inventory drift are rejected. Signed checkpoints, including the 70-method native runtime follow-up, passed exact-ID validation against real xcresults. The full OCR-dependent selection remains failing. |
| Text transaction | Latest focused run: 43 tests pass (0.198 s), covering exact text, dropped/changed input, deadlines, ownership, task constraints and journal recovery | Controlled component tests, including the production host dispatch seam. |
| Native and WebKit edits | Actual AX and Unicode input, independent application-state readback, and identical-looking field replacement. Combined suite: 45 tests pass (53.839 s) | Both fixtures verify long exact text and reject retained references to replaced controls. Only fictional local data is used. |
| Apple local model | Read-only tool proposal passed using the installed model (1.962 s) | A real inference with no tool execution. |
| Apple semantic routing | Initial run failed three cases. Corrected host-identity fixtures and app-selection instruction; all 16 cases passed on rerun (12.222 s) | Real local-model routing over supplied screen context. Does not prove grounding, execution, or whole-task completion. |

The earlier signed expanded selection built and ran all 190 methods: 104 passed and 86 failed, with 98 assertions/errors (89 unexpected), concentrated in the OCR-dependent executor suite. Unit, native-component, and routing results remain distinct from the full production-package gate.

## Failures retained for investigation

- A selected 182-test core run finished with 179 passing, two opt-in skips, and one unexpected OCR failure in `testRenderedFinishedChecklistVisionEvidenceCompletes` (58.956 s total). The earlier parallel process-per-test run repeatedly incurred extreme Vision latency and was stopped after diagnostic stack samples. Core compilation itself succeeds.
- A standalone accurate Vision request on a blank 640×480 image took 148.197 s. CPU-only accurate mode took 164.710 s; revision 2 took 27.614 s; revision 1 took 47.311 s. These measurements are specific to this beta OS and machine.
- Fast OCR took 0.095 s for the blank image. It recognized the checkout label and quote numbers in candidate fixtures, but changed spacing in a time and failed the system-consent detector. The candidate qualification test failed; fast OCR has **not** replaced production OCR.
- The native integration initially rejected AppKit text views because they omit `AXEnabled` and `AXEditable`. Actual inspection showed writable `AXValue` and `AXSelectedText` attributes. The adapter now accepts that positive edit capability while rejecting an explicitly disabled element, and the real AX integration subsequently passed.

## Remaining boundaries

- The native form candidate now has real-app pause/resume evidence, immutable ordered step identities, and a durable attempt journal. Normal execution still uses the earlier in-memory checkpoint path; general executor integration and safe target rebinding after process restart remain open. Interrupted edits require reconciliation; they are not silently replayed.
- Large exact quoted text can use a host-owned payload reference. Model-generated text retains its smaller schema limit. Multi-payload task compilation exists only in the disabled native goal candidate; the normal visual path's task-global repeated-action policy is not yet repaired.
- Text comparisons use exact UTF-8 equality. No undocumented application normalization is accepted.
- The observation worker frees the caller on cancellation/deadline. A blocked native OCR call retains the single worker permit until it exits, preventing queued retries from accumulating. This does not repair the underlying beta-OS OCR latency.
- Native and browser text integration now pass the bounded fixtures described below. Actual visual-model grounding, qualified goal decomposition, whole-task outcome verification, multi-display capture, and the full phone-to-Mac flow remain outstanding.

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

## Contract and stale-field follow-up

- Focused component suite: **43 passed**, 0.198 s, `/tmp/remotedesktop-text-deadline-contract-final.log`. A 60-second monotonic edit deadline is checked before each mutation, including after a slow preflight read. A possibly delivered edit is never resent on deadline. Synchronous native calls can still overrun the caller's budget; the next mutation is prevented, but this is not a hard native-call timeout.
- Journal recovery now binds length-framed hashes of the entire contract: ordered step identity, original value, selection, exact payload and expected value, plus unchanged-field constraints. A recovered journal that drops a constraint, changes the original state, or has an unreachable status order is rejected. The journal contains hashes and statuses, not field values or payloads. A process restart still requires safe target rebinding; this does not establish seamless crash recovery.
- Explicit unchanged-field constraints are checked before further edits and at completion. Input authority is rechecked after persisting an attempt. Host payload IDs are chosen so they cannot alias existing task text such as `p1` or a fake marker.
- Actual native/WebKit/component suite: **45 passed**, 53.839 s, `/tmp/remotedesktop-text-target-membership.log`. Each fixture now replaces a control with an identical-looking control and proves the old AX target ID is rejected. The adapter validates ancestry to the current window and identity of the AX document root, with the messaging timeout applied before the first query on each reference. Document reloads that reuse the same AX objects still require generation notifications; AX queries still run on MainActor.
- Reviewed source inventory: **210 methods**. The latest SDK compiles the candidate; the pinned Xcode 26.2/Swift 6.2 CI toolchain uses its unavailable branch because it predates the token-count API. That older-toolchain branch has not been compiled locally on this machine.
- Signed host follow-up: **43 passed**, 1.616 s, `/tmp/remotedesktop-signed-text-contracts.xcresult`; full log `/tmp/remotedesktop-signed-text-contracts.log`. Exact-ID validation used the reviewed five-class subset in `/tmp/remotedesktop-text-contract-verified-inventory.json`; no skips, unexpected tests, or count substitution were accepted. Python suite: **108 passed**, 0.865 s, `/tmp/remotedesktop-contract-checkpoint-python.log`.

## Planner experiments: interpretation remains unqualified

The requirement-coverage experiment copies all task words/punctuation into an ordered list of requirements, then rejects non-text operations before execution. It passed **2/10** regression cases in 30.386 s; log `/tmp/remotedesktop-requirements-planner.log`. N02 and N13 passed. Six cases were rejected as invalid plans, including N06's correctly identified unsupported operation with incomplete punctuation coverage. N03 selected replacement instead of append; N08 selected Origin for a missing City field. Those latter two are semantic errors that a structurally valid plan does not prevent. The candidate remains disconnected from normal execution.

A proposal-only comparison used the already cached [Qwen3-VL-2B-Instruct](https://huggingface.co/Qwen/Qwen3-VL-2B-Instruct), revision `89644892e4d85e24eaac8bacfd4f463576704203`, through Transformers 4.57.6, PyTorch 2.5.1, MPS FP16/eager attention and four CPU threads. SHA-256 of the actual weights was independently checked: `7de1838c87a5349b016c26a1c3f7d2bc400a3d485f95ef39a7059ffd734977a0`. All loading and inference were local, with offline mode and `local_files_only`; no weights were downloaded. The model chat template was inspected to confirm the full system instruction was retained.

This Qwen candidate passed **3/10** current cases: N01, N02 and N07. Total inference was 46.470 s, median 2.177 s; model load 4.571 s. Peak process RSS was 9,319,317,504 bytes; MPS driver allocation at completion was 8,351,170,560 bytes. Most short responses rejected supported tasks. N03 used the wrong mode plus an empty extra edit; N06 returned an invalid `unsupported` edit mode instead of a whole-task unsupported result. A strict host validator rejects those malformed proposals. Log: `/tmp/remotedesktop-qwen-text-regression.log`; retained fictional proposals: [qwen-text-regression-results.json](qwen-text-regression-results.json). The portable, proposal-only benchmark is [benchmark_native_text_qwen.py](../../../host-mac/scripts/benchmark_native_text_qwen.py).

These experiments use different schemas/prompts and are **not a controlled ranking of the underlying models**. No native effects were executed during either corpus run. Neither candidate qualifies for production; copying every word proves source coverage, not faithful meaning. A second model or a larger prompt is not accepted as a repair without measured whole-goal accuracy and operational cost.

The 14-case `native-text-goals-heldout-v2.json` corpus was frozen before the requirement-coverage rewrite and was unrun at that checkpoint. Its SHA-256 is `5811fd2bc05ff5ed8b91726312d94d0ed374187e2bb0ff2f2c5ecae06121d556`. It includes different labels, phrasing, ordered edits, negation, ambiguous fields and compound requests. Its first frozen-candidate run is recorded below. Once used to revise a candidate it must be relabeled as a regression set, not repeatedly presented as held-out evidence.

## A bounded Qwen3.5 planner candidate

The next comparison used [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) in the [Unsloth Q4_K_M conversion](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF), revision `e87f176479d0855a907a41277aca2f8ee7a09523`. The 2,740,937,888-byte download was independently checked against SHA-256 `00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4`. It remains in the task comparison directory, not an installed product package. Only build caches created for this task were cleaned for disk headroom; source, result bundles, the user's model caches, and the installed app were preserved.

The existing installed llama.cpp **b9992 / 6eddde06a** binary ran the model with an authenticated loopback endpoint, no web UI or computer-control tools, offline mode, one slot, 4,096 context tokens, and four CPU threads. The temporary server process was stopped and its credential removed after each run. These are sequential candidate experiments, not a controlled comparison of model architectures or quantization quality.

| Candidate | Regression result | Inference time across 10 cases | Peak server RSS |
|---|---|---:|---:|
| Same baseline prompt, reasoning off, unconstrained response | 4/10 | 11.956 s | 3,192,029,184 bytes |
| Explicit host-owned literal IDs plus constrained JSON, reasoning off | 6/10 | 12.114 s | 3,198,746,624 bytes |
| Same typed contract, reasoning on with a 512-token budget; at most 1,024 total output tokens | 10/10 | 81.284 s | 3,257,286,656 bytes |

The baseline had three `fieldId`/`fieldID` schema errors and rejected several otherwise supported requests. Explicit payload-ID availability and constrained JSON eliminated the spelling errors and enabled more literal cases, but still rejected valid requests. Enabling bounded reasoning repaired the remaining regression failures. That combined result does not establish that either change alone explains every improvement. Model reasoning text is not retained in the artifacts; only final fictional proposals, token counts, and outcomes are recorded.

The selected configuration, model/runtime hashes, benchmark source hash, and corpus hash were committed at **`5d2e0e9` before the holdout was run**. See [the frozen manifest](native-text-planner-candidate-v1.json). Both source and corpus hashes remained unchanged for the first holdout run, and the 14 observed case IDs exactly matched the expected corpus.

**First holdout result: 13/14 (92.9%).** Total inference was 122.330 s, median 9.401 s, maximum 10.505 s; startup 0.881 s and peak server RSS 3,256,369,152 bytes. H06 was a conservative unsupported response to a supported edit that stopped before submission. No accepted proposal had incorrect expected final field values in this sample. Results: [held-out v2 proposals](qwen35-text-heldout-v2-results.json); log `/tmp/remotedesktop-qwen35-text-heldout-v2.log`.

This does **not** meet the proposed 95% gate or qualify actual app completion. It is one small, self-authored holdout within a bounded form task family, with no desktop effects. The local candidate is now injectable into the native executor for the live checks below; it is not registered in normal app execution. Production package trust and resource handling, broader interruption/recovery, and the phone-to-Mac flow remain required. The failed H06 expectation is preserved; it has not been weakened or used for another prompt-tuning pass.

## Local planner through actual form execution

`ComputerUseLocalTextGoalPlanner` uses the frozen candidate's exact system instruction and model-visible field/literal-ID projection. Its instruction SHA-256 is `552441dde6058647031da17493e732f7182fc5339a259fe1f9f7ddda6dba211f`. Existing values, AX identities and captured literal contents remain in host memory. Exact server template/tokenization counts reserve 1,024 output tokens and 64 framing tokens within the 4,096-token context. Strict parsing rejects duplicate keys, truncated output, another model alias, invented text, missing targets, malformed edits, and tool calls. Every unedited discovered field becomes an unchanged final predicate.

The native executor requires an explicitly injected planner and checks ownership before and after inference. It retains the same contract on same-task resume. A typed verified-step callback supports precise interruption tests; a separate injected edit adapter forces controlled delivery faults without changing the normal editor path. The old implicit Apple candidate and its optional live-effect test hook were removed; Apple proposal-only experiments remain available for diagnosis.

The first actual-model AppKit/WebKit run passed **two XCTest methods covering 26 scenarios** in **221.087 seconds**. Each fixture ran the ten non-fault regression cases (seven supported form outcomes, two unsupported requests and one clarification), then append/pause/resume, partial delivery without replay, and actual control replacement after inference. Readback came from each fixture's own state, independent of the executor's AX verifier. Append/resume required only one planner call and did not duplicate the first append. The partial-delivery scenario deliberately supplied a faulted edit adapter; it is not a claim that the OS randomly dropped that input. The runtime/model were real in every goal proposal. Log: `/tmp/remotedesktop-native-model-live-v1.log`; summary: `/tmp/remotedesktop-native-model-live-v1.json`.

An expanded run with the streaming transport passed the ten regression cases and append/resume in both fixtures, then failed at N12's new compound prompt before its changed-final-value fault could be injected. The subsequent cancellation/delivery scenarios did not execute in that run. This is a retained failure, not a passing expanded suite: `/tmp/remotedesktop-native-model-live-v2.log` and `/tmp/remotedesktop-native-model-live-v2.xunit.xml`. Fault scenarios can now be diagnosed separately without repeating the ten regression cases; their narrower result is labeled explicitly.

The isolated fault run verifies **five of six scenarios in each fixture**, with N12 still failing. Actual inference cancellation returned in about **0.002 seconds** in each fixture, with no edits. An injected adapter then forced the real Unicode fallback, interrupted while typing was active, and required the fixture to show a nonempty partial prefix. Posted key-downs and releases matched exactly; resume reported an uncertain effect and posted no further keys. Partial-delivery and replaced-target checks also passed. Log: `/tmp/remotedesktop-native-model-faults-v1.log`. These measurements cover the controlled ownership/cancellation path on this machine, not all capture/OCR/desktop load or physical hardware tiers.

A separate proposal-only probe of the same N12 prompt returned `unsupported` with no edits in **9.351 seconds**. Raising the reasoning budget from 512 to 1,024 tokens and the output ceiling from 1,024 to 2,048 still returned the same rejection in **18.004 seconds**. More inference budget did not repair this error and was not adopted. Compact results and raw-log hashes for all three live runs and both probes are retained in [native-text-execution-evidence-v1.json](native-text-execution-evidence-v1.json). Results from repeated runs are not summed into an independent accuracy estimate.

The shared local HTTP transport now rejects redirects and bounds response collection while streaming, including chunked bodies without Content-Length. It cancels the underlying request on cancellation, size rejection, and early exit. Ten wire/transport tests pass in **0.334 seconds**, including real loopback redirect, stalled-body cancellation, oversized unfinished bodies, and exact-limit acceptance. A first oversized-header fixture stalled under native MIME sniffing; explicitly declaring its content type established the intended response boundary. Both the failed probes and passing follow-up are retained in `/tmp/remotedesktop-response-bounds*.log`. This establishes bounded application-side collection, not a bound on every internal CFNetwork allocation.

`run_native_text_model_acceptance.py` verifies the model, runtime binary and frozen benchmark hashes before launch, uses private temporary credentials and loopback-only offline inference, and stops its own process group on success, failure, timeout or interruption. It retains exact test results and refuses to overwrite earlier evidence. Four Python checks cover altered model data, invalid/skipped test reports, actual child-process teardown after an exception, and shell failure propagation. An empty-array expansion under macOS Bash 3 initially prevented the default gate from reaching Swift; the corrected gate uses a nonempty explicit serial argument list, and the new shell test proves it executes Swift and propagates a failed test exit code. The full Python suite passed **112 tests** in **1.253 seconds**.

The final component/native/WebKit run passed **55 tests** in **53.842 seconds** (`/tmp/remotedesktop-local-text-component-final-v2.log`). The shared runtime/installation/planner/task selection passed exactly **89 methods** in **7.891 seconds**, checked against source IDs and `/tmp/remotedesktop-local-planner-runtime.xunit.xml`. The signed host subsequently passed exactly **119 reviewed methods** in **2.795 test seconds** (2.847 seconds including suite overhead), with no skips, failures, or substituted IDs. Evidence: `/tmp/remotedesktop-signed-local-text-planner.xcresult`, `/tmp/remotedesktop-signed-local-text-planner.log`, and `/tmp/remotedesktop-signed-local-text-inventory.json`. These signed tests validate components and runtime contracts; they do not substitute for the failing expanded actual-model fixture suite or the full OCR-dependent gate.

```sh
COMPUTER_USE_TEST_BUILD_PATH=/tmp/remotedesktop-text-tests \
python3 host-mac/scripts/run_native_text_model_acceptance.py \
  --model-path /tmp/remotedesktop-qwen35-comparison/Qwen3.5-4B-Q4_K_M.gguf \
  --server-binary /Applications/RemoteDesktopHost.app/Contents/Resources/ComputerUseRuntime/llama-b9992/llama-server \
  --report /tmp/remotedesktop-native-model-new-run.json
```

Use a fresh report path for each run. `--faults-only` runs only the six interruption/recovery scenarios per fixture and cannot qualify the ten non-fault regression goals. The controlled form capability remains a candidate: these fixtures do not establish application-wide task interpretation, browser ownership, document generations, low-memory behavior, production installation, or mobile transport readiness.

## Next contract: frozen evaluation boundary

The 20-case [held-out v3 corpus](../../../host-mac/AcceptanceFixtures/native-text-goals-heldout-v3.json) is frozen before implementing contract v2, at source checkpoint `d918784`. SHA-256: `d3fd472a1b82e6f9f03cdee054a27bc2a29c535a877af18a0b5d552e73c3eafb`. It is **unrun**. This is another self-authored capability test set, not an external representative benchmark.

The next revision addresses two contract defects rather than increasing inference budget: internal focus/selection/readback steps must be distinguished from additional user-requested outcomes, and a quoted field name must remain resolvable after the host replaces quoted spans with exact-payload references. Neither issue justifies enabling the current candidate or changing a failed expected outcome. The frozen v1 instruction and results remain available for comparison.

## Contract v2 candidate, before held-out evaluation

The optional v2 contract describes the text capability's internal mechanics separately from the requested outcomes. It also adds `literalFieldMatches`: host-computed matches between captured quoted spans and field labels already present in the observation. A quoted target such as `"Destination"` can therefore resolve to its field ID. When the same quoted string supplies a value, it still resolves to the original exact payload; it does not authorize reading or copying an existing field. Duplicate label matches remain ambiguous. Unmatched payload contents and all existing values remain outside the model request. The frozen v1 contract remains unchanged and selectable.

This revision passed **all six real-model fault scenarios in both fixtures**: two XCTest methods, 101.650 seconds total (WebKit 50.999; AppKit 50.651). N12 now executes both edits, and the executor refuses completion after the first field is changed. Append/resume, cancellation during inference and Unicode input, partial-delivery reconciliation, and stale-target rejection also pass. Evidence: [v2 fault results](native-text-v2-fault-results.json), `/tmp/remotedesktop-native-model-v2-contract-faults.xunit.xml`, and its matching log. This replaces the failed v1 outcome for that candidate; the earlier failure remains recorded.

The Swift adapter also passed **14/14 known proposal regressions** in 139.812 seconds, median 10.587 seconds. These comprise the ten non-fault v1 cases, the known N12 failure, and three explicit quoted-target/value-role cases. No desktop effect adapter is present in this separate test. The host computes the proposed final values with the real task-contract implementation and compares exact UTF-8 against the fixture; the output records disposition, field IDs, edit modes, payload lengths and durations, not payload contents or reasoning text. Results: [v2 regression results](native-text-v2-regression-results.json).

Twelve signed wire tests passed in 0.332 seconds and were checked by exact ID against `/tmp/remotedesktop-signed-text-v2-wire.xcresult` using `/tmp/remotedesktop-signed-text-v2-wire-inventory.json`. The SwiftPM follow-up also passed all 12 after adding the proposal driver (0.327 seconds). The latest Python run passed 112 checks in 1.330 seconds. The new proposal driver rejects missing/duplicate result IDs, distinguishes its scope from live fixtures, and writes results after each case so an early failure cannot conceal unrun cases.

The [v2 candidate manifest](native-text-planner-candidate-v2.json) freezes the source dependencies, test driver, runner, exact configuration, model/runtime hashes and held-out v3 hash before its first run. The 2,517-byte instruction has SHA-256 `f2c43600e2302139c363d0d210d6e2d2fdf12a76abaaa4b52327bc59bb06666b`. The model and inference budget remain the same; the rejected doubled-budget experiment was not adopted. The 20-case holdout is still **unrun** at this freeze, and the candidate is still disconnected from normal app execution.

For proposal-only evaluation, add `--contract candidate-v2 --proposal-corpus host-mac/AcceptanceFixtures/native-text-goals-regression-v2.json` to the local runner command above and use a new report path. Omit `--proposal-corpus` to run the real fixtures; `--faults-only` selects their six fault scenarios. These are separate scopes and cannot be combined into a single accuracy denominator.

## Contract v2: first holdout and complete actual-model fixtures

Candidate commit **`a4a01b9`** preceded the first held-out v3 run. All frozen dependency hashes and the corpus hash matched before and after that run. **20/20 cases passed**: 14 supported edit plans, three unsupported outcomes and three clarification outcomes. Total proposal time was 200.796 seconds, median 10.307 and maximum 11.381. The test used the actual Swift adapter and exact host-computed final values, without desktop effects. See [first held-out v3 results](native-text-v2-heldout-v3-results.json). The earlier “unrun” statements describe the historical freeze, not current status.

The same unchanged planner then passed the **complete 32-scenario AppKit/WebKit run**: ten regression goals and six interruption/recovery scenarios per fixture, checked by two exact XCTest method IDs with no skipped or missing methods. Wrapper elapsed time was 320.293 seconds including startup/build overhead. Each effect was checked against the fixture's independent state. See [complete v2 fixture results](native-text-v2-complete-results.json), `/tmp/remotedesktop-native-text-v2-complete.xunit.xml`, and its matching log. The report records the source hash, configuration, scenario count and raw-evidence hashes.

These are bounded, self-authored form tests on one 32 GiB Mac, not universal task reliability or a release gate. The application still needs production model installation, runtime ownership, capability readiness and normal executor composition; the full OCR-dependent gate and mobile-to-Mac qualification remain open. No installed application or release artifact was replaced by these tests.

## Text planning through the production runtime owner

The existing `OSAtlasLlamaRuntime` now accepts a separate native-text input type. It stops and awaits the current process before switching between text and visual models, preserves endpoint-generation checks and holds one model lease across tokenization, inference and strict decoding. Text endpoints have no OS-Atlas variant and reject visual requests. `ComputerUseRuntimeTextGoalPlanner` supplies the frozen v2 planner through that owner. The text launch uses the measured 4K/512-reasoning-token configuration, no projector, one process, and a private credential file verified immediately before launch and removed after shutdown. The compact memory ceiling is a resource policy, not evidence of physical 8 GiB qualification.

All **70 runtime/planner tests passed** in SwiftPM (6.420 test seconds) and in the signed host (1.251 test seconds). Exact-ID verification used `/tmp/remotedesktop-native-owner-inventory.json` against `/tmp/remotedesktop-native-owner-unit-v3.xunit.xml` and `/tmp/remotedesktop-signed-native-owner.xcresult`. The initial new tests expected an exit-finished fixture event that the simple fake process did not emit; adding that event and updating the two existing exact event sequences resolved those fixture failures. Earlier failed outputs remain in `/tmp/remotedesktop-native-owner-unit*.log`. The reviewed source manifest includes all six new methods; both selectors and expected IDs were checked. Python checks: **112 passed**, 1.361 seconds.

The actual runtime owner then passed **14/14 known proposal regressions**, 144.623 proposal seconds and 148.204 seconds including wrapper overhead. It launched the verified local Qwen GGUF itself, performed local inference, and awaited shutdown; no llama-server process remained after the run. See [owned runtime results](native-text-owned-runtime-results.json) and `/tmp/remotedesktop-native-owned-runtime-regression.log`. This is a regression run through the production process code, not a fresh holdout or desktop-effect test. Use `--runtime-owner --contract candidate-v2 --proposal-corpus ...` to select this scope; the runner rejects incompatible scope/contract combinations.

The planner source and prompt remain unchanged from the first successful v2 holdout. Normal app composition and independent model installation/readiness are still open, so the installed app has not yet gained the new form capability.
