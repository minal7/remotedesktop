[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | not accepted (latest batch 3/10) | Runs efbbd7d4, 810a8313, and 44c92438 passed; a502f354 stopped before Return after AX setValue returned an error, though the retained focused field showed the exact canonical URL. Ambiguous 33a403d0 token stays quarantined. |
| Build / regression checkpoint | compiled / tested | Full `w1-account-full-20261010-023553`: 3,117 passed /156 failed /371 skipped, 965.2 s. All 155 baseline failures remain; the extra unchanged `test_managerAuthenticationWithoutABrowserCannotSilentlyResume` failed on asynchronous status-message delivery and passed alone in `w1-account-handoff-regression-20261010-025259` (1/1, 10.4 s). Focused Safari/Gmail/typing: 134 passed /0 failed /20 skipped; fresh Gmail completion checks previously 62 passed /0 failed /4 skipped. Full suite is not green. Raw traces remain outside Git, capped at 20 runs. |
| W2 Drive / Dropbox web upload | not started | After W1; reuse its picker and signed-in test accounts. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused by A6: sync work committed behind computerUseV2, unrouted; acceptance disabled. |

A1 bounded repair (≤1 day): batch stopped at 3/10 when a502f354 reported an AX setter error although the retained focused address field contained the exact URL; no Return was sent.
The compiled repair uses fresh exact same-field/value readback after an attempted setter returns any status, retaining the window, focus, task, and gate checks; no setter replay or typing fallback. Error-with-no-effect, error-after-effect, cancellation, and gate-loss cases pass.
Retry the ten distinct saved-draft cases, then three Send-approval stops. W1 stays unaccepted until both pass. Send/fingerprint authority and paused OS-level acceptance remain unchanged.
