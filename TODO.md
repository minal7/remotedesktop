[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | in progress | Latest batch 1/10, median 126.3 s: recovery `3e66e5c1` passed; `4685d30e` paused while its picker opened. Bounded fresh-scope recovery is implemented, compiled and focused-tested; ten distinct exact saved drafts and three Send-approval stops remain pending. Keep ambiguous `33a403d0` quarantined. |
| Build / regression checkpoint | in progress | Compiled/tested: full `w1-account-full-20261010-042627`, 3,120 passed /155 failed /371 skipped in 1,038.3 s; exact baseline failure set, no added failures. Final settling checks 12/12 passed (`w1-account-settling-scope-green-20261010-042446`); broader Safari/Gmail/picker checks 141 passed /0 failed /20 skipped. Full suite remains non-green due to the recorded baseline. Raw traces stay outside Git, capped at 20 runs. |
| W2 Drive / Dropbox web upload | not started | After W1; reuse its picker and signed-in test accounts. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused by A6: sync work committed behind computerUseV2, unrouted; acceptance disabled. |

A1 bounded repair (≤1 day): the picker inventory read was healthy with and without the sheet (65 windows; whole reads 24–40 ms; slices at most 28 ms), so no paging or timeout change is warranted.
During post-action settling, allow a transient scope-read failure after an initially valid sample to be revalidated within the existing deadline; restart editor sampling and the quiet interval only from fresh authority.
Never reuse cached scope, replay the original effect, or relax per-action checks. Preserve the verified draft recovery URL and recipient/Send gates; OS-level acceptance remains paused under A6.
