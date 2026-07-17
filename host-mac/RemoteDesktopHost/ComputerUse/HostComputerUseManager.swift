import AppKit
import ApplicationServices
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation

fileprivate struct ComputerUseApprovalFingerprint: Equatable {
    let action: ComputerUsePredictedAction
    let applicationID: String
    let accessibilityIdentity: String
    let visualDigest: String?
}

fileprivate struct ComputerUsePreparedApproval {
    let message: String
    let fingerprint: ComputerUseApprovalFingerprint
}

/// Dependency boundary used by deterministic host tests. Production leaves
/// the provider nil and always derives these values from the live frontmost
/// app, Accessibility tree, and bounded screen pixels.
struct ComputerUseApprovalTargetSnapshot: Equatable {
    let context: String
    let applicationID: String
    let accessibilityIdentity: String
}

struct ComputerUseCalculatorSnapshot: Equatable {
    let inputValue: String?
    let expressionValue: String?
}

/// Privacy-bounded Accessibility evidence used only to decide whether the
/// person must take over for authentication. Editable field values are never
/// included. Tests inject this seam without touching the live desktop.
struct ComputerUseAuthenticationContextSnapshot: Equatable {
    let focusedElement: String?
    let boundedWindowContext: String
}

/// Identity sampled immediately before and after a display capture. Quote and
/// sign-in OCR may use the focused-window rectangle only when both samples
/// still describe the same Accessibility window at the same location.
struct ComputerUseFrontmostWindowCaptureIdentity: Equatable {
    let applicationProcessIdentifier: pid_t
    let accessibilityWindowHash: CFHashCode
    let bounds: CGRect
}

@MainActor
final class ComputerUseHostTools {
    enum ToolError: Error, LocalizedError {
        case paused
        case screenshotUnavailable
        case applicationUnavailable
        case approvalTargetUnavailable
        case approvalTargetChanged

        var errorDescription: String? {
            switch self {
            case .paused: return "AI Computer Use is paused by the user."
            case .screenshotUnavailable: return "The Mac screen could not be captured."
            case .applicationUnavailable:
                return "The requested Mac app could not be found or opened."
            case .approvalTargetUnavailable:
                return "The host could not verify the exact control or field, so the action was not offered for approval."
            case .approvalTargetChanged:
                return "The screen or selected field changed while approval was pending."
            }
        }
    }

    private let injector: InputInjector
    private let mayAct: () -> Bool
    private let applicationOpener: (String) async throws -> Void
    private let approvalTargetProvider:
        ((ComputerUsePredictedAction) throws -> ComputerUseApprovalTargetSnapshot)?
    private let actionPerformer: ((ComputerUsePredictedAction) throws -> Void)?
    private let screenProvider: (() throws -> ComputerUseScreenObservation)?
    private let conservativeActionAdjustmentProvider:
        ((ComputerUsePredictedAction) -> ComputerUsePredictedAction)?
    private let transientSystemOverlayProvider:
        ((ComputerUsePredictedAction) -> Bool)?
    private let accessibilityContextProvider:
        ((ComputerUsePredictedAction) -> String)?
    private let calculatorSnapshotProvider: (() -> ComputerUseCalculatorSnapshot?)?
    private let authenticationContextProvider:
        (() -> ComputerUseAuthenticationContextSnapshot?)?
    private let screenCaptureConsentContextProvider:
        (() -> ComputerUseAuthenticationContextSnapshot?)?
    private let frontmostApplicationProvider: () -> String?

    init(
        injector: InputInjector,
        mayAct: @escaping () -> Bool,
        applicationOpener: @escaping (String) async throws -> Void = {
            try await ComputerUseHostTools.openInstalledApplication(named: $0)
        },
        approvalTargetProvider:
            ((ComputerUsePredictedAction) throws -> ComputerUseApprovalTargetSnapshot)? = nil,
        actionPerformer: ((ComputerUsePredictedAction) throws -> Void)? = nil,
        screenProvider: (() throws -> ComputerUseScreenObservation)? = nil,
        conservativeActionAdjustmentProvider:
            ((ComputerUsePredictedAction) -> ComputerUsePredictedAction)? = nil,
        transientSystemOverlayProvider:
            ((ComputerUsePredictedAction) -> Bool)? = nil,
        accessibilityContextProvider:
            ((ComputerUsePredictedAction) -> String)? = nil,
        calculatorSnapshotProvider: (() -> ComputerUseCalculatorSnapshot?)? = nil,
        authenticationContextProvider:
            (() -> ComputerUseAuthenticationContextSnapshot?)? = nil,
        screenCaptureConsentContextProvider:
            (() -> ComputerUseAuthenticationContextSnapshot?)? = nil,
        frontmostApplicationProvider: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.localizedName
        }
    ) {
        self.injector = injector
        self.mayAct = mayAct
        self.applicationOpener = applicationOpener
        self.approvalTargetProvider = approvalTargetProvider
        self.actionPerformer = actionPerformer
        self.screenProvider = screenProvider
        if let conservativeActionAdjustmentProvider {
            self.conservativeActionAdjustmentProvider =
                conservativeActionAdjustmentProvider
        } else if screenProvider != nil {
            // A virtual screen has no relationship to the person's live AX
            // tree. Keep deterministic tests and hidden evaluation fixtures
            // from reading or snapping to unrelated desktop controls.
            self.conservativeActionAdjustmentProvider = { $0 }
        } else {
            self.conservativeActionAdjustmentProvider = nil
        }
        if let transientSystemOverlayProvider {
            self.transientSystemOverlayProvider =
                transientSystemOverlayProvider
        } else if screenProvider != nil {
            // Synthetic screenshots must not be combined with unrelated live
            // Notification Center state from the person's desktop.
            self.transientSystemOverlayProvider = { _ in false }
        } else {
            self.transientSystemOverlayProvider = nil
        }
        self.accessibilityContextProvider = accessibilityContextProvider
        self.calculatorSnapshotProvider = calculatorSnapshotProvider
        if let authenticationContextProvider {
            self.authenticationContextProvider = authenticationContextProvider
        } else if screenProvider != nil {
            // A synthetic/virtual screen must never be combined with live AX
            // state from the person's unrelated foreground application.
            self.authenticationContextProvider = { nil }
        } else {
            self.authenticationContextProvider = nil
        }
        if let screenCaptureConsentContextProvider {
            self.screenCaptureConsentContextProvider =
                screenCaptureConsentContextProvider
        } else if screenProvider != nil {
            // A synthetic screen must never be paired with Accessibility text
            // from a live system permission prompt. Tests opt in explicitly.
            self.screenCaptureConsentContextProvider = { nil }
        } else {
            self.screenCaptureConsentContextProvider = nil
        }
        self.frontmostApplicationProvider = frontmostApplicationProvider
    }

    func frontmostApplicationName() -> String? {
        frontmostApplicationProvider()
    }

    /// Checks whether a transient macOS notification owns the exact pointer
    /// target. Waiting and re-observing is safer than sending the intended
    /// click through an unrelated overlay or dismissing that overlay without
    /// the person's request.
    func actionIsObstructedByTransientSystemOverlay(
        _ action: ComputerUsePredictedAction
    ) throws -> Bool {
        guard mayAct() else { throw ToolError.paused }
        if let transientSystemOverlayProvider {
            return transientSystemOverlayProvider(action)
        }
        return liveActionIsObstructedByTransientSystemOverlay(action)
    }

    static func isTransientSystemOverlayApplication(
        bundleIdentifier: String?
    ) -> Bool {
        guard let bundleIdentifier else { return false }
        switch bundleIdentifier.lowercased() {
        case "com.apple.usernotificationcenter",
                "com.apple.notificationcenterui":
            return true
        default:
            return false
        }
    }

    private func liveActionIsObstructedByTransientSystemOverlay(
        _ action: ComputerUsePredictedAction
    ) -> Bool {
        let points: [CGPoint]
        switch action {
        case .click(let x, let y, _, _):
            points = [CGPoint(x: x, y: y)]
        case .drag(let fromX, let fromY, let toX, let toY):
            points = [
                CGPoint(x: fromX, y: fromY),
                CGPoint(x: toX, y: toY),
            ]
        case .scroll(let x, let y, _, _):
            points = [CGPoint(x: x, y: y)]
        case .requestApproval(_, let proposedAction):
            return liveActionIsObstructedByTransientSystemOverlay(
                proposedAction)
        case .key, .typeText, .wait, .done:
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()
        for point in points {
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                systemWide,
                Float(point.x),
                Float(point.y),
                &element) == .success,
                  let element else { continue }
            var processIdentifier: pid_t = 0
            guard AXUIElementGetPid(
                element,
                &processIdentifier) == .success else { continue }
            let bundleIdentifier = NSRunningApplication(
                processIdentifier: processIdentifier)?.bundleIdentifier
            if Self.isTransientSystemOverlayApplication(
                bundleIdentifier: bundleIdentifier) {
                return true
            }
        }
        return false
    }

    /// Reads a small, value-redacted Accessibility slice from the frontmost
    /// focused window. This is intentionally separate from action-target
    /// context so the executor can detect an authentication barrier before it
    /// asks a model to choose any action.
    func currentAuthenticationContext()
        throws -> ComputerUseAuthenticationContextSnapshot? {
        guard mayAct() else { throw ToolError.paused }
        if let authenticationContextProvider {
            return authenticationContextProvider()
        }
        return liveAuthenticationContext()
    }

    /// Reads only a bounded, value-redacted Accessibility slice that may own
    /// the macOS screen-and-audio consent sheet. This remains separate from
    /// authentication AX because the secure system sheet can be owned by the
    /// host even while Safari remains the frontmost application.
    func currentScreenCaptureConsentContext()
        throws -> ComputerUseAuthenticationContextSnapshot? {
        guard mayAct() else { throw ToolError.paused }
        if let screenCaptureConsentContextProvider {
            return screenCaptureConsentContextProvider()
        }
        return liveScreenCaptureConsentContext()
    }

    /// Opens exactly one installed application selected by the local visual
    /// model. Native Launch Services is substantially more reliable than
    /// racing synthetic text against Spotlight, while the model still decides
    /// the action from the current screenshot and the user's prompt.
    func openApplication(named rawName: String) async throws {
        guard mayAct() else { throw ToolError.paused }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= 200,
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains("\0"),
              !name.contains("\n"),
              !name.contains("\r") else {
            throw ToolError.applicationUnavailable
        }
        try await applicationOpener(name)
    }

    private static func openInstalledApplication(named name: String) async throws {
        // Launch Services' name resolver remains the only system API that maps
        // a user-facing application name (rather than a bundle identifier) to
        // an installed bundle. Revalidate the returned URL before opening it.
        guard let path = NSWorkspace.shared.fullPath(forApplication: name) else {
            throw ToolError.applicationUnavailable
        }
        let applicationURL = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              Bundle(url: applicationURL)?.bundleIdentifier != nil else {
            throw ToolError.applicationUnavailable
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application == nil {
                    continuation.resume(throwing: ToolError.applicationUnavailable)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func currentScreen() throws -> ComputerUseScreenObservation {
        guard mayAct() else { throw ToolError.paused }
        if let screenProvider {
            return try screenProvider()
        }
        // Read the focused-window geometry next to the display capture. The
        // screenshot remains a full-display input for visual control, while
        // fact extractors can fail closed to this one active window instead
        // of accepting a coherent stale result from another visible app.
        let windowBeforeCapture = liveFrontmostWindowSnapshot()
        let displayID = CGMainDisplayID()
        guard let image = CGDisplayCreateImage(displayID) else {
            throw ToolError.screenshotUnavailable
        }
        let windowAfterCapture = liveFrontmostWindowSnapshot()
        let frontmostWindowBounds = Self.stableFrontmostWindowBounds(
            before: windowBeforeCapture,
            after: windowAfterCapture)
        let displayBounds = CGDisplayBounds(displayID)
        let bounds = displayBounds.width > 0 && displayBounds.height > 0
            ? displayBounds
            : CGRect(
                x: 0,
                y: 0,
                width: CGDisplayPixelsWide(displayID),
                height: CGDisplayPixelsHigh(displayID))
        return ComputerUseScreenObservation(
            image: CIImage(cgImage: image),
            displayBounds: bounds,
            frontmostWindowBounds: frontmostWindowBounds)
    }

    static func stableFrontmostWindowBounds(
        before: ComputerUseFrontmostWindowCaptureIdentity?,
        after: ComputerUseFrontmostWindowCaptureIdentity?
    ) -> CGRect? {
        guard let before, let after, before == after else { return nil }
        return after.bounds
    }

    private func liveFrontmostWindowSnapshot()
        -> ComputerUseFrontmostWindowCaptureIdentity? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !application.isTerminated else {
            return nil
        }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            root,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue) == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedWindow = unsafeBitCast(
            focusedWindowValue,
            to: AXUIElement.self)
        guard let origin = pointAttribute(
                kAXPositionAttribute as CFString,
                from: focusedWindow),
              let size = sizeAttribute(
                kAXSizeAttribute as CFString,
                from: focusedWindow),
              origin.x.isFinite,
              origin.y.isFinite,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return ComputerUseFrontmostWindowCaptureIdentity(
            applicationProcessIdentifier: application.processIdentifier,
            accessibilityWindowHash: CFHash(focusedWindow),
            bounds: CGRect(origin: origin, size: size))
    }

    func currentScreenJPEG(quality: CGFloat = 0.78) throws -> Data {
        let observation = try currentScreen()
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let data = context.jpegRepresentation(
            of: observation.image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: min(1, max(0, quality))]) else {
            throw ToolError.screenshotUnavailable
        }
        return data
    }

    /// Reads only Calculator's visible input/result field from its bounded
    /// Accessibility subtree. The deterministic arithmetic route uses this
    /// as execution evidence and never reports completion from the injected
    /// keystrokes alone.
    func calculatorSnapshot() throws -> ComputerUseCalculatorSnapshot? {
        guard mayAct() else { throw ToolError.paused }
        if let calculatorSnapshotProvider {
            return calculatorSnapshotProvider()
        }
        return Self.liveCalculatorSnapshot()
    }

    private static func liveCalculatorSnapshot() -> ComputerUseCalculatorSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier == "com.apple.calculator",
              !application.isTerminated else {
            return nil
        }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            root,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue) == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedWindow = unsafeBitCast(
            focusedWindowValue,
            to: AXUIElement.self)
        guard let inputContainers = calculatorContainers(
            in: focusedWindow,
            identifier: "StandardInputView"),
              inputContainers.count == 1,
              let expressionContainers = calculatorContainers(
                in: focusedWindow,
                identifier: "StandardResultView"),
              expressionContainers.count <= 1 else {
            return nil
        }
        var inputVisited = 0
        let inputValue = firstStaticTextValue(
            in: inputContainers[0],
            depth: 0,
            visited: &inputVisited)
        let expressionValue: String?
        if let expressionContainer = expressionContainers.first {
            var expressionVisited = 0
            expressionValue = firstStaticTextValue(
                in: expressionContainer,
                depth: 0,
                visited: &expressionVisited)
        } else {
            expressionValue = nil
        }
        guard inputValue != nil else { return nil }
        return ComputerUseCalculatorSnapshot(
            inputValue: inputValue,
            expressionValue: expressionValue)
    }

    private static func calculatorContainers(
        in element: AXUIElement,
        identifier targetIdentifier: String
    ) -> [AXUIElement]? {
        var queue: [(AXUIElement, Int)] = [(element, 0)]
        var index = 0
        var matches: [AXUIElement] = []
        while index < queue.count, index < 500 {
            let (current, depth) = queue[index]
            index += 1
            guard depth <= 12 else { continue }
            if stringAttribute(
                kAXIdentifierAttribute as CFString,
                from: current) == targetIdentifier {
                matches.append(current)
                guard matches.count <= 1 else { return nil }
            }
            var childValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                current,
                kAXChildrenAttribute as CFString,
                &childValue) == .success,
               let children = childValue as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(80).map {
                    ($0, depth + 1)
                })
            }
        }
        guard index < 500 || index == queue.count else { return nil }
        return matches
    }

    private static func firstStaticTextValue(
        in element: AXUIElement,
        depth: Int,
        visited: inout Int
    ) -> String? {
        guard depth <= 6, visited < 80 else { return nil }
        visited += 1
        let role = stringAttribute(
            kAXRoleAttribute as CFString,
            from: element) ?? ""
        let identifier = stringAttribute(
            kAXIdentifierAttribute as CFString,
            from: element) ?? ""

        if role == kAXStaticTextRole as String,
           let value = stringAttribute(
               kAXValueAttribute as CFString,
               from: element),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        if identifier == "StandardInputView" || identifier == "StandardResultView",
           let value = stringAttribute(
               kAXValueAttribute as CFString,
               from: element),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }

        var childValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childValue) == .success,
              let children = childValue as? [AXUIElement] else {
            return nil
        }
        for child in children.prefix(80) {
            if let value = firstStaticTextValue(
                in: child,
                depth: depth + 1,
                visited: &visited) {
                return value
            }
        }
        return nil
    }

    private static func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value) == .success else {
            return nil
        }
        return value as? String
    }

    func approvalReason(for action: ComputerUsePredictedAction) -> String? {
        ComputerUseActionSafetyPolicy.approvalReason(
            for: action,
            accessibilityContext: accessibilityContext(for: action))
    }

    /// Correct only a primary single-click, and only when the model point lands
    /// on a non-actionable Accessibility container while one unique enabled
    /// control is visible within a tightly bounded neighborhood. This never
    /// chooses between candidates and never changes drags or secondary clicks.
    func conservativelyAdjustedAction(
        _ action: ComputerUsePredictedAction
    ) -> ComputerUsePredictedAction {
        if let conservativeActionAdjustmentProvider {
            return conservativeActionAdjustmentProvider(action)
        }
        guard case .click(let x, let y, let button, let count) = action,
              button == 1,
              count == 1 else { return action }
        let predicted = CGPoint(x: x, y: y)
        let directHit = accessibilityClickCandidate(at: predicted)
        guard let directHit, !directHit.isActionable else { return action }
        let radius = OSAtlasAccessibilityClickCorrection.maximumRadius
        let step: CGFloat = 16
        var nearby: [OSAtlasAccessibilityClickCandidate] = []
        for offsetY in stride(from: -radius, through: radius, by: step) {
            for offsetX in stride(from: -radius, through: radius, by: step) {
                guard offsetX != 0 || offsetY != 0,
                      hypot(offsetX, offsetY) <= radius else { continue }
                let point = CGPoint(
                    x: predicted.x + offsetX,
                    y: predicted.y + offsetY)
                if let candidate = accessibilityClickCandidate(at: point) {
                    nearby.append(candidate)
                }
            }
        }
        let corrected = OSAtlasAccessibilityClickCorrection.correctedPoint(
            predicted: predicted,
            directHit: directHit,
            nearbyCandidates: nearby)
        guard corrected != predicted else { return action }
        return .click(
            x: Int(corrected.x.rounded()),
            y: Int(corrected.y.rounded()),
            button: button,
            count: count)
    }

    fileprivate func prepareApproval(
        for action: ComputerUsePredictedAction
    ) throws -> ComputerUsePreparedApproval {
        let target = try approvalTarget(for: action)
        let message = ComputerUseActionSafetyPolicy.approvalReason(
            for: action,
            accessibilityContext: target.context,
            forceConfirmation: true)
            ?? "Perform this exact action on the current screen"
        let fingerprint = ComputerUseApprovalFingerprint(
            action: action,
            applicationID: target.applicationID,
            accessibilityIdentity: target.accessibilityIdentity,
            visualDigest: try visualDigest(around: target.visualCheckpoints))
        return ComputerUsePreparedApproval(
            message: message,
            fingerprint: fingerprint)
    }

    fileprivate func performApproved(
        _ action: ComputerUsePredictedAction,
        fingerprint: ComputerUseApprovalFingerprint
    ) throws {
        let current = try prepareApproval(for: action).fingerprint
        guard current == fingerprint else {
            throw ToolError.approvalTargetChanged
        }
        try perform(action)
    }

    private struct ApprovalTarget {
        let context: String
        let accessibilityIdentity: String
        let applicationID: String
        let visualCheckpoints: [CGPoint]
    }

    private struct AccessibilitySnapshot {
        let summary: String
        let identity: String
        let center: CGPoint?
        let frame: CGRect?
        let isEnabled: Bool
        let isActionable: Bool
    }

    private func approvalTarget(
        for action: ComputerUsePredictedAction
    ) throws -> ApprovalTarget {
        if let approvalTargetProvider {
            let snapshot = try approvalTargetProvider(action)
            return ApprovalTarget(
                context: snapshot.context,
                accessibilityIdentity: snapshot.accessibilityIdentity,
                applicationID: snapshot.applicationID,
                visualCheckpoints: [])
        }
        let applicationID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            ?? "pid:\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)"
        let snapshots: [AccessibilitySnapshot]
        let checkpoints: [CGPoint]

        switch action {
        case .click(let x, let y, _, _):
            let point = CGPoint(x: x, y: y)
            snapshots = elementSnapshot(at: point).map { [$0] } ?? []
            checkpoints = [point]

        case .drag(let fromX, let fromY, let toX, let toY):
            let from = CGPoint(x: fromX, y: fromY)
            let to = CGPoint(x: toX, y: toY)
            snapshots = [elementSnapshot(at: from), elementSnapshot(at: to)]
                .compactMap { $0 }
            checkpoints = [from, to]

        case .key:
            let focused = focusedElementSnapshot()
            snapshots = focused.map { [$0] } ?? []
            checkpoints = focused?.center.map { [$0] }
                ?? [CGPoint(x: CGDisplayBounds(CGMainDisplayID()).midX,
                            y: CGDisplayBounds(CGMainDisplayID()).midY)]

        case .typeText:
            guard let focused = focusedElementSnapshot() else {
                throw ToolError.approvalTargetUnavailable
            }
            snapshots = [focused]
            // Accessibility identity includes the field's role, label, app,
            // position, and size. Avoid a pixel check here because a blinking
            // insertion caret would otherwise invalidate every approval.
            checkpoints = []

        case .scroll(let x, let y, _, _):
            let point = CGPoint(x: x, y: y)
            snapshots = elementSnapshot(at: point).map { [$0] } ?? []
            checkpoints = [point]

        case .requestApproval(_, let proposedAction):
            return try approvalTarget(for: proposedAction)

        case .wait, .done:
            throw ToolError.approvalTargetUnavailable
        }

        return ApprovalTarget(
            context: snapshots.map(\.summary).filter { !$0.isEmpty }.joined(separator: " → "),
            accessibilityIdentity: snapshots.isEmpty
                ? "unavailable"
                : snapshots.map(\.identity).joined(separator: " -> "),
            applicationID: applicationID,
            visualCheckpoints: checkpoints)
    }

    private func accessibilityContext(for action: ComputerUsePredictedAction) -> String {
        if let accessibilityContextProvider {
            return accessibilityContextProvider(action)
        }
        switch action {
        case .click(let x, let y, _, _):
            return elementSnapshot(at: CGPoint(x: x, y: y))?.summary ?? ""
        case .drag(let fromX, let fromY, let toX, let toY):
            return [
                elementSnapshot(at: CGPoint(x: fromX, y: fromY))?.summary,
                elementSnapshot(at: CGPoint(x: toX, y: toY))?.summary,
            ].compactMap { $0 }.joined(separator: " → ")
        case .key, .typeText:
            return focusedElementSnapshot()?.summary ?? ""
        case .scroll(let x, let y, _, _):
            return elementSnapshot(at: CGPoint(x: x, y: y))?.summary ?? ""
        case .requestApproval(_, let proposedAction):
            return accessibilityContext(for: proposedAction)
        case .wait, .done:
            return ""
        }
    }

    private func elementSnapshot(at point: CGPoint) -> AccessibilitySnapshot? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &element) == .success,
              let element else { return nil }
        return accessibilitySnapshot(for: element)
    }

    private func accessibilityClickCandidate(
        at point: CGPoint
    ) -> OSAtlasAccessibilityClickCandidate? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &element) == .success,
              var current = element else { return nil }

        var fallback: AccessibilitySnapshot?
        for _ in 0 ..< 8 {
            let snapshot = accessibilitySnapshot(for: current)
            if fallback == nil { fallback = snapshot }
            if snapshot.isActionable, snapshot.frame != nil {
                return clickCandidate(from: snapshot)
            }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        guard let fallback else { return nil }
        return clickCandidate(from: fallback)
    }

    private func clickCandidate(
        from snapshot: AccessibilitySnapshot
    ) -> OSAtlasAccessibilityClickCandidate? {
        guard let frame = snapshot.frame else { return nil }
        return OSAtlasAccessibilityClickCandidate(
            identity: snapshot.identity,
            frame: frame,
            isEnabled: snapshot.isEnabled,
            isActionable: snapshot.isActionable)
    }

    private func parentElement(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func focusedElementSnapshot() -> AccessibilitySnapshot? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return accessibilitySnapshot(
            for: unsafeBitCast(value, to: AXUIElement.self))
    }

    private func liveScreenCaptureConsentContext()
        -> ComputerUseAuthenticationContextSnapshot? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let systemFocused: AXUIElement?
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue) == .success,
           let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            systemFocused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        } else {
            systemFocused = nil
        }

        var roots: [AXUIElement] = []
        if let systemFocused {
            var contextRoot = systemFocused
            var current = systemFocused
            for _ in 0 ..< 10 {
                let role = Self.stringAttribute(
                    kAXRoleAttribute as CFString,
                    from: current) ?? ""
                contextRoot = current
                if ["AXWindow", "AXSheet", "AXDialog"].contains(role) {
                    break
                }
                guard let parent = parentElement(of: current) else { break }
                current = parent
            }
            roots.append(contextRoot)
        }

        // The screen-capture consent sheet can remain owned by this process
        // while another app is reported as frontmost. Include only the host's
        // bounded windows, then rely on local OCR if AX does not expose them.
        let ownRoot = AXUIElementCreateApplication(
            ProcessInfo.processInfo.processIdentifier)
        var ownWindowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            ownRoot,
            kAXWindowsAttribute as CFString,
            &ownWindowsValue) == .success,
           let ownWindows = ownWindowsValue as? [AXUIElement] {
            roots.append(contentsOf: ownWindows.prefix(8))
        }

        let focusedSummary = systemFocused
            .map(authenticationContextSummary)
            .flatMap { $0.isEmpty ? nil : $0 }
        var queue = roots.map { ($0, 0) }
        var index = 0
        var summaries: [String] = []
        var seen = Set<String>()
        while index < queue.count, index < 128 {
            let (element, depth) = queue[index]
            index += 1
            guard depth <= 8 else { continue }
            let summary = authenticationContextSummary(for: element)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty, seen.insert(summary).inserted {
                summaries.append(summary)
            }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(48).map {
                    ($0, depth + 1)
                })
            }
        }
        let bounded = String(
            summaries.joined(separator: "\n").prefix(4_000))
        guard focusedSummary != nil || !bounded.isEmpty else { return nil }
        return ComputerUseAuthenticationContextSnapshot(
            focusedElement: focusedSummary,
            boundedWindowContext: bounded)
    }

    private func liveAuthenticationContext()
        -> ComputerUseAuthenticationContextSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !application.isTerminated else {
            return nil
        }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedElement: AXUIElement?
        if AXUIElementCopyAttributeValue(
            root,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue) == .success,
           let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        } else {
            focusedElement = nil
        }
        let focusedSummary = focusedElement.map(authenticationContextSummary)
            .flatMap { $0.isEmpty ? nil : $0 }

        var windowValue: CFTypeRef?
        let focusedWindow: AXUIElement?
        if AXUIElementCopyAttributeValue(
            root,
            kAXFocusedWindowAttribute as CFString,
            &windowValue) == .success,
           let windowValue,
           CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            focusedWindow = unsafeBitCast(windowValue, to: AXUIElement.self)
        } else {
            focusedWindow = nil
        }

        // A focused browser window can expose a very large tree. Bound both
        // traversal and retained text, and never read editable field values.
        var queue: [(AXUIElement, Int)] = focusedWindow.map { [($0, 0)] } ?? []
        var index = 0
        var summaries: [String] = []
        var seen = Set<String>()
        while index < queue.count, index < 96 {
            let (element, depth) = queue[index]
            index += 1
            guard depth <= 8 else { continue }
            let summary = authenticationContextSummary(for: element)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty, seen.insert(summary).inserted {
                summaries.append(summary)
            }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(48).map {
                    ($0, depth + 1)
                })
            }
        }
        let bounded = String(
            summaries.joined(separator: "\n").prefix(4_000))
        guard focusedSummary != nil || !bounded.isEmpty else { return nil }
        return ComputerUseAuthenticationContextSnapshot(
            focusedElement: focusedSummary,
            boundedWindowContext: bounded)
    }

    /// Attribute names, labels, and placeholders reveal field purpose without
    /// exposing what the person typed. Static labels/buttons may contribute a
    /// short value so provider-based sign-in sheets remain detectable.
    private func authenticationContextSummary(
        for element: AXUIElement
    ) -> String {
        var summary = accessibilitySnapshot(for: element).summary
        let role = Self.stringAttribute(
            kAXRoleAttribute as CFString,
            from: element) ?? ""
        let safeValueRoles: Set<String> = [
            "AXStaticText", "AXButton", "AXLink", "AXHeading",
            "AXRadioButton", "AXCheckBox",
        ]
        if safeValueRoles.contains(role),
           let value = Self.stringAttribute(
               kAXValueAttribute as CFString,
               from: element)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            let boundedValue = String(value.prefix(200))
            if !summary.localizedCaseInsensitiveContains(boundedValue) {
                summary += summary.isEmpty ? boundedValue : " • \(boundedValue)"
            }
        }
        return summary
    }

    private func accessibilitySnapshot(
        for element: AXUIElement
    ) -> AccessibilitySnapshot {
        let attributes: [(String, CFString)] = [
            ("role", kAXRoleAttribute as CFString),
            ("subrole", kAXSubroleAttribute as CFString),
            ("title", kAXTitleAttribute as CFString),
            ("description", kAXDescriptionAttribute as CFString),
            ("help", kAXHelpAttribute as CFString),
            ("identifier", kAXIdentifierAttribute as CFString),
            ("placeholder", kAXPlaceholderValueAttribute as CFString),
        ]
        let values: [(String, String)] = attributes.compactMap { name, attribute in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                attribute,
                &value) == .success,
                  let string = value as? String,
                  !string.isEmpty else { return nil }
            return (name, string)
        }
        let position = pointAttribute(
            kAXPositionAttribute as CFString,
            from: element)
        let size = sizeAttribute(
            kAXSizeAttribute as CFString,
            from: element)
        let enabled = boolAttribute(
            kAXEnabledAttribute as CFString,
            from: element) ?? false
        var actionNames: CFArray?
        let copyActionsResult = AXUIElementCopyActionNames(element, &actionNames)
        let actions = copyActionsResult == .success
            ? (actionNames as? [String] ?? [])
            : []
        let role = values.first(where: { $0.0 == "role" })?.1 ?? ""
        let actionableRoles: Set<String> = [
            kAXButtonRole as String,
            kAXCheckBoxRole as String,
            kAXRadioButtonRole as String,
            kAXPopUpButtonRole as String,
            kAXComboBoxRole as String,
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXMenuItemRole as String,
            kAXSliderRole as String,
            kAXIncrementorRole as String,
        ]
        let isActionable = actions.contains(kAXPressAction as String)
            || actionableRoles.contains(role)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        var identity = values.map { "\($0.0)=\($0.1)" }.joined(separator: "|")
        identity += "|pid=\(pid)"
        if let position {
            identity += "|position=\(Int(position.x.rounded())),\(Int(position.y.rounded()))"
        }
        if let size {
            identity += "|size=\(Int(size.width.rounded())),\(Int(size.height.rounded()))"
        }
        let center: CGPoint?
        let frame: CGRect?
        if let position, let size {
            center = CGPoint(
                x: position.x + size.width / 2,
                y: position.y + size.height / 2)
            frame = CGRect(origin: position, size: size)
        } else {
            center = nil
            frame = nil
        }
        return AccessibilitySnapshot(
            summary: values.map(\.1).joined(separator: " • "),
            identity: identity,
            center: center,
            frame: frame,
            isEnabled: enabled,
            isActionable: isActionable)
    }

    private func boolAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    private func pointAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func visualDigest(around points: [CGPoint]) throws -> String? {
        guard !points.isEmpty else { return nil }
        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0,
              let image = CGDisplayCreateImage(displayID) else {
            throw ToolError.screenshotUnavailable
        }

        let scaleX = CGFloat(image.width) / bounds.width
        let scaleY = CGFloat(image.height) / bounds.height
        var digestInput = Data()
        for point in points {
            let pixelPoint = CGPoint(
                x: (point.x - bounds.minX) * scaleX,
                y: (point.y - bounds.minY) * scaleY)
            let radius: CGFloat = 48
            let imageBounds = CGRect(
                x: 0,
                y: 0,
                width: image.width,
                height: image.height)
            let cropRect = CGRect(
                x: pixelPoint.x - radius,
                y: pixelPoint.y - radius,
                width: radius * 2,
                height: radius * 2)
                .intersection(imageBounds)
                .integral
            guard cropRect.width > 0, cropRect.height > 0,
                  let crop = image.cropping(to: cropRect) else {
                throw ToolError.approvalTargetUnavailable
            }

            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: 32,
                    height: 32,
                    bitsPerComponent: 8,
                    bytesPerRow: 32 * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    return false
                }
                context.interpolationQuality = .low
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 32, height: 32))
                return true
            }
            guard rendered else { throw ToolError.screenshotUnavailable }
            digestInput.append(contentsOf: pixels)
        }
        return SHA256.hash(data: digestInput)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func perform(_ action: ComputerUsePredictedAction) throws {
        func inject(_ message: ControlMessage) throws {
            guard injector.apply(message, ifAllowed: mayAct) else {
                throw ToolError.paused
            }
        }

        guard mayAct() else { throw ToolError.paused }
        if let actionPerformer {
            try actionPerformer(action)
            return
        }
        switch action {
        case .click(let x, let y, let button, let count):
            for index in 0 ..< max(1, count) {
                try inject(.pointer(x: x, y: y, buttons: button))
                try inject(.pointer(x: x, y: y, buttons: 0))
                if index + 1 < count { Thread.sleep(forTimeInterval: 0.08) }
            }
        case .drag(let fromX, let fromY, let toX, let toY):
            try inject(.pointer(x: fromX, y: fromY, buttons: 0))
            try inject(.pointer(x: fromX, y: fromY, buttons: 1))
            // Real AppKit drag destinations commonly require several moved
            // events while the button is held. Interpolate a short, bounded
            // path instead of teleporting directly from source to destination.
            let distance = hypot(Double(toX - fromX), Double(toY - fromY))
            let steps = max(4, min(24, Int((distance / 24).rounded(.up))))
            for step in 1 ... steps {
                let fraction = Double(step) / Double(steps)
                let x = Int((Double(fromX) + Double(toX - fromX) * fraction).rounded())
                let y = Int((Double(fromY) + Double(toY - fromY) * fraction).rounded())
                try inject(.pointer(x: x, y: y, buttons: 1))
            }
            try inject(.pointer(x: toX, y: toY, buttons: 0))
        case .scroll(let x, let y, let dx, let dy):
            try inject(.pointer(x: x, y: y, buttons: 0))
            try inject(.scroll(x: x, y: y, dx: 0, dy: 0, phase: .begin))
            try inject(.scroll(x: x, y: y, dx: dx, dy: dy, phase: .changed))
            try inject(.scroll(x: x, y: y, dx: 0, dy: 0, phase: .end))
        case .key(let usage, let modifiers):
            try inject(.key(usage: usage, down: true, modifiers: modifiers))
            try inject(.key(usage: usage, down: false, modifiers: modifiers))
        case .typeText(let text):
            try inject(.text(text))
        case .requestApproval, .wait, .done:
            break
        }
    }
}

private final class ComputerUseActionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    private var automationActive = false
    private var approvalPending = false

    var allowsActions: Bool {
        lock.withLock { value }
    }

    func setAllowsActions(_ allowed: Bool) {
        lock.withLock { value = allowed }
    }

    func beginAutomation() {
        lock.withLock {
            value = true
            automationActive = true
            approvalPending = false
        }
    }

    /// Moves directly from the held approval state into the one approved
    /// operation. A synchronous user-intervention close clears
    /// `approvalPending`, so a delayed approval response cannot reopen the
    /// gate after the person has already taken control.
    func beginApprovedAutomation() -> Bool {
        lock.withLock {
            guard approvalPending else { return false }
            value = true
            automationActive = true
            approvalPending = false
            return true
        }
    }

    /// Finishing normal work may reopen the idle gate only while this caller
    /// still owns an active automation or approval transition. Intervention
    /// clears both ownership flags synchronously and therefore wins over a
    /// later completion callback.
    @discardableResult
    func endAutomation(allowsActions: Bool) -> Bool {
        lock.withLock {
            let ownsTransition = automationActive || approvalPending
            if !allowsActions {
                value = false
            } else if ownsTransition {
                value = true
            }
            automationActive = false
            approvalPending = false
            return value
        }
    }

    func beginApprovalWait() {
        lock.withLock {
            value = false
            automationActive = false
            approvalPending = true
        }
    }

    func blockForIntervention() -> Bool {
        lock.withLock {
            guard automationActive || approvalPending else { return false }
            value = false
            automationActive = false
            approvalPending = false
            return true
        }
    }
}

private final class ComputerUsePeerAuthorizationEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.withLock {
            value &+= 1
            return value
        }
    }
}

@MainActor
enum ComputerUseExecutionResult: Equatable {
    case completed(String)
    /// The executor reached a terminal, evidence-backed explanation that the
    /// requested end state cannot be achieved on this host.
    case unableToComplete(String)
    /// The task cannot proceed until the user supplies missing information.
    /// Unlike live-screen intervention, this terminalizes the stable task ID;
    /// the answer arrives as a new prompt with recent conversation context.
    case clarificationRequired(String)
    /// The requested task is still active, but the next step must be performed
    /// by the person (for example, entering account credentials). The manager
    /// preserves the task context and pauses all automation until Resume.
    case userInterventionRequired(String)
    case approvalRequired(message: String, action: ComputerUsePredictedAction)
    case mcpApprovalRequired(MCPPreparedApproval)
}

protocol HostComputerUseChannel: Sendable {
    @discardableResult
    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope

    func poll() async throws -> [ComputerUseEnvelope]
    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws
}

extension HostComputerUseChannel {
    @discardableResult
    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?
    ) async throws -> ComputerUseEnvelope {
        try await send(
            kind: kind,
            body: body,
            to: explicitTargetID,
            sessionID: explicitSessionID,
            messageID: nil)
    }
}

extension CloudKitComputerUseChannel: HostComputerUseChannel {}

/// Read-only status checks are intentionally separate from installation so
/// constructing the manager or opening the Mac UI can never start a download.
/// The production actor performs signature and receipt validation for status;
/// tests inject an in-memory implementation and never touch the network.
protocol MacControlMCPProvisioning: Sendable {
    func durableStatus() async -> MacControlMCPInstaller.DurableStatus
    func install(
        progress: @MainActor @Sendable @escaping (MacControlMCPInstaller.Update) -> Void
    ) async throws -> MacControlMCPInstallationReceipt
}

extension MacControlMCPInstaller: MacControlMCPProvisioning {}

protocol ComputerUseModelProvisioning: Sendable {
    func currentInstallation() async -> ComputerUseInstallationReceipt?
    func interruptedInstallationExists() async -> Bool
    func clearInterruptedInstallationMarker() async
    func install(
        progress: @MainActor @Sendable @escaping (ComputerUseInstaller.Update) -> Void
    ) async throws -> ComputerUseInstallationReceipt
}

extension ComputerUseInstaller: ComputerUseModelProvisioning {}

@MainActor
protocol ComputerUseExecuting: AnyObject {
    var isReady: Bool { get }
    var runtimeName: String { get }
    func execute(
        prompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult

    /// Runs a task while keeping model conversation context structurally
    /// separate from the current user-authored request. Implementations may
    /// show `prompt` to a planner, but host policy, evidence, and completion
    /// gates must use only `trustedUserPrompt`.
    func execute(
        taskID: String,
        prompt: String,
        trustedUserPrompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult
}

extension ComputerUseExecuting {
    func execute(
        taskID: String,
        prompt: String,
        trustedUserPrompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        try await execute(
            // An executor that has not explicitly adopted the separated API
            // gets the narrower user request by default. This is fail-safe:
            // it may lose conversational convenience, but it can never
            // accidentally treat prior assistant prose as host authority.
            prompt: trustedUserPrompt,
            tools: tools,
            progress: progress)
    }
}

typealias ComputerUseExecutorComposer = @MainActor @Sendable (
    MacControlMCPInstallationReceipt,
    any ComputerUseExecuting
) async throws -> any ComputerUseExecuting

@MainActor
final class HostComputerUseManager: ObservableObject {
    static let orderedControlsRequiredResponse =
        "AI Computer Use requires an updated iPhone app with ordered task controls. Update Remote Desktop before trying again. No action was taken."
    static let userInterventionGuidance =
        "AI paused because control of the Mac changed. Check the screen, then tap Let AI continue."
    static let connectionEndedResponse =
        "The connection ended before this task finished. It will not resume automatically."
    static let terminalPersistenceFailureResponse =
        "The host could not safely save the final result, so the task was not reported as complete."
    static let activeTaskConflictResponse =
        "Another AI Computer Use task is still active. Finish it or stop it, then send this request again. This request was not run."

    enum ModelState: Equatable {
        case downloadRequired
        case packageFound(fileName: String)
        case installing(detail: String, fraction: Double?)
        case ready(runtimeName: String)
        case error(String)
    }

    enum Activity: Equatable {
        case idle
        case working(String)
        case paused
        case awaitingApproval(String)
    }

    @Published private(set) var modelState: ModelState = .downloadRequired
    @Published private(set) var activity: Activity = .idle

    var capability: ComputerUseCapability {
        if macControlReceipt != nil, executor?.isReady == true {
            switch activity {
            case .idle:
                return .ready
            case .working:
                return ComputerUseCapability(
                    state: .busy,
                    detail: "AI Computer Use is working")
            case .paused:
                return ComputerUseCapability(
                    state: .paused,
                    detail: "AI Computer Use is paused")
            case .awaitingApproval:
                return ComputerUseCapability(
                    state: .paused,
                    detail: "AI Computer Use is waiting for your approval")
            }
        }

        switch modelState {
        case .installing(let detail, _):
            return ComputerUseCapability(state: .installing, detail: detail)
        case .downloadRequired, .packageFound, .error:
            return ComputerUseCapability(
                state: .setupRequired,
                detail: modelStateDetail)
        case .ready:
            guard macControlReceipt != nil else {
                return ComputerUseCapability(
                    state: .setupRequired,
                    detail: "Set up Mac control")
            }
            return .ready
        }
    }

    nonisolated static var modelDirectoryURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Remote Desktop Host", isDirectory: true)
            .appendingPathComponent("Computer Use Model", isDirectory: true)
    }

    private struct SetupRecipient: Hashable {
        let senderID: String
        let sessionID: String
        let requestID: String
        let idempotencyKey: String
    }

    private struct SetupProgressDelivery: Sendable {
        let progress: ComputerUseSetupProgress
        let targetID: String
        let sessionID: String
    }

    private struct ExecutionContext {
        let envelope: ComputerUseEnvelope
        let channel: any HostComputerUseChannel
        /// Current user-authored request, retained separately from the model
        /// prompt so assistant conversation can never become host evidence.
        let trustedUserPrompt: String
        /// False only when a versioned Pause reached the durable ledger before
        /// its Prompt. Resume can then claim and start that Prompt exactly once
        /// instead of treating it as work that needs a continuation replan.
        let hasStarted: Bool

        init(
            envelope: ComputerUseEnvelope,
            channel: any HostComputerUseChannel,
            trustedUserPrompt: String? = nil,
            hasStarted: Bool = true
        ) {
            self.envelope = envelope
            self.channel = channel
            self.trustedUserPrompt = trustedUserPrompt
                ?? ComputerUsePromptRequest.decodeCompatibleBody(
                    envelope.body).prompt
            self.hasStarted = hasStarted
        }

        func belongs(to control: ComputerUseEnvelope) -> Bool {
            envelope.senderID == control.senderID
                && envelope.sessionID == control.sessionID
        }
    }

    private enum PendingOperation {
        case visual(
            action: ComputerUsePredictedAction,
            fingerprint: ComputerUseApprovalFingerprint)
        case mcp(MCPPreparedApproval)
    }

    private struct PendingApproval {
        let request: ComputerUseApprovalRequest
        let context: ExecutionContext
        let operation: PendingOperation
    }

    private var executor: (any ComputerUseExecuting)?
    private let injector: InputInjector
    private let tools: ComputerUseHostTools
    private let actionGate: ComputerUseActionGate
    private let installer: any ComputerUseModelProvisioning
    private let macControlInstaller: any MacControlMCPProvisioning
    private let visualExecutorLoader: any ComputerUseVisualExecutorLoading
    private let executorComposer: ComputerUseExecutorComposer
    private let taskLedger: ComputerUseTaskLedger
    /// False only for app-hosted test sessions. Direct manager constructions
    /// keep the production default so their installer lifecycle tests retain
    /// the behavior they are explicitly exercising.
    let allowsExternalServices: Bool
    private let peerAuthorizationEpoch = ComputerUsePeerAuthorizationEpoch()
    private let channelFactory: @MainActor (String) -> any HostComputerUseChannel
    private var channel: (any HostComputerUseChannel)?
    private var pollingTask: Task<Void, Never>?
    /// Invalidates a poll result that arrives after its transport was stopped.
    /// Some channel implementations cannot promptly cancel an in-flight
    /// network request, so Task cancellation alone is not a sufficient fence.
    private var transportGeneration: UInt64 = 0
    private var executionTask: Task<Void, Never>?
    private var currentExecution: ExecutionContext?
    private var pausedExecution: ExecutionContext?
    /// One host task can be resumably paused at a time. Retaining its exact
    /// bounded instruction lets a duplicate accepted Prompt replay the same
    /// typed handoff instead of replacing useful sign-in guidance with a
    /// generic pause explanation.
    private var lastUserIntervention: (taskID: String, guidance: String)?
    private var currentExecutionToken: UUID?
    private var pendingApproval: PendingApproval?
    private var approvalDeliveryTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var setupProgressDeliveryTask: Task<Void, Never>?
    private var modelCheckTask: Task<Void, Never>?
    private var setupRecipients: Set<SetupRecipient> = []
    private var currentSetupProgress: ComputerUseSetupProgress?
    private var macControlReceipt: MacControlMCPInstallationReceipt?
    private var authorizedPeerID: String?
    private var authorizedPeerSupportsOrderedComputerUseControls = false
    private var appliedPeerAuthorizationEpoch: UInt64 = 0
    private var localInputMonitors: [Any] = []
    private var lastInstallerProgressPhase: ComputerUseSetupProgress.Phase?
    private var lastInstallerProgressFraction: Double?
    private var lastInstallerProgressDate = Date.distantPast
    private var isShuttingDown = false

    init(
        injector: InputInjector,
        executor: (any ComputerUseExecuting)? = nil,
        installer: (any ComputerUseModelProvisioning)? = nil,
        macControlInstaller: (any MacControlMCPProvisioning)? = nil,
        visualExecutorLoader: (any ComputerUseVisualExecutorLoading)? = nil,
        executorComposer: ComputerUseExecutorComposer? = nil,
        taskLedger: ComputerUseTaskLedger = ComputerUseTaskLedger(),
        allowsExternalServices: Bool = true,
        approvalTargetProvider:
            ((ComputerUsePredictedAction) throws -> ComputerUseApprovalTargetSnapshot)? = nil,
        actionPerformer: ((ComputerUsePredictedAction) throws -> Void)? = nil,
        screenProvider: (() throws -> ComputerUseScreenObservation)? = nil,
        accessibilityContextProvider:
            ((ComputerUsePredictedAction) -> String)? = nil,
        channelFactory: @escaping @MainActor (String) -> any HostComputerUseChannel = {
            CloudKitComputerUseChannel(
                containerIdentifier: HostConfig.cloudKitContainerIdentifier,
                pairingCode: $0)
        }
    ) {
        let gate = ComputerUseActionGate()
        self.executor = executor
        self.injector = injector
        self.actionGate = gate
        self.tools = ComputerUseHostTools(
            injector: injector,
            mayAct: { [weak gate] in gate?.allowsActions == true },
            approvalTargetProvider: approvalTargetProvider,
            actionPerformer: actionPerformer,
            screenProvider: screenProvider,
            accessibilityContextProvider: accessibilityContextProvider)
        self.installer = installer ?? ComputerUseInstaller()
        self.macControlInstaller = macControlInstaller ?? MacControlMCPInstaller()
        self.visualExecutorLoader = visualExecutorLoader
            ?? OSAtlasVisualExecutorLoader()
        self.executorComposer = executorComposer ?? { helperReceipt, visualFallback in
            try await MCPFirstComputerUseExecutor.load(
                binaryURL: URL(fileURLWithPath: helperReceipt.binaryPath),
                visualFallback: visualFallback,
                clientPool: MCPClientPool())
        }
        self.taskLedger = taskLedger
        self.allowsExternalServices = allowsExternalServices
        self.channelFactory = channelFactory
        if allowsExternalServices {
            refreshModelState()
            installLocalInterventionMonitors()
        }
    }

    func refreshModelState() {
        guard allowsExternalServices, !isShuttingDown else { return }
        if macControlReceipt != nil, let executor, executor.isReady {
            modelState = .ready(runtimeName: executor.runtimeName)
            return
        }
        guard setupTask == nil, modelCheckTask == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { modelCheckTask = nil }
            let helperStatus = await macControlInstaller.durableStatus()
            guard !Task.isCancelled, !isShuttingDown else { return }
            switch helperStatus {
            case .ready(let receipt):
                macControlReceipt = receipt
                if let executor, executor.isReady {
                    modelState = .ready(runtimeName: executor.runtimeName)
                } else if let modelReceipt = await installer.currentInstallation() {
                    modelState = .packageFound(fileName: "Verified model installation")
                    beginActivation(of: modelReceipt)
                } else if await installer.interruptedInstallationExists() {
                    // The helper receipt plus the model marker prove that this
                    // setup was explicitly initiated before the host exited.
                    modelState = .installing(
                        detail: "Resuming AI setup…",
                        fraction: nil)
                    startSetupPipeline()
                } else {
                    modelState = .downloadRequired
                }

            case .downloadPresent(let downloadedByteCount, _)
                where downloadedByteCount > 0:
                // Only real bytes in the installer's managed download area
                // authorize an automatic helper resume. A fresh status check,
                // repair state, or zero-byte marker never starts networking.
                macControlReceipt = nil
                modelState = .installing(
                    detail: "Resuming Mac control setup…",
                    fraction: nil)
                startSetupPipeline()

            case .notInstalled, .repairRequired, .downloadPresent:
                macControlReceipt = nil
                modelState = .downloadRequired
            }
        }
        modelCheckTask = task
    }

    func revealModelFolder() {
        try? FileManager.default.createDirectory(
            at: Self.modelDirectoryURL,
            withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Self.modelDirectoryURL])
    }

    func start(pairingCode: String) {
        guard allowsExternalServices else { return }
        stopTransport()
        actionGate.setAllowsActions(true)
        refreshModelState()
        let channel = channelFactory(pairingCode)
        let generation = transportGeneration
        self.channel = channel
        pollingTask = Task { [weak self] in
            await self?.pollLoop(
                channel: channel,
                generation: generation)
        }
    }

    func authorizePeer(
        senderID: String,
        supportsOrderedComputerUseControls: Bool = true
    ) {
        guard !senderID.isEmpty else { return }
        authorizedPeerID = senderID
        authorizedPeerSupportsOrderedComputerUseControls =
            supportsOrderedComputerUseControls

        guard !supportsOrderedComputerUseControls else { return }
        _ = blockActionsForUserIntervention()
        switch activity {
        case .working, .awaitingApproval:
            userIntervened()
        case .idle, .paused:
            actionGate.setAllowsActions(false)
        }
    }

    func revokePeerAuthorization() {
        authorizedPeerID = nil
        authorizedPeerSupportsOrderedComputerUseControls = false
        _ = blockActionsForUserIntervention()
        switch activity {
        case .working, .awaitingApproval:
            userIntervened()
        case .idle, .paused:
            actionGate.setAllowsActions(false)
        }
    }

    nonisolated func nextPeerAuthorizationEpoch() -> UInt64 {
        peerAuthorizationEpoch.next()
    }

    func applyPeerAuthorization(
        senderID: String,
        authorized: Bool,
        supportsOrderedComputerUseControls: Bool,
        epoch: UInt64
    ) {
        guard epoch > appliedPeerAuthorizationEpoch else { return }
        appliedPeerAuthorizationEpoch = epoch
        if authorized {
            // A disconnect closes the gate synchronously off-main. Even if a
            // newer reconnect callback reaches MainActor first, preserve that
            // intervention as a paused task requiring an explicit Resume.
            if !actionGate.allowsActions {
                switch activity {
                case .working, .awaitingApproval:
                    userIntervened()
                case .idle, .paused:
                    break
                }
            }
            authorizePeer(
                senderID: senderID,
                supportsOrderedComputerUseControls:
                    supportsOrderedComputerUseControls)
        } else {
            revokePeerAuthorization()
        }
    }

    func isPeerAuthorized(senderID: String) -> Bool {
        authorizedPeerID == senderID
    }

    func isPeerAuthorizedForComputerUse(senderID: String) -> Bool {
        authorizedPeerID == senderID
            && authorizedPeerSupportsOrderedComputerUseControls
    }

    func stop() {
        stopTransport()
        actionGate.setAllowsActions(false)
        activity = .idle
    }

    /// Application termination is stronger than disconnecting a remote peer:
    /// every in-flight setup task must finish unwinding and the local visual
    /// runtime must be gone before AppKit is allowed to exit. A plain
    /// `stop()` intentionally keeps the verified model warm for reconnects.
    func shutdown() async {
        isShuttingDown = true

        // Keep strong handles before stopTransport clears the manager slots.
        // Application shutdown is a teardown barrier: a cancelled executor
        // must finish unwinding before the visual runtime can be deactivated,
        // otherwise stale model work could outlive that deactivation boundary.
        let pendingExecution = executionTask
        let pendingSetup = setupTask
        let pendingModelCheck = modelCheckTask
        stopTransport()
        actionGate.setAllowsActions(false)
        activity = .idle

        pendingExecution?.cancel()
        setupTask?.cancel()
        modelCheckTask?.cancel()
        await pendingExecution?.value
        await pendingSetup?.value
        await pendingModelCheck?.value

        // A status check from an older build/test double may ignore task
        // cancellation and enqueue setup while it is unwinding. Re-read after
        // awaiting it so even that late task is cancelled before deactivation.
        if let lateSetup = setupTask {
            lateSetup.cancel()
            await lateSetup.value
        }

        await visualExecutorLoader.deactivate()
        executor = nil
    }

    /// Called before direct user input so automation and a person never race.
    func userIntervened() {
        switch activity {
        case .working:
            blockActionsForUserIntervention()
            let interrupted = currentExecution
            pausedExecution = interrupted
            currentExecution = nil
            currentExecutionToken = nil
            cancelActiveMCPWork()
            executionTask?.cancel()
            executionTask = nil
            activity = .paused
            if let interrupted {
                sendUserInterventionStatus(
                    Self.userInterventionGuidance,
                    replyingTo: interrupted.envelope,
                    channel: interrupted.channel)
            }

        case .awaitingApproval:
            let invalidated = pendingApproval
            pendingApproval = nil
            cancelMCPApprovalIfNeeded(invalidated)
            pausedExecution = invalidated?.context
            approvalDeliveryTask?.cancel()
            approvalDeliveryTask = nil
            activity = .paused
            if let invalidated {
                sendUserInterventionStatus(
                    Self.userInterventionGuidance,
                    replyingTo: invalidated.context.envelope,
                    channel: invalidated.context.channel)
            }

        case .idle, .paused:
            return
        }
    }

    /// The WebRTC callback invokes this synchronously before injecting the
    /// person's event. Cancellation and UI state then follow on MainActor.
    /// This closes the small race where the model could otherwise inject one
    /// more action after the user had already touched the screen.
    @discardableResult
    nonisolated func blockActionsForUserIntervention() -> Bool {
        injector.interruptAutomation { [actionGate] in
            actionGate.blockForIntervention()
        }
    }

    private func stopTransport() {
        // Fence an in-flight poll before doing anything that can yield. A
        // cancellation-ignoring channel may still return, but its generation
        // can no longer enter `handle` or acknowledge stale envelopes.
        transportGeneration &+= 1

        // Close native injection first, then durably terminalize the one live
        // task while its original envelope and channel are still available.
        // This applies equally to executing, user-paused, and approval-pending
        // work. A reconnect must never silently resume any of those states.
        actionGate.endAutomation(allowsActions: false)
        let invalidatedApproval = pendingApproval
        let terminalContext = currentExecution
            ?? pausedExecution
            ?? invalidatedApproval?.context
        if let terminalContext {
            sendDurableTerminal(
                Self.connectionEndedResponse,
                outcome: .unableToComplete,
                replyingTo: terminalContext.envelope,
                channel: terminalContext.channel)
            sendStatus(
                "ready",
                replyingTo: terminalContext.envelope,
                channel: terminalContext.channel)
        }

        if let continuation = executor as? any MCPApprovalContinuing {
            continuation.cancelMCPWork()
        }
        pollingTask?.cancel()
        pollingTask = nil
        executionTask?.cancel()
        executionTask = nil
        currentExecution = nil
        pausedExecution = nil
        pendingApproval = nil
        approvalDeliveryTask?.cancel()
        approvalDeliveryTask = nil
        setupProgressDeliveryTask?.cancel()
        setupProgressDeliveryTask = nil
        currentExecutionToken = nil
        channel = nil
        authorizedPeerID = nil
        authorizedPeerSupportsOrderedComputerUseControls = false
        setupRecipients.removeAll()
    }

    private func pollLoop(
        channel: any HostComputerUseChannel,
        generation: UInt64
    ) async {
        while !Task.isCancelled, generation == transportGeneration {
            do {
                let envelopes = try await channel.poll()
                guard !Task.isCancelled,
                      generation == transportGeneration else { return }
                var acknowledged: [ComputerUseEnvelope] = []
                for envelope in envelopes {
                    guard !Task.isCancelled,
                          generation == transportGeneration else { return }
                    if handle(envelope, channel: channel) {
                        acknowledged.append(envelope)
                    }
                }
                guard !Task.isCancelled,
                      generation == transportGeneration else { return }
                try await channel.acknowledge(acknowledged)
            } catch is CancellationError {
                return
            } catch {
                // WebRTC and an in-flight local installation stay usable during
                // a transient CloudKit problem. The short poll retries.
            }

            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    @discardableResult
    func handle(
        _ envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) -> Bool {
        switch envelope.kind {
        case .setupRequest:
            handleSetupRequest(envelope, channel: channel)
            return true
        case .setupProgress:
            return true
        case .approvalRequest:
            return true
        case .approvalResponse:
            guard let authorizedPeerID else { return false }
            guard authorizedPeerID == envelope.senderID else { return true }
            guard authorizedPeerSupportsOrderedComputerUseControls else {
                return true
            }
            handleApprovalResponse(envelope)
            return true
        case .prompt:
            guard let authorizedPeerID else { return false }
            guard authorizedPeerID == envelope.senderID else { return true }
            guard authorizedPeerSupportsOrderedComputerUseControls else {
                send(
                    kind: .assistant,
                    body: "Update Remote Desktop on this iPhone or iPad before using AI Computer Use. Ordinary remote control is still available.",
                    replyingTo: envelope,
                    channel: channel,
                    outcome: .userInterventionRequired)
                sendStatus("ready", replyingTo: envelope, channel: channel)
                return true
            }
            startExecution(for: envelope, channel: channel)
            return true
        case .pause, .resume, .cancel:
            guard let authorizedPeerID else { return false }
            guard authorizedPeerID == envelope.senderID else { return true }
            guard authorizedPeerSupportsOrderedComputerUseControls else {
                return true
            }
            return handleControl(envelope, channel: channel)
        case .assistant, .status:
            return true
        }
    }

    private func handleControl(
        _ envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) -> Bool {
        guard let control = ledgerControl(for: envelope.kind) else { return true }

        if envelope.body.isEmpty {
            handleLegacyControl(
                control,
                envelope: envelope,
                channel: channel)
            return true
        }

        guard let request = try? ComputerUseControlRequest.decodeBody(
            envelope.body),
              request.isValid else {
            // A nonempty malformed body is not treated as legacy. That would
            // let a corrupted task ID accidentally control whichever task is
            // currently active.
            return true
        }

        let context = executionContext(
            taskID: request.taskID,
            matching: envelope)

        let resolution: ComputerUseTaskLedger.ControlResolution
        do {
            resolution = try taskLedger.applyControl(
                control,
                taskID: request.taskID,
                revision: request.revision,
                senderID: envelope.senderID,
                sessionID: envelope.sessionID)
        } catch {
            // Control is fail-closed unless its causal state was durably
            // recorded. Pause and Cancel also stop the live executor before
            // returning the envelope for retry; otherwise a disk failure
            // could be acknowledged while automation kept acting.
            if control == .pause || control == .cancel,
               let context {
                pauseExecution(context)
            }
            return false
        }
        guard resolution.disposition != .identityMismatch else { return true }

        let replyEnvelope = context?.envelope
            ?? controlReplyEnvelope(
                taskID: request.taskID,
                basedOn: envelope)
        let replyChannel = context?.channel ?? channel

        if let terminalResponse = resolution.terminalResponse {
            if resolution.state == .cancelled, let context {
                stopExecution(context)
            }
            send(
                kind: .assistant,
                body: terminalResponse,
                replyingTo: replyEnvelope,
                channel: replyChannel,
                outcome: taskLedger.terminalOutcome(taskID: request.taskID))
            sendStatus(
                "ready",
                replyingTo: replyEnvelope,
                channel: replyChannel)
            return true
        }

        switch resolution.state {
        case .paused:
            if let context {
                pauseExecution(context)
            } else {
                // The Prompt may still be in flight. Its stable ID is used for
                // correlation even though no execution context exists yet.
                sendUserInterventionStatus(
                    Self.userInterventionGuidance,
                    replyingTo: replyEnvelope,
                    channel: replyChannel)
            }

        case .running:
            if resolution.disposition == .advanced,
               let context {
                if pendingApproval?.context.envelope.id
                    == context.envelope.id {
                    // A newer Resume revision supersedes the causal state
                    // stamped onto the outstanding approval. Tear down its
                    // delivery loop and held MCP generation, then replan from
                    // the current screen so only a revision-current approval
                    // can be presented or accepted.
                    pauseExecution(context)
                    resumeExecution(context, controlEnvelope: envelope)
                } else if pausedExecution?.envelope.id
                    == context.envelope.id {
                    resumeExecution(context, controlEnvelope: envelope)
                } else {
                    sendCurrentStatus(
                        for: context,
                        fallback: "ready",
                        replyingTo: replyEnvelope,
                        channel: replyChannel)
                }
            } else {
                sendCurrentStatus(
                    for: context,
                    fallback: "ready",
                    replyingTo: replyEnvelope,
                    channel: replyChannel)
            }

        case .cancelled:
            // Cancel always creates a terminal response in the ledger.
            assertionFailure("Cancelled control missing terminal response")
        case nil:
            break
        }
        return true
    }

    private func handleLegacyControl(
        _ control: ComputerUseTaskLedger.Control,
        envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) {
        // Empty bodies are the compatibility path for shipped clients. With no
        // task ID or revision, they may only touch the one live context owned
        // by the same sender and session. In particular, nil-context Pause is
        // a no-op instead of placing the whole host in a phantom paused state.
        guard let context = legacyExecutionContext(matching: envelope) else {
            return
        }

        switch control {
        case .pause:
            pauseExecution(context)
        case .resume:
            guard pausedExecution?.envelope.id == context.envelope.id else {
                return
            }
            resumeExecution(context, controlEnvelope: envelope)
        case .cancel:
            sendDurableTerminal(
                ComputerUseTaskLedger.stoppedResponse,
                outcome: .unableToComplete,
                replyingTo: context.envelope,
                channel: context.channel)
            stopExecution(context)
            sendStatus(
                "ready",
                replyingTo: context.envelope,
                channel: context.channel)
        }
    }

    private func ledgerControl(
        for kind: ComputerUseEnvelope.Kind
    ) -> ComputerUseTaskLedger.Control? {
        switch kind {
        case .pause: return .pause
        case .resume: return .resume
        case .cancel: return .cancel
        default: return nil
        }
    }

    private func legacyExecutionContext(
        matching envelope: ComputerUseEnvelope
    ) -> ExecutionContext? {
        let context = currentExecution
            ?? pausedExecution
            ?? pendingApproval?.context
        guard let context, context.belongs(to: envelope) else { return nil }
        return context
    }

    private func executionContext(
        taskID: String,
        matching envelope: ComputerUseEnvelope
    ) -> ExecutionContext? {
        let candidates = [
            currentExecution,
            pausedExecution,
            pendingApproval?.context,
        ]
        return candidates.compactMap { $0 }.first {
            $0.envelope.id == taskID && $0.belongs(to: envelope)
        }
    }

    private func pauseExecution(_ context: ExecutionContext) {
        if pausedExecution?.envelope.id == context.envelope.id {
            sendStatus(
                "paused",
                replyingTo: context.envelope,
                channel: context.channel)
            return
        }

        // Close injection before cancellation. Executors are untrusted to
        // observe Task cancellation promptly and may still unwind through a
        // final tool call.
        actionGate.endAutomation(allowsActions: false)
        let invalidatedApproval = pendingApproval
        pausedExecution = context
        currentExecution = nil
        pendingApproval = nil
        cancelMCPApprovalIfNeeded(invalidatedApproval)
        approvalDeliveryTask?.cancel()
        approvalDeliveryTask = nil
        currentExecutionToken = nil
        cancelActiveMCPWork()
        executionTask?.cancel()
        executionTask = nil
        activity = .paused
        sendUserInterventionStatus(
            Self.userInterventionGuidance,
            replyingTo: context.envelope,
            channel: context.channel)
    }

    private func resumeExecution(
        _ context: ExecutionContext,
        controlEnvelope: ComputerUseEnvelope
    ) {
        guard case .paused = activity,
              let pausedExecution,
              pausedExecution.envelope.id == context.envelope.id,
              pausedExecution.belongs(to: controlEnvelope) else {
            sendCurrentStatus(
                for: context,
                fallback: "ready",
                replyingTo: context.envelope,
                channel: context.channel)
            return
        }

        self.pausedExecution = nil
        actionGate.setAllowsActions(true)
        actionGate.endAutomation(allowsActions: true)
        activity = .idle

        if !pausedExecution.hasStarted {
            // This Prompt was durably claimed while a pre-delivered Pause was
            // in force. Re-enter the normal claim path: the ledger atomically
            // marks executionStarted and returns `.new` exactly once.
            startExecution(
                for: pausedExecution.envelope,
                channel: pausedExecution.channel)
            return
        }

        guard let executor, executor.isReady else {
            self.pausedExecution = pausedExecution
            actionGate.setAllowsActions(false)
            actionGate.endAutomation(allowsActions: false)
            activity = .paused
            sendUserInterventionStatus(
                Self.userInterventionGuidance,
                replyingTo: pausedExecution.envelope,
                channel: pausedExecution.channel)
            return
        }

        let original = pausedExecution.envelope
        let resumed = ComputerUseEnvelope(
            id: original.id,
            senderID: original.senderID,
            targetID: original.targetID,
            pairingCode: original.pairingCode,
            sessionID: original.sessionID,
            kind: .prompt,
            body: original.body
                + "\n\nContinue from the current screen after the user intervened. Some actions may already be complete; observe carefully and do not repeat them.",
            createdAt: original.createdAt)
        beginExecution(
            executor,
            for: resumed,
            trustedUserPrompt: pausedExecution.trustedUserPrompt,
            channel: pausedExecution.channel,
            isResuming: true)
    }

    private func stopExecution(_ context: ExecutionContext) {
        let activeTaskID = currentExecution?.envelope.id
            ?? pausedExecution?.envelope.id
            ?? pendingApproval?.context.envelope.id
        guard activeTaskID == context.envelope.id else { return }
        // Cancel is terminal for this execution. Keep the automation gate
        // closed until a later, separately claimed Prompt explicitly begins;
        // never let cancellation-ignoring work inject during unwind.
        actionGate.endAutomation(allowsActions: false)
        let invalidatedApproval = pendingApproval
        cancelActiveMCPWork()
        executionTask?.cancel()
        executionTask = nil
        currentExecution = nil
        pausedExecution = nil
        pendingApproval = nil
        cancelMCPApprovalIfNeeded(invalidatedApproval)
        approvalDeliveryTask?.cancel()
        approvalDeliveryTask = nil
        currentExecutionToken = nil
        activity = .idle
    }

    private func sendCurrentStatus(
        for context: ExecutionContext?,
        fallback: String,
        replyingTo envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) {
        let status: String
        if context != nil {
            switch activity {
            case .working: status = "working"
            case .paused: status = "paused"
            case .awaitingApproval:
                status = "Waiting for your approval before continuing…"
            case .idle: status = fallback
            }
        } else {
            status = fallback
        }
        sendStatus(status, replyingTo: envelope, channel: channel)
    }

    private func controlReplyEnvelope(
        taskID: String,
        basedOn control: ComputerUseEnvelope
    ) -> ComputerUseEnvelope {
        ComputerUseEnvelope(
            id: taskID,
            senderID: control.senderID,
            targetID: control.targetID,
            pairingCode: control.pairingCode,
            sessionID: control.sessionID,
            kind: .prompt,
            body: "",
            createdAt: control.createdAt)
    }

    private func handleApprovalResponse(_ envelope: ComputerUseEnvelope) {
        guard let pendingApproval,
              pendingApproval.context.belongs(to: envelope),
              let response = try? ComputerUseApprovalResponse.decodeBody(envelope.body),
              response.requestID == pendingApproval.request.requestID,
              approvalResponse(response, matches: pendingApproval) else {
            return
        }
        self.pendingApproval = nil
        approvalDeliveryTask?.cancel()
        approvalDeliveryTask = nil

        guard response.approved,
              let executor,
              executor.isReady else {
            cancelMCPApprovalIfNeeded(pendingApproval)
            actionGate.endAutomation(allowsActions: true)
            activity = .idle
            sendDurableTerminal(
                "Canceled. No action was taken.",
                outcome: .unableToComplete,
                replyingTo: pendingApproval.context.envelope,
                channel: pendingApproval.context.channel)
            sendStatus(
                "ready",
                replyingTo: pendingApproval.context.envelope,
                channel: pendingApproval.context.channel)
            return
        }

        guard actionGate.beginApprovedAutomation() else {
            // Direct input can close the gate synchronously before its
            // MainActor lifecycle callback arrives. That close owns the race:
            // keep the held task resumable and never execute the approval.
            cancelMCPApprovalIfNeeded(pendingApproval)
            pauseAfterApprovedOperationWasBlocked(
                context: pendingApproval.context)
            return
        }

        switch pendingApproval.operation {
        case .mcp(let prepared):
            continueApprovedMCP(
                prepared,
                executor: executor,
                context: pendingApproval.context)

        case .visual(let action, let fingerprint):
            activity = .working("Executing the one approved action…")
            do {
                try tools.performApproved(action, fingerprint: fingerprint)
            } catch ComputerUseHostTools.ToolError.approvalTargetChanged {
                guard actionGate.endAutomation(allowsActions: true) else {
                    pauseAfterApprovedOperationWasBlocked(
                        context: pendingApproval.context)
                    return
                }
                activity = .idle
                let original = pendingApproval.context.envelope
                let replanned = ComputerUseEnvelope(
                    id: original.id,
                    senderID: original.senderID,
                    targetID: original.targetID,
                    pairingCode: original.pairingCode,
                    sessionID: original.sessionID,
                    kind: .prompt,
                    body: original.body
                        + "\n\nThe screen or focused field changed while the user was approving the prior action. Nothing was executed. Observe the current screen again and request a fresh approval for any consequential action.",
                    createdAt: original.createdAt)
                sendStatus(
                    "The screen changed — checking again before acting…",
                    replyingTo: original,
                    channel: pendingApproval.context.channel)
                beginExecution(
                    executor,
                    for: replanned,
                    trustedUserPrompt:
                        pendingApproval.context.trustedUserPrompt,
                    channel: pendingApproval.context.channel,
                    isResuming: true)
                return
            } catch ComputerUseHostTools.ToolError.paused {
                pauseAfterApprovedOperationWasBlocked(
                    context: pendingApproval.context)
                return
            } catch {
                finishApprovedActionFailure(error, context: pendingApproval.context)
                return
            }
            guard actionGate.endAutomation(allowsActions: true) else {
                pauseAfterApprovedOperationWasBlocked(
                    context: pendingApproval.context)
                return
            }

            let original = pendingApproval.context.envelope
            let approvedPrompt = ComputerUseEnvelope(
                id: original.id,
                senderID: original.senderID,
                targetID: original.targetID,
                pairingCode: original.pairingCode,
                sessionID: original.sessionID,
                kind: .prompt,
                body: original.body + "\n\nThe host executed the one action the user approved: "
                    + pendingApproval.request.message
                    + "\nContinue from the current screen. Do not repeat it. Any later consequential action needs a new confirmation.",
                createdAt: original.createdAt)
            activity = .idle
            beginExecution(
                executor,
                for: approvedPrompt,
                trustedUserPrompt:
                    pendingApproval.context.trustedUserPrompt,
                channel: pendingApproval.context.channel,
                isResuming: true)
        }
    }

    private func pauseAfterApprovedOperationWasBlocked(
        context: ExecutionContext
    ) {
        actionGate.endAutomation(allowsActions: false)
        currentExecution = nil
        currentExecutionToken = nil
        executionTask = nil
        pausedExecution = context
        activity = .paused
        sendUserInterventionStatus(
            Self.userInterventionGuidance,
            replyingTo: context.envelope,
            channel: context.channel)
    }

    private func approvalResponse(
        _ response: ComputerUseApprovalResponse,
        matches approval: PendingApproval
    ) -> Bool {
        let taskID = approval.context.envelope.id
        let expectedRevision = approval.request.appliedControlRevision
        guard approval.request.taskID == taskID,
              taskLedger.appliedControlRevision(taskID: taskID)
                == expectedRevision else {
            // A lifecycle control advanced after the card was created. The
            // approved fingerprint and its decision are no longer causal for
            // the current task state.
            return false
        }

        if response.taskID == nil,
           response.appliedControlRevision == nil {
            // Pre-revision clients did not echo task metadata. They remain
            // compatible only while the task itself has never received a
            // versioned lifecycle control.
            return expectedRevision == nil
        }

        return response.taskID == taskID
            && response.appliedControlRevision == expectedRevision
    }

    private func cancelMCPApprovalIfNeeded(_ approval: PendingApproval?) {
        guard let approval,
              case .mcp = approval.operation,
              let continuation = executor as? any MCPApprovalContinuing else { return }
        continuation.cancelMCPWork()
    }

    /// Captures and invalidates the currently owned helper generation before
    /// task cancellation can race an immediate Resume. MCPFirst binds the
    /// asynchronous stop to that captured generation, so stale cleanup cannot
    /// terminate the generation started by the resumed task.
    private func cancelActiveMCPWork() {
        guard let continuation = executor as? any MCPApprovalContinuing else { return }
        continuation.cancelMCPWork()
    }

    private func finishApprovedActionFailure(
        _ error: Error,
        context: ExecutionContext
    ) {
        actionGate.endAutomation(allowsActions: true)
        activity = .idle
        let response = "The approved action was not performed: \(error.localizedDescription)"
        sendDurableTerminal(
            response,
            outcome: .unableToComplete,
            replyingTo: context.envelope,
            channel: context.channel)
        sendStatus("ready", replyingTo: context.envelope, channel: context.channel)
    }

    private func handleSetupRequest(
        _ envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) {
        let request: ComputerUseSetupRequest
        do {
            request = try ComputerUseSetupRequest.decodeBody(envelope.body)
        } catch {
            sendSetupProgress(
                ComputerUseSetupProgress(
                    requestID: "invalid",
                    phase: .failed,
                    detail: "The setup request was invalid.",
                    errorMessage: "Update the iOS app and try again."),
                replyingTo: envelope,
                channel: channel)
            return
        }

        guard request.idempotencyKey == ComputerUseSetupRequest.currentIdempotencyKey else {
            sendSetupProgress(
                ComputerUseSetupProgress(
                    requestID: request.requestID,
                    idempotencyKey: request.idempotencyKey,
                    phase: .failed,
                    detail: "This host needs an update.",
                    errorMessage: "Update Remote Desktop Host, then try again."),
                replyingTo: envelope,
                channel: channel)
            return
        }

        let recipient = SetupRecipient(
            senderID: envelope.senderID,
            sessionID: envelope.sessionID,
            requestID: request.requestID,
            idempotencyKey: request.idempotencyKey)

        // A fresh tap after a terminal failure is an explicit retry. Do not
        // replay the old failure before the new pipeline has a chance to start.
        if currentSetupProgress?.phase == .failed, setupTask == nil {
            setupRecipients = [recipient]
            currentSetupProgress = nil
            startSetupPipeline()
            return
        }
        // One iOS install identity has only one active monitor for this setup
        // generation. App relaunch creates a new request/session pair; keeping
        // the superseded pair would publish every later byte update to an
        // abandoned CloudKit session for the rest of a multi-hour download.
        // Other devices have different sender IDs and remain subscribed.
        setupRecipients = setupRecipients.filter {
            $0.senderID != recipient.senderID
                || $0.idempotencyKey != recipient.idempotencyKey
        }
        setupRecipients.insert(recipient)

        if macControlReceipt != nil, executor?.isReady == true {
            publishSetupProgress(
                phase: .ready,
                fraction: 1,
                detail: "AI Computer Use is ready")
            return
        }
        if let currentSetupProgress {
            sendSetupProgress(currentSetupProgress, replyingTo: envelope, channel: channel)
        }
        if setupTask == nil { startSetupPipeline() }
    }

    private func startSetupPipeline() {
        guard allowsExternalServices,
              !isShuttingDown,
              setupTask == nil else { return }
        modelCheckTask?.cancel()
        modelCheckTask = nil
        lastInstallerProgressPhase = nil
        lastInstallerProgressFraction = nil
        lastInstallerProgressDate = .distantPast
        publishSetupProgress(
            phase: .queued,
            fraction: 0,
            detail: "Checking this Mac…")
        modelState = .installing(detail: "Checking this Mac…", fraction: 0)
        setupTask = Task { [weak self] in
            guard let self else { return }
            defer { setupTask = nil }
            do {
                let helperReceipt = try await macControlInstaller.install { [weak self] update in
                    self?.consumeMacControlInstallerUpdate(update)
                }
                macControlReceipt = helperReceipt
                try Task.checkCancellation()
                let receipt = try await installer.install { [weak self] update in
                    self?.consumeInstallerUpdate(update)
                }
                try Task.checkCancellation()
                modelState = .installing(
                    detail: "Loading the on-device AI…",
                    fraction: 0.98)
                publishSetupProgress(
                    phase: .installingPackages,
                    fraction: 0.98,
                    detail: "Loading the on-device AI…")
                executor = nil
                let loaded = try await visualExecutorLoader.load(
                    receipt: receipt,
                    progress: { [weak self] detail in
                        self?.consumeRuntimeActivationUpdate(detail)
                    })
                try Task.checkCancellation()
                modelState = .installing(
                    detail: "Starting verified local Mac tools…",
                    fraction: 0.99)
                publishSetupProgress(
                    phase: .installingPackages,
                    fraction: 0.99,
                    detail: "Starting verified local Mac tools…")
                let hybrid = try await executorComposer(helperReceipt, loaded)
                try Task.checkCancellation()
                executor = hybrid
                modelState = .ready(runtimeName: hybrid.runtimeName)
                publishSetupProgress(
                    phase: .ready,
                    fraction: 1,
                    detail: "AI Computer Use is ready")
            } catch is CancellationError {
                await visualExecutorLoader.deactivate()
                executor = nil
                modelState = .downloadRequired
                publishSetupProgress(
                    phase: .failed,
                    fraction: nil,
                    detail: "Setup stopped",
                    errorMessage: "Setup stopped before AI Computer Use was activated. Tap Retry to continue.")
                return
            } catch {
                await visualExecutorLoader.deactivate()
                executor = nil
                await installer.clearInterruptedInstallationMarker()
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                modelState = .error(message)
                publishSetupProgress(
                    phase: .failed,
                    fraction: nil,
                    detail: "Setup needs attention",
                    errorMessage: message)
            }
        }
    }

    private func beginActivation(of receipt: ComputerUseInstallationReceipt) {
        guard allowsExternalServices,
              !isShuttingDown,
              setupTask == nil,
              let helperReceipt = macControlReceipt,
              executor?.isReady != true else { return }
        modelState = .installing(
            detail: "Loading the on-device AI…",
            fraction: 0.98)
        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                executor = nil
                let loaded = try await visualExecutorLoader.load(
                    receipt: receipt,
                    progress: { [weak self] detail in
                        self?.consumeRuntimeActivationUpdate(detail)
                    })
                try Task.checkCancellation()
                modelState = .installing(
                    detail: "Starting verified local Mac tools…",
                    fraction: 0.99)
                let hybrid = try await executorComposer(helperReceipt, loaded)
                try Task.checkCancellation()
                executor = hybrid
                modelState = .ready(runtimeName: hybrid.runtimeName)
                publishSetupProgress(
                    phase: .ready,
                    fraction: 1,
                    detail: "AI Computer Use is ready")
            } catch is CancellationError {
                await visualExecutorLoader.deactivate()
                executor = nil
                modelState = .downloadRequired
            } catch {
                await visualExecutorLoader.deactivate()
                executor = nil
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                modelState = .error(message)
            }
            setupTask = nil
        }
    }

    /// The small signed helper receives a visible 8% phase allocation. Its
    /// byte-count detail remains authoritative while the allocation prevents a
    /// 2.6 MB prerequisite from looking frozen beside the multi-GB model.
    private func consumeMacControlInstallerUpdate(_ update: MacControlMCPInstaller.Update) {
        let candidate = Self.visibleMacControlInstallerFraction(update)
        consumeProvisioningProgress(
            phase: .installingPackages,
            candidateFraction: candidate,
            detail: update.detail,
            minimumPublishDelta: 0.005,
            forcePublish: update.phase == .ready)
    }

    private func consumeInstallerUpdate(_ update: ComputerUseInstaller.Update) {
        let visibleFraction = Self.visibleModelInstallerFraction(update)
        let phase: ComputerUseSetupProgress.Phase
        switch update.phase {
        case .preparing:
            phase = .installingPackages
        case .downloadingModel:
            phase = .downloadingModel
        case .verifying:
            phase = .verifying
        case .ready:
            phase = .installingPackages
        }
        consumeProvisioningProgress(
            phase: phase,
            candidateFraction: visibleFraction,
            detail: update.detail,
            minimumPublishDelta: 0.02,
            forcePublish: visibleFraction == 0.97)
    }

    /// Runtime activation is part of setup too. Forward its changing detail to
    /// CloudKit so the iOS row does not appear frozen after the downloads and
    /// checksum verification have completed.
    private func consumeRuntimeActivationUpdate(_ detail: String) {
        consumeProvisioningProgress(
            phase: .installingPackages,
            candidateFraction: 0.99,
            detail: detail,
            minimumPublishDelta: 0.005,
            forcePublish: false)
    }

    private func consumeProvisioningProgress(
        phase: ComputerUseSetupProgress.Phase,
        candidateFraction: Double?,
        detail: String,
        minimumPublishDelta: Double,
        forcePublish: Bool
    ) {
        let visibleFraction = candidateFraction.map {
            max(lastInstallerProgressFraction ?? 0, min(0.99, max(0, $0)))
        } ?? lastInstallerProgressFraction
        modelState = .installing(
            detail: detail,
            fraction: visibleFraction)
        let now = Date()
        let fractionDelta = abs(
            (visibleFraction ?? lastInstallerProgressFraction ?? 0)
                - (lastInstallerProgressFraction ?? 0))
        let shouldPublish = phase != lastInstallerProgressPhase
            || fractionDelta >= minimumPublishDelta
            || now.timeIntervalSince(lastInstallerProgressDate) >= 2
            || forcePublish
        guard shouldPublish else { return }
        lastInstallerProgressPhase = phase
        lastInstallerProgressFraction = visibleFraction
        lastInstallerProgressDate = now
        publishSetupProgress(
            phase: phase,
            fraction: visibleFraction,
            detail: detail)
    }

    nonisolated static let macControlSetupFraction = 0.08

    nonisolated static func visibleMacControlInstallerFraction(
        _ update: MacControlMCPInstaller.Update
    ) -> Double {
        guard update.fraction.isFinite else { return 0 }
        return min(1, max(0, update.fraction)) * macControlSetupFraction
    }

    nonisolated static func visibleModelInstallerFraction(
        _ update: ComputerUseInstaller.Update
    ) -> Double? {
        guard let internalFraction = visibleInstallerFraction(update) else { return nil }
        let normalized = internalFraction / 0.97
        return macControlSetupFraction
            + normalized * (0.97 - macControlSetupFraction)
    }

    /// The installer owns the first 97% of user-visible setup. Native model
    /// activation then advances through 98-99% before readiness reaches 100%.
    /// This prevents the installer's internal `.ready == 1` event from making
    /// the device-row progress bar jump backward while OS-Atlas starts.
    nonisolated static func visibleInstallerFraction(
        _ update: ComputerUseInstaller.Update
    ) -> Double? {
        guard let fraction = update.fraction, fraction.isFinite else { return nil }
        return min(0.97, max(0, fraction))
    }

    private func publishSetupProgress(
        phase: ComputerUseSetupProgress.Phase,
        fraction: Double?,
        detail: String,
        errorMessage: String? = nil
    ) {
        let template = ComputerUseSetupProgress(
            requestID: setupRecipients.first?.requestID ?? "host",
            phase: phase,
            fractionCompleted: fraction,
            detail: detail,
            errorMessage: errorMessage)
        currentSetupProgress = template
        guard let channel else { return }
        let deliveries = setupRecipients.map { recipient in
            let progress = ComputerUseSetupProgress(
                requestID: recipient.requestID,
                idempotencyKey: recipient.idempotencyKey,
                phase: phase,
                fractionCompleted: fraction,
                detail: detail,
                errorMessage: errorMessage)
            return SetupProgressDelivery(
                progress: progress,
                targetID: recipient.senderID,
                sessionID: recipient.sessionID)
        }
        enqueueSetupProgress(deliveries, on: channel)
    }

    private func sendSetupProgress(
        _ progress: ComputerUseSetupProgress,
        replyingTo envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) {
        enqueueSetupProgress([
            SetupProgressDelivery(
                progress: progress,
                targetID: envelope.senderID,
                sessionID: envelope.sessionID),
        ], on: channel)
    }

    /// CloudKit sends are asynchronous. Chaining every setup update prevents
    /// a slower 99% write from arriving after the terminal 100% update and
    /// making the phone's progress bar appear to move backward or stall.
    private func enqueueSetupProgress(
        _ deliveries: [SetupProgressDelivery],
        on channel: any HostComputerUseChannel
    ) {
        guard !deliveries.isEmpty else { return }
        let previous = setupProgressDeliveryTask
        setupProgressDeliveryTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            for delivery in deliveries {
                guard !Task.isCancelled,
                      let body = try? delivery.progress.encodedBody() else {
                    continue
                }
                _ = try? await channel.send(
                    kind: .setupProgress,
                    body: body,
                    to: delivery.targetID,
                    sessionID: delivery.sessionID)
            }
        }
    }

    private func startExecution(
        for envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) {
        let activeTaskID = currentExecution?.envelope.id
            ?? pausedExecution?.envelope.id
            ?? pendingApproval?.context.envelope.id
        let hasDifferentActiveTask: Bool
        switch activity {
        case .idle:
            hasDifferentActiveTask = false
        case .working, .paused, .awaitingApproval:
            // A non-idle state without this task's matching context is also
            // treated as a conflict. It is safer to terminalize the new ID
            // than to let a transient invariant failure strand it forever.
            hasDifferentActiveTask = activeTaskID != envelope.id
        }
        do {
            switch try taskLedger.claim(
                taskID: envelope.id,
                senderID: envelope.senderID,
                sessionID: envelope.sessionID) {
            case .new:
                if hasDifferentActiveTask {
                    sendDurableTerminal(
                        Self.activeTaskConflictResponse,
                        outcome: .userInterventionRequired,
                        replyingTo: envelope,
                        channel: channel)
                    return
                }
                break
            case .paused:
                if hasDifferentActiveTask {
                    sendDurableTerminal(
                        Self.activeTaskConflictResponse,
                        outcome: .userInterventionRequired,
                        replyingTo: envelope,
                        channel: channel)
                    return
                }
                let context = ExecutionContext(
                    envelope: envelope,
                    channel: channel,
                    hasStarted: false)
                pausedExecution = context
                currentExecution = nil
                pendingApproval = nil
                currentExecutionToken = nil
                actionGate.setAllowsActions(false)
                actionGate.endAutomation(allowsActions: false)
                activity = .paused
                sendUserInterventionStatus(
                    Self.userInterventionGuidance,
                    replyingTo: envelope,
                    channel: channel)
                return
            case .completed(let response):
                send(
                    kind: .assistant,
                    body: response,
                    replyingTo: envelope,
                    channel: channel,
                    outcome: taskLedger.terminalOutcome(taskID: envelope.id))
                sendStatus("ready", replyingTo: envelope, channel: channel)
                return
            case .accepted:
                let activeID = currentExecution?.envelope.id
                    ?? pausedExecution?.envelope.id
                    ?? pendingApproval?.context.envelope.id
                if activeID == envelope.id {
                    switch activity {
                    case .working:
                        sendStatus(
                            "working",
                            replyingTo: envelope,
                            channel: channel)
                    case .paused:
                        let guidance: String
                        if let lastUserIntervention,
                           lastUserIntervention.taskID == envelope.id {
                            guidance = lastUserIntervention.guidance
                        } else {
                            guidance = Self.userInterventionGuidance
                        }
                        sendUserInterventionStatus(
                            guidance,
                            replyingTo: envelope,
                            channel: channel)
                    case .awaitingApproval:
                        sendStatus(
                            "Waiting for your approval before continuing…",
                            replyingTo: envelope,
                            channel: channel)
                    case .idle:
                        sendStatus(
                            "ready",
                            replyingTo: envelope,
                            channel: channel)
                    }
                } else {
                    let response = "That request was received before the host restarted, so it was not run again. Send it as a new request if it is still needed."
                    sendDurableTerminal(
                        response,
                        outcome: .unableToComplete,
                        replyingTo: envelope,
                        channel: channel)
                    sendStatus("ready", replyingTo: envelope, channel: channel)
                }
                return
            case .identityMismatch:
                return
            }
        } catch {
            send(
                kind: .assistant,
                body: "The host could not safely record this request, so no action was taken.",
                replyingTo: envelope,
                channel: channel,
                outcome: .unableToComplete)
            return
        }
        guard let executor, executor.isReady else {
            let response = "AI Computer Use still needs setup. Return to Devices and tap Set up AI."
            sendDurableTerminal(
                response,
                outcome: .userInterventionRequired,
                replyingTo: envelope,
                channel: channel)
            return
        }

        let request = ComputerUsePromptRequest.decodeCompatibleBody(envelope.body)
        let clarification: String?
        if request.prompt.isEmpty {
            clarification = "What would you like me to do on your Mac?"
        } else {
            clarification = ComputerUseClarificationPolicy.question(for: request)
        }
        if let clarification {
            // This is a terminal response for this stable task ID. The user's
            // answer is a new prompt carrying this question in recent chat
            // context, which keeps retries at-most-once and multi-turn chat
            // unambiguous across host or app restarts.
            sendDurableTerminal(
                clarification,
                outcome: .userInterventionRequired,
                replyingTo: envelope,
                channel: channel)
            sendStatus("ready", replyingTo: envelope, channel: channel)
            return
        }

        // From here onward the existing pause/approval/replan lifecycle works
        // with plain model input. The original IDs and routing fields remain
        // unchanged, so ledger replay and CloudKit correlation stay intact.
        let executionEnvelope = ComputerUseEnvelope(
            id: envelope.id,
            senderID: envelope.senderID,
            targetID: envelope.targetID,
            pairingCode: envelope.pairingCode,
            sessionID: envelope.sessionID,
            kind: envelope.kind,
            body: request.modelPrompt,
            createdAt: envelope.createdAt)
        beginExecution(
            executor,
            for: executionEnvelope,
            trustedUserPrompt: request.prompt,
            channel: channel)
    }

    private func beginExecution(
        _ executor: any ComputerUseExecuting,
        for envelope: ComputerUseEnvelope,
        trustedUserPrompt: String,
        channel: any HostComputerUseChannel,
        isResuming: Bool = false
    ) {
        executionTask?.cancel()
        actionGate.beginAutomation()
        let context = ExecutionContext(
            envelope: envelope,
            channel: channel,
            trustedUserPrompt: trustedUserPrompt)
        let token = UUID()
        currentExecution = context
        currentExecutionToken = token
        activity = .working(isResuming ? "Continuing…" : "Starting…")
        sendStatus("working", replyingTo: envelope, channel: channel)
        executionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let progress: (String) -> Void = { [weak self] value in
                    guard self?.currentExecutionToken == token else { return }
                    self?.activity = .working(value)
                    self?.sendStatus(value, replyingTo: envelope, channel: channel)
                }
                let result = try await executor.execute(
                    taskID: envelope.id,
                    prompt: envelope.body,
                    trustedUserPrompt: trustedUserPrompt,
                    tools: tools,
                    progress: progress)
                guard !Task.isCancelled,
                      currentExecutionToken == token else { return }
                try acceptExecutionResult(
                    result,
                    executor: executor,
                    context: context,
                    token: token)
            } catch is CancellationError {
                // Lifecycle-driven cancellation clears/replaces the token
                // before this task observes it. A cancellation originating
                // inside a model/runtime must not leave the UI permanently in
                // "working" with an accepted, nonterminal ledger record.
                finishUnexpectedCancellationIfCurrent(
                    context: context,
                    token: token)
                return
            } catch ComputerUseHostTools.ToolError.paused {
                // The injection gate can close synchronously on local input or
                // WebRTC disconnect before its MainActor lifecycle callback.
                // Preserve the task for explicit Resume instead of recording
                // a pause as a terminal failure.
                guard currentExecutionToken == token else { return }
                currentExecution = nil
                currentExecutionToken = nil
                pausedExecution = context
                actionGate.endAutomation(allowsActions: false)
                activity = .paused
                sendUserInterventionStatus(
                    Self.userInterventionGuidance,
                    replyingTo: envelope,
                    channel: channel)
            } catch {
                guard currentExecutionToken == token else { return }
                if currentExecution?.envelope.id == envelope.id {
                    currentExecution = nil
                }
                currentExecutionToken = nil
                actionGate.endAutomation(allowsActions: true)
                activity = .idle
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                let response = "I couldn't complete that task: \(message)"
                sendDurableTerminal(
                    response,
                    outcome: .unableToComplete,
                    replyingTo: envelope,
                    channel: channel)
                sendStatus("ready", replyingTo: envelope, channel: channel)
            }
        }
    }

    private func continueApprovedMCP(
        _ prepared: MCPPreparedApproval,
        executor: any ComputerUseExecuting,
        context: ExecutionContext
    ) {
        guard let continuation = executor as? any MCPApprovalContinuing else {
            finishApprovedActionFailure(
                MCPClientError.approvalMismatch,
                context: context)
            return
        }

        executionTask?.cancel()
        let token = UUID()
        currentExecution = context
        currentExecutionToken = token
        activity = .working("Performing the one approved Mac action…")
        sendStatus(
            "Performing the one approved Mac action…",
            replyingTo: context.envelope,
            channel: context.channel)

        executionTask = Task { [weak self] in
            guard let self else { return }
            guard actionGate.allowsActions else {
                pauseAfterApprovedOperationWasBlocked(context: context)
                return
            }
            do {
                let result = try await continuation.continueAfterApproval(
                    prepared,
                    tools: tools,
                    progress: { [weak self] value in
                        guard self?.currentExecutionToken == token else { return }
                        self?.activity = .working(value)
                        self?.sendStatus(
                            value,
                            replyingTo: context.envelope,
                            channel: context.channel)
                    })
                guard !Task.isCancelled,
                      currentExecutionToken == token else { return }
                try acceptExecutionResult(
                    result,
                    executor: executor,
                    context: context,
                    token: token)
            } catch is CancellationError {
                finishUnexpectedCancellationIfCurrent(
                    context: context,
                    token: token)
                return
            } catch {
                guard currentExecutionToken == token else { return }
                currentExecution = nil
                currentExecutionToken = nil
                executionTask = nil
                finishApprovedActionFailure(error, context: context)
            }
        }
    }

    private func acceptExecutionResult(
        _ result: ComputerUseExecutionResult,
        executor: any ComputerUseExecuting,
        context: ExecutionContext,
        token: UUID
    ) throws {
        guard currentExecutionToken == token else { throw CancellationError() }
        let envelope = context.envelope

        switch result {
        case .completed(let response):
            sendDurableTerminal(
                response,
                outcome: .taskCompleted,
                replyingTo: envelope,
                channel: context.channel)
            currentExecution = nil
            currentExecutionToken = nil
            executionTask = nil
            actionGate.endAutomation(allowsActions: true)
            activity = .idle
            sendStatus("ready", replyingTo: envelope, channel: context.channel)

        case .unableToComplete(let response):
            sendDurableTerminal(
                response,
                outcome: .unableToComplete,
                replyingTo: envelope,
                channel: context.channel)
            currentExecution = nil
            currentExecutionToken = nil
            executionTask = nil
            actionGate.endAutomation(allowsActions: true)
            activity = .idle
            sendStatus("ready", replyingTo: envelope, channel: context.channel)

        case .clarificationRequired(let response):
            sendDurableTerminal(
                response,
                outcome: .userInterventionRequired,
                replyingTo: envelope,
                channel: context.channel)
            currentExecution = nil
            currentExecutionToken = nil
            executionTask = nil
            actionGate.endAutomation(allowsActions: true)
            activity = .idle
            sendStatus("ready", replyingTo: envelope, channel: context.channel)

        case .userInterventionRequired(let message):
            // This is not a terminal assistant response and must not complete
            // the idempotency ledger. Preserve the exact prompt so the user
            // can sign in through the live screen and resume from the changed
            // UI without starting a second task.
            pausedExecution = context
            currentExecution = nil
            currentExecutionToken = nil
            executionTask = nil
            actionGate.setAllowsActions(false)
            actionGate.endAutomation(allowsActions: false)
            activity = .paused
            sendUserInterventionStatus(
                message,
                replyingTo: envelope,
                channel: context.channel)

        case .approvalRequired(_, let proposedAction):
            // The visual model's confirmation copy is untrusted. Build the
            // user-facing description and TOCTOU fingerprint from the exact
            // action and current Accessibility target.
            let prepared = try tools.prepareApproval(for: proposedAction)
            let request = ComputerUseApprovalRequest(
                taskID: envelope.id,
                message: prepared.message)
            enterApproval(
                PendingApproval(
                    request: request,
                    context: context,
                    operation: .visual(
                        action: proposedAction,
                        fingerprint: prepared.fingerprint)))

        case .mcpApprovalRequired(let prepared):
            guard prepared.call.taskID == envelope.id else {
                throw MCPClientError.approvalMismatch
            }
            let presentation = prepared.computerUsePresentation
            let request = ComputerUseApprovalRequest(
                taskID: envelope.id,
                message: presentation.message,
                details: presentation.details,
                confirmLabel: presentation.confirmLabel)
            enterApproval(PendingApproval(
                request: request,
                context: context,
                operation: .mcp(prepared)))
        }
    }

    private func finishUnexpectedCancellationIfCurrent(
        context: ExecutionContext,
        token: UUID
    ) {
        guard currentExecutionToken == token else { return }
        currentExecution = nil
        currentExecutionToken = nil
        executionTask = nil
        actionGate.endAutomation(allowsActions: true)
        activity = .idle
        let response = "The task stopped before it finished. It will not be retried automatically."
        sendDurableTerminal(
            response,
            outcome: .unableToComplete,
            replyingTo: context.envelope,
            channel: context.channel)
        sendStatus("ready", replyingTo: context.envelope, channel: context.channel)
    }

    private func enterApproval(_ approval: PendingApproval) {
        let request = ComputerUseApprovalRequest(
            requestID: approval.request.requestID,
            taskID: approval.context.envelope.id,
            message: approval.request.message,
            details: approval.request.details,
            confirmLabel: approval.request.confirmLabel,
            appliedControlRevision: taskLedger.appliedControlRevision(
                taskID: approval.context.envelope.id))
        let stampedApproval = PendingApproval(
            request: request,
            context: approval.context,
            operation: approval.operation)
        pendingApproval = stampedApproval
        currentExecution = nil
        currentExecutionToken = nil
        executionTask = nil
        actionGate.beginApprovalWait()
        activity = .awaitingApproval(request.message)
        startApprovalDelivery(stampedApproval)
        sendStatus(
            "Waiting for your approval before continuing…",
            replyingTo: stampedApproval.context.envelope,
            channel: stampedApproval.context.channel)
    }

    private func sendStatus(
        _ status: String,
        replyingTo envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel,
        outcome: ComputerUseTerminalOutcome? = nil
    ) {
        send(
            kind: .status,
            body: status,
            replyingTo: envelope,
            channel: channel,
            outcome: outcome)
    }

    /// Every resumable handoff carries both the legacy-safe text prefix and the
    /// host-authoritative typed outcome. The prefix keeps older clients safely
    /// paused; the outcome lets current clients and evaluators distinguish a
    /// person-only step from generic progress without parsing prose.
    private func sendUserInterventionStatus(
        _ guidance: String,
        replyingTo envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) {
        let signal = ComputerUseStatusSignal.userIntervention(guidance)
        if let boundedGuidance = ComputerUseStatusSignal
            .userInterventionMessage(from: signal) {
            lastUserIntervention = (
                taskID: envelope.id,
                guidance: boundedGuidance)
        }
        sendStatus(
            signal,
            replyingTo: envelope,
            channel: channel,
            outcome: .userInterventionRequired)
    }

    /// A terminal reply is authoritative only after its first-result-wins
    /// ledger record reaches durable storage. If that write fails, never emit
    /// the requested result (especially success); report the storage failure
    /// directly and leave the poisoned ledger to reject future retries.
    private func sendDurableTerminal(
        _ response: String,
        outcome: ComputerUseTerminalOutcome,
        replyingTo envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) {
        do {
            let terminal = try taskLedger.complete(
                taskID: envelope.id,
                response: response,
                outcome: outcome)
            send(
                kind: .assistant,
                body: terminal.response,
                replyingTo: envelope,
                channel: channel,
                outcome: terminal.outcome)
        } catch {
            send(
                kind: .assistant,
                body: Self.terminalPersistenceFailureResponse,
                replyingTo: envelope,
                channel: channel,
                outcome: .unableToComplete)
        }
    }

    private func startApprovalDelivery(_ approval: PendingApproval) {
        approvalDeliveryTask?.cancel()
        approvalDeliveryTask = Task { [weak self] in
            guard let body = try? approval.request.encodedBody() else { return }
            while !Task.isCancelled {
                guard self?.pendingApproval?.request.requestID
                        == approval.request.requestID else { return }
                _ = try? await approval.context.channel.send(
                    kind: .approvalRequest,
                    body: body,
                    to: approval.context.envelope.senderID,
                    sessionID: approval.context.envelope.sessionID,
                    messageID: nil)
                do {
                    try await Task.sleep(for: .seconds(8))
                } catch {
                    return
                }
            }
        }
    }

    private func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        replyingTo envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel,
        outcome: ComputerUseTerminalOutcome? = nil
    ) {
        let wireBody: String
        switch kind {
        case .assistant, .status:
            wireBody = (try? ComputerUseTaskUpdate(
                taskID: envelope.id,
                text: body,
                appliedControlRevision: taskLedger.appliedControlRevision(
                    taskID: envelope.id),
                outcome: outcome).encodedBody()) ?? body
        default:
            wireBody = body
        }
        Task {
            _ = try? await channel.send(
                kind: kind,
                body: wireBody,
                to: envelope.senderID,
                sessionID: envelope.sessionID,
                messageID: nil)
        }
    }

    private var modelStateDetail: String {
        switch modelState {
        case .downloadRequired:
            return "Set up AI Computer Use"
        case .packageFound:
            return "Loading the installed AI model"
        case .installing(let detail, _):
            return detail
        case .ready:
            return "AI Computer Use is ready"
        case .error(let message):
            return message
        }
    }

    private func installLocalInterventionMonitors() {
        guard !HostRuntimeContext.isRunningUnitTests else {
            return
        }
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .keyDown, .flagsChanged,
        ]
        let interrupt: @Sendable (NSEvent) -> Void = { [weak self] event in
            guard !InputInjector.isSynthetic(event),
                  self?.blockActionsForUserIntervention() == true else { return }
            Task { @MainActor [weak self] in self?.userIntervened() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: mask,
            handler: interrupt) {
            localInputMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: mask,
            handler: { event in
                interrupt(event)
                return event
            }) {
            localInputMonitors.append(local)
        }
    }
}
