[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | in progress | Latest batch 0/10, 238.7 s: a21e2a6e passed startup and reached the exact Gmail composer/attachment picker, then two AXWindows reads returned cannotComplete during validation. Unique draft retry URL preserved; no attachment confirmation or Send. Focused checks: 158 passed / 0 failed / 22 skipped. Still need 10 distinct drafts and 3 Send stops. |
| Build / regression checkpoint | compiled / tested | Full `w1-account-full-20261009-220840`: 3,110 passed / 155 failed / 371 skipped, 933.3 s; exact unchanged external 155-failure baseline, zero new failing tests. Focused Safari/Gmail checks: 158 passed / 0 failed / 22 skipped. Full suite is not green. Raw traces remain outside Git, capped at 20 runs. |
| W2 Drive / Dropbox web upload | not started | After W1; reuse its picker and signed-in test accounts. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused by A6: sync work committed behind computerUseV2, unrouted; acceptance disabled. |

A1 bounded experiment (≤30 minutes, after this checkpoint): a21e2a6e reached the exact Gmail composer and attachment picker, then two root AXWindows reads returned cannotComplete (-25204) during read-only post-action validation. Existing unique draft URL is preserved for retry.
Allow only bounded additional fresh captures for that exact transient read error, with cancellation/active-task/full authoritative-app checks before each; retain every fresh PID/CFEqual/focus/sheet guard, discard failed snapshots and never replay input. Keep all other errors terminal.
Current startup/navigation focused checks pass (158 passed / 0 failed / 22 skipped); full suite completed with zero new failing tests before commit. W1 remains 0/10 in latest batch (238.7 s), awaiting 10 distinct exact drafts +3 Send stops; no Send or OS-level acceptance.
