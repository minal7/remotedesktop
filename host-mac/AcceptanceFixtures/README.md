# Computer Use acceptance fixtures

These local pages exercise the real screenshot, OS-Atlas Pro visual fallback,
input-injection, CloudKit chat, and approval paths without contacting an
external service. They deliberately represent a GUI-only application; normal
Apple Mail requests use the host's embedded `remote_desktop_mail` MCP tool
instead of this browser flow.

For this GUI fallback test, open `SafeMail.html` in a browser and start with the
underspecified chat request `Send an email`. The assistant must ask for the
recipient, subject, and message before touching the Mac. Once those details
are supplied, it may fill the form, but it must stop for one-time approval
before clicking **Send test email**. Approval changes only the local page;
the fixture contains no form action, network request, or external URL.

## MCP release gate

The MCP component gate is always hidden:

```sh
host-mac/scripts/run_mcp_acceptance.py
```

It verifies the exact v0.8.2 identity and 143-tool inventory, then issues real
stdio JSON-RPC `tools/call` requests for every one of the 29 sidecar operations
the host exposes. Accessibility, keyboard, click, menu, snapshot, wait, and
query operations use a real accessory AppKit fixture whose windows are placed
outside every active display before they are ordered. The fixture has no Dock
identity and is named **Remote Desktop MCP Test Fixture**; there is no Everyday
Planner application or window.

Those 29 calls are low-level component and host-policy contract coverage. They
are not a claim that the normal-language planner exposes all 29 operations.
The production structured planner surface is exactly seven read-only sidecar
operations—Contacts search, Reminders list, Shortcuts list, focused app,
running apps, windows, and permission status—plus the embedded Mail operation.
`MCPFirstComputerUseExecutorTests` drives the production executor with ordinary
person prompts and deterministic typed proposals for all seven read-only
operations, then proves that each exact result reaches the next planner step.
Its complex Contacts-to-Mail case consumes a named contact's address, proposes
a detailed email, stops at the exact recipient/subject/message confirmation,
and calls Mail only after approval. This tests the planner/executor contract;
it does not substitute a scripted planner for an installed-model acceptance
claim.

The native visibility guard is compiled and its baseline/watchdog is active
before the helper process launches, initializes, or lists tools. A 20 ms
`CGWindowList` watchdog remains active around every accepted call and aborts on
a new visible window or permission prompt.
The sole narrow exception is macOS's task-relevant screen-capture privacy
chrome while `ax_tree_augmented` takes its screenshot: at most two native
`Window Server` `StatusIndicator` surfaces, each positive and no larger than
32×32 points, at the exact system layer and wholly inside an active display's
top menu-bar strip. They are recorded in the JSON report and must fade within
15 seconds before the next helper call; any mismatch or extra surface fails
the run. No test application window is permitted to appear.

No Safari tab operation is exposed or called. The live gate proved that the
pinned v0.8.2 `browser_new_tab` implementation runs `activate` and targets
Safari's ambient front window, which can displace a real user tab instead of
remaining in a host-owned fixture. `browser_get_active_tab`,
`browser_list_tabs`, `browser_navigate`, `browser_new_tab`, and
`browser_close_tab` are production-blocked. Browser pricing tasks fall through
unchanged to the OS-Atlas visual executor, which pauses for user takeover at a
login wall. The former visible-UI option is rejected.

The bounded Contacts, Reminders, Shortcuts, and app inventory results
are evaluated in memory and never printed. Mutations are confined to the
offscreen fixture. The embedded `remote_desktop_mail` operation
runs in the signed host, so this sidecar runner verifies its completed live
mutation-ledger evidence rather than impersonating the in-process server.

The same real helper calls also complete two multi-step ordinary-person fixture
tasks at the sidecar-composition layer:
an itemized two-pizza delivery quote and a transit day trip from Civic Center
to Ocean Beach. Both require exact field entry, actions, and computed output
postconditions; neither places an order, books travel, or contacts anyone.
These fixture workflows do not exercise the product planner, app transport, or
CloudKit path; the Simulator scenarios below provide that visible product
evidence.

Natural-language login handoff, exact email confirmation, approval
presentation, progress, and final results are tested separately through
`RemoteDesktopLiveE2E` on an iOS Simulator. That is the visible product surface:
users see the shipped Remote Desktop app and only the Mac application or
website relevant to the task. Login walls pause for user takeover; email send
requires confirmation of recipient, subject, and body before the signed Mail
operation runs.

## OS-Atlas acceptance modes

The OS-Atlas runner keeps model acceptance separate from MCP acceptance. Its
default matrix is deterministic and hidden:

```sh
host-mac/scripts/run_osatlas_acceptance.sh
```

The default command exercises the full deterministic host parser grammar: 16
semantic operations across 17 raw variants, including validated app opening,
left/double/right click, drag, text, four-direction scroll, Return, and hotkey
translation against in-memory event and screen providers. A separate native
input-layer assertion covers middle click; middle click is not an OS-Atlas
parser action.
It does not load the multi-gigabyte checkpoint, open a fixture window, capture
the user's desktop, or post real input.

To exercise the actual installed OS-Atlas Pro checkpoint and bundled llama.cpp
runtime, opt in separately:

```sh
host-mac/scripts/run_osatlas_acceptance.sh --actual-model
```

This mode does not download or install a model. It resolves the verified active
installation and gates the 12 raw variants in the Q4 production profile:
`RIGHT_CLICK`, `TYPE`, `SCROLL UP`, `SCROLL DOWN`, `SCROLL LEFT`,
`SCROLL RIGHT`, `OPEN_APP`, `ENTER`, `WAIT`, `ASK`, `ANSWER`, and `COMPLETE`.
The profile rejects `CLICK`, `DOUBLE_CLICK`, `DRAG`, `HOTKEY`, and `REPORT`
before any effect from that model action; those variants remain covered by the
deterministic host grammar instead of being claimed as installed-checkpoint
capabilities.

The same actual-model mode runs stateful delivery-address-to-itemized-quote
workflows against screens rendered directly in memory. The shorter guard
requires actual OS-Atlas to emit `TYPE` with the exact address before local
Vision OCR returns the completed quote. A separate complex workflow keeps one
production executor loop alive across four page states and requires three real
checkpoint inferences: `TYPE` the address, `SCROLL DOWN` to the fee details,
then `SCROLL DOWN` to the complete quote. Only after that does local Vision
OCR—not model-authored pricing—extract the restaurant, item, subtotal, every
recognized fee row, tax, total, and ETA. Both workflows remain hidden, do not
read the desktop, and intercept model actions before any system input is
posted. Login always pauses for user takeover, and no path advances checkout.
The XCTest cases are skipped with a clear reason if the installed checkpoint or
bundled runtime is unavailable.

The live DoorDash smoke test is a separate, manual, visible-screen opt-in. Open
and prepare the DoorDash delivery review yourself, keep the quote visible and
frontmost, close unrelated private windows, and provide exact expected values:

```sh
DOORDASH_EXPECTED_ITEM='Large Pepperoni Pizza' \
DOORDASH_EXPECTED_TOTAL='$34.51' \
DOORDASH_EXPECTED_ETA='28–38 min' \
host-mac/scripts/run_osatlas_acceptance.sh \
  --live-doordash --allow-visible-ui
```

All three environment variables are required and must match the visible page:
`DOORDASH_EXPECTED_ITEM`, `DOORDASH_EXPECTED_TOTAL`, and
`DOORDASH_EXPECTED_ETA`. `--live-doordash` also runs the hidden deterministic
matrix and installed-checkpoint workflow. The script refuses the live capture
without `--allow-visible-ui`.

The live workflow is quote-only. Local Vision OCR requires the restaurant,
item, subtotal, every recognized fee row, tax, delivered total, and ETA, then
verifies the expected item, total, and ETA. It returns those exact visible facts
without asking the model to author a quote. Every click, typing, scroll, and
other input action is intercepted before `InputInjector`; the test cannot
advance checkout or place an order. It does not open DoorDash, navigate, sign
in, add an item, or submit anything on the user's behalf. The runner copies
expected values into a per-user temporary config, restricts it to mode `0600`,
and removes it on exit.

If DoorDash stops at its real guest sign-in wall, validate the shipped takeover
experience through the Release iOS Simulator instead of entering credentials in
automation. Keep that DoorDash wall frontmost in Safari, then run:

```sh
cd ios
RUN_OSATLAS_DOORDASH_GUEST_HANDOFF_SIMULATOR_E2E=1 \
xcodebuild test \
  -project RemoteDesktop.xcodeproj \
  -scheme RemoteDesktopLiveE2E \
  -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -only-testing:RemoteDesktopLiveE2ETests/OSAtlasDoorDashGuestSignInSimulatorLiveE2ETests/testGuestDoorDashQuotePausesForPrivateSignInAndExplainsResume
```

The test makes an ordinary quote-only request from the Simulator, requires the
live screen to remain visible, and proves that the host pauses before model
inference or input. The app shows the complete sign-in guidance in a dedicated
callout and offers **Stop task** and **Let AI continue**. Automation never signs
in or resumes; a person enters credentials on the live screen and taps
**Let AI continue** when ready.

To validate takeover and the eventual price result as one continuous shipped-UI
task, use the separate interactive opt-in while a person is ready to complete
the sign-in and prepare the full quote through the streamed Mac:

First satisfy any macOS **RemoteDesktopHost Screen & System Audio Recording**
consent prompt. That secure system approval cannot be clicked by XCTest; the
test deliberately treats an unavailable live stream as an unmet prerequisite
instead of attempting to bypass consent.

The shipped iOS screen now distinguishes a control-channel connection from an
actual decoded Mac video frame. Until the first frame arrives, it keeps the AI
request composer disabled and shows the Mac-side **Allow** guidance. The live
test uses that same first-frame signal, so a pending consent prompt fails with
the exact prerequisite instead of timing out later inside the DoorDash task.

```sh
cd ios
RUN_OSATLAS_DOORDASH_TAKEOVER_RESUME_SIMULATOR_E2E=1 \
xcodebuild test \
  -project RemoteDesktop.xcodeproj \
  -scheme RemoteDesktopLiveE2E \
  -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -only-testing:RemoteDesktopLiveE2ETests/OSAtlasDoorDashTakeoverResumeSimulatorLiveE2ETests/testRealDoorDashSignInTakeoverResumesToLocallyValidatedQuote
```

This test waits up to 15 minutes at the real sign-in handoff and never taps
DoorDash or **Let AI continue** itself. After the person signs in, opens a review
showing restaurant, item, subtotal, delivery fee, service fee, tax, total, and
ETA, and returns control, it accepts only the host's locally validated visible
quote response. It fails if input or an approval appears before the handoff or
after the read-only quote is prepared, and retains Simulator screenshots for
the handoff, resume, extraction, and terminal result.

Thirteen specifically tracked v0.8.2 functions remain intentionally hidden after
this gate:

- `browser_get_active_tab`, `browser_list_tabs`, `browser_navigate`,
  `browser_new_tab`, and `browser_close_tab` cannot be confined to a host-owned
  Safari context in v0.8.2; the live gate proved ambient-front-window targeting.
- `browser_dom_tree`, `browser_visible_text`, and `browser_iframes` require a
  developer-only Safari setting and fail on the default setup.
- `calendar_list_events` is denied to the separately signed helper, and
  `calendar_create_event` has no verified isolated mutation fixture.
- `reminders_create` and `run_shortcut` have no safe temporary data-store
  fixture with deterministic cleanup.
- `scroll_to_element` is not exposed because the pinned helper scrolls at the
  ambient pointer and can accept an offscreen accessibility match without
  proving that it actually scrolled.

These thirteen are the explicitly documented near-surface exceptions, not the
complete policy-blocked count from the helper's 143-tool inventory. The JSON
inventory reports the full blocked count.

Do not expose one of these functions until its default-state success path and
cleanup are represented in the runner and the exact allowlist test is updated.
