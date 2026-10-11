[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | passing 10/10 | Accepted: draft batch `215bfefb`→`91255b7b` independently reopened 10 distinct saved drafts with exact fields and one exact attachment name/size, median 132.2 s. Send batch `0bc93140`→`160e72ae`: 3/3 stopped at approval with exact review fields, median 75.4 s; zero Send approvals granted. Coordinate fix committed as `d923f79`. |
| Build / regression checkpoint | in progress | Compiled; page-reader47 tests:45 passed/0 failed/2 skipped in72.8s, including latency/pruning regression. Full w2-full-20261011-035745 timed out at1,800.1s after3,374 completed tests and two legacy OSAtlas array-index crashes; all148 observed failures match the fixed155-failure baseline, but complete comparison is unavailable. Last complete full:154 baseline failures/zero added. Suite remains non-green. |
| W2 Drive / Dropbox web upload | passing 0/10 | Metadata batch regression green:45 passed/0 failed/2 skipped. Real95cb087b failed0/1 in84.0s:14 reads/15.2s still outer-page incomplete/ambiguous; site/upload/Open/approval dispatches0. Identity retired/no replay; test-window close unknown after CUA timeout. Prior fec2c1fe0/10 and2d08e3d7 timeout420s show the same AX discovery limitation. Dropbox owner sign-in pending. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused and unrouted by A6: sync work committed behind computerUseV2; acceptance disabled. |

A1 ≤1-day redesign completed: generic web-upload outer discovery batches the same four pre-pruning attributes; children/content, deadlines, fresh authority and standard Gmail remain unchanged. Focused regression45 passed/0 failed/2 skipped; real Drive95cb087b still failed before upload. No more AX patches proposed.
The ≤30-minute live experiment completed in84.0s with14 readiness reads/15.2s and zero site/upload/Open/approval dispatches. Retire95cb087b without replay; preserve unknown2d08e3d7 effects and unknown test-window close. Full suite attempted once before this checkpoint:30min timeout,3,374 completed/148 baseline failures/two legacy OSAtlas crashes; complete comparison unavailable. Owned test processes exited.
Next proposal needs an A6 order decision: advance Safari W4 before W2/W3, first prove a read-only task/tab/document-bound bridge, then add upload operations and rerun unchanged acceptance. No bridge implementation until owner agrees; Rule7, credentials, frozen Apple Mail, paused OS work and model-evaluation limits stay unchanged.
