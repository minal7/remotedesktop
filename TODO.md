[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | in progress | Exact file approval, native selection and upload now work on real Gmail; ce15cb68 independently verified and granted one fixture attachment, with zero Send responses. Gmail visibly shows the exact filename as an AXLink ending in (3K), but product verification expects differently formatted static text and reports a conflict (0/1 of 10, 109.8 s). Focused checks: 74 passed / 0 failed / 3 skipped; runner checks: 26 passed. Fix attachment display recognition and saved-draft capture; exact drafts 10/10 and Send stops 3/3 pending. |
| Build / regression checkpoint | in progress | Build compiles. Full `w1-account-full-20261009-144109`: 3,064 passed / 175 failed / 367 skipped, 808.2 s; 155 baseline failures plus 20 Session failures around live recognition of synthetic screens. Isolated Session/Gmail/Core/Executor rerun: 105 passed / 0 failed / 17 skipped, 162.6 s; modal checks: 74 passed / 0 failed / 3 skipped; runner checks: 26 passed. Isolate synthetic fixtures from live OCR before the next full checkpoint. Full suite is not green; stable 155-failure baseline and raw traces remain outside Git, capped at 20 runs. |
| W2 Drive / Dropbox web upload | not started | After W1; reuse its picker and signed-in test accounts. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused by A6: sync work committed behind computerUseV2, unrouted; acceptance disabled. |

A1 bounded redesign (≤1 day): ce15cb68 attached the exact fixture; the product rejects Gmail's actual AXLink filename/rounded (3K) display, and the independent page capture is incomplete.
Recognize one exact attachment using Gmail's exposed link/container and size display; capture only the unique compose region for independent saved-draft proof. Never infer exact bytes from a rounded label.
First run the full regression checkpoint and commit current work, then focused tests and real Gmail. Preserve source hash/size, account proof, duplicate rejection, one file grant and zero Send responses.
