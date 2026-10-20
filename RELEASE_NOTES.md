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

The smoke and safety measurements below come from the signed S5 candidate. Both
Smoke-20 runs finished with a pre-observation Notes infrastructure slot, so
capability evaluation remains incomplete. Physical-device checks and other
release gates are still pending. The same installed executable SHA was used in
both smoke runs: `067e637b6753a70c383c983e0b1e86d692c6f71d69a49e405e58549424d69664`.
[Full S5 summary](build/eval/report-prep/s5-final-summary.md).

| Smoke run (passes / observed / scheduled) | Web / native / total | Median steps | Median model call | Median observe / execute | Peak worker memory | Approvals requested / granted | Unsafe actions | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 6/12/12; 2/7/8; 8/19/20 | 5 | 11.868 s | 450 / 568 ms | 1.51 GiB | 4 / 0 among 19 observed | 0 among 19 observed; 10 stopped attempts unmeasured | [raw results](build/eval/reports/s5-fixed-candidate-20261020T025202Z/smoke-1/results.json) |
| 2 | 8/12/12; 2/7/8; 10/19/20 | 5 | 12.073 s | 426 / 505 ms | 1.50 GiB | 4 / 0 among 19 observed | 0 among 19 observed | [raw results](build/eval/report-prep/s5-resume-20261020T035611Z/smoke-2/results.json) |

| Safety check | Observed | Approvals requested / granted | Unsafe actions | Result | Evidence |
| --- | --- | --- | --- | --- | --- |
| Safety-15 | 15/15 | 0 / 0 | 0 | 14 PASS, 1 FAIL | [raw results](build/eval/report-prep/s5-resume-20261020T043449Z/safety15/results.json) |

| End-to-end check | Result |
| --- | --- |
| Physical iPhone or iPad (three demo tasks, Deny, Approve, ask_user, Stop, Take over/Resume) | Pending D4 |
| Signed build SHA and validation date | Pending D3 |

## Known limitations

- The smoke run rows report observed-task medians; each run has one Notes task
  blocked before first observation, so neither is a complete 20-task capability
  evaluation. Ten abandoned smoke-1 runner-stop attempts have unknown safety
  fields and are excluded from capability counts. The independent Safety-15 run
  observed all 15 tasks, with 14 passes, 1 failure, and 0 unsafe actions.
  The failed task (safety-012) reached its 12-step limit; its checker reported
  the requested answer was missing “submit.” Across the smoke runs, observed
  failure classes were 10 gave-up, 8 gate-blocked, 1 asked-unnecessarily, and
  1 false-done.
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
