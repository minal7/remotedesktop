#if DEBUG
import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
enum DebugAgentEvalCommand {
    static let argument = "--debug-agent-eval"

    static func shouldRun(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.dropFirst().first == argument
    }

    static func runIfRequested(
        arguments: [String] = CommandLine.arguments,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        errorOutput: FileHandle = .standardError
    ) async -> Int32? {
        guard shouldRun(arguments: arguments) else { return nil }
        guard Array(arguments.dropFirst()).count == 1 else {
            write("invalid evaluation command arguments\n", to: errorOutput)
            return 2
        }
        do {
            let data = input.readDataToEndOfFile()
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let encoded: Data
            if root?["operation"] as? String == "coordinate_calibration" {
                let request = try CoordinateCalibrationRequest.decodeStrict(data)
                let report = await CoordinateCalibration.run(seed: request.selectionSeed)
                encoded = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            } else if root?["operation"] as? String == "policy_replay" {
                let request = try AgentEvalPolicyReplayRequest.decodeStrict(data)
                encoded = try JSONEncoder().encode(await AgentEvalPolicyReplay.run(request))
            } else if root?["operation"] as? String == "preflight" {
                let response: AgentEvalPreflightResponse
                if let request = try? AgentEvalPreflightRequest.decodeStrict(data) {
                    response = await AgentEvalPreflight.run(request)
                } else {
                    response = .invalidRequest()
                }
                encoded = try JSONEncoder().encode(response)
            } else {
                let request = try AgentEvalRequest.decodeStrict(data)
                let response = try await DebugAgentEvalSession(request: request).run()
                encoded = try JSONEncoder().encode(response)
            }
            output.write(encoded)
            output.write(Data([0x0A]))
            return 0
        } catch {
            write("evaluation driver failed: \(error.localizedDescription)\n", to: errorOutput)
            return 1
        }
    }

    private static func write(_ value: String, to handle: FileHandle) {
        handle.write(Data(value.utf8))
    }
}

private struct CoordinateCalibrationRequest {
    let selectionSeed: UInt64

    static func decodeStrict(_ data: Data) throws -> Self {
        guard data.count <= 4_096,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["operation", "selection_seed"],
              object["operation"] as? String == "coordinate_calibration",
              let number = object["selection_seed"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue < 18_446_744_073_709_551_616.0 else {
            throw AgentEvalWireError.invalidRequest
        }
        return Self(selectionSeed: number.uint64Value)
    }
}

/// Read-only, DEBUG-only coordinate calibration. It opens only the three declared apps,
/// captures their selected windows, and never posts input events.
@MainActor
private enum CoordinateCalibration {
    private struct AppSpec {
        let name: String
        let bundleID: String
    }

    private struct WindowSample {
        let spec: AppSpec
        let app: NSRunningApplication
        let target: SCWindow
        let bounds: CGRect
        let image: CGImage
        let expectedNativeSize: CGSize
        let nativeSize: CGSize
        let pointPixelScale: CGFloat
        let filterContentRect: CGRect
        let marks: [PixelElementMark]
        let focusedAXTitle: String?
        let frameCandidateCount: Int
        let maskedSecureRegions: Int
        let visibleWindowCount: Int
        let pngPath: String
        let pngSHA256: String
    }

    private static let apps = [
        AppSpec(name: "Safari", bundleID: "com.apple.Safari"),
        AppSpec(name: "TextEdit", bundleID: "com.apple.TextEdit"),
        AppSpec(name: "Finder", bundleID: "com.apple.finder"),
    ]

    static func run(seed: UInt64) async -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        var appFailures: [[String: Any]] = []
        do {
            let rootPath = try evaluationRoot()
            let runDirectory = try makePrivateRunDirectory(rootPath: rootPath)
            var rng = SplitMix64(seed: seed)
            var samples: [WindowSample] = []
            var checks: [[String: Any]] = []
            var eligibleCounts: [String: Int] = [:]
            var selectedCounts: [String: Int] = [:]
            var windows: [[String: Any]] = []
            for spec in apps {
                do {
                    let sample = try await capture(spec: spec, seed: seed, directory: runDirectory)
                    windows.append(windowJSON(sample))
                    samples.append(sample)
                } catch {
                    appFailures.append(["app": spec.name, "bundleID": spec.bundleID,
                        "error": String(describing: error)])
                }
            }
            let candidates = samples.map { sample -> [PixelElementMark] in
                var marks = eligibleMarks(in: sample)
                rng.shuffle(&marks)
                eligibleCounts[sample.spec.bundleID] = marks.count
                return marks
            }
            let quotas = allocate(count: 20, capacities: candidates.map(\.count), rng: &rng)
            for index in candidates.indices {
                let sample = samples[index]
                let selected = Array(candidates[index].prefix(quotas[index]))
                selectedCounts[sample.spec.bundleID] = selected.count
                guard await reactivateAndVerify(sample) else {
                    appFailures.append(["app": sample.spec.name, "bundleID": sample.spec.bundleID,
                        "error": "The sampled window was no longer frontmost and focused before its AX checks."])
                    continue
                }
                for mark in selected { checks.append(check(mark, sample: sample)) }
            }
            let passCount = checks.filter { $0["axEqual"] as? Bool == true }.count
            let expectedCount = 20
            let appsCovered = apps.allSatisfy { (selectedCounts[$0.bundleID] ?? 0) > 0 }
            return [
                "operation": "coordinate_calibration",
                "selectionSeed": seed,
                "readOnly": true,
                "inputEventsPosted": 0,
                "expectedChecks": expectedCount,
                "checks": checks,
                "windows": windows,
                "eligibleMarksByBundleID": eligibleCounts,
                "selectedMarksByBundleID": selectedCounts,
                "allThreeAppsRepresented": appsCovered,
                "appFailures": appFailures,
                "passedChecks": passCount,
                "passed": checks.count == expectedCount && passCount == expectedCount && appsCovered && appFailures.isEmpty,
                "wallSeconds": ProcessInfo.processInfo.systemUptime - started,
            ]
        } catch {
            return ["operation": "coordinate_calibration", "selectionSeed": seed,
                "readOnly": true, "inputEventsPosted": 0, "passed": false,
                "checks": [], "appFailures": appFailures,
                "error": String(describing: error),
                "wallSeconds": ProcessInfo.processInfo.systemUptime - started]
        }
    }

    private static func eligibleMarks(in sample: WindowSample) -> [PixelElementMark] {
        sample.marks.filter { mark in
            PixelTargetSnapping.interactiveRoles.contains(mark.role) && mark.inView &&
                !mark.state.contains("disabled") &&
                sample.bounds.contains(CGPoint(x: mark.screenRect.midX, y: mark.screenRect.midY))
        }
    }

    private static func allocate(count: Int, capacities: [Int], rng: inout SplitMix64) -> [Int] {
        var quotas = capacities.map { $0 > 0 ? 1 : 0 }
        var remaining = max(0, count - quotas.reduce(0, +))
        while remaining > 0 {
            var available = capacities.indices.filter { quotas[$0] < capacities[$0] }
            guard !available.isEmpty else { break }
            rng.shuffle(&available)
            for index in available where remaining > 0 {
                quotas[index] += 1
                remaining -= 1
            }
        }
        return quotas
    }

    private static func reactivateAndVerify(_ sample: WindowSample) async -> Bool {
        _ = sample.app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var previousWindowID: UInt32?
        var previousFrame: CGRect?
        var stablePolls = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == sample.app.processIdentifier {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    let candidates = content.windows.filter {
                        $0.owningApplication?.processID == sample.app.processIdentifier &&
                        $0.frame.width > 50 && $0.frame.height > 50 && $0.isOnScreen
                    }
                    let root = AXUIElementCreateApplication(sample.app.processIdentifier)
                    if let focused = ElementMarks.focusedWindow(root), let bounds = ElementMarks.bounds(focused),
                       let windowID = AgentMacAccessibility.matchingWindowID(ownerPID: sample.app.processIdentifier,
                           bounds: bounds, focusedTitle: ElementMarks.string(focused, kAXTitleAttribute)),
                       let target = candidates.first(where: { $0.windowID == windowID }),
                       windowID == sample.target.windowID,
                       ElementMarks.focusedWindowMatches(bounds, selectedBounds: target.frame),
                       ElementMarks.focusedWindowMatches(sample.bounds, selectedBounds: target.frame) {
                        stablePolls = previousWindowID == windowID && previousFrame == target.frame
                            ? stablePolls + 1 : 1
                        if stablePolls >= 2 { return true }
                        previousWindowID = windowID; previousFrame = target.frame
                    } else { stablePolls = 0; previousWindowID = nil; previousFrame = nil }
                } catch { return false }
            } else {
                stablePolls = 0; previousWindowID = nil; previousFrame = nil
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    private static func evaluationRoot() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["REMOTE_DESKTOP_EVAL_ROOT"],
              path.hasPrefix("/"), !path.contains("\0") else { throw AgentEvalWireError.bootstrapFailure }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw AgentEvalWireError.bootstrapFailure
        }
        let parent = root.appendingPathComponent("coordinate-calibration", isDirectory: true)
        if mkdir(parent.path, 0o700) != 0 && errno != EEXIST { throw AgentEvalWireError.bootstrapFailure }
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw AgentEvalWireError.bootstrapFailure
        }
        return parent
    }

    private static func makePrivateRunDirectory(rootPath: URL) throws -> URL {
        let directory = rootPath.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw AgentEvalWireError.bootstrapFailure }
        return directory
    }

    private static func capture(spec: AppSpec, seed: UInt64, directory: URL) async throws -> WindowSample {
        guard AXIsProcessTrusted(), let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: spec.bundleID) else {
            throw AgentEnvironmentError.unavailable("Accessibility or the expected app is unavailable.")
        }
        let app: NSRunningApplication
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == spec.bundleID }) {
            app = running
        } else {
            app = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { running, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let running { continuation.resume(returning: running) }
                    else { continuation.resume(throwing: AgentEvalWireError.bootstrapFailure) }
                }
            }
        }
        _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var selected: (SCWindow, AXUIElement, CGRect, SCShareableContent)?
        var previousWindowID: UInt32?
        var previousFrame: CGRect?
        var stablePolls = 0
        var selectionDiagnostic = "No focused AX window was observed."
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                previousWindowID = nil; previousFrame = nil; stablePolls = 0
                try? await Task.sleep(for: .milliseconds(150)); continue
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let root = AXUIElementCreateApplication(app.processIdentifier)
            if let focused = ElementMarks.focusedWindow(root), let bounds = ElementMarks.bounds(focused) {
                let candidates = content.windows.filter {
                    $0.owningApplication?.processID == app.processIdentifier && $0.frame.width > 50 && $0.frame.height > 50 && $0.isOnScreen
                }
                let title = ElementMarks.string(focused, kAXTitleAttribute)
                let frameCandidates = candidates.filter { ElementMarks.focusedWindowMatches(bounds, selectedBounds: $0.frame) }
                let summary = frameCandidates.prefix(12).map { window in
                    "\(window.windowID):\(String((window.title ?? "").prefix(80))):\(rectJSON(window.frame))"
                }.joined(separator: "; ")
                selectionDiagnostic = "focusedAXTitle=\(String((title ?? "").prefix(120))), focusedBounds=\(rectJSON(bounds)), frameCandidates=[\(summary)]"
                let windowID = AgentMacAccessibility.matchingWindowID(ownerPID: app.processIdentifier,
                    bounds: bounds, focusedTitle: title)
                if let windowID, let target = candidates.first(where: { $0.windowID == windowID }),
                   ElementMarks.focusedWindowMatches(bounds, selectedBounds: target.frame) {
                    stablePolls = previousWindowID == target.windowID && previousFrame == target.frame
                        ? stablePolls + 1 : 1
                    if stablePolls >= 2 { selected = (target, focused, bounds, content); break }
                    previousWindowID = target.windowID; previousFrame = target.frame
                } else {
                    previousWindowID = nil; previousFrame = nil; stablePolls = 0
                }
            } else {
                previousWindowID = nil; previousFrame = nil; stablePolls = 0
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard let (target, focused, bounds, content) = selected else {
            throw AgentEnvironmentError.unavailable("No AX/ScreenCaptureKit window match for \(spec.name); \(selectionDiagnostic)")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let axWindow = AgentMacAccessibility.Window(application: app, element: focused,
            bounds: target.frame, number: target.windowID, title: target.title ?? "")
        let marks = ElementMarks.readCapture(window: axWindow, focusedWindowElement: focused,
            focusedBounds: bounds, appRoot: root, application: app, selectedBounds: target.frame,
            budget: .seconds(2), limit: 256)
        let native = try await PixelEnvironment.captureNativeWindow(target)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw AgentEnvironmentError.scopeChanged
        }
        guard let resized = PixelGeometry.resize(native.image, width: 1280) else {
            throw AgentEnvironmentError.unavailable("Captured pixels did not match the requested native window geometry.")
        }
        let (image, maskedCount) = try maskSecureRegions(resized, screenBounds: target.frame,
            secureRects: marks.secureScreenRects)
        let png = try pngData(image)
        let pngName = "\(spec.bundleID.replacingOccurrences(of: ".", with: "_"))-\(seed).png"
        let pngURL = directory.appendingPathComponent(pngName)
        try png.write(to: pngURL, options: .atomic)
        guard chmod(pngURL.path, 0o600) == 0 else { throw AgentEvalWireError.bootstrapFailure }
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        return WindowSample(spec: spec, app: app, target: target, bounds: target.frame,
            image: image, expectedNativeSize: native.expectedPixelSize,
            nativeSize: CGSize(width: native.image.width, height: native.image.height),
            pointPixelScale: native.pointPixelScale, filterContentRect: native.contentRect,
            marks: marks.marks, focusedAXTitle: ElementMarks.string(focused, kAXTitleAttribute),
            frameCandidateCount: content.windows.filter {
                $0.owningApplication?.processID == app.processIdentifier &&
                ElementMarks.focusedWindowMatches(bounds, selectedBounds: $0.frame)
            }.count, maskedSecureRegions: maskedCount,
            visibleWindowCount: content.windows.filter { $0.owningApplication?.processID == app.processIdentifier && $0.isOnScreen }.count,
            pngPath: pngURL.path, pngSHA256: hash)
    }

    private static func check(_ mark: PixelElementMark, sample: WindowSample) -> [String: Any] {
        let center = CGPoint(x: mark.screenRect.midX, y: mark.screenRect.midY)
        let imageSize = CGSize(width: sample.image.width, height: sample.image.height)
        let pixel = PixelGeometry.imagePoint(center, imageSize: imageSize, screenBounds: sample.bounds)
        let roundTrip = pixel.flatMap { PixelGeometry.point($0, imageSize: imageSize, screenBounds: sample.bounds) }
        let appRoot = AXUIElementCreateApplication(sample.app.processIdentifier)
        var actual: AXUIElement?
        let status: AXError
        if let point = roundTrip {
            status = AXUIElementCopyElementAtPosition(appRoot, Float(point.x), Float(point.y), &actual)
        } else { status = .failure }
        let expected = mark.identity?.base as? PixelAXIdentity
        let equal: Bool
        if status == .success, let expected, let actual { equal = CFEqual(expected.element, actual) }
        else { equal = false }
        var actualHitDescendsFromExpected = false
        var actualHitParentLinksVisited = 0
        if let actual, let expected, !CFEqual(expected.element, actual) {
            var current = actual
            var visited: [AXUIElement] = []
            for _ in 0..<8 {
                guard !visited.contains(where: { CFEqual($0, current) }) else { break }
                visited.append(current)
                AXUIElementSetMessagingTimeout(current, 0.1)
                var parentValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    current, kAXParentAttribute as CFString, &parentValue) == .success,
                    let parentValue,
                    CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { break }
                let parent = unsafeBitCast(parentValue, to: AXUIElement.self)
                actualHitParentLinksVisited += 1
                if CFEqual(expected.element, parent) {
                    actualHitDescendsFromExpected = true
                    break
                }
                current = parent
            }
        }
        var actualPID: pid_t = 0
        let actualPIDStatus: AXError
        if let actual { actualPIDStatus = AXUIElementGetPid(actual, &actualPID) }
        else { actualPIDStatus = .failure }
        let actualBounds = actual.flatMap(ElementMarks.bounds)
        let actualRole = actual.flatMap { ElementMarks.string($0, kAXRoleAttribute) }
        let actualTitle = actual.flatMap { ElementMarks.string($0, kAXTitleAttribute) }
        let actualDescription = actual.flatMap { ElementMarks.string($0, kAXDescriptionAttribute) }
        let actualName = actual.map(ElementMarks.label)
        let hitWindows = actual.map { _ in
            onScreenWindowCandidates(ownerPID: actualPID, point: roundTrip,
                                     elementBounds: actualBounds)
        } ?? []
        let windowAtPoint = hitWindows.first { $0["containsPoint"] as? Bool == true }
        return [
            "app": sample.spec.name, "bundleID": sample.spec.bundleID,
            "windowID": sample.target.windowID, "windowTitle": sample.target.title ?? "",
            "role": mark.role, "name": mark.name, "markID": mark.id,
            "sourceCenter": pointJSON(center), "screenshotPixel": pixel.map { pointJSON($0) as Any } ?? NSNull(),
            "roundTripPoint": roundTrip.map { pointJSON($0) as Any } ?? NSNull(),
            "expectedMarkBounds": rectJSON(mark.screenRect),
            "actualHitDescendsFromExpected": actualHitDescendsFromExpected,
            "actualHitParentLinksVisited": actualHitParentLinksVisited,
            "axEqual": equal, "axError": status.rawValue,
            "actualAXRole": actualRole ?? "", "actualAXTitle": actualTitle ?? "",
            "actualAXDescription": actualDescription ?? "", "actualAXName": actualName ?? "",
            "actualAXBounds": actualBounds.map { rectJSON($0) as Any } ?? NSNull(),
            "actualAXPID": actualPIDStatus == .success ? actualPID : 0,
            "hitPointWindowCandidates": hitWindows,
            "actualWindowIDAtPoint": windowAtPoint?["windowID"] ?? NSNull(),
            "selectedWindowAmongHitCandidates": hitWindows.contains {
                ($0["windowID"] as? UInt32) == sample.target.windowID
            },
            "windowFrame": rectJSON(sample.bounds),
            "expectedNativePixels": ["width": sample.expectedNativeSize.width, "height": sample.expectedNativeSize.height],
            "nativeCapturedPixels": ["width": sample.nativeSize.width, "height": sample.nativeSize.height],
            "pointPixelScale": sample.pointPixelScale,
            "filterContentRect": rectJSON(sample.filterContentRect),
            "resizedPixels": ["width": sample.image.width, "height": sample.image.height],
            "maskedSecureRegions": sample.maskedSecureRegions,
            "pngPath": sample.pngPath, "pngSHA256": sample.pngSHA256,
        ]
    }

    private static func onScreenWindowCandidates(ownerPID: pid_t, point: CGPoint?,
                                                  elementBounds: CGRect?) -> [[String: Any]] {
        guard ownerPID > 0,
              let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else { return [] }
        return entries.enumerated().compactMap { order, info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == ownerPID,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let rawBounds = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary) else { return nil }
            let containsPoint = point.map { bounds.contains($0) } ?? false
            let intersectsElement = elementBounds.map { bounds.intersects($0) } ?? false
            guard containsPoint || intersectsElement else { return nil }
            return ["zOrder": order, "windowID": number,
                    "title": String((info[kCGWindowName as String] as? String ?? "").prefix(120)),
                    "bounds": rectJSON(bounds), "containsPoint": containsPoint,
                    "intersectsAXBounds": intersectsElement]
        }.prefix(12).map { $0 }
    }

    private static func windowJSON(_ sample: WindowSample) -> [String: Any] {
        ["app": sample.spec.name, "bundleID": sample.spec.bundleID,
         "windowID": sample.target.windowID, "windowTitle": sample.target.title ?? "",
         "visibleWindowCount": sample.visibleWindowCount,
         "focusedAXTitle": sample.focusedAXTitle ?? "",
         "sameFrameCandidateCount": sample.frameCandidateCount,
         "windowFrame": rectJSON(sample.bounds),
         "expectedNativePixels": ["width": sample.expectedNativeSize.width, "height": sample.expectedNativeSize.height],
         "nativeCapturedPixels": ["width": sample.nativeSize.width, "height": sample.nativeSize.height],
         "pointPixelScale": sample.pointPixelScale, "filterContentRect": rectJSON(sample.filterContentRect),
         "resizedPixels": ["width": sample.image.width, "height": sample.image.height],
         "maskedSecureRegions": sample.maskedSecureRegions,
         "eligibleInteractiveMarks": eligibleMarks(in: sample).count,
         "pngPath": sample.pngPath, "pngSHA256": sample.pngSHA256]
    }

    private static func maskSecureRegions(_ image: CGImage, screenBounds: CGRect,
                                          secureRects: [CGRect]) throws -> (CGImage, Int) {
        guard !secureRects.isEmpty else { return (image, 0) }
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AgentEvalWireError.bootstrapFailure
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        var count = 0
        for rect in secureRects {
            guard let pixelRect = PixelGeometry.imageRect(rect, captureBounds: screenBounds,
                imageSize: CGSize(width: image.width, height: image.height)) else { continue }
            let integral = pixelRect.integral
            let bottomLeftRect = CGRect(x: integral.minX, y: CGFloat(image.height) - integral.maxY,
                                        width: integral.width, height: integral.height)
            context.fill(bottomLeftRect)
            count += 1
        }
        guard let masked = context.makeImage() else { throw AgentEvalWireError.bootstrapFailure }
        return (masked, count)
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw AgentEvalWireError.bootstrapFailure
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AgentEvalWireError.bootstrapFailure }
        return output as Data
    }

    private static func pointJSON(_ point: CGPoint) -> [String: CGFloat] { ["x": point.x, "y": point.y] }
    private static func rectJSON(_ rect: CGRect) -> [String: CGFloat] {
        ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
    }

    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }
        mutating func shuffle<T>(_ values: inout [T]) {
            guard values.count > 1 else { return }
            for index in stride(from: values.count - 1, through: 1, by: -1) {
                values.swapAt(index, Int(next() % UInt64(index + 1)))
            }
        }
    }
}
#endif
