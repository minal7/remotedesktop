[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | in progress | Primary Safari AX inbox navigation passed 1/1. Gmail gate stopped before its first action: 0/1 attempted, 10 planned; no new draft or attachment. A real UserNotificationCenter modal covers Safari. Owner must finish or dismiss it before live testing resumes. |
| W2 Drive / Dropbox web upload | not started | After W1; reuse its picker, use signed-in test accounts. |
| W3 Flights | not started | After W2; read-only search/extraction with no approvals. Historical baseline requested an unnecessary approval. |
| W4 Safari / Chrome DOM bridge | not started | After W3; migrate W1–W3 without changing their acceptance gates. |
| W5 General web tasks | not started | 20 WebTailBench tasks after the bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 send-approval stops. Keep its tests passing. |
| Sync-folder copy / native apps | paused | Committed behind computerUseV2; not advertised or routed; acceptance disabled by A6. |

A1 bounded fix (≤30 minutes): review found the navigation URL latch was set before focus-only checks, preventing safe Resume after a conclusively pre-write failure.
Move it immediately before the AX destination write; keep uncertain-write/Return no-replay behaviour and preserve Send/secure-field rules.
Both retry cases now pass in the injected test. Focused checks and the complete host regression are recorded below; live Gmail remains paused for the owner-only modal.

Current source checkpoint:
- Account routing committed as `cc4a3b5`: multiple signed-in accounts use the existing choice UI; only an explicit choice stores a preference. Both production constructors require the selected account, and fresh account proof precedes actions.
- Primary navigation uses the observed Safari chrome field, exact value readback, guarded Return and the retained signed window. No AppleEvent or Automation-consent fallback remains in this path. Native inbox probe `w1-account-nav-probe-20261009-010415` passed 1/1, including repeat-URL rejection.
- Latest focused checks `w1-account-nav-focused-20261009-012150`: 25 passed / 0 failed / 2 skipped, 27.6 s. This includes the pre-write retry and uncertain-write no-replay cases.
- Complete host regression `w1-account-full-20261009-012232`: 3,062 passed / 155 failed / 367 skipped, 872.1 s. Exact comparison with the cc4a3b5 baseline found 0 added failures; its prior WebKit teardown failure passed. No failures are in Gmail, Apple Mail, default-browser session, acceptance-harness, MCP-first or mobile-initiation classes. The remaining 155 existing research/form/legacy/license failures mean the full suite is not green. A compact exact-ID baseline is outside Git at `~/Library/Application Support/RemoteDesktopHost/Traces/host-test-checkpoint-baseline.json`.
- Full run `w1-account-full-20261009-011536` was interrupted after 95 s to include the retry repair; it is not a baseline.

Owner-only stop, class `guard-rejected`: production capture correctly rejects the real system modal above Safari (PID 46605, layer 8, bounds 734/202/260/346). The sanitized probe independently observed the overlap; no screen guard was changed. Computer Use previously rejected UserNotificationCenter for safety. The owner question to finish or dismiss the dialog is pending. No credentials, new draft or attachment were entered.
Three example traces under `~/Library/Application Support/RemoteDesktopHost/Traces/`:
- `m0-acceptance-gmail-20261009T080516Z-6278c748/outcome.json` — Gmail stopped before any action (the old harness labelled all handoffs approval-needed; that classification is corrected in the current patch).
- `w1-account-nav-probe-20261009-011412/navigation.json` — independent AX/CG overlap evidence and production visualSurfaceObscured; inbox navigation itself passed, 16.8 s.
- `w1-focused-20261008-224819/host.xcresult` — earlier system consent experiment timed out. No consent bypass was attempted.

Known limitations: W1 remains unaccepted. Production navigation currently supports Safari. Native account-menu discovery, chained account/recipient clarification and the complete attachment picker still need live proof. Missing Gmail AX targets hand off; the bounded Fara fallback is pending. Acceptance must still prove exact Drafts fields and attachment name/size 10/10, then 3/3 Send approval stops. Raw traces remain outside Git, capped at 20 task-created run directories. Optional cloud planning stays off by default; no new model evaluations or paused OS acceptance runs.
