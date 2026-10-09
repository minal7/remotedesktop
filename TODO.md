[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | in progress | Real retry `m0-acceptance-gmail-20261009T202652Z-7fec6b02` stopped 0/1 attempted (10 planned), 48.3 s: window-lost after Inbox, before the existing draft or attachment. Two-route Safari probe passed 1/1 in 35.4 s. Add finite validation-phase evidence and a final activity/cancellation recheck before the URL write; no further live input until that recheck is tested. Exact Drafts/attachment 10/10 and Send-approval stops 3/3 remain pending. Safari only; missing-AX Fara fallback unverified. |
| Build / regression checkpoint | in progress | Build compiles. Focused `w1-account-fix-20261009-131939`: 99 passed / 0 failed / 17 skipped, 198.4 s; runner checks 25 passed. Full `w1-account-full-20261009-132928`: 3,073 passed / 155 failed / 367 skipped, 835.9 s; exact comparison with 01e4de3 found 0 added failures. Full suite is not green. Compact baseline and raw traces are outside Git; raw runs capped at 20. |
| W2 Drive / Dropbox web upload | not started | After W1; reuse its picker and signed-in test accounts. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused by A6: sync work committed behind computerUseV2, unrouted; acceptance disabled. |

A1 bounded experiment (≤30 minutes): the real Gmail retry loses window authority before draft navigation, while the native two-route probe passes.
Add only finite capture/target/sheet/focus diagnostics and restore the final cancellation/activity check after awaiting address focus; keep Send, secure-field and uncertain-write rules.
Run focused checks, then one fail-fast retry using the existing test draft and fixture; use the observed phase to choose the smallest next repair. Optional cloud planning remains off by default.
