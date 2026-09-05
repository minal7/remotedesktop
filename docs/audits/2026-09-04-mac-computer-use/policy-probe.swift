// Audit probe only. Compiles the repository's real policy and input sources.
// The event sink discards every CGEvent; no input is posted to macOS.
import AppKit
import Foundation

// Only WireFormat's unused video-negotiation serializer needs this constant.
// Avoid importing the unrelated WebRTC binary package into this policy probe.
enum DesktopVideoQuality { static let targetFramesPerSecond = 30 }

private final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0
    func record() { lock.withLock { storedCount += 1 } }
    var count: Int { lock.withLock { storedCount } }
}

@main
enum AuditPolicyProbe {
    static func main() {
        let click = ComputerUsePredictedAction.click(x: 10, y: 10, button: 1, count: 1)
        for label in ["AXButton • Send", "AXButton • Enviar", "AXButton • Continue"] {
            let reason = ComputerUseActionSafetyPolicy.approvalReason(
                for: click, accessibilityContext: label)
            print("click [\(label)] -> approval=\(reason != nil)")
        }
        let reason = ComputerUseActionSafetyPolicy.approvalReason(
            for: .key(usage: 0x28, modifiers: 0),
            accessibilityContext: "AXTextField • Search and submit payment")
        print("Return [AXTextField • Search and submit payment] -> approval=\(reason != nil)")

        let events = EventCounter()
        let injector = InputInjector(eventPoster: { _ in events.record() })
        let returned = injector.apply(.text("hello"), ifAllowed: { true })
        print("Discarded event sink: text apply returned=\(returned), discardedEvents=\(events.count), deliveredEvents=0")
        print("These are component observations, not end-to-end authorization bypass claims.")
    }
}
