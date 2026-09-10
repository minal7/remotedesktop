# Bound initial capture and keep signaling available during startup

Source repair; compilation and native execution remain pending. This continues the [capture availability review](CAPTURE_AVAILABILITY_REVIEW.md) and reuses the [recovery budget](CAPTURE_RECOVERY_BUDGET_REVIEW.md) and [native stream ownership barrier](CAPTURE_STREAM_OWNERSHIP_REVIEW.md). No build, typecheck, test/assertion execution, app/device/browser operation, inference run, SSH retry or installed-app replacement was performed.

## First-principles findings

The first image needs the same bounded availability requirement as recovery. Native discovery/start can hang, return without output, or deliver a frame before startup completes. None of these events by itself proves usable current output. A deadline armed only after a reported failure leaves an initial silent startup outside the policy.

Previously, [HostPeerSession.acceptOffer](../../../host-mac/RemoteDesktopHost/HostPeerSession.swift) awaited initial capture directly. The [host signaling loop](../../../host-mac/RemoteDesktopHost/HostSession.swift) awaited that entire offer call before flushing buffered ICE and processing subsequent signaling messages. A stuck capture call could therefore also prevent that loop from consuming remote ICE and disconnects. The native capture task and signaling work need separate lifetimes while preserving exact capture cleanup ownership.

Review also found a stop-classification race. The current stream was retired synchronously, but its stop receipt was consumed in a later task. A retry could create a new native attempt first, invalidating that receipt before the handler classified a terminal error. Extending recovery to initial startup requires closing that race as well.

## Implemented source behavior

After the answer has been sent, the peer requests initial capture through the existing asynchronous capture worker. The request arms one availability episode and its independent deadline while holding the peer lock, before creating the worker or entering a native await. `acceptOffer` returns after scheduling capture; the signaling loop can continue with buffered ICE and subsequent messages.

The initial request is admitted once per peer. Renegotiation cannot replace its episode, renew its deadline or restart a stream that already has available output. Startup uses the existing **five-attempt, 30-second** policy, including the first native attempt. Retried start failures retain the same deadline and cleanup barriers. A running stream that produces no complete frame keeps the deadline without starting a polling/restart loop. Early complete output is remembered, but readiness still requires its exact attempt to be running and available before the deadline.

Reported nonterminal loss during startup retains that original episode. A subsequent stop also retains the same attempt/time allowance. The fifth admitted native start may deliver a frame before the deadline; the budget forbids a sixth attempt. Failure text now refers to capture becoming available, covering both startup and recovery.

The deadline task runs independently of discovery/start. Expiration claims terminal peer state before closure, revokes input/media and reports through the existing generation-scoped `onEnded` path. That keeps the existing distinction between a local visual sidecar and the separate LAN task channel. Exact native teardown still joins any discovery/start call that has not returned. This bounds readiness and begins closure; it does not force a native call to terminate or prove a hard scheduling limit.

Stop classification is now synchronous inside the current capture callback after input revocation. The handler consumes the exact stop receipt before a waiting retry can acquire capture admission. Recoverable stops schedule or join the current worker. A terminal stop claims the peer as ended and retires its capture owner under the capture gate, preventing a queued worker from preparing another stream for that owner. Peer-connection teardown and terminal reporting remain deferred so they run after capture admission is released. Duplicate/foreign callbacks remain excluded by the existing lifecycle.

The signaling owner retains the exact offered peer and generation across offer negotiation. It rechecks identity, cancellation and terminal peer state before publishing paired state, including after awaited advertisement cleanup. The error path checks identity again after awaiting task shutdown, and clears shared ICE state before awaiting the retired capture barrier. A stale completion cannot mark a replaced peer as paired or use the replacement's peer reference for cleanup. This is a repair to this offer path, not a proof that every signaling/native callback is race-free.

## Time and readiness boundaries

The 30-second capture budget starts when initial capture is requested after answer delivery. Earlier native WebRTC negotiation, audio setup and signaling awaits do not receive a new deadline in this patch. Those remain separate lifecycle work.

The phone's initial input hello still has its existing **10-second** timeout. Capture-loss invalidation retains its **35-second** handshake allowance, and connection recovery retains its own deadline. The earliest applicable timeout can close the connection; this patch does not promise the phone will wait through the full host startup allowance. These are configured limits, not measured latency or resource budgets.

The host can show a paired signaling session while capture is starting. Input authorization remains unavailable until validated current source output exists. Source output still does not prove the phone has decoded and presented a fresh image. The [capture-to-render evidence sequence](CAPTURE_FRAME_EVIDENCE_REVIEW.md#detailed-sequence-to-close-the-actual-recovery-gap) remains open.

## Prepared regression evidence

Three methods are authored and **unrun** in [ScreenCaptureSizingTests](../../../host-mac/RemoteDesktopHostTests/ScreenCaptureSizingTests.swift):

1. Manually evaluate the initial deadline while fake discovery is held, retire the owner, and ensure the late prepared stream is cleaned without starting or admitting output.
2. Record early output while fake native startup is held; after startup returns, require the original deadline even when the remembered frame and running identity match.
3. Compose five failed native starts with the original episode and exact cleanup barrier, requiring ordered cleanup before each retry and rejecting a sixth reservation.

These compose production value/lifecycle types with a fake stream and manually supplied clock instants. They do not execute HostPeerSession's scheduled watchdog/worker, the signaling loop, SCStream, real input or a renderer. Existing lifecycle, availability and input cases remain selected. Duplicate offer scheduling, production callback order, actual terminal reporting and login preservation still require native execution evidence.

The [startup inventory](capture-startup-host-inventory.json) retains all 64 prior capture/input/availability host identifiers and adds the three named methods. Source inventories select **1958 default host / 1275 focused browser-host / 67 focused startup host** methods. Unchanged capture-input client and client-core inventories retain **32 / 35** methods. Expected identifiers were extended from the prior committed inventories with the three explicit names.

Four changed Swift files pass parse-only checks. The documentation scan checks **227 Markdown files / 1883 local targets / zero broken paths**. Whitespace validation is clean, and the effective `.git/hooks` directory contains **zero executable non-sample hooks**. These checks do not establish compilation, passing assertions, native behavior, natural-language correctness or acceptable resource use.

## Remaining repair sequence

1. **Produce bounded fresh capture for unchanged displays.** The conservative loss clock can reject queued resume frames. Design a current-owner fresh-capture request without moving/clicking the desktop, and qualify native started/idle sequences.
2. **Detect unreported capture loss.** Silent stalls, blocked consumers and permission/display changes without a reported loss status still need an explicit observation/probe policy. Do not assume a periodic idle-callback guarantee. Define connection-level repeated-failure behavior.
3. **Complete media and foreground evidence.** Bind the host challenge through actual encoding, transport, decoding and presentation, then rearm that evidence when the phone returns active. Source readiness alone remains insufficient.
4. **Qualify the complete startup lifecycle.** Exercise real discovery/start hangs, early/late frames, native stop classification, retry/close races, signaling ICE/bye progress, duplicate offers, send failures, shutdown, timeout interactions and native cleanup. Earlier negotiation/audio/signaling deadlines and broader owner races remain open.
5. **Qualify user work later.** Verify that visual-sidecar failure preserves the exact paused LAN/login task and deliberate Resume requirements. Actual travel/concert/movie tasks still need explicit permission. Model replacement or authorized remote-GPU work, thermal measurements and the 8 GB target follow correctness work.
