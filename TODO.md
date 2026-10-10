[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | in progress | Latest batch `69230bed` 0/10, median 159.3 s: recipient and native picker passed; correct attachment appeared, but its standalone static filename/size structure was rejected. Repair compiled and passed the focused checks (68 passed, 0 failed, 5 opt-in skipped). Fresh browser E2E paused while confirming Safari availability after unrelated navigation appeared. Failed test identities are preserved and excluded. The runner now rejects attempted identities lacking a proven opaque draft URL before another compose can open; W1 unaccepted. |
| Build / regression checkpoint | compiled / tested, baseline non-green | Standalone compose, native URL bridging and static attachment evidence have meaningful RED→GREEN coverage. Latest focused `105628`: 68 passed /0 failed /5 opt-in skipped. Full `w1-account-full-20261010-112305`: 3,134 passed /155 failed /372 skipped; exact immutable baseline failure set, 0 added failures. All 37 Python runner/checker tests passed (`112258`); the retry guard reproduced both unsafe cases in RED (`112019`). W1 acceptance remains pending; external traces capped at 20 runs. |
| W2 Drive / Dropbox web upload | not started | After W1; reuse its picker and signed-in test accounts. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused by A6: sync work committed behind computerUseV2, unrouted; acceptance disabled. |

A1 bounded repair (≤30-minute experiment): failed Gmail acceptance identities without a verified opaque draft URL currently reopen a new compose on retry, risking duplicate drafts observed during W1.
Grouped RED reproduced both unsafe cases (`112019`); the guard now preserves attempted session/staged fixture bytes and stops before browser effects without a proven retry URL. All 37 runner tests pass (`112258`), including fresh identities, URL-backed reuse and in-memory rotation; full regression adds 0 failures.
Keep exact independent draft/attachment/duplicate proof, Rule 7 and all quarantines unchanged. No automatic draft recreation, rotation, deletion, Send or credentials; fresh browser acceptance remains pending owner availability.
