[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | in progress | Latest real batch: 2/10 passed (3 attempted), median 141.6 s. Third draft completed, but the independent saved-recipient AX menu action failed. Replaced it with one scoped native context-click and exact visible Copy-address proof: native/Core/Gmail/Executor checks 47 passed, 3 skipped. Retry bookmarks prevent interrupted picker tests from opening another draft; the earlier ambiguous fixture remains quarantined. Run 10 distinct drafts and 3 Send stops. No Send granted. |
| Build / regression checkpoint | in progress | Build compiles. Full `w1-account-full-20261009-175509`: 3,097 passed / 155 failed / 369 skipped, 873.7 s; exactly the unchanged external 155-failure baseline, no new failed tests. The previous 20 extra synthetic-screen failures are resolved. Focused picker checks: 51 passed / 4 skipped; file-query checks: 65 passed / 4 skipped; editor/wait checks: 12 passed; runner checks: 35 passed. Full suite is not green. Raw traces remain outside Git, capped at 20 runs. |
| W2 Drive / Dropbox web upload | not started | After W1; reuse its picker and signed-in test accounts. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused by A6: sync work committed behind computerUseV2, unrouted; acceptance disabled. |

A1 bounded experiment completed: run0d81e3ad exposed AXInvalidUIElement in the independent saved-recipient menu action; a native context-click on the actual unique chip showed the exact address.
The checker now makes one fresh scoped context-click, requires exact Copy-address proof and verified menu cleanup, and rejects invalid/out-of-window bounds or covering panels. The existing-draft probe and 47 focused checks passed; Send/fingerprint rules are unchanged.
Full regression matches all 155 baseline failures with no additions. Commit this working step and rerun 10 distinct Gmail drafts plus 3 Send stops; keep the recovery bookmark navigation-only and preserve the quarantined ambiguous fixture.
