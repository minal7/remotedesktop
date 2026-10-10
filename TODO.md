[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | passing 2/10 | Latest batch c1529216 +6eefa368 passed exact saved drafts (227.7 s /228.0 s); 0799407f stopped at AX address readback before Return or composer (65.1 s). Scoped AX write and bounded readback compiled/tested; native Inbox→Drafts probe passed in 32.0 s. Startup window replacement remains under investigation; ambiguous 33a403d0 token stays quarantined. Need 10 distinct exact drafts +3 Send stops. |
| Build / regression checkpoint | compiled / tested | Full `w1-account-full-20261009-235641`: 3,111 passed /155 failed /371 skipped, 940.6 s; exact unchanged external 155-failure baseline, zero added/removed failing tests. Focused Safari/Gmail/typing checks: 127 passed /0 failed /20 skipped; native read-only probe 235533 passed. Full suite is not green. Raw traces remain outside Git, capped at 20 runs. |
| W2 Drive / Dropbox web upload | not started | After W1; reuse its picker and signed-in test accounts. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused by A6: sync work committed behind computerUseV2, unrouted; acceptance disabled. |

A1 bounded redesign (≤1 day): replace only the verified Safari address-entry actuator with one scoped AXValue write through the existing fingerprint/effect boundary; exact readback remains required before Return. TDD covers one write, changed authority→zero writes, uncertain/partial writes→no fallback/retry/Return, and delayed readback. Generic typing, credentials and rule-7 semantics stay unchanged.
Latest batch: c1529216 and 6eefa368 passed (227.7 s /228.0 s); 0799407f failed after one AX write at readback (65.1 s). After the run stopped, root observed the expected address value in the retained Safari field. Whether this is transient AX read delay remains unproven; no Return or composer was opened.
Bound exact same-field readback to 2 seconds with fresh task/gate/window/field/focus checks on each observation. Distinguish finite payload-free field, focus, value, scope, and deadline failures; never repeat the setter or dispatch Return without exact value proof. Then focused checks and one canonical Inbox/Drafts host probe before fresh compose; compare full regression baseline once before commit. W1 requires 10 distinct exact drafts +3 Send stops; no Send/OS-level acceptance.
