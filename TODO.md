[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | in progress | Latest batch 0/10, 125.7 s: `167f42b3` navigated successfully, opened Attach files, then paused with the native picker visible before file selection. Saved draft retained for retry; no attachment/Send approval granted. W1 remains unaccepted. Keep ambiguous `33a403d0` quarantined. |
| Build / regression checkpoint | in progress | Navigation/startup repair compiled and tested: focused 82 passed /0 failed /16 skipped, grouped post-write and baseline-window omission checks 1/1 each, real Safari navigation 1/1. Full `w1-account-full-20261010-061413`: 3,124 passed /155 failed /371 skipped; exact baseline failure set, 0 added failures. Full suite remains non-green due to that baseline. Raw traces stay outside Git, capped at 20 runs. |
| W2 Drive / Dropbox web upload | not started | After W1; reuse its picker and signed-in test accounts. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused by A6: sync work committed behind computerUseV2, unrouted; acceptance disabled. |

A1 bounded experiment (≤30 minutes): Gmail `167f42b3` reached the native picker, then paused with Session validation complete and no file approval; the existing report omits three post-action recovery deadline phases.
Commit the verified navigation/startup repairs after the full checkpoint. Then expose only those existing finite phases, run the focused sanitizer test, and retry the retained saved draft through the harness to identify the failing transition before changing behavior.
Never repeat the Attach click on uncertain completion or manually reuse a cached draft URL. Keep current retry identity, quarantine `33a403d0`, Rule 7 and Send approvals unchanged; OS work stays paused.
