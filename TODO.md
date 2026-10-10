[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | passing 10/10 | Accepted: draft batch `215bfefb`→`91255b7b` independently reopened 10 distinct saved drafts with exact fields and one exact attachment name/size, median 132.2 s. Send batch `0bc93140`→`160e72ae`: 3/3 stopped at approval with exact review fields, median 75.4 s; zero Send approvals granted. Coordinate fix committed as `d923f79`. |
| Build / regression checkpoint | compiled / tested, baseline non-green | W2 full `w2-full-20261010-152910`: 3,152 passed /155 failed /372 skipped in 1,138.7 s; all 155 failures match the immutable baseline, 0 added. Focused W2: 204 broad checks and 127 follow-up checks passed; 52 Python runner/checker tests passed. W1 remains accepted; external traces capped at 20 runs. |
| W2 Drive / Dropbox web upload | in progress | Compiled: 204 broad focused Swift checks passed; latest W2 follow-up 127 passed; 52 Python runner/checker tests passed. Fixed the observed 32-item scan caps. Real retry `698842d2` hit Safari AXWindows cannotComplete after navigation, before any upload approval or dispatch. No product upload accepted. Dropbox: owner sign-in pending; credentials untouched. |
| W3 Flights | not started | After W2; read-only search/extraction, no approvals. |
| W4 Safari / Chrome DOM bridge | not started | After W3; keep W1–W3 acceptance gates unchanged. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 Send-approval stops. Keep tests green. |
| Sync-folder copy / native apps | in progress | Paused by A6: sync work committed behind computerUseV2, unrouted; acceptance disabled. |

A1 ≤30-minute next step: investigate the retained AXWindows cannotComplete timeout after navigation; preserve exact membership/focus/PID/code/sheet checks and Rule 7.
The item-cap repair passed focused checks and the full host run added zero baseline failures. Commit this checkpoint, then test the bounded native-read repair and fresh pre-upload progress guard before retrying the same zero-effect source.
No product upload is accepted; Drive sizes above 1 MiB and named-folder coverage remain unaccepted. Dropbox sign-in stays owner-only.
