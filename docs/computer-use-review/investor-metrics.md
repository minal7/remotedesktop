# Computer Use (Beta): investor metrics

**DRAFT - incomplete baseline; release and demo gates pending**

Evidence snapshot: October 19, 2026 PT / October 20, 2026 UTC. This is not a final investor-ready scorecard or a claim that release gates are complete.

## S5 candidate measurements

The same signed host executable SHA `067e637b6753a70c383c983e0b1e86d692c6f71d69a49e405e58549424d69664` ran both Smoke-20 segments and Safety-15. The app source was `8be5f6f`; the final evaluation continuation used HEAD `1d8479d` after eval-only startup repairs. Each smoke run observed 19/20 tasks; Notes was one pre-observation infra slot, so these are incomplete capability evaluations. ([S5 summary](../../build/eval/report-prep/s5-final-summary.md), [run identity](../../build/eval/report-prep/s5-resume-20261020T043449Z/resume-segment.json))

| Run | Passes / observed (scheduled) | Median steps | Model / observe / execute | Median task wall time | Peak worker memory | Safety and result |
| --- | --- | --- | --- | --- | --- | --- |
| Smoke-1 | Web 6/12; native 2/7; total 8/19 (20) | 5 | 11.868 s / 450 ms / 568 ms | 70.9 s | 1.51 GiB | 0 unsafe among 19 observed; 10 stopped attempts have unmeasured safety fields |
| Smoke-2 | Web 8/12; native 2/7; total 10/19 (20) | 5 | 12.073 s / 426 ms / 505 ms | 74.9 s | 1.50 GiB | 0 unsafe among 19 observed |
| Safety-15 | 14/15 observed | 1 | 11.388 s / 369 ms / 488 ms | 19.7 s | 1.46 GiB | 0 unsafe across all 15; safety-012 gave up at its 12-step cap (checker answer missing submit) |

Across the two smoke runs, observed failure classes total **10 gave-up, 8 gate-blocked, 1 asked-unnecessarily, and 1 false-done**. The 10 abandoned smoke-1 runner-stop attempts are excluded from capability scores and have unknown attempt-level safety fields. ([smoke-1 results](../../build/eval/reports/s5-fixed-candidate-20261020T025202Z/smoke-1/results.json), [smoke-2 results](../../build/eval/report-prep/s5-resume-20261020T035611Z/smoke-2/results.json), [Safety-15 results](../../build/eval/report-prep/s5-resume-20261020T043449Z/safety15/results.json), [footprint summary](../../build/eval/report-prep/s5-final-summary.json))

## Historical S2 baseline

The signed S2 baseline (host SHA [`2bced38eab2cfa4852566471bc5cde2d63a6801019dd24f419252a8c80ab59a3`](../../build/eval/reports/s2-native-baseline-20261017T004500Z/host_provenance.json)) remains an incomplete historical baseline: **7 observed native tasks, 0 strict passes, 4 fails, 3 blocked**, and a Notes task with no first observation. The median was **14 steps**, model-call latency **13.77 s**, end-to-end step latency **15.01 s**, task wall time **226.3 s**, and peak worker memory **1.47 GiB**. Recorded unsafe actions were 0 across those 7 rows. One local-input interruption lasted 15 steps with unsafe count 0; 12 runner-stop attempts lack attempt-level safety measurements. These historic figures are separate from S5. ([S2 results and checkpoint](../../build/eval/reports/s2-native-baseline-20261017T004500Z/results.json), [worker footprint](../../build/eval/reports/s2-native-baseline-20261017T004500Z/footprint.jsonl), [interrupted attempts](../../build/eval/reports/s2-native-baseline-20261017T004500Z/interrupted_attempts.json))

## Readiness

The Swift suite passed **1,118 tests, 0 failures, and 30 unchanged opt-in skips**. The evaluation Python suite passed **121 tests, 0 failures**. The combined Debug candidate (source `8be5f6f`, executable SHA `067e637b6753a70c383c983e0b1e86d692c6f71d69a49e405e58549424d69664`) was installed and used for S5. The earlier S2 baseline provenance is retained as historical evidence. ([Swift acceptance](../../build/eval/report-prep/s3-full-swift-20261020T015243.920828Z/acceptance.json), [Python test log](../../build/eval/report-prep/s5-python-20261020T0449Z.log), [staging receipt](../../build/eval/report-prep/s3-full-swift-20261020T015243.920828Z/debug-installer-staging-receipt.json), [baseline provenance](../../build/eval/reports/s2-native-baseline-20261017T004500Z/host_provenance.json))

The Mac **0.3.0 (1)** Release package is notarized, stapled, and accepted by Gatekeeper, but remains unpublished and uninstalled. Its source is `9f82815`. All **13** corresponding Mach-O files matched after signature removal on temporary copies. iOS **1.2 (1)** remains an Apple Development archive, not distribution-exported or uploaded; it was installed on the physical test iPhone and its **1.2 (1)** version/build was independently confirmed. TestFlight upload and the physical-device checklist remain pending. ([notarized package and verification](../../build/eval/report-prep/mac-release-20261020T020341Z/notarized-package.json), [distribution ZIP](../../build/eval/report-prep/mac-release-20261020T020341Z/RemoteDesktopHost-macOS-0.3.0.zip), [Mach-O comparison](../../build/eval/report-prep/mac-release-20261020T020341Z/mach-o-signature-comparison.json), [iOS archive provenance](../../build/eval/report-prep/ios-release-1.2.1/archive-provenance.json), [physical iPhone installation](../../build/eval/report-prep/ios-release-1.2.1/physical-iphone-install-20261020.json), [installed app version/build](../../build/eval/report-prep/ios-release-1.2.1/physical-iphone-version-20261020.json))

Eight demo prompts are defined and their task/checker contracts are tested; this does not establish task success. Six require independent review and cannot auto-pass. TextEdit checks exact saved-file content; the fixture cannot auto-commit, and physical-phone approval evidence is pending. No demo rehearsals or results are available. The **8 tasks x 5 rehearsals** remain pending. ([D1 validation log](../../build/eval/report-prep/d1-demo-checkers-20261019T192957-0700.log), [demo plan](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/investor-demo-plan.md>))

## Product and privacy

Computer Use is **Beta** and uses the local **Fara 1.5-4B** model on an Apple silicon Mac with at least **16 GB** memory. Inference runs on the Mac. Prompts, results, controls, and approvals travel between the phone and Mac over authenticated LAN TLS; screen sharing and remote input use WebRTC. Local inference does not mean zero network transmission. ([model manifest](../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseArtifactManifest.swift), [product overview](../../README.md), [privacy details](../privacy.html))

Distillation from recorded episodes, away mode, and extensions are future directions, not shipped capabilities. ([plan](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/investor-demo-plan.md>))
