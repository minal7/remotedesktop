[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | in progress | Fresh draft batch `215bfefb`→`91255b7b`: 10/10 exact independently reopened saved drafts, 10 distinct identities, median 132.2 s. Send-stop batch `b46bcf3e`: 0/3 (76.7 s); generic risky-click approval omitted the verified email review fields, and the harness denied it. Nothing sent; W1 remains unaccepted. |
| Build / regression checkpoint | compiled / tested, baseline non-green | Send coordinate binding reproduced the exact one-point mismatch in RED (`120958`). Focused `121708`: 72 passed /0 failed /5 opt-in skipped, including existing display mapping checks. Full `w1-account-full-20261010-121819`: 3,137 passed /154 failed /372 skipped; 0 added failures against the immutable 155-failure baseline (one historical failure passed this run). All 37 Python runner/checker tests passed (`112258`). W1 Send acceptance remains pending; external traces capped at 20 runs. |
| W2 Drive / Dropbox web upload | not started | After W1; reuse its picker and signed-in test accounts. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused by A6: sync work committed behind computerUseV2, unrouted; acceptance disabled. |

A1 bounded repair (≤1 day): the Send action reached approval safely, but its review fields did not bind because pending approval rounded the AX center while dispatch floored its normalized coordinate. The regression reproduced that exact one-point mismatch.
The pending approval now uses the validated dispatch coordinate mapper; the proposed click and draft lifecycle are unchanged. Focused checks passed, full regression added no failures; run fresh 3/3 Send stops and preserve the independently verified 10/10 draft evidence.
Keep Rule 7, exact action equality/fingerprints, fields, attachment and duplicate proof unchanged. No fuzzy action matching, Send approval, credentials or uncertain input replay; preserved identities and the unrelated Safari window stay untouched.
