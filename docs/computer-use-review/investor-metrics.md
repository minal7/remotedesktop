# Computer Use (Beta): investor metrics

**DRAFT — B7 Smoke-20 stopped incomplete.** Nineteen of 20 scheduled tasks produced completed observations; native-008 remains pending after pre-observation setup failures. This is not a completed Smoke-20 or a ship-gate pass. B7 Safety-15 has not been measured. The installed Mac app is signed Debug B7, not Release.

Evidence snapshot: October 20, 2026. The owner authorizes current/default accounts; no isolated-account requirement applies. Preserve unrelated content. Only task-owned test items may be created or checked.

## Current B7 candidate

B7 product change `04c3117fc9ac4f4bee824718dc0b9eeb7e1cc056`; source HEAD `50226d440d77bb0be3402ce8334939275583700b`; installed signed Debug executable SHA-256 `3b8c46af27fa3ea94dc4bae3dc44bc4f27f0b7e238e8ec19a6054d08d8cfc8af`. The reconciled snapshot reports 19 completed observations from 20 scheduled tasks, with native-008 still inflight and no cleanup pending. The full Swift suite passed 1,129 tests with 0 failures and 30 unchanged opt-in skips; source checks report 6,703 Agent lines. [B7 Debug installation](../../build/eval/report-prep/b7-install/20261020T210627Z/receipt.json), [reconciled first-measurement summary](../../build/eval/report-prep/b7-run/first-measurement-summary.json), [full Swift acceptance](../../build/eval/report-prep/b7-full-swift/20261020T201913Z/receipt.json), [source checks and Agent line count](../../build/eval/report-prep/b7-full-swift/20261020T201913Z/source-checks.json).

| Scope | Observed result | Measurement limits |
| --- | --- | --- |
| Web smoke | 8 PASS, 2 FAIL, 2 BLOCKED / 12 observed of 12 scheduled; median 4 steps; median model call 13.003 s. | Completed observations only. |
| Native smoke | 3 PASS, 4 FAIL / 7 observed of 8 scheduled; median 14 steps; median model call 10.6505 s. | Native-008 has no observation; setup failed before first observation. |
| Combined smoke | 11 PASS, 6 FAIL, 2 BLOCKED / 19 observed of 20 scheduled; median 7 steps; pooled median model call 11.719 s. | Runner stopped incomplete; do not describe as a completed 20-task evaluation. |
| Safety | Not measured on B7. | No Safety-15 result is available. |
| Worker memory | 378 footprint samples across 3 segments; maximum reported worker peak 1,639,583,848 bytes (1.64 GB). | Peak is the largest reported worker value, not a device-wide memory claim. |

Among the 19 completed observations, unsafe-action count was recorded as zero (known coverage 19/19). The history separately contains 8 abandoned attempt records with unknown safety; native-008 is an additional unfinished scheduled task with no first observation, not another abandoned-attempt record. Its four pre-observation setup blockers report Notes selection failure `Must select at least one note (-10000)`; the setup path is being repaired separately, with no product change claimed here. These infrastructure events are separate from the 19 completed-row outcomes.

The 19 observed rows recorded 2 approval requests and 0 grants. The raw task outcome classes are 11 PASS, 6 FAIL (`gave-up`), and 2 BLOCKED (`gate-blocked` pending approval). Eight invalid action proposals were rejected: unsupported pointer movement (4), malformed computer-use action (2), unavailable memory action (1), and unsupported key/modifier combination (1). These gate rejections are not additional task failures. The summary records 12 infrastructure-blocker events overall: 8 earlier blockers resolved during recovery and 4 unresolved Native-008 Notes-selection setup blockers. [Reconciled B7 snapshot](../../build/eval/report-prep/b7-run/first-measurement-summary.json), [B7 segment receipts and raw evidence](../../build/eval/report-prep/b7-run/).

| Gate | Current evidence | Status |
| --- | --- | --- |
| G1 smoke | B7: 19 observed / 20 scheduled; native-008 has no observation after setup blockers. | Incomplete |
| G2 Safety-15 | No B7 Safety measurement. | Pending |
| G4 demo rehearsals | D2 selected 5-task subset: only 3/5 tasks reached ≥4/5; full goal is 8/8 and ship threshold is ≥6/8. | Open |
| G7/G8 packaging | Earlier B6-source Mac Release package passed packaging checks; it is not the B7 source. | B7 Release pending |
| D4 physical checks | iOS 1.2 (1) archive installed on iPad; no physical checklist action run. Current Mac host is B7 Debug. | Pending |

## Historical candidate measurements

These runs used different source or campaign identities and are not interchangeable with B7.

| Candidate | Observed result | Important limits and evidence |
| --- | --- | --- |
| B1 Debug | 10/19 smoke passes; 1 unsafe action. Four pre-observation Notes attempts have unknown safety. | Retain the unsafe result and unknown attempts; do not relabel the fixture submission. [Independent summary](../../build/eval/report-prep/b1-smoke20-20261020T080335Z-independent/summary.json), [stop receipt](../../build/eval/report-prep/b1-smoke20-20261020T080335Z/operator-stop-receipt.json) |
| B2 Debug | 10/18 observed smoke passes; Safety-15: 10 PASS, 2 FAIL, 3 BLOCKED, 0 recorded unsafe/15. | Smoke was incomplete; one abandoned Safety pre-observation attempt had unknown safety. [Combined summary](../../build/eval/report-prep/b2-validation-20261020T085211Z-combined-summary.json) |
| B6 Debug | Smoke: 5 PASS, 2 FAIL, 2 BLOCKED / 9 terminal rows from 19 selected of 20; web-043 was interrupted after two wrong-target bookmark clicks and its effects are unknown. | Nine selected tasks were unattempted; native-008 was withheld. [Smoke rows](../../build/eval/reports/b6-campaign-20261020T192814Z/smoke20/results.json), [stop receipt](../../build/eval/report-prep/b6-campaign-20261020T192814Z/root-stop-receipt.json) |
| B6 Safety-15 | 9 PASS, 5 BLOCKED, 1 FAIL / 15; 0 recorded unsafe/15. | Environment-contaminated: an action exposed the sidebar and later output referred to unrelated bookmark content. A separate zero-observation Safety startup attempt has unknown safety. Do not use the recorded zero as clean G2 evidence. [Reviewed Safety summary](../../build/eval/report-prep/b6-terminal-review/summary-reviewed.json), [excluded startup attempt](../../build/eval/report-prep/b6-safety-clean-start/unplanned-attempt-preservation.json) |

B6 used signed Debug executable `ebd61780a1617c5a4a45c6fd46d70e67cc42bc5797d51937e40c1a74a973901d`; its B6-source notarized package is historical relative to B7. Earlier S5/S6 and S2 native results also remain historical and incomplete: [S5](../../build/eval/report-prep/s5-final-summary.md), [S6 smoke](../../build/eval/report-prep/s6-final-summary.json), [S6 Safety](../../build/eval/report-prep/s6-safety-final-summary.json), [S2 native results](../../build/eval/reports/s2-native-baseline-20261017T004500Z/results.json).

## D2 selected demo campaign

D2 completed 25/25 selected attempts from a 40-attempt catalog: 20 pass, 3 fail, 2 incomplete. The selected five tasks were Wikipedia 3/5, Google Flights 3/5 (two incomplete handoffs), Apple 5/5, TextEdit 5/5, and Finder 4/5. Only 3/5 selected tasks met ≥4/5, below the G4 threshold of 6/8 catalog tasks. Fifteen catalog attempts were withheld. This was a signed Debug evaluation, not Release or physical-device evidence; D2 worker memory was not measured. [Reviewed D2 summary](../../build/eval/report-prep/d2-final-reviewed-summary-20261020.json), [terminal receipt](../../build/eval/report-prep/d2-terminal-receipt-20261020.json).

## Device, privacy, and measurement notes

The iOS 1.2 (1) Release-configuration archive was installed to the physical iPad from [RemoteDesktop.xcarchive](../../build/eval/report-prep/ios-release-1.2.1-privacy-20261020T113336Z/RemoteDesktop.xcarchive). Its installation receipt reports executable SHA-256 `99e30c2f28572cdc3535f2674baca47de31599d1a00882869c3d1d658fadc7d6`, `launch_requested: false`, `physical_checks_completed: false`, and `testflight: false`; installed version/build match 1.2/1. No physical task or TestFlight processing is claimed. [iPad installation receipt](../../build/eval/report-prep/b7-run/ipad-install-20261020T212627Z/receipt.json), [readiness record](../../build/eval/report-prep/b7-run/ipad-readiness.json).

Computer Use is a Beta using local Fara 1.5-4B inference. The measured test Mac is Apple M2 Max with 32 GiB RAM; 16 GB is the product minimum, not the measured machine. Local model inference does not mean zero network transmission: prompts, results, controls, and approvals travel between phone and Mac over authenticated LAN TLS, while screen sharing and remote input use WebRTC. [Hardware record](../../build/eval/report-prep/test-mac-hardware-20261020.json), [model manifest](../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseArtifactManifest.swift), [privacy details](../privacy.html).

B7 smoke remains incomplete and B7 Safety is unmeasured. Do not infer a completed 20-task smoke result or any Safety pass from these observations. Physical Release checks, TestFlight distribution, filming, and publication remain pending.
