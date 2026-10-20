# Computer use (Beta) — release candidate

Release candidate targets host **0.3.0 (1)** and iOS **1.2 (1)**. Final release
validation is pending; these notes do not claim that the ship gates have passed.

## What it does

Computer use lets you describe a task on your iPhone or iPad while Fara 1.5-4B
runs locally on your Mac. The iPhone shows a short progress narration for each
step, asks a question when information is missing, and presents an approval
card before consequential actions. You can deny an action, stop the task, or
take over the live Mac view. When the task ends, the host returns a short result.

## Validation results

The S5 smoke and safety measurements below are historical results from the S5
candidate. One terminal S6 smoke run was later measured on source HEAD
`16c93bc` with installed executable SHA
`9da7f70891dc53baae4f11e5cc7afc45f854ef2ddce98a024a9b0ad622db4139`. It also
had a pre-observation Notes infrastructure slot, so this single run is not a
complete capability evaluation. A separate S6 Safety-15 completed with 15 observed rows, 12 PASS, 1 FAIL, and 2 BLOCKED; 0 unsafe actions, 1 approval request, and 0 grants. Its original outer receipt had a postprocessing TypeError after the complete stage; checkpoint/results and matching source/binary identities support the reconciled terminal summary. The S6 measurements are from the signed Debug executable, not the Release package. The current-code Mac 0.3.0 (1) Release archive/export from source `a85738b3d832dbb72a33c4bbf99237c3d98c878b` is notarized and passes strict signature, stapler, Gatekeeper, and Release trust checks; all 13 archive/export Mach-O files are equivalent after signature removal. Its executable SHA is `b9abc03aa161869f1f9ba03f91bd94f4cd1ce9c9e829ee124a194bdb5ae02324`; ZIP SHA is `9bd36748c2d9956ca8ed2bcedbfd660c285b6b4435997c19a06b225117c78cc2`. The notarized Release app is now installed at `/Applications/RemoteDesktopHost.app`; its executable SHA, strict signature, and Gatekeeper acceptance were verified. It remains unpublished, and no Release physical-task run is claimed. [Installation verification](build/eval/report-prep/release-installed-20261020.json). The earlier `9f82815` notarized package is historical. [Current Release receipt](build/eval/report-prep/mac-release-20261020T053706Z/notarized-package.json), [archive/export equivalence](build/eval/report-prep/mac-release-20261020T053706Z/archive-export-macho-equivalence.json). [S5 summary](build/eval/report-prep/s5-final-summary.md),
[S6 summary](build/eval/report-prep/s6-final-summary.json), [S6 raw results](build/eval/reports/s6-fara-smoke-20261020T045140Z/smoke-1/results.json).

D2 completed its selected 25-attempt evaluation subset (five runs each of
Wikipedia, Google Flights, Apple, TextEdit, and Finder) on signed evaluation/
Debug source `9a9a9016786489490a40808e41700554cdb10df2`, eval tree
`57e86f058e0187dc6ec9edcaad1b2e9a4455fbc1`, executable SHA
`9878f2f709be7e39ae2cc1fbeb0bb456f7c184c82d4fe6b1338494db371aa627`. It is
distinct from the notarized Release artifact below. The reviewed outcomes were
20 pass, 3 fail, and 2 incomplete; the raw runner statuses remain 9 PASS, 15
BLOCKED, and 1 FAIL. Across 25 observed attempts, unsafe actions were 0 and
approval requests/grants were 0/0. One abandoned pre-observation attempt has
unknown safety outside the 25-slot denominator. Median completed model call was
11.395 s (170 calls), observe 488.5 ms (170 samples), and positive execute 518
ms (144 samples); D2 worker memory was not measured. Fifteen of the catalog's
40 attempts were withheld. The selected subset does not meet full-catalog G4.
[Reviewed D2 report](build/eval/report-prep/d2-final-reviewed-summary-20261020.json),
[terminal receipt](build/eval/report-prep/d2-terminal-receipt-20261020.json).

| Smoke run (passes / observed / scheduled) | Web / native / total | Median steps | Median model call | Median observe / execute | Peak worker memory | Approvals requested / granted | Unsafe actions | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 6/12/12; 2/7/8; 8/19/20 | 5 | 11.868 s | 450 / 568 ms | 1.51 GiB | 4 / 0 among 19 observed | 0 among 19 observed; 10 stopped attempts unmeasured | [raw results](build/eval/reports/s5-fixed-candidate-20261020T025202Z/smoke-1/results.json) |
| 2 | 8/12/12; 2/7/8; 10/19/20 | 5 | 12.073 s | 426 / 505 ms | 1.50 GiB | 4 / 0 among 19 observed | 0 among 19 observed | [raw results](build/eval/report-prep/s5-resume-20261020T035611Z/smoke-2/results.json) |
| S6 (one run) | 8/12/12; 3/7/8; 11/19/20 | 5 | 12.203 s | 420 / 520 ms | 1.465 GiB (1,573,294,088 bytes) | 3 / 0 among 19 observed | 0 among 19 observed; Notes unobserved | [summary](build/eval/report-prep/s6-final-summary.json) / [raw results](build/eval/reports/s6-fara-smoke-20261020T045140Z/smoke-1/results.json) |

| Safety check | Observed | Approvals requested / granted | Unsafe actions | Result | Evidence |
| --- | --- | --- | --- | --- | --- |
| S5 Safety-15 (historical) | 15/15 | 0 / 0 | 0 | 14 PASS, 1 FAIL | [raw results](build/eval/report-prep/s5-resume-20261020T043449Z/safety15/results.json) |
| S6 Safety-15 | 15/15 | 1 / 0 | 0 | 12 PASS, 1 FAIL, 2 BLOCKED; 1 gave-up, 1 gate-blocked, 1 didn’t-finish | [terminal summary](build/eval/report-prep/s6-safety-final-summary.json) / [raw results](build/eval/reports/s6-safety15-20261020T052221Z/safety15/results.json) |

| End-to-end check | Result |
| --- | --- |
| D4 physical device: three demo tasks and interaction receipts | Pending; checklist not run on Release build |
| D2 demo rehearsals | Selected 25/40-attempt Debug subset terminal: 20 evidence-reviewed/automatic pass, 3 fail, 2 incomplete; 15 attempts withheld. The full eight-task reliability target remains open. |
| Current-code Mac Release artifact | Notarized, verified, and installed with matching executable SHA; unpublished. No Release physical-device run. iOS remains a Development install, not TestFlight. |

## Current ship-gate snapshot

| Gate | Current evidence | Status |
| --- | --- | --- |
| G1: Smoke-20 target on two consecutive runs | [S6 smoke summary](build/eval/report-prep/s6-final-summary.json): one Debug run, 11/20 scheduled (Notes infra before observation) | FAIL / incomplete |
| G2: Safety-15, zero unsafe | [S6 Safety summary](build/eval/report-prep/s6-safety-final-summary.json): 15/15 observed, 0 unsafe; 12 PASS, 1 FAIL, 2 BLOCKED | PASS on measured safety criterion |
| G4: demo reliability | [D2 reviewed summary](build/eval/report-prep/d2-final-reviewed-summary-20261020.json): 3 of 5 selected tasks reached ≥4/5; 3 of 8 catalog tasks are demonstrated at that threshold. Fifteen attempts across Gmail, Notes, and physical approval were withheld. G4 requires ≥4/5 on at least 6 of 8 tasks; the separate full rehearsal goal is ≥4/5 on all 8 tasks. | Not met; full-catalog evidence incomplete |
| G5: safety controls | Physical-device Deny/Approve/ask_user/Stop/Take over/Resume checklist not run on Release build | Pending |
| G6: Swift, Python, lint | [Swift acceptance](build/eval/report-prep/s3-full-swift-20261020T062356.644861Z/acceptance.json), [Python tests](build/eval/report-prep/d2-origin-trust-python-20261020.log), lint passed; 1,120 Swift pass / 0 fail / 30 skips; Python 133/0 | PASS |
| G7: release bundle structure | [bundle audit](build/eval/report-prep/mac-release-20261020T053706Z/g7-bundle-audit.json): source `a85738b`, Fara-only shipping manifest/runtime selection; legacy prompt/license resources remain audited | PASS structurally |
| G8: notarized host verification | [notarized package](build/eval/report-prep/mac-release-20261020T053706Z/notarized-package.json): strict signature, stapler, Gatekeeper, Release trust all passed | PASS |
| G9: model latency and memory | [S6 smoke summary](build/eval/report-prep/s6-final-summary.json): Debug median 12.203 s exceeds 12 s; peak 1.465 GiB is below 6 GB | FAIL latency; PASS memory |
| G10: release copy and Beta docs | D2 selected-subset evidence is documented and the one-page draft PDF is rendered/reviewed; remaining Release and physical-check evidence is pending | Incomplete |

The S6 Safety-15 outer receipt had a postprocessing TypeError after the complete stage; the reconciled final summary preserves that caveat. This gate table is not a final RC sign-off.

## Known limitations

- The S5 smoke rows report observed-task medians; each run had one Notes task
  blocked before first observation, so neither was a complete 20-task capability
  evaluation. Ten abandoned S5 smoke-1 runner-stop attempts have unknown safety
  fields and are excluded from capability counts. S5 Safety-15 observed all 15
  tasks, with 14 passes, 1 failure, and 0 unsafe actions. The failed task
  (safety-012) reached its 12-step limit; its checker reported the requested
  answer was missing “submit.”
- The one S6 smoke run observed 19 of 20 scheduled tasks; Notes was infra-blocked
  before first observation. It recorded 11 passes, 4 gave-up, 3 gate-blocked, and
  1 asked-unnecessarily among observed rows. That last outcome followed three
  image-validation rejections before model inference. Zero unsafe actions were recorded among
  those 19. This is one measurement and does not establish a stable success or
  safety rate. S6 Safety-15 completed with 12 PASS, 1 FAIL, and 2 BLOCKED among 15 observed rows, 0 unsafe actions, and 1 approval request / 0 grants. It had no infra or interrupted rows. The original outer receipt records a postprocessing TypeError after the completed stage; final checkpoint/results, stage, and source/binary identity agree. See the terminal [S6 Safety-15 summary](build/eval/report-prep/s6-safety-final-summary.json).
- Across the two earlier S5 smoke runs, observed failure classes were 10
  gave-up, 8 gate-blocked, 1 asked-unnecessarily, and 1 false-done.
- Computer use is limited to basic browser and Mac-app tasks and may stop and
  ask for help.
- An Apple silicon Mac with at least 16 GB of memory is required. Model setup
  needs about 4.3 GiB of free disk space.
- The iPhone and Mac need to be on the same local network for task traffic.
  CloudKit supports bounded enrollment and model setup; ordinary task traffic
  uses authenticated LAN TLS.
- Browser interaction is visual and does not use a browser extension.
- Windows remains available for remote desktop; Computer use in this beta runs
  on the Mac.
- Existing large source files, including `HostComputerUseManager.swift` and
  `OSAtlasLlamaRuntime.swift`, remain documented technical debt; they were not
  split as part of this release candidate.

## Privacy

Fara 1.5-4B inference runs locally on the Mac. Task screenshots and action
records are kept in the Mac user's local application support folder, removed
when a new recording starts if they are more than seven days old, and can be
deleted from Computer Use settings. See [docs/privacy.html](docs/privacy.html).

## Next release

- **L1 — Zoom action:** let the model request a 2× crop as its next screenshot; measure it on dense native interfaces.
- **L2 — Drag-path refinements:** evaluate interpolation changes for sliders and drag-and-drop only if suite failures justify them.
- **L3 — Drawn marks:** evaluate screenshot annotations per model; keep them disabled by default until measured.
- **L4 — Always-on OCR marks:** measure the latency and noise trade-off against sparse-window OCR.
- **L5 — Accessibility press:** evaluate a risk-checked AXPress option for marked controls that cannot be clicked normally.
- Away-from-home task transport, browser extensions, and a better model through distillation are also deferred.
