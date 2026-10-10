[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | in progress | Latest batch: 1/10 passed (2 attempted), median 152.5 s. The saved-draft retry passed with exact fields and one attachment. Fresh compose navigation was cancelled by the 45 s proposal-worker timer: host navigation was incorrectly inside its proposal callback. Host navigation now runs outside the model worker under the same execution guards; focused checks pass and the full suite adds no failures. Retry real acceptance next. Still need 10 distinct drafts and 3 Send stops; no Send granted. |
| Build / regression checkpoint | compiled / tested | Full `w1-account-full-20261009-202129`: 3,105 passed / 155 failed / 370 skipped, 943.4 s; exact unchanged external 155-failure baseline, zero new failing tests. Visible-page selection, native URL entry, transient recapture and host-preparation checks pass. Full suite is not green. Raw traces remain outside Git, capped at 20 runs. |
| W2 Drive / Dropbox web upload | not started | After W1; reuse its picker and signed-in test accounts. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused by A6: sync work committed behind computerUseV2, unrouted; acceptance disabled. |

A1 bounded redesign (≤1 day): 3b01a053 saved-draft retry passed; fresh 9e77a6c3 timed out while typing its compose URL. Host navigation currently runs inside the proposal-only worker's 45 s timer; latest batch 1/10, median 152.5 s.
Implemented host navigation before fresh observation and outside the model worker, after startup consent checks; lease, task, active-control, signed-app/window and URL-dispatch guards are preserved. Model/native typing deadlines are unchanged; no uncertain-input replay.
Focused regressions and the full suite are tested with zero new failures; next run a fresh 10-draft batch and 3 Send stops. Prior ambiguous drafts remain excluded; no Send, cleanup or owner-account changes are authorized by this redesign.
