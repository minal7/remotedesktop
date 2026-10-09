[Controlling agent brief](</Users/michael/Documents/ChatGPT/remote desktop/docs/computer-use-review/agent-brief.md>) — Amendment A6: web first.

| Job | Status | Blocker |
| --- | --- | --- |
| W1 Gmail with attachment | in progress | Host-owned compose/picker, contact/account choices and remembered account routing compile. Latest focused check: 292 unique passed / 45 skipped. Native account-reader probe remains unverified because its foreground check sees Finder; no composer was opened. A3 live gate remains 0/1 before compose. Safari Automation consent is the owner-only acceptance blocker. |
| W2 Drive / Dropbox web upload | not started | Reuse W1 picker; test accounts must already be signed in. |
| W3 Flights | not started | Read-only host search/extraction; historical baseline stopped at unnecessary approval. |
| W4 Safari / Chrome DOM bridge | not started | Follows passing W1–W3. |
| W5 General web tasks | not started | 20 WebTailBench tasks after bridge. |
| M4 Away | not started | After W5; physical iPhone on cellular required. |
| Apple Mail | passing 10/10 | Frozen; historical 3/3 send-approval checks. |
| Sync-folder copy / native apps | paused | Paused by A6; copy retained behind computerUseV2, not advertised or routed; acceptance disabled. |

A1 redesign (≤1 day): replace Gmail's model action loop with a host-controlled compose/picker workflow.
Verify exact prefilled fields and attachment before completion; preserve existing Send approval and secure-field rules.
Run focused checks, then one real Gmail task before the 10-run gate; hand off authentication without entering credentials.

A1 bounded redesign (≤1 day): one typed extraction includes the file's metadata query; host lookup and existing choices resolve it before opening the picker.
Reuse an exact existing attachment and one owned draft on retry; reject duplicate attachments and extra recipients.
Probe Gmail's observed recipient menu for exact address proof, then run the live draft gate without typed field input.

A1 experiment (≤30 minutes): Gmail's collapsed recipient has variable AX wrappers, so the direct Subject-parent lookup fails.
Search bounded Subject ancestors inside the unique composer, require one observed recipient chip, and preserve exact menu-address checks.
Verify the existing draft accepts its real recipient and rejects a wrong address before running the live attachment gate.

A1 redesign (≤1 day): the first live Gmail run stopped at address-bar text verification after Safari changed its window title.
Navigate the host-approved URL in the retained browser tab through a scoped native browser API, preserving typing and Send guards.
Run a bounded in-place navigation experiment, then repeat the fail-fast real Gmail gate using the same fixture and owned draft.

A1 experiment (≤30 minutes): several Safari windows share the retained window's bounds, so unique geometry cannot identify the native window.
Use CGWindow's documented front-to-back order, then require matching retained AX focus and Safari's exact front-window ID before and after navigation.
Reject a differently placed front window and rerun the same-window, no-compose navigation probe before the Gmail gate.

A1 experiment (≤30 minutes): Safari's native call times out even with the Automation switch enabled; it has made no draft.
Check the permission status before dispatch and distinguish a known denial from an uncertain browser result; only known denial allows retry after Resume.
If permission is granted, test the same fixed browser call through a bounded asynchronous runner rather than changing text or Send guards.

Owner-action stop: W1 browser navigation cannot proceed without the test build's Safari Automation consent; no acceptance draft or attachment was created.
Tried scoped native window mapping (fixed identical-bounds ambiguity), corrected AppleEvent arguments, enabled the visible Safari Automation switch, and checked the OS permission status. The OS still returned -1744 (consent required). A consent request timed out; the normal task path does not request or wait on the modal.
Computer Use rejects the UserNotificationCenter consent app for safety reasons. Owner must accept the Safari Automation prompt when a consent experiment is restarted; no sign-in or credentials are needed. W2–W5 remain pending behind W1.
Example traces (outside Git):
- `/Users/michael/Library/Application Support/RemoteDesktopHost/Traces/w1-focused-20261008-224229/navigation.json` — Safari call timed out before navigation.
- `/Users/michael/Library/Application Support/RemoteDesktopHost/Traces/w1-focused-20261008-224644/navigation.json` — explicit permission status -1744, no dispatch.
- `/Users/michael/Library/Application Support/RemoteDesktopHost/Traces/w1-focused-20261008-224819/host.xcresult` — consent request exceeded test deadline.

Focused verification: `w1-focused-20261008-232304` — 526 passed, 109 skipped, one stale Apple Mail prompt. Corrected that prompt; `w1-focused-20261008-233025` passed it and the new missing-extractor test (2/2). This gives 528 unique passing checks with 109 skips. The 25 Python harness checks also pass. Contact-choice mapping is component-tested and its continuation reviewed; live Gmail acceptance remains required.

A1 bounded redesign (≤1 day): ambiguous Gmail Contacts matches currently repeat a handoff instead of consuming a user choice.
Reuse the existing typed clarification and retained-task lifecycle; show name/address choices and bind the selected address to this Gmail setup.
Verify exact selection and stale-choice rejection without inference; keep live Gmail stopped for the owner-only Safari consent step. Multi-account preference selection was subsequently implemented below; real-site continuation remains unverified.

A1 bounded fix (≤30 minutes): the full suite found Gmail's initial navigation stage also intercepted ordinary browser jobs.
Require an active Gmail setup/job before that stage; align native Mail test prompts with A6's explicit-Apple-Mail routing.
Rerun the affected browser/Mail integration checks, then the full suite once before checkpointing. Initial full run: 2,984 passed / 216 failed / 365 skipped; trace `w1-host-regression-20261008-230013`.

Checkpoint full regression: `w1-host-regression-20261008-233109` — 3,049 passed / 155 failed / 365 skipped, 787.9 s. Resolved all 61 failing IDs in browser-session, native-text integration, MCP-first and mobile-initiation classes from this turn's first full run; no added failing IDs. Remaining failures are in browser research, legacy model and license tests. The older baseline recorded 154 failures, but its IDs were pruned, so equivalence to that baseline is unverified. A compact exact-ID baseline is retained at `~/Library/Application Support/RemoteDesktopHost/Traces/host-test-checkpoint-baseline.json` for future comparisons. This is a source checkpoint, not W1 acceptance.

Known W1 limitations: native URL navigation currently supports Safari; account preference selection is now implemented and component-tested; native menu discovery and chained clarification await real-site proof; a missing Gmail AX target hands off rather than using the pending single-step Fara fallback. Mixed unresolved recipient lists ask for exact addresses. No new inference or real-site run was started while consent was pending.

A1 experiment (≤30 minutes): inspect the signed-in test Gmail account menu to ground account selection in actual page accessibility data.
Use no composer, model inference, credentials or consent-dialog access; keep the production acceptance gate stopped.
If the page exposes bounded signed-in account choices, reuse the existing phone choice contract and remember the selected account; otherwise report the observed limitation.

A1 bounded redesign (≤1 day): the observed Gmail account menu contains two signed-in accounts and separate signed-out entries.
Select only bounded account entries from that menu, ask through the existing choice contract when needed, and remember the selected address.
Bind compose verification to that account; exclude sign-in/add-account links and keep live acceptance stopped for Safari consent.

A1 bounded compiler fix (≤30 minutes): the account-selection patch exposed initializer actor isolation and closure-scope errors.
Resolve the optional injected preference once inside the main-actor initializer and bind account clarification IDs to the retained root task.
Compile focused checks before any probe; no inference, live compose or permission request is enabled.

A1 experiment (≤30 minutes): the read-only account probe stopped before discovery because its test host displaced the default browser's foreground window.
Wait at most 20 seconds in the opt-in probe for Computer Use to reactivate the already-open Gmail window; record only browser/foreground metadata.
Do not navigate, compose, enter credentials or request consent; ordinary tests still skip this probe.

W1 account checkpoint: selected-account identity now determines the compose route and is checked before actions, including picker dispatch and approved Send. Multiple signed-in accounts use the existing phone choice; only an explicit choice stores a preference. Signed-out/add-account/foreign links are excluded. A missing remembered account hands off. Both production job constructors require a selected account.
Focused verification: `w1-account-focused-20261009-000926` — 291 passed / 1 failed / 45 skipped. Corrected the observed account-link display-name suffix; `w1-account-fix-20261009-001542` — 20 passed / 0 failed / 2 skipped. Together: 292 unique passing focused checks. The account→recipient publication path is reviewed but lacks an executor-level/live continuation proof.
Read-only native probe remains unverified: the test process reports frontmost `com.apple.finder`, default `com.apple.Safari`, before entering account discovery. Computer Use opened/closed only the observed account menu, tried Raise, toolbar focus and the address-bar shortcut; no composer, attachment, credentials or consent prompt was opened. The test guard stays strict. Retry this verification in the retained production session after the owner-only consent step, rather than adding more probe machinery.
Three examples of the foreground-check failure (outside Git):
- `~/Library/Application Support/RemoteDesktopHost/Traces/w1-account-probe-20261009-001712/summary.json` — initial frontmost-window prerequisite absent.
- `~/Library/Application Support/RemoteDesktopHost/Traces/w1-account-probe-20261009-001844/summary.json` — bounded 20-second wait still saw Finder.
- `~/Library/Application Support/RemoteDesktopHost/Traces/w1-account-probe-20261009-002228/summary.json` — same prerequisite failure after Computer Use foreground attempts.
No additional A3 acceptance run was started. W2 onward remains pending in the requested order.

Account full regression: `w1-account-full-20261009-002334` — 3,056 passed / 156 failed / 366 skipped, 869.7 s. Exact comparison with the 9f286e1 baseline found the same 155 failing IDs plus one browser-DOM test reporting WebKit `InvalidTransition` during teardown. That added test passed its isolated rerun (`w1-account-retry-20261009-003823`, 1/1, 3.7 s); no source was changed for the rerun. The full suite is not green. Gmail/account checks have no failing IDs in this full run. This remains a source checkpoint, not W1 acceptance.

A1 experiment (≤30 minutes): inspect Safari's normal Accessibility address-field navigation as a primary host-owned path, avoiding an extra Automation permission dependency.
Require the retained signed browser/window, a unique writable nonsecure chrome field, a host-approved Gmail URL, guarded submission and fresh destination proof; never fall back from a denied AppleEvent.
Test navigation to the test Gmail inbox only, with no compose, inference, credentials or consent-dialog interaction; proceed to a ≤1-day redesign only if this bounded experiment succeeds.
