[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | passing 10/10 | Accepted: draft batch `215bfefb`→`91255b7b` independently reopened 10 distinct saved drafts with exact fields and one exact attachment name/size, median 132.2 s. Send batch `0bc93140`→`160e72ae`: 3/3 stopped at approval with exact review fields, median 75.4 s; zero Send approvals granted. Coordinate fix committed as `d923f79`. |
| Build / regression checkpoint | compiled / focused tested; full incomplete | Focused `w2-upload-narrow-20261010-234305`: 153 passed /0 failed /7 skipped in 126.7 s; real read-only URL validation 3/3 in 289–515 ms; Python 55/0. Latest full `w2-full-20261010-235004` timed out after 1,800.1 s without a complete result: baseline comparison unavailable. Previous completed full `w2-full-20261010-205003`: 3,164 passed /154 failed /372 skipped, zero added failures against the fixed 155-failure baseline. The full suite remains non-green. |
| W2 Drive / Dropbox web upload | implemented / compiled / focused tested; acceptance failing | Latest `0cc7f057`: 0/1 in 112.5 s; Swift/XCTest task-local runtime crash before outcome recording, dispatch counts unknown. Identity retired unchanged without replay; unconfirmed window preserved. Prior `032f3a78` passed independent account/collision checking but New-click pixel checks rejected three attempts; its owned window closed. Drive now reuses its guarded shortcut directly; focused 153/0/7. Prior `52b7d40a` uploaded one exact 8 KB file but failed acceptance. Size proof ≤1 MiB; root folder only. Dropbox: owner sign-in pending. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | paused / unrouted | Paused by A6: sync work committed behind computerUseV2; acceptance disabled. |

A1 ≤30-minute harness experiment next: the earlier short no-effect failure returned normally, so a reporting-only change is weak evidence. After committing this checkpoint, run one temporary 100-second no-effect failure through the unchanged wrapper with body_started/body_finished/wrapper_reporting markers; compare duration versus live-body lifecycle without changing product semantics.
The crashed identity is retired unchanged without replay; dispatch counts are unknown and unconfirmed window 9D1B4A3F is preserved. Exact-window/account/source checks, one-shot latch, pixel/Send rules and Rule 7 remain unchanged.
The required full run timed out and provides no complete baseline comparison; preserve that limitation in the commit. Continue the bounded harness experiment, then a fresh Drive identity if it exits normally. Dropbox owner sign-in remains pending.
