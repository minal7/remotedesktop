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
translation against in-memory event and screen providers. It also verifies the
hybrid boundary: a typed semantic plan owns the operation, OS-Atlas output is a
non-executable point carrier for pointer actions, and direct actions require no
visual-model completion. A separate native input-layer assertion covers middle
click; middle click is not an OS-Atlas parser action.
It does not load the multi-gigabyte checkpoint, open a fixture window, capture
the user's desktop, or post real input.

To exercise the actual installed OS-Atlas Pro checkpoint and bundled llama.cpp
runtime, opt in separately:

```sh
host-mac/scripts/run_osatlas_acceptance.sh --actual-model
```

This mode does not download or install a model. Its first release gate resolves
the verified active package with `ComputerUseArtifactManifest.current` and
`resolvePackage`, then loads the installed semantic GGUF through the production
multi-model API. Apple routing is forced unavailable without supplying a mock
semantic answer, so a purchase prompt must travel through real Granite typed
routing, OS-Atlas point grounding, and host approval validation. The gate
reports an explicit prerequisite until the immutable V4 semantic artifact is
present in the production manifest and installed; it never substitutes the
legacy visual-only package.

The additional diagnostic matrices invoke Apple's installed on-device language
model and the installed OS-Atlas package.
The ordinary-language matrix covers all 16 host-composed semantic actions.
Click, double-click, secondary-click, and drag require real OS-Atlas point
grounding; other actions are produced directly from the typed semantic plan.
`ANSWER` and `REPORT` share one visible-evidence behavior. Production always
installs the semantic router, including when Apple's model is warming up or
unavailable at startup. Deterministic app-first, literal-entry, and unambiguous
navigation routes run before the per-step model check. An unavailable
non-deterministic step returns `unable to complete`; it never asks OS-Atlas for
an executable verb. OS-Atlas receives only typed pointer-grounding requests.

The opt-in mode also runs a consolidated 15-scenario regular-user matrix. Its
terminal result is asserted as exactly one of `task completed`,
`user intervention required`, or `unable to complete`. The matrix includes app
opening, Return submission, exact text entry, scrolling to a named section,
visible-fact answers, an already-finished task, wait-then-answer, missing input,
authentication takeover, purchase approval, persistent unavailable content, a
platform-incompatible app, two additional real OS-Atlas pointer-grounding
tasks, and an unrecognized-operation fail-closed case. Purchase, calendar, and
folder pointer proposals are the only three model calls in that forced-Apple-
unavailable matrix, and each raw response must be a CLICK point carrier. Every
screen is rendered in memory and every proposed host action is intercepted.

The same actual-model test command retains stateful delivery-address-to-
itemized-quote fixtures for regression measurement of the legacy raw checkpoint
parser. Those fixtures use the executor's test-only compatibility configuration;
production installs typed semantic routing and disables that raw-action mode.
The shorter fixture requires actual OS-Atlas to emit `TYPE` with the exact
address before local Vision OCR returns the completed quote. A separate complex
fixture keeps one executor loop alive across four page states and measures
`TYPE`, `SCROLL DOWN`, then `SCROLL DOWN`. Only after that does local Vision
OCR—not model-authored pricing—extract the restaurant, item, subtotal, every
recognized fee row, tax, total, and ETA. Both fixtures remain hidden, do not
read the desktop, and intercept model actions before any system input is
posted. Login always pauses for user takeover, and no path advances checkout.
The XCTest cases are skipped with a clear reason if the installed checkpoint
or bundled runtime is unavailable.

### Shipped-path local hybrid fixture

The safest visible shipped-path acceptance is the repository-owned
`LocalDeliveryQuote.html` page. It has a restrictive Content Security Policy,
no external resources, no form action, and no control that can send, buy,
authenticate, or mutate data outside the page. The exact harmless token
`LOCAL-QUOTE-7421` is required to create the quote DOM; the complete quote is
then below the initial viewport. Its one **Start local quote setup** button
only enables and focuses the local token field; this gives the installed
OS-Atlas checkpoint a harmless visible target with an observable local effect.

The full B01–B11 runner owns fixture preparation, the transactional host swap,
the matched iPhone Air Simulator build, strict result counting, and restoration
after a failed run. Debug may build a local Apple Development host:

```sh
REMOTE_DESKTOP_APPLE_CONFIGURATION=Debug \
REMOTE_DESKTOP_HOST_CONFIGURATION=Debug \
REMOTE_DESKTOP_IOS_CONFIGURATION=Debug \
host-mac/scripts/run_local_browser_live_acceptance.sh
```

Release never rebuilds a development-signed host. It requires a notarized
Developer ID app whose code-signed `RemoteDesktopSourceCommit` key matches the
full commit of a clean checkout:

```sh
SOURCE_COMMIT="$(git rev-parse HEAD)"
host-mac/scripts/run_local_browser_live_acceptance.sh \
  --host-artifact "/absolute/path/RemoteDesktopHost.app" \
  --expected-source-commit "$SOURCE_COMMIT"
```

Before replacing the installed host, the runner checks the Developer ID team,
hardened runtime and secure timestamps for the app and every nested Mach-O,
the exact Production CloudKit contract, absence of task-debugging and APS
entitlements, the stapled notarization ticket, Gatekeeper, and signed source
revision. It then hash-compares the installed executable with the artifact and
repeats bundle verification.

First open the fixture in Safari, make the Safari content area at least
900 x 650 points, and leave **Start local quote setup** unclicked. Leave that
tab loaded, then hide Safari and foreground Calculator so the fixture is not
visible in the streamed starting frame. The acceptance runner performs and
verifies those last two steps fail-closed:

```sh
cd /path/to/remotedesktop
open -a Safari "$PWD/host-mac/AcceptanceFixtures/LocalDeliveryQuote.html"
```

Do not pre-focus the token field. It remains disabled until the AI clicks the
setup button, whose local handler enables and focuses it without a network,
form, account, or external mutation.

With an AI-ready signed host running from the same Debug or Release
configuration as the iOS build under test, Screen Recording and Accessibility
already granted to that exact host, and a booted signed-in iOS Simulator, run
only the local-fixture scenario:

```sh
# Use the exact UDID of the booted, signed-in simulator.
# Obtain it from: xcrun simctl list devices available
SIMULATOR_UDID='<exact signed-in simulator UDID>'
CONFIGURATION="${REMOTE_DESKTOP_APPLE_CONFIGURATION:-Release}"
cd ios
xcodebuild test \
  -project RemoteDesktop.xcodeproj \
  -scheme RemoteDesktopLiveE2E \
  -configuration "$CONFIGURATION" \
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" \
  -only-testing:RemoteDesktopLiveE2ETests/OSAtlasLocalFixtureSimulatorLiveE2ETests/testLocalFixtureUsesShippedHybridAppFirstNativeTypeAndScrollBeforeVisibleQuote \
  REMOTE_DESKTOP_APPLE_CONFIGURATION="$CONFIGURATION" \
  RUN_OSATLAS_LOCAL_FIXTURE_SIMULATOR_E2E=1
```

This is the end-to-end product route for either matched configuration. CloudKit
provides automatic same-account discovery and binding (Development for Debug,
Production for Release); the ordinary prompt, progress, and result travel over
the authenticated local TLS channel. B01 proves that prompt channel is ready
independently, then requires the product's otherwise optional visual sidecar to
reach live state with a compatible host, current display metadata, and a fresh
decoded frame. The signed host first opens Safari from the unrelated app. The
always-installed local semantic router preserves the exact fixture token and
explicit scroll direction, but it will not let deterministic TYPE or navigation
skip an earlier pending pointer instruction. After Safari opens, the semantic
router selects the visible setup control and the installed OS-Atlas checkpoint
must return its screen-grounded click point. That click changes the button to
**Local quote setup started**, enables and focuses the field, and only then can
native exact typing succeed. Each deterministic navigation route runs once,
then the updated screen and bounded history are evaluated before another
action. The host scrolls natively until the complete quote is visible; only
then can the focused-window OCR validator return the fixed itemized result. The
test OCRs a Calculator-only starting frame with Safari/fixture markers absent,
observes the requested-app open and OS-Atlas click progress, proves the click's
visible local effect before native typing, and finally OCRs distinctive
unlocked quote content. A model-authored answer, an in-memory intercepted
action, a direct-only flow, a TLS-only pass, or a stale media frame cannot
satisfy it.

### Shipped takeover, direct-input, resume, and stop lifecycle

`ComputerUseLocalLifecycleSimulatorLiveE2ETests` uses the same default local
fixture and a second fixed token, `HUMAN-CONTROL-2468`, to validate lifecycle
controls without an external site. The token only reveals **MANUAL REMOTE INPUT
CONFIRMED** inside the page. There is no form submission, network request,
account, message, purchase, or other external effect.

Reload `LocalDeliveryQuote.html`, manually click **Start local quote setup**,
leave its empty blue **Fixture code** field focused in a Safari content area at
least 900 x 650 points, and turn off Simulator **I/O > Keyboard > Connect
Hardware Keyboard**. The test deliberately requires the shipped takeover
strip's software-keyboard path; it fails rather than silently substituting a
different input channel.

Run only the lifecycle scenario:

```sh
# Use the exact UDID of the booted, signed-in simulator.
# Obtain it from: xcrun simctl list devices available
SIMULATOR_UDID='<exact signed-in simulator UDID>'
cd ios
xcodebuild test \
  -project RemoteDesktop.xcodeproj \
  -scheme RemoteDesktopLiveE2E \
  -configuration Release \
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" \
  -only-testing:RemoteDesktopLiveE2ETests/ComputerUseLocalLifecycleSimulatorLiveE2ETests/testTakeControlManualInputResumeTakeControlAndStopThroughCurrentHost \
  RUN_COMPUTER_USE_LOCAL_LIFECYCLE_SIMULATOR_E2E=1
```

The test requires live host visual-observation progress before the first **Take control**,
types the fixed token through the iOS software keyboard and WebRTC, OCRs the
Mac-side proof, holds a three-second paused dwell, taps **Let AI continue**, and
requires fresh host observation for the same task. It then takes control again,
checks that the prior resume marker cleared, taps **Stop task**, and accepts only
`Stopped. You're in control of the Mac.` as the terminal host response. Every
post-send failure runs fail-closed cleanup: deny any approval, or take control
and stop, then wait up to 60 seconds for the corresponding terminal response.

The live UI currently selects the first visible **Use AI Computer Use on ...**
button; it does not expose a code-hash assertion. Operationally isolate this
run by leaving only the exact signed host build under test advertising Ready.

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
# Use the exact UDID of the booted, signed-in simulator.
# Obtain it from: xcrun simctl list devices available
SIMULATOR_UDID='<exact signed-in simulator UDID>'
cd ios
RUN_OSATLAS_DOORDASH_GUEST_HANDOFF_SIMULATOR_E2E=1 \
xcodebuild test \
  -project RemoteDesktop.xcodeproj \
  -scheme RemoteDesktopLiveE2E \
  -configuration Release \
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" \
  -only-testing:RemoteDesktopLiveE2ETests/OSAtlasDoorDashGuestSignInSimulatorLiveE2ETests/testGuestDoorDashQuotePausesForPrivateSignInAndExplainsResume
```

The test makes an ordinary quote-only request from the Simulator, requires the
live screen to remain visible, and proves that the host pauses before model
inference or input. The app shows the complete sign-in guidance in a dedicated
callout and offers **Stop task** and **Let AI continue**. This guest-handoff test
never signs in or resumes: after verifying the safe person-control boundary, it
taps **Stop task** and requires the exact terminal cancellation. Use the
separate takeover-resume scenario below when a person will enter credentials,
prepare the quote, and explicitly tap **Let AI continue**.

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
# Use the exact UDID of the booted, signed-in simulator.
# Obtain it from: xcrun simctl list devices available
SIMULATOR_UDID='<exact signed-in simulator UDID>'
cd ios
RUN_OSATLAS_DOORDASH_TAKEOVER_RESUME_SIMULATOR_E2E=1 \
xcodebuild test \
  -project RemoteDesktop.xcodeproj \
  -scheme RemoteDesktopLiveE2E \
  -configuration Release \
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" \
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
