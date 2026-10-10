[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | in progress | Latest batch 2/10 (`b779ca1a`, median 156.9 s): two independently reopened exact saved drafts passed; case 3 model omitted two subject characters and the attachment guard denied it. Previous batch 5/10, median 204.5 s. W1 unaccepted; `33a403d0` and the mismatched `147b3ba4` retry record are quarantined. |
| Build / regression checkpoint | in progress | Focus-wait/shared bounds-read/pre-write fingerprint recovery: meaningful RED (`073341`), then 2/2 GREEN (`074029`). Independent row oracle: 21 passed /0 failed /3 opt-in skipped (`075851`). Quoted-literal reference repair: meaningful RED (`081415`), then 62 passed /0 failed /4 opt-in skipped (`082208`), including subject-bound recovery metadata. All 35 Python checker tests passed. Full `w1-account-full-20261010-082341`: 3,128 passed /155 failed /371 skipped, exact baseline failure set with 0 added failures. Full suite remains non-green. Raw traces stay outside Git, capped at 20 runs. |
| W2 Drive / Dropbox web upload | not started | After W1; reuse its picker and signed-in test accounts. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused by A6: sync work committed behind computerUseV2, unrouted; acceptance disabled. |

A1 bounded repair (≤1 day): case 3 in `b779ca1a` proves model content extraction mutated the quoted subject before compose; the independent attachment guard stopped the action. Preserve the wrong draft, and quarantine its retry record after an exact requested-token search proves no matching draft.
Let the model select task-local quoted-source references for subject/body/filename fragments; the host resolves original bytes and rejects mutated text before effects. Persist recovery bookmarks only when the product-verified subject byte-matches the expected subject. Focused checks passed and full regression added 0 failures; commit, then run a fresh 10-draft batch and 3 Send stops.
Keep all independent saved-URL, exact fields/attachment and duplicate requirements, Rule 7, account/window binding, and both quarantines unchanged. No Send, credential entry, uncertain input replay, or acceptance relaxation.
