| Step | Status | Suite result | Next / blocker |
| --- | --- | --- | --- |
| Checkpoint | committed (`61c848b`); signed build green on Xcode 27 | Swift 31/31; Python 35/35. Previous Safari smoke: 20 infra-blocked before observation, no model score. | Controlling plan: frontier-harness-plan.md. Safari parked; no more bridge work. |
| 1 — PixelEnvironment | implemented, compiled, synthetic tests green; live acceptance in step 2 | Signed Xcode27 build green (84.65s); focused Swift60/60 (15.14s), Python39/39; no skips. | Width1280 crops, AX≤300ms, paste/restore, generic picker; both adapters use one loop/schema. File search retains the existing generic catalog pending HostTools simplification. |
| 2 — First model numbers | Fara run recorded; UI-TARS interrupted by owner permission dialog | Fara: 0/17 observed tasks, 3 Finder tasks infra-blocked at generic app lookup; 2 median steps, 9.14s pooled median model call, 34 empty-argument rejections, 0 approvals. UI-TARS: 9/20 rows recorded, valid proposals but Documents permission covers the screen; not a capability score. Eval reporting regression tests42/42. | Owner: allow Remote Desktop Host Documents access (Privacy & Security → Files & Folders if the dialog closed). All evaluation host/model/runner processes stopped; restart the unchanged signed baseline afterwards. Reporting preserves pending-boundary metrics and pools step latencies. UI-TARS Q4/f16 on32GB is not16GB-qualified. |
| 3 — Thin ActionGate / loop | pending after baseline | Not run. | Semantic approvals, no pixel/pre-keystroke checks; rerun smoke. |
| 4 — Cleanup D1–D4 | pending; one Luna ticket per group | Build +full unit tests +smoke after each. | No deletions before first real model numbers. |
| 5 — Top2 generic failure classes | pending | Not run. | Improve observation/actions/adapters, never task-specific code. |
| 6 — Cleanup D5–D8 / rename / CI | pending | Not run. | Park Safari branch, archive audits, LocalModel rename, lint; Agent≤2500,total≤15000,files≤800. |
| 7 — Full suites / demo trials | pending | web80,native30,safety15; demo5×3. | Same local harness and recorded episodes. |
| 8 — Model recommendation | pending | smoke20+native30,3runs/model. | Owner approves model pick. |
| 9 — Demo v0 | pending | iPhone+Mac video and suite table. | Owner present for test Gmail sign-in check. |
| 10 — Training | pending; general-agent-plan.md governs training only | Not run. | Owner approves teacher terms,GPU budget and training start. |
