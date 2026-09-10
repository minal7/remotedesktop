# Reject input buffered across retired connections

Source repair; execution pending. This follows the [local input-session repair](DIRECT_INPUT_SESSION_REVIEW.md). No build, typecheck, test/assertion run, app/browser launch, native input, model run, real-site task or SSH connection ran. Swift parsing, source inventories, project-file syntax and local documentation checks are the available verification.

## First-principles findings

A host-created dispatch token describes when the host admitted a packet. It cannot identify when the sender created a packet still buffered inside WebRTC. A connection loss can retire all captured host work, yet an old key release or text packet first delivered after reconnect could acquire the replacement token.

The freshness evidence must travel with the packet. Both sides can detect an outage independently, and neither can assume that the other received the same connection callback. Duplicate handshake delivery must preserve sequence state; otherwise replayed acknowledgement could reset the sender counter. An older controller that sends no session identity cannot safely reuse its channel after a detected loss.

## Repair

The shared [direct-input session protocol and client state](../../../protocol/Swift/DirectInputSessionProtocol.swift) introduce an optional v1 handshake. The client supplies a channel UUID and increasing hello revision. The host echoes that pair and supplies a fresh host UUID plus increasing generation. Input carries the host identity/generation and its own increasing sequence. Integers and UUIDs use typed decoding; malformed opt-in metadata cannot silently become an unscoped packet. The [wire contract](../../../protocol/PROTOCOL.md) specifies bounds, duplicates, recovery and legacy behavior.

The [Mac packet decoder](../../../host-mac/RemoteDesktopHost/WireFormat.swift) retains the metadata separately from semantic input. Under its authority lock, the [peer session](../../../host-mac/RemoteDesktopHost/HostPeerSession.swift) admits only a current host ID/generation and a newer sequence, then returns the local injection identity. The injector's existing posting-lock check still handles revocation after admission. An old, missing or duplicate stamp cannot invoke the direct-input callback, post input or clean up replacement holds.

Host-only recovery rotates the host lifetime and sends a fresh acknowledgement. Phone-only recovery increments the client's hello revision; the host retires old manual holds and publishes a loss before reauthorizing the new lifetime, preserving the manager's interruption boundary even if the Mac saw no native disconnect. Exact duplicate hello preserves held input, generation and admitted sequence. Older hello, changed client ID and mode downgrade cannot replace the current negotiation.

The [iOS transport](../../../ios/RemoteDesktop/Transport/WebRTCTransport.swift) owns the shared client state on MainActor. It requires a connected peer and open channel before sending hello, disables input until the current acknowledgement, and stamps only direct input through the [iOS encoder](../../../ios/RemoteDesktop/Protocol/WireFormat.swift). Duplicate acknowledgement does not reset sequence. Native peer/channel callbacks check object identity, channel close is terminal, and an extra live channel cannot replace the current one. Input/hello send failure terminates the transport; an unanswered sent hello has a ten-second deadline. There is no retry queue for text or key effects.

Legacy initial remote control remains available. The updated Mac closes an unscoped channel on connection loss, and the updated phone closes after a loss when its host acknowledged only legacy behavior. Recovery then requires a new connection. This trades automatic legacy ICE recovery for an explicit boundary, because no wire identity exists to distinguish its queued old input. New-host/new-client scoped recovery retains the stronger protocol path.

The shared source is referenced by the tracked Mac project and the generated local iOS project. Both project files pass syntax checks; the iOS project is Git-ignored and its checked-in `project.yml` already includes the shared source directory. The client-core script also discovers the new Foundation-only shared file by directory. No project generation or build ran.

## Prepared verification

Six new [host methods](../../../host-mac/RemoteDesktopHostTests/ComputerUseTests.swift) and two new [iOS methods](../../../ios/RemoteDesktopTests/WebRTCTransportTests.swift) are authored and unrun:

- Typed metadata rejects invalid UUID/version, missing fields, zero, negative, fractional, boolean/string and overflow counters. iOS also rejects malformed capability containers and metadata instead of interpreting them as legacy readiness.
- Duplicate and stale stamps, absent metadata, mixed old/new identity fields and old releases cannot affect replacement input; a current release still succeeds.
- A newer client hello releases the previous hold, publishes an interruption boundary and cannot be undone by old hello, changed client identity or downgrade. Duplicate hello preserves its original lifetime.
- The client cannot send before its current acknowledgement; duplicate acknowledgement preserves sequence, older acknowledgement cannot restore readiness, and new acknowledgement starts a new scoped sequence.
- Legacy connection loss retires the host input lifetime and closes the phone state. Neither side silently resumes that channel.
- A client-state/host-authority composition uses actual Mac packet decoding and acknowledgement encoding to reject text first delivered after host-only recovery, then repeats recovery observed only by the phone. Only current text is captured by the fixture event poster.
- The actual iOS encoder puts handshake metadata only on hello and stamps only on pointer/key/scroll/text. Exact Unicode text remains intact; legacy envelope sequence stays separate. Its actual acknowledgement decoder supplies the scope to the shared client state.

Three prior host reconnect fixtures now explicitly negotiate this extension. The [20-method host inventory](wire-input-session-inventory.json) retains the previous local-session, cleanup, physical handback and provider-popup coverage; the [five-method iOS inventory](wire-input-session-client-inventory.json) retains ordinary hello negotiation and sidecar readiness. Source inventories select **1911 default host / 1228 focused host / 35 client core / 20 focused wire-host / 5 focused wire-client methods**. These counts identify source methods, not executed tests or runtime discovery.

Seven Swift files pass parse-only checks; both effective project files pass syntax checks. Documentation checks cover 218 Markdown files and 1,775 local targets with no broken targets. Whitespace checks are clean, and the effective Git hook directory contains no executable non-sample hooks. These checks do not establish compilation, assertion outcomes or native behavior.

## Remaining sequence and limits

1. Expose transient input unavailability to the phone's screen/composer and modifier/gesture state. Transport rejection alone can silently discard input while the existing model still displays a connected screen. Require current display/frame evidence and explicit user handback where appropriate before restoring interactivity; do not carry a stale latched modifier into the recovered session.
2. Qualify native RTC delivery and ordering, including the configured reliable-ordered channel properties, callback-to-MainActor scheduling, opposite callback orders, channel replacement, handshake send failure/deadline cleanup and one-sided ICE loss. The prepared composition does not invoke the native transport or prove callback chronology.
3. Review admission versus complete native packet dispatch when callbacks overlap. The local identity fences revocation, while the current ordering contract still relies on ordered native delivery. Also review queued data/backpressure and packet age without an observed disconnect. The extension does not bound the age of input within one continuously live session.
4. Qualify legacy behavior on Windows/older peers, and scope remaining lifecycle/video-quality callbacks as needed. Old hosts cannot be made to validate metadata by updating only the phone; this repair does not claim their host-only outage protection.
5. Compose with browser/login ownership, physical event chronology, exact task controls, native process recovery and completion evidence. Account login success requires fresh page evidence after handback, not acknowledgement of a remote input session. Global navigation-source completion remains restricted.
6. Keep tests, real flight/concert/movie/login scenarios and model execution deferred until explicit permission. Correctness remains ahead of model selection and 8 GB Mac resource qualification. The reported RTX 3080 remains authorized for later model work; SSH is unverified after the earlier timeout.
