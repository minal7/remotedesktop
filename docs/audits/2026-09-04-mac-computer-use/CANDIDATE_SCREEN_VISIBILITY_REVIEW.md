# Candidate screen visibility and input readiness

Follow-up: [native surface integration](PRESENTATION_SURFACE_INTEGRATION_REVIEW.md) now connects the producer in client source. This document records the earlier checkpoint; native execution and product qualification remain pending.

Source repair, 2026-09-10. This continues the visibility prerequisite in the [presentation producer review](PRESENTATION_PRODUCER_REVIEW.md) and the [screen privacy/input review](SCREEN_PRIVACY_INPUT_REVIEW.md). This change is in the iOS client that displays and controls the Mac. No builds, typechecks, assertion execution, app launches, native rendering, browser actions or model inference ran. The Metal producer remains uninstantiated, and input readiness still uses the existing renderer-submission contract.

## First-principles defect

A screen cannot require proof of visible presentation before allowing the image to become visible. Previously the waiting overlay covered the whole remote screen until input readiness arrived. Replacing the submission callback with a drawable receipt under that overlay would retain a waiting-screen cycle. Also, leaving a hidden native RTC view attached would let it accumulate cached frames and deferred work during a privacy interval.

Four distinct facts must remain separate:

| Fact | What it permits or proves |
| --- | --- |
| Current session/display and visibility policy | Candidate pixels may be shown in the owned screen. |
| Current renderer submission | The existing implementation may reopen input after its other gates pass. This is the current, incomplete readiness contract. |
| Exact current drawable presentation | The candidate producer can associate GPU completion and native presentation with one drawable; it is not connected to this screen yet. |
| Host capture freshness | Requires capture-to-media identity and recovery evidence beyond a local drawable receipt. |

This repair implements the first distinction and preserves the other outstanding gates.

## Implemented behavior

[SessionModel](../../../ios/RemoteDesktop/SessionModel.swift) exposes `mayRevealRemoteScreenPixels` independently of `hasReceivedVideoFrame` and sidecar `.live` state. It requires an active connected session, current display metadata and hello, application/scene activity, a validated account, and permission under the current task privacy policy. Computer Use additionally requires its prompt connection; the local TLS mode requires the optional visual sidecar's current compatible hello/display. A true value grants no input source or send permission.

Native visibility observers read current policy after state commits. They have weak owners, support explicit removal and serialize nested notifications. Task/connection changes notify even when the privacy bit and keyboard policy are unchanged. The observer callback does not capture a stale visibility Boolean. Account, activity and task privacy continue to close pixel eligibility. New input also reads requested activity and rejects admission during activity retirement.

Held keys, pointer buttons and scrolls finish their owned cleanup before policy-driven native detachment. This ordering matters: detaching a renderer can withdraw frame readiness, which would otherwise prevent the remaining release messages from using their old input scope. A privacy edge inside an existing release joins that release scope before notification. A concurrent return/reveal is read again after cleanup; it does not restore the retired input sources.

[RemoteScreenUIView](../../../ios/RemoteDesktop/Session/RemoteScreenView.swift) observes its exact session and attaches its surface only while candidate pixels are allowed and the view has a window. Withdrawal hides the surface/cursor and detaches through the existing renderer binding. That binding joins the old exact detach before attaching its latest desired target. Reveal can therefore prepare a replacement native sink before input is ready. The production [surface lifetime](NATIVE_SURFACE_LIFETIME_REVIEW.md) creates a new RTC child per attachment and hides, disables and removes the retired child.

Session binding requests and observer owners are tracked separately. Cleanup cannot overwrite a newer binding request; an observer registered during a synchronous replacement cannot take over the successor's registration. Reentrant visibility changes update the binding's desired target while its previous detach is still in progress. Dismantle removes the observation and detaches its own surface.

Frame-only sidecar loss now preserves its authenticated display metadata while retiring input/frame readiness. Clearing that display caused another cycle: the replacement surface could not reveal candidate pixels until it received readiness from a renderer it could not prepare. A new hello still clears the old display, including when the sidecar was already waiting. Repeated hello notifications therefore carry the lifetime change despite unchanged state text. Sidecar transitions have revisions; after notifying observers, an older waiting/live callback cannot mutate readiness belonging to a newer transition.

[ComputerUseView](../../../ios/RemoteDesktop/ComputerUse/ComputerUseView.swift) and [SessionView](../../../ios/RemoteDesktop/Session/SessionView.swift) use a small waiting banner when candidate pixels are allowed. They retain the opaque cover when visibility is denied. The persistent Mail shield keeps its explicit **Show Mac** action while the native container is available, independently of input readiness; detaching the renderer no longer removes the only way to reveal it. Loading/accessibility text distinguishes candidate pixels from available input. Controls remain gated by the existing input policy.

## Prepared regression cases

Eight methods in [WebRTCTransportTests](../../../ios/RemoteDesktopTests/WebRTCTransportTests.swift) are authored and **unrun**:

1. Candidate pixels become eligible after hello/display, before frame readiness; input remains denied.
2. Activity withdrawal finishes held input cleanup and retains a return requested during notification.
3. Frame-only sidecar loss retains display metadata; a repeated hello withdraws it until a new display arrives.
4. A hosted screen detaches for Mail privacy and reattaches on Show Mac before readiness returns.
5. A dead native owner or explicit observer removal prevents later visibility delivery.
6. Prompt stop/start changes pixel eligibility even when the privacy bit remains false.
7. A newer session installed during old renderer detachment retains its own visibility observation and avoids attaching the interrupted session.
8. A newer frame admitted during a waiting notification cannot be retired by the older callback afterward.

The existing sidecar frame-loss case now expects retained display metadata, while preserving its owned modifier release, stale-input rejection, TLS continuity and readiness assertions. The two new hosted-screen methods use `RemoteKeyboardTestWindow` and a recording transport. That transport records surface attachment/detachment and can inject a readiness-withdrawal callback; it does not call the native renderer factory. These cases do not allocate a Metal drawable or prove native rendering, compositing, focus behavior or callback order.

The [candidate visibility inventory](candidate-screen-visibility-client-inventory.json) contains 18 explicitly reviewed existing methods plus the eight new ones. [Client core](../../../ios/AcceptanceFixtures/computer-use-client-core-tests.json) preserves the committed selectors and expected identifiers and adds the eight explicit names. Expected names were not generated from source discovery.

## Source checks and remaining work

Five changed Swift files pass parse-only checks. Seven inventories match their selected source identifiers: **2025 default host / 1342 focused browser host / 121 client core / 26 candidate visibility / 110 pause acknowledgement / 65 native surface / 74 presentation producer**. These are source checks, not compilation, XCTest discovery, passed assertions or native qualification.

Documentation checking covers **251 Markdown files / 2130 local targets / zero missing paths**; anchors were not checked. Whitespace validation is clean. The effective `.git/hooks` directory contains **zero executable non-sample hooks**.

The next implementation work remains the actual presentation connection: own drawable acquisition and a bounded latest-frame mailbox, handle supported CVPixelBuffer and software I420 formats, define unavailable/unsupported/encoding-failure handling and bounded retries, retire presentation context on viewport/layout/window/activity/privacy changes, and replace submission readiness only with receipts from the current attachment/context. Do not retry committed drawables or release unfinished GPU capacity on an observer timeout.

Candidate visibility is permission to expose pixels, not proof that the view is unobscured, current or correctly rendered. Actual overlay hit testing, native frame/color/orientation output, source-capture identity, login handback and complete natural-language website tasks remain unqualified. The real travel/concert/movie scenarios still require later explicit permission. Alternate-model work and the RTX 3080 desktop remain available for the later evaluation/training phase; no model was changed or run here. The 8 GB and thermal target also remains unqualified.
