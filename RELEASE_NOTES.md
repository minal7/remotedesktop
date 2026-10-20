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

### Latest measured candidate: B2 signed Debug

B2 source HEAD `e9996b22f65d626b5af7e8240149d5a5b93dbbed`, signed Debug executable SHA `0420ff3edae8f8de21b9b333edc510dad3497a362da554622121c7b4be9eeaec`. Full Swift passed 1,123 tests / 0 failures / 30 unchanged opt-in skips; Python passed 133/0. The smoke is incomplete: 18 observed of 20 catalog tasks, 10 PASS / 5 FAIL / 3 BLOCKED; 19 were selected, with native-007 pending pre-observation infrastructure and native-008 withheld. Independent Safety-15 observed 15/15: 10 PASS / 2 FAIL / 3 BLOCKED, 0 unsafe, 3 approval requests / 0 grants. Three pre-observation attempts have unknown safety outside the observed denominators. Smoke median: 5 steps, model 11.2765 s (124 calls), observe 421.5 ms, positive execute 493 ms. Safety median: 1 step, model 10.3855 s (30 calls), observe 644.5 ms, positive execute 489.5 ms. Across 366 memory samples, maximum current footprint was 1,593,430,072 bytes and maximum worker-reported peak was 1,593,561,144 bytes. ([B2 combined summary](build/eval/report-prep/b2-validation-20261020T085211Z-combined-summary.md), [raw aggregate and provenance](build/eval/report-prep/b2-validation-20261020T085211Z-combined-summary.json), [Swift acceptance](build/eval/report-prep/s3-full-swift-20261020T084535.288181Z/acceptance.json), [Python log](build/eval/report-prep/d2-origin-trust-python-20261020.log))

The same-source Mac 0.3.0 (1) package from `e9996b2` passed G7 structure, strict signature, stapler, Gatekeeper, Release trust, notarization, and 13-file Mach-O equivalence checks. Notarized executable SHA `dc8f8b39770f633c694c4e2b94b10dcf2439ade11d1953e49c4fd13ab52d1bbe`; ZIP SHA `01104546382479849c4501839e40d9d20450798d30034267422a44a310d16629`. It is unpublished and installed with the expected executable identity. The current GUI remains at Setup Step 1 with Screen Recording required, and Check Again left the state unchanged; no physical task run is claimed. The earlier notarized package from `a85738b` predates B1/B2. ([current notarized package](build/eval/report-prep/mac-release-20261020T093832Z/notarized-package.json), [Mach-O signature comparison receipt](build/eval/report-prep/mac-release-20261020T093832Z/notarized-package.json), [ZIP](build/eval/report-prep/mac-release-20261020T093832Z/RemoteDesktopHost-macOS-0.3.0.zip), [historical package](build/eval/report-prep/mac-release-20261020T053706Z/notarized-package.json))

### D2 selected Debug demo campaign

D2 completed 25 of 25 selected attempts from the 40-attempt catalog. Evidence-reviewed/automatic outcomes were 20 pass, 3 fail, 2 incomplete; 15 catalog attempts were withheld. Three of five selected tasks met 4/5, below G4's requirement of at least six of eight tasks. The D2 run did not measure Release performance or worker memory. ([D2 reviewed summary](build/eval/report-prep/d2-final-reviewed-summary-20261020.json), [terminal receipt](build/eval/report-prep/d2-terminal-receipt-20261020.json))

### Historical S5 and S6 Debug measurements

These prior candidate measurements are retained as history and do not describe B2 or the current Release archive.

| Run (passes / observed / scheduled) | Web / native / total | Median steps | Model call | Observe / execute | Peak memory | Safety | Evidence |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| S5 Smoke-1 | 6/12/12; 2/7/8; 8/19/20 | 5 | 11.868 s | 450 / 568 ms | 1.51 GiB | 0 unsafe / 19 observed; 10 stopped attempts unmeasured | [S5 results](build/eval/reports/s5-fixed-candidate-20261020T025202Z/smoke-1/results.json) |
| S5 Smoke-2 | 8/12/12; 2/7/8; 10/19/20 | 5 | 12.073 s | 426 / 505 ms | 1.50 GiB | 0 unsafe / 19 observed | [S5 results](build/eval/report-prep/s5-resume-20261020T035611Z/smoke-2/results.json) |
| S6 Smoke-20 (one run) | 8/12/12; 3/7/8; 11/19/20 | 5 | 12.203 s | 420 / 520 ms | 1.465 GiB | 0 unsafe / 19 observed; Notes unobserved | [S6 summary](build/eval/report-prep/s6-final-summary.json) |
| S5 Safety-15 | 14 PASS, 1 FAIL / 15 observed | 1 | 11.388 s | 369 / 488 ms | 1.46 GiB | 0 unsafe / 15 | [S5 results](build/eval/report-prep/s5-resume-20261020T043449Z/safety15/results.json) |
| S6 Safety-15 | 12 PASS, 1 FAIL, 2 BLOCKED / 15 observed | 1 | 13.368 s | 439.5 / 515 ms | 1.46 GiB | 0 unsafe / 15 | [S6 summary](build/eval/report-prep/s6-safety-final-summary.json) |

S5 smoke had one Notes infrastructure slot in each segment. S6's only smoke observed 19/20; its separate Safety-15 outer receipt had a postprocessing TypeError after completion, reconciled against the final checkpoint/results and matching source/binary identities. These are historical candidate results. ([S5 summary](build/eval/report-prep/s5-final-summary.md), [S6 summary](build/eval/report-prep/s6-final-summary.json))

## Current ship-gate snapshot

| Gate | Current evidence | Status |
| --- | --- | --- |
| G1: Smoke-20 target on two consecutive runs | [B2 smoke summary](build/eval/report-prep/b2-validation-20261020T085211Z-combined-summary.md): 18/20 catalog rows observed, 10 strict PASS; 19 selected. Native-007 pending infra; native-008 withheld. | FAIL / incomplete |
| G2: Safety-15, zero unsafe | [B2 Safety summary](build/eval/report-prep/b2-validation-20261020T085211Z-combined-summary.json): 15/15 observed, 0 unsafe; 10 PASS, 2 FAIL, 3 BLOCKED; 3 requests / 0 grants. One abandoned pre-observation attempt has unknown safety outside the denominator. | Observed zero-unsafe criterion met; broader ship gates pending |
| G4: demo reliability | [D2 reviewed summary](build/eval/report-prep/d2-final-reviewed-summary-20261020.json): 3 of 5 selected tasks reached ≥4/5; 3 of 8 catalog tasks are demonstrated at that threshold. Fifteen attempts across Gmail, Notes, and physical approval were withheld. G4 requires ≥4/5 on at least 6 of 8 tasks; the separate full rehearsal goal is ≥4/5 on all 8 tasks. | Not met; full-catalog evidence incomplete |
| G5: safety controls | Physical-device Deny/Approve/ask_user/Stop/Take over/Resume checklist not run on Release build | Pending |
| G6: Swift, Python, lint | [Swift acceptance](build/eval/report-prep/s3-full-swift-20261020T084535.288181Z/acceptance.json), [Python tests](build/eval/report-prep/d2-origin-trust-python-20261020.log): 1,123 Swift pass / 0 fail / 30 unchanged skips; Python 133/0; lint status is separate. | Current verification evidence; remaining gates pending |
| G7: release bundle structure | [Current-source audit](build/eval/report-prep/mac-release-20261020T093832Z/g7-bundle-audit.json): B2 source `e9996b2`; Fara runtime selection and bundle structure passed. | PASS structurally |
| G8: notarized host verification | Current-source [notarized package](build/eval/report-prep/mac-release-20261020T093832Z/notarized-package.json): strict signature, stapler, Gatekeeper, and Release trust passed. ZIP SHA `01104546382479849c4501839e40d9d20450798d30034267422a44a310d16629`; 13 Mach-O files equivalent after signature removal. [Installed identity](build/eval/report-prep/mac-release-20261020T093832Z/installed-release-receipt.json) matches; GUI permission check remains blocked. | PASS; GUI/physical readiness pending |
| G9: model latency and memory | [B2 summary](build/eval/report-prep/b2-validation-20261020T085211Z-combined-summary.md): smoke model-call median 11.2765 s (124 calls); maximum sampled current footprint 1.593 GB and reported peak 1.594 GB, below the 6 GB limit. The smoke is incomplete and is not a Release measurement. | Measured Debug values within thresholds; full gate pending |
| G10: release copy and Beta docs | B2 metrics and Release provenance are being reconciled; physical Release evidence is absent. | Incomplete |

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
