[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | passing 10/10 | Accepted: draft batch `215bfefb`→`91255b7b` independently reopened 10 distinct saved drafts with exact fields and one exact attachment name/size, median 132.2 s. Send batch `0bc93140`→`160e72ae`: 3/3 stopped at approval with exact review fields, median 75.4 s; zero Send approvals granted. Coordinate fix committed as `d923f79`. |
| Build / regression checkpoint | compiled / focused tested; full baseline non-green | Focused `w2-upload-narrow-20261010-204445`: 147 passed /0 failed /7 skipped in 139.3 s; Python 55/0 in 0.097 s. Full `w2-full-20261010-205003`: 3,164 passed /154 failed /372 skipped in 1,370.4 s: zero added failures against the fixed 155-failure baseline; one baseline failure passed. The suite remains non-green. The prior two intermittent navigation failures passed this full run. |
| W2 Drive / Dropbox web upload | implemented / compiled / focused tested; acceptance failing | Latest `5a961aac`: 0/1 in 51.5 s; startup could not capture the new window, before W2 preparation. All upload/Open counters zero; retired without replay. W2 retained-window recovery, navigation and parent reads pass focused tests; the recovery was not exercised in this run. Prior `52b7d40a` uploaded one exact 8 KB file, but acceptance failed. Size proof currently ≤1 MiB; root folder only. Dropbox: owner sign-in pending. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | paused / unrouted | Paused by A6: sync work committed behind computerUseV2; acceptance disabled. |

A1 ≤30-minute startup experiment: `5a961aac` stopped before W2 preparation at the full window inventory (10 transient AXWindows failures, no successful after-window capture). All upload/Open counters were zero; the failed identity is retired without replay.
Full check finished with zero added failures; commit the compiled repairs. Then compare a fresh focused-window read with the global window-list read during startup; keep full ownership checks and Gmail/Send unchanged until evidence supports a W2-only redesign.
Focused `204445` passed 147/0/7; the live run did not exercise the new retained-window recovery. Drive remains unaccepted, Dropbox needs owner sign-in, and unconfirmed windows are preserved.
