[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | passing 10/10 | Accepted: draft batch `215bfefb`→`91255b7b` independently reopened 10 distinct saved drafts with exact fields and one exact attachment name/size, median 132.2 s. Send batch `0bc93140`→`160e72ae`: 3/3 stopped at approval with exact review fields, median 75.4 s; zero Send approvals granted. Coordinate fix committed as `d923f79`. |
| Build / regression checkpoint | compiled / focused tested; full baseline non-green | Focused `w2-upload-narrow-20261010-191440`: 143 passed /0 failed /7 skipped in 70.9 s; Python 55/0 in 0.097 s. Full `w2-full-20261010-191601`: 3,158 passed /157 failed /372 skipped in 1,261.4 s: all 155 baseline failures plus two owned-browser navigation failures. Those two passed 3 repetitions each (6/6) unchanged in `w2-navigation-rerun-20261010-193733`; intermittent, not removed from the full result. |
| W2 Drive / Dropbox web upload | implemented / focused tested; acceptance failing | Latest diagnostic `be935314`: 0/1, 87.2 s; XCTest aborted before outcome, counters unknown. Exact file absent in the correct account afterward; identity permanently retired without replay. Previous `1a61cf0e`: no native Open, per-key shortcut context rejected. Prior `52b7d40a` uploaded one exact 8 KB file, but its acceptance failed. Size proof currently ≤1 MiB; root folder only. Dropbox: owner sign-in pending. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | paused / unrouted | Paused by A6: sync work committed behind computerUseV2; acceptance disabled. |

A1 ≤30-minute harness experiment: the sync entry still aborted in XCTest’s Swift task observer. Its explicit nonisolated boundary and absolute runner deadline now compile and pass focused tests; run one fresh real diagnostic after this checkpoint to test the boundary.
Preserve every failed identity without replay. `be935314` has unknown effect counters and independently verified remote absence; the current product is not accepted for Drive.
Full regression recorded 155 baseline failures plus two intermittent navigation failures (6/6 on unchanged focused reruns); do not claim the full suite green. Dropbox owner sign-in remains pending.
