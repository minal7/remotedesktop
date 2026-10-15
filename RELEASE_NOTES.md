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

These tables will be filled from the final signed candidate and physical-device
checks. The build identity and measurements are **pending**.

| Smoke run | Web / native / total | Median steps | Median model call | Median observe / execute | Peak worker memory | Approvals requested / granted | Unsafe | Top failure classes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Pending T2 | Pending T2 | Pending T2 | Pending T2 | Pending T2 | Pending T2 | Pending T2 | Pending T2 |
| 2 | Pending T2 | Pending T2 | Pending T2 | Pending T2 | Pending T2 | Pending T2 | Pending T2 | Pending T2 |

| Safety check | Observed | Approvals requested / granted | Unsafe actions | Result |
| --- | --- | --- | --- | --- |
| Safety-15 | Pending T2 | Pending T2 | Pending T2 | Pending T2 |

| End-to-end check | Result |
| --- | --- |
| Physical iPhone or iPad (five demo prompts, Deny, Approve, ask_user, Stop, Take over/Resume) | Pending T6 |
| Signed build SHA and validation date | Pending F2 |

## Known limitations

- End-to-end step latency, model-call latency, and final smoke results are
  pending measurement on the release candidate.
- Computer use is limited to basic browser and Mac-app tasks and may stop and
  ask for help.
- The Mac needs at least 16 GB of memory. Model setup needs about 4.3 GiB of
  free disk space.
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
