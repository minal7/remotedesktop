# Computer Use (Beta): investor metrics

**DRAFT - incomplete baseline; release and demo gates pending**

Evidence snapshot: October 19, 2026 PT / October 20, 2026 UTC. This is not a final investor-ready scorecard or a claim that release gates are complete.

## Current evidence

The signed S2 baseline (host SHA [`2bced38eab2cfa4852566471bc5cde2d63a6801019dd24f419252a8c80ab59a3`](../../build/eval/reports/s2-native-baseline-20261017T004500Z/host_provenance.json)) is incomplete. It has **7 observed native tasks: 0 strict passes, 4 fails, and 3 blocked**, plus a Notes task with no first observation. The latest Notes resume also stopped before observation; the seven evaluated rows did not change. ([results](../../build/eval/reports/s2-native-baseline-20261017T004500Z/results.json), [checkpoint](../../build/eval/reports/s2-native-baseline-20261017T004500Z/checkpoint.json))

Across those observed rows, the median was **14 steps**, median model-call latency **13.77 s**, median end-to-end step latency **15.01 s**, median task wall time **226.3 s**, and peak worker memory **1.47 GiB**. ([results](../../build/eval/reports/s2-native-baseline-20261017T004500Z/results.json), [worker footprint](../../build/eval/reports/s2-native-baseline-20261017T004500Z/footprint.jsonl))

Recorded unsafe actions were **0 across the 7 evaluated rows**. Separately, one native-002 local-input interruption lasted **15 steps** and recorded unsafe count **0**. The interruption log contains **12 abandoned-after-runner-stop attempts** without attempt-level safety measurements. One native-008 attempt remains inflight in the checkpoint with no first observation or safety measurement. These unmeasured attempts are not included in the zero-unsafe claim. ([interrupted attempts](../../build/eval/reports/s2-native-baseline-20261017T004500Z/interrupted_attempts.json), [checkpoint](../../build/eval/reports/s2-native-baseline-20261017T004500Z/checkpoint.json))

## Readiness

The Swift suite passed **1,118 tests, 0 failures, and 30 unchanged opt-in skips**. The evaluation Python suite passed **113 tests, 0 failures**. The combined Debug candidate (source `8be5f6f`, executable SHA `067e637b6753a70c383c983e0b1e86d692c6f71d69a49e405e58549424d69664`) is staged only, not installed. The installed S2 baseline SHA remains unchanged. ([Swift acceptance](../../build/eval/report-prep/s3-full-swift-20261020T015243.920828Z/acceptance.json), [Python test log](../../build/eval/report-prep/d1-demo-checkers-20261019T192957-0700.log), [staging receipt](../../build/eval/report-prep/s3-full-swift-20261020T015243.920828Z/debug-installer-staging-receipt.json), [baseline provenance](../../build/eval/reports/s2-native-baseline-20261017T004500Z/host_provenance.json))

The Mac **0.3.0 (1)** Release package is notarized, stapled, and accepted by Gatekeeper, but remains unpublished and uninstalled. Its source is `9f82815`. All **13** corresponding Mach-O files matched after signature removal on temporary copies. iOS **1.2 (1)** remains an Apple Development archive, not distribution-exported or uploaded; it was installed on the physical test iPhone and its **1.2 (1)** version/build was independently confirmed. TestFlight upload and the physical-device checklist remain pending. ([notarized package and verification](../../build/eval/report-prep/mac-release-20261020T020341Z/notarized-package.json), [distribution ZIP](../../build/eval/report-prep/mac-release-20261020T020341Z/RemoteDesktopHost-macOS-0.3.0.zip), [Mach-O comparison](../../build/eval/report-prep/mac-release-20261020T020341Z/mach-o-signature-comparison.json), [iOS archive provenance](../../build/eval/report-prep/ios-release-1.2.1/archive-provenance.json), [physical iPhone installation](../../build/eval/report-prep/ios-release-1.2.1/physical-iphone-install-20261020.json), [installed app version/build](../../build/eval/report-prep/ios-release-1.2.1/physical-iphone-version-20261020.json))

Eight demo prompts are defined and their task/checker contracts are tested; this does not establish task success. Six require independent review and cannot auto-pass. TextEdit checks exact saved-file content; the fixture cannot auto-commit, and physical-phone approval evidence is pending. No demo rehearsals or results are available. Both Smoke-20 runs, Safety-15, and the **8 tasks x 5 rehearsals** remain pending. ([D1 validation log](../../build/eval/report-prep/d1-demo-checkers-20261019T192957-0700.log), [demo plan](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/investor-demo-plan.md>))

## Product and privacy

Computer Use is **Beta** and uses the local **Fara 1.5-4B** model on an Apple silicon Mac with at least **16 GB** memory. Inference runs on the Mac. Prompts, results, controls, and approvals travel between the phone and Mac over authenticated LAN TLS; screen sharing and remote input use WebRTC. Local inference does not mean zero network transmission. ([model manifest](../../host-mac/RemoteDesktopHost/ComputerUse/ComputerUseArtifactManifest.swift), [product overview](../../README.md), [privacy details](../privacy.html))

Distillation from recorded episodes, away mode, and extensions are future directions, not shipped capabilities. ([plan](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/investor-demo-plan.md>))
