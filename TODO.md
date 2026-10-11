[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | passing 10/10 | Accepted: draft batch `215bfefb`→`91255b7b` independently reopened 10 distinct saved drafts with exact fields and one exact attachment name/size, median 132.2 s. Send batch `0bc93140`→`160e72ae`: 3/3 stopped at approval with exact review fields, median 75.4 s; zero Send approvals granted. Coordinate fix committed as `d923f79`. |
| Build / regression checkpoint | in progress | Compiled; upload-focused `w2-upload-narrow-20261011-023603`:156 passed /0 failed /7 skipped in101.0s; Python launcher/checker60/60. Integrated negative launch stopped before task start and exited in4.1s. Full `w2-full-20261011-024410` timed out at1,800.1s after3,377 tests; all149 reported failures match the fixed155-failure baseline, but complete comparison is unavailable. Previous completed full `w2-full-20261010-205003`:3,164 passed /154 failed /372 skipped, zero added failures. Suite remains non-green. |
| W2 Drive / Dropbox web upload | passing 0/10 | Public10-run batch stopped at fec2c1fe:0/10 in79.0s; standalone driver exited normally and checker/summary recorded failure. Initial page outer discovery exceeded budget; zero upload/Open/approval counters. Exact031594EE window/account observed; close confirmation timed out, no blind retry. Prior b0fd8bfb reached picker (Open0), with previous-page/cold-control fixes live verified; parent retry is component-tested but not yet reached live. Dropbox owner sign-in pending. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused and unrouted by A6: sync work committed behind computerUseV2; acceptance disabled. |

A1 ≤30-minute next experiment: the shared window-lost class persists at AX page discovery; measure one retained Drive window's outer-tree read timing and completeness inside the signed host, with no input, before changing another deadline or guard. Preserve the normal product and checker paths.
Standalone Drive/Dropbox launch is integrated and live verified as driver-only; independent acceptance remains0/10. Gmail and Apple Mail keep their accepted paths. Unknown or failed identities are retired unchanged/no replay; unconfirmed windows are preserved until fresh identity proof.
The required full run ended incomplete at its30-minute cap; no complete baseline comparison or green-suite claim. Commit the focused-tested working step, then run and remove the temporary one-read timing probe. The experiment stays inside Rule7; no credentials, approvals, OS work or model evaluations.
