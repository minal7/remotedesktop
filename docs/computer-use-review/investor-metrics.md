# Computer Use (Beta): investor metrics

**DRAFT — B2 measurements are incomplete; release, physical-device, and full demo gates remain open.**

Evidence snapshot: October 20, 2026. These results describe a signed Debug candidate, not a Release build or a completed release evaluation.

## Current B2 Debug measurements

B2 source HEAD is `e9996b22f65d626b5af7e8240149d5a5b93dbbed` (evaluation tree `57e86f058e0187dc6ec9edcaad1b2e9a4455fbc1`), signed Debug executable SHA `0420ff3edae8f8de21b9b333edc510dad3497a362da554622121c7b4be9eeaec`. The candidate includes a generic web Enter/Return approval guard. Full Swift verification passed **1,123 tests, 0 failures, 30 unchanged opt-in skips**; the focused gate tests passed 15/15. The product Agent source is 6,702 lines. ([B2 combined run summary](../../build/eval/report-prep/b2-validation-20261020T085211Z-combined-summary.md), [source and binary receipts](../../build/eval/report-prep/b2-validation-20261020T085211Z-combined-summary.json), [full Swift acceptance](../../build/eval/report-prep/s3-full-swift-20261020T084535.288181Z/acceptance.json), [focused gate receipt](../../build/eval/report-prep/b2-implicit-web-enter/focused-test-receipt.json))

| Measurement | Result | Scope |
| --- | --- | --- |
| B2 smoke | **10 strict passes / 18 observed; 19 selected / 20 catalog**. Web 8/12; native 2/6 observed, with 7 selected and 8 catalog. Median **5 steps**; model **11.2765 s (124 calls)**, observation **421.5 ms**, positive execution **493 ms**. | Incomplete: native-007 remains pre-observation infrastructure-blocked; native-008 was withheld with no attempt. |
| B2 Safety-15 | **10 PASS, 2 FAIL, 3 BLOCKED / 15 observed**; **0 unsafe actions / 15**; 3 approval requests, 0 grants. Median **1 step**; model **10.3855 s (30 calls)**, observation **644.5 ms**, positive execution **489.5 ms**. | Terminal for these 15 tasks. One abandoned pre-observation safety attempt has unknown safety. |
| Memory | Maximum sampled current footprint **1,593,430,072 bytes**; maximum worker-reported peak **1,593,561,144 bytes** across 366 valid samples. | B2 smoke and Safety samplers. |

Across the two stages, **20 PASS / 33 observed rows**; these are not a complete smoke or release evaluation. For reference, pooled medians were 11.246 s completed model call (154 calls), 421.5 ms observation (154 samples), 491.5 ms positive execution (126 samples), and 3 median steps (33 rows). See the [combined summary and raw metric records](../../build/eval/report-prep/b2-validation-20261020T085211Z-combined-summary.json).
There are **three unknown-safety pre-observation attempts outside the observed denominator**: two native-007 attempts and one abandoned safety-001 attempt. The withheld native-008 task had no attempt. These are not counted as safe or unsafe. ([smoke and Safety summaries](../../build/eval/report-prep/b2-validation-20261020T085211Z-combined-summary.json), [raw smoke results](../../build/eval/reports/b2-validation-20261020T085211Z/), [independent Safety receipt](../../build/eval/report-prep/b2-independent-safety-20261020T092844Z/independent-safety-receipt.json))

The newer candidate has not completed a Release physical-device checklist. The same-source Mac 0.3.0 (1) package from `e9996b2` passed G7 structure, strict signature, stapler, Gatekeeper, Release trust, notarization, and 13-file Mach-O equivalence. Notarized app SHA `dc8f8b39770f633c694c4e2b94b10dcf2439ade11d1953e49c4fd13ab52d1bbe`; ZIP SHA `01104546382479849c4501839e40d9d20450798d30034267422a44a310d16629`. It remains unpublished and is installed with the expected executable identity. The current GUI remains at Setup Step 1 with Screen Recording required; Check Again left the state unchanged. No physical task run or LAN-readiness claim is made. The prior notarized package from source `a85738b` predates B1 and B2 and is historical. ([notarized package](../../build/eval/report-prep/mac-release-20261020T093832Z/notarized-package.json), [Mach-O signature comparison receipt](../../build/eval/report-prep/mac-release-20261020T093832Z/notarized-package.json), [ZIP](../../build/eval/report-prep/mac-release-20261020T093832Z/RemoteDesktopHost-macOS-0.3.0.zip), [installed identity](../../build/eval/report-prep/mac-release-20261020T093832Z/installed-release-receipt.json), [GUI readiness](../../build/eval/report-prep/mac-release-20261020T093832Z/gui-readiness.json)) iOS 1.2 (1) remains a Development install, not TestFlight. ([prior notarized package provenance](../../build/eval/report-prep/mac-release-20261020T053706Z/notarized-package.json), [iOS installation record](../../build/eval/report-prep/ios-release-1.2.1/physical-iphone-install-20261020.json))

## Earlier safety and smoke evidence

| Candidate | Result | Interpretation |
| --- | --- | --- |
| B1 Debug, source `ab5f547`, executable SHA `f6a314384ff5f0154c00b86b134379f3e1bc6619f9e532b104a65bba83ec1258` | 10/19 smoke passes; 1 unsafe action; 5 requests, 0 grants. Four pre-observation Notes attempts had unknown safety. | Historical failure; B2 adds approval gating for ambiguous web Enter/Return. The B1 record remains unchanged. |
| S6 Debug, source `16c93bc` | 11/19 smoke passes; 0 unsafe observed; separate Safety-15: 12 PASS, 1 FAIL, 2 BLOCKED; 0 unsafe. | One historical measurement; not evidence for B2 or Release. |
| S5 Debug, executable SHA `067e637b6753a70c383c983e0b1e86d692c6f71d69a49e405e58549424d69664` | Smoke runs 8/19 and 10/19; Safety-15 14/15; observed unsafe 0. | Historical comparison; Notes was unobserved in both smoke runs. |
| S2 native baseline | 0 strict passes among 7 observed; 4 FAIL, 3 BLOCKED; Notes had no first observation. | Earlier incomplete baseline, retained for context. |

B1 through B2 results are not interchangeable release tests: each used a distinct candidate or campaign. ([B1 independent summary](../../build/eval/report-prep/b1-smoke20-20261020T080335Z-independent/summary.json), [S6 summary](../../build/eval/report-prep/s6-final-summary.json), [S5 summary](../../build/eval/report-prep/s5-final-summary.json), [S2 results](../../build/eval/reports/s2-native-baseline-20261017T004500Z/results.json))

## D2 selected demo campaign

D2 completed **25 of 25 selected attempts** from a **40-attempt** catalog. Evidence review and automatic checkers found **20 pass, 3 fail, and 2 incomplete**; raw runner rows remain separate. The selected five tasks were Wikipedia 3/5, Google Flights 3/5 (two incomplete handoffs), Apple 5/5, TextEdit 5/5, and Finder 4/5. Only **3 of 5 selected tasks** met 4/5, below G4's requirement of at least 6/8 catalog tasks. Fifteen catalog attempts were withheld, including Gmail, Notes, and physical-approval tasks. This was a signed Debug evaluation, not a Release or physical-device test. D2 worker memory was not measured. ([D2 final reviewed summary](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json), [D2 terminal receipt](../../build/eval/report-prep/d2-terminal-receipt-20261020.json))

| Selected task | Evidence-reviewed or checked outcome | Median steps | Median wall time | Completed model-call median |
| --- | --- | ---: | ---: | ---: |
| Wikipedia | 3 pass, 2 fail | 2 | 26.9 s | 12.338 s (8 calls) |
| Google Flights | 3 pass, 2 incomplete | 9 | 146.4 s | 14.097 s (39 calls) |
| Apple | 5 pass | 4 | 64.5 s | 13.107 s (22 calls) |
| TextEdit | 5 pass | 10 | 116.3 s | 10.369 s (50 calls) |
| Finder | 4 pass, 1 fail | 8 | 93.9 s | 10.395 s (51 calls) |

## Product and readiness

Computer Use is a **Beta** using local **Fara 1.5-4B** inference. The measured test Mac had an Apple M2 Max with **32 GiB** memory; **16 GB** is the product minimum. Inference runs locally on the Mac, while prompts, results, controls, and approvals travel between phone and Mac over authenticated LAN TLS; screen sharing and remote input use WebRTC. Local inference does not mean zero network transmission. ([test hardware record](../../build/eval/report-prep/test-mac-hardware-20261020.json), [model manifest](../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseArtifactManifest.swift), [privacy details](../privacy.html))

The full 20-task smoke, native-008 Notes setup, 8-task rehearsal target, physical Release checklist, TestFlight distribution, filming, and publication remain pending. D2's selected subset and B2's observed rows do not meet those gates. Distillation, away mode, and extensions remain future directions, not shipped capabilities. ([B2 combined summary](../../build/eval/report-prep/b2-validation-20261020T085211Z-combined-summary.md), [D2 final reviewed summary](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json))
