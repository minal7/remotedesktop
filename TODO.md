[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | passing 10/10 | Accepted: draft batch `215bfefb`→`91255b7b` independently reopened 10 distinct saved drafts with exact fields and one exact attachment name/size, median 132.2 s. Send batch `0bc93140`→`160e72ae`: 3/3 stopped at approval with exact review fields, median 75.4 s; zero Send approvals granted. Coordinate fix committed as `d923f79`. |
| Build / regression checkpoint | in progress | Compiled; page-reader47 tests:45 passed/0 failed/2 skipped in72.8s, including latency/pruning regression. Full w2-full-20261011-035745 timed out at1,800.1s after3,374 completed tests and two legacy OSAtlas array-index crashes; all148 observed failures match the fixed155-failure baseline, but complete comparison is unavailable. Last complete full:154 baseline failures/zero added. Suite remains non-green. |
| W2 Drive / Dropbox web upload | passing 0/10 | A1 native probe: 5fbe695d first inventory read 26 valid metadata batches, then invalidUIElement(-25202) at visited27/pages0/pending5; Safari supports batching. Run timed out420.0s without outcome; effects/counts unknown, identity retired/no replay. Earlier4c40b392 failed21.1s before probe on startup windows_read cannotComplete; all upload/Open/approval dispatches0. Temporary source probes removed exactly; owned test app/runtime stopped. Prior95cb087b0/1; Dropbox owner sign-in pending. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | A6 puts this after W3. Owner decision pending on bringing Safari bridge forward after repeated W2 AX failures; read-only first-slice proposal ready, no implementation. Keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused and unrouted by A6: sync work committed behind computerUseV2; acceptance disabled. |

A1 W2 redesign assessment completed read-only: focused-page ancestry could bypass defunct chrome, but would leave the observed native-picker parent-page failure unless the exact observation token and new unoccluded hit-test proof are threaded through both parent URL checks. Current live traces do not establish focus availability at readiness or visibility beneath the picker.
Reject this speculative cross-cutting slice for now: no source edits, builds or acceptance replays. Preserve complete page authority, exact account/URL, native panel parent identity and secure-field rules. No new recovery/cache architecture or deadline increases without evidence that it resolves the whole upload path.
The existing owner decision on moving Safari W4 ahead remains the next actionable step under A6. Drive stays0/10;5fbe695d timed out with unknown effects and is retired/no replay, all temporary probes removed; Dropbox sign-in remains owner action. The full suite remains non-green/incomplete against the unchanged baseline.
