| ID | Item | Status | Result / evidence | Next |
| --- | --- | --- | --- | --- |
| T1 | Native calibration | Accepted | 20/20 correct window; 10 exact + 8 descendant; both misses retained. Owner threshold 18/20 identity. | No further calibration approval before ship. |
| T2 | Previous smoke pair | Interrupted; invalid release measurement | Run 1 segmented: web 7/12, native 0/8 under invalid saved-document setup. Run 2: 5 PASS, 2 BLOCKED, 1 FAIL, 12 infra; local-input pause and incomplete final provenance. Evidence: build/eval/reports/t2-continuation-20261016T004333Z/. Owner paused the session; the gap was authorized. | Exclude partial run 2; replace with S2/S5. |
| T3 | Latency candidate | Prepared, not applied | Paired HTTP experiment: combined one prior image / 768 image cap 11.225 s, peak 1.458 GiB. Not end-to-end quality evidence. | S4, then measure in S5. |
| T4 | Mark follow-ups | Implemented, linted; not compiled | 0c2d990; Agent 6,673/6,703 lines; installed app unchanged. | S3. |
| T5 | Packaging | Implemented; archive pending | Fara-only manifest, executor test, lint and docs archive. Installed ab3f0e4 suite: 1,108 passed, 0 failed, 30 unchanged opt-in skips. Developer ID key probe passed. | D3 release archive and notarization. |
| T6 | Physical iPad/iPhone | Pending owner session | Checklist 74b286e; signed iPad app installed. No iPhone Mirroring. | D4 against release build. |
| F1 | Release copy and versions | Implemented; measurements pending | Host 0.3.0 (1), iOS 1.2 (1), Beta labels and privacy/support/README. | Fill final suite/demo measurements. |
| F2 | Ship gates + PR | Pending | G1/G2/G4/G5/G8/G9 need current evidence; G6 must cover final source; G7 bundle audit and G10 final measurements pending. | M1 then M5. |
| S1 | Native fixture and runner repair | Tested; eval only | 98 Python tests passed in 4.117 s; 3/3 signed-app native start probes reached one frontmost Untitled window. Evidence: build/eval/reports/s1-start-probes-20261017T003100Z/report.json and s1-eval-unit.log. Installed SHA 2bced38eab2cfa4852566471bc5cde2d63a6801019dd24f419252a8c80ab59a3 unchanged. Agent 6,673 lines. | S2 native-8 on unchanged app; historical partial run 2 excluded. |
| S2 | Native-8 re-baseline | Pending | No agent change or installation before this measurement. | Announce hands-off window; detached one-run baseline. |
| S3 | Compile mark follow-ups | Pending | Source patch retained, not installed. | Full Swift green after S2. |
| S4 | Apply latency candidate | Pending | One previous image and 768 image-token cap, same signed build as S3. | Verify request flags. |
| S5 | Smoke-20 twice + safety-15 | Pending | One frozen signed build; detached and resumable. | Target 14/20 each, web 10/12, native 4/8, zero unsafe, median model ≤12 s. |
| S6 | One generic failure fix | Conditional | Two-hour limit; choose from S5 evidence. | One measured smoke delta. |
| D1 | Eight demo task YAMLs | Pending | Prompts/checkers only; no task-specific production code. | Define after Saturday measurements. |
| D2 | Five rehearsals per demo | Pending | Preserve every episode and failed attempt. | Per-task pass/time table. |
| D3 | Release archive + notarization | Pending | Developer ID setup ready; owner credentials only if required. | Strict verification, notarization, iOS archive. |
| D4 | Physical-device checklist | Pending | Owner operates physical iPad/iPhone; Codex verifies episodes. | Deny/Approve/ask_user/Stop/Take over/Resume. |
| M1 | Final ship gates | Pending | No waivers inferred. | Gate table on release build. |
| M2 | Demo video | Pending | Owner films device; raw footage retained; speed changes labelled. | 2–3 minute package. |
| M3 | Metrics one-pager | Pending | Every number links to a report. | Markdown + one-page PDF. |
| M4 | Live runbook | Pending | Preparation, narration and recorded fallbacks. | Publish with demo package. |
| M5 | PR to main | Pending | Owner merges, uploads TestFlight and publishes host. | Open after gates; stop. |
| OWNER | Outstanding owner actions | None blocking S1 | Future: physical device session, credentials if required, TestFlight upload, video filming and merge. | Hands-off run window will be announced before live tests. |
