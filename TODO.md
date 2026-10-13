| Phase | Status | Suite result | Blocker |
| --- | --- | --- | --- |
| 0 — Freeze and branch | committed (`4b153a1`) | Snapshot recorded; prior focused baseline was 46/48. | None |
| 1 — Shared contracts | committed (`0a6c834`) | Xcode 7/7, Python 13/13, shared corpus 58 cases. | None |
| 2 — Single general loop | committed (`86c13bb`); compiled and tested | Xcode 102/102; Python 13/13; existing harness 136/136; bridge Node 15/15. | Real-host Safari bridge and model end-to-end remain unverified. |
| 3 — Remove obsolete pipelines | pending; one Luna ticket per deletion group, then build + smoke | Not run. | Fix bridge startup and rerun the real-host smoke first; preserve all Safari bridge/helper/extension files. |
| 4 — General evaluation | bridge diagnosis; signed build green on Xcode 27; preflight and duplicate-launch fixes in progress | First real-host smoke: 20 infra-blocked before observation; no model capability score. Installed preflight passes signature, Accessibility, and Screen Recording; helper status is notFound despite verified packaging. | ≤30-minute experiment: verify packaged plist and executable before first registration. Register a verified but previously unseen service; retain distinct missing-package, registration-error, and approval states. Then prove enabled helper/extension and 100-ping p95 and rerun 20 tasks; VM setup deferred. |
| 5 — Policy baseline | pending | Not run. | Phase 4 baseline data. |
| 6 — Training pipeline | pending | Not run. | Owner approval of model, teacher terms, and GPU budget. |
| 7 — Product integration | pending | Not run. | First promoted model. |
