[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | passing 10/10 | Accepted: draft batch `215bfefb`→`91255b7b` independently reopened 10 distinct saved drafts with exact fields and one exact attachment name/size, median 132.2 s. Send batch `0bc93140`→`160e72ae`: 3/3 stopped at approval with exact review fields, median 75.4 s; zero Send approvals granted. Coordinate fix committed as `d923f79`. |
| Build / regression checkpoint | compiled / tested, baseline non-green | Send coordinate binding reproduced the exact one-point mismatch in RED (`120958`). Focused `121708`: 72 passed /0 failed /5 opt-in skipped, including existing display mapping checks. Full `w1-account-full-20261010-121819`: 3,137 passed /154 failed /372 skipped; 0 added failures against the immutable 155-failure baseline (one historical failure passed this run). All 37 Python runner/checker tests passed (`112258`). W1 accepted; external traces capped at 20 runs. |
| W2 Drive / Dropbox web upload | in progress | Reuse W1 picker and signed-in test accounts; add provider controls and exact unique listing-row name/size/completion proof. No website upload acceptance run yet. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused by A6: sync work committed behind computerUseV2, unrouted; acceptance disabled. |

A1 bounded W2 experiment (≤30 min) and implementation (≤1 day): inspect the signed-in provider pages read-only, then reuse the existing local file catalog and W1 native picker for narrow Drive/Dropbox upload jobs; no new model harness.
Add focused tests for typed file/folder arguments, one upload dispatch, verify-only uncertain resume and exact unique same-row filename/size/completion; then run one real workflow before each provider's 10-run gate. Rotate fixture identities only after verified success.
Keep Rule 7, exact approvals/fingerprints, secure fields and unrelated windows unchanged. Use only test accounts; hand off sign-in/2FA/CAPTCHA, ambiguity and preexisting filename collisions; never enter credentials or replay an uncertain upload.
