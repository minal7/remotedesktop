import AppKit
import ApplicationServices
import CryptoKit
import CoreImage
import CoreML
import ScreenCaptureKit
import XCTest
import Vision
@testable import RemoteDesktopHost

private final class ConsentDiagnosticCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func incrementAndRead() -> Int { lock.withLock { storage += 1; return storage } }
    func set(_ value: Int) { lock.withLock { storage = value } }
    var value: Int { lock.withLock { storage } }
}

@MainActor
final class ComputerUseNativeTextIntegrationTests: XCTestCase {
    /// Opt-in, read-only comparison of the exact production consent OCR call
    /// and Vision's public CPU compute-stage assignment on one captured frame.
    /// The artifact intentionally contains geometry and errors only, never OCR text.
    func testOptInLiveSafariConsentVisionCPUComparisonOnSingleCapture() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_SAFARI_CONSENT_VISION_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_SAFARI_CONSENT_VISION_DIAGNOSTIC=1 to inspect one foreground Safari frame.")
        }
        guard let safari = NSWorkspace.shared.frontmostApplication,
              safari.bundleIdentifier == "com.apple.Safari" else {
            throw XCTSkip("Bring the intended Safari window to the foreground before running this diagnostic.")
        }
        let pid = safari.processIdentifier
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        })
        try tools.requireActive()
        let before = tools.frontmostApplicationSnapshot()
        guard before.identity?.bundleIdentifier == "com.apple.Safari",
              before.identity?.processIdentifier == pid else {
            throw XCTSkip("The foreground application changed before capture.")
        }
        let observation = try tools.currentScreen()
        try tools.requireActive()
        let after = tools.frontmostApplicationSnapshot()
        guard after.identity == before.identity else {
            throw XCTSkip("The foreground Safari identity changed during capture.")
        }

        var record: [String: Any] = [
            "captureSource": "ComputerUseHostTools.currentScreen",
            "bundleIdentifier": "com.apple.Safari",
            "productionDetector": ["stage": "ComputerUseDesktopExecutor.observe -> ComputerUseObservationWorker.performConsentRecognition -> ComputerUseScreenCaptureConsentDetector.requiresUserIntervention(from:)"] as [String: Any],
            "imageExtent": ["x": Double(observation.image.extent.origin.x),
                "y": Double(observation.image.extent.origin.y),
                "width": Double(observation.image.extent.width),
                "height": Double(observation.image.extent.height)],
            "displayBounds": Self.rectDiagnostic(observation.displayBounds),
            "frontmostWindowBounds": observation.frontmostWindowBounds.map { Self.rectDiagnostic($0) as Any } ?? NSNull(),
        ]

        let productionStarted = DispatchTime.now().uptimeNanoseconds
        do {
            try Task.checkCancellation()
            let requiresIntervention = try await ComputerUseObservationWorker.performConsentRecognition(
                timeout: 10, coldStartTimeout: 60) {
                    try ComputerUseScreenCaptureConsentDetector.requiresUserIntervention(from: observation.image)
                }
            try Task.checkCancellation()
            record["productionDetector"] = [
                "stage": "ComputerUseDesktopExecutor.observe -> ComputerUseObservationWorker.performConsentRecognition -> ComputerUseScreenCaptureConsentDetector.requiresUserIntervention(from:)",
                "result": requiresIntervention,
                "elapsedMilliseconds": Int((DispatchTime.now().uptimeNanoseconds - productionStarted) / 1_000_000),
            ]
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var diagnostic = Self.errorDiagnostic(
                stage: "ComputerUseDesktopExecutor.observe -> ComputerUseObservationWorker.performConsentRecognition -> ComputerUseScreenCaptureConsentDetector.requiresUserIntervention(from:)", error: error)
            diagnostic["elapsedMilliseconds"] = Int(
                (DispatchTime.now().uptimeNanoseconds - productionStarted) / 1_000_000)
            record["productionDetector"] = diagnostic
        }
        try Task.checkCancellation()

        // A timed-out/busy blocking worker may still be executing Vision. Do not
        // start a second heavy request unless the production call returned.
        let productionWorkerFailure = (record["productionDetector"] as? [String: Any])?["workerFailure"] as? String
        let productionTimedOut = productionWorkerFailure == "timedOut" || productionWorkerFailure == "busy"
        if productionTimedOut {
            record["cpuComparison"] = ["stage": "skipped", "reason": "production-worker-not-idle"]
        } else {
            try Task.checkCancellation()
            let cpuStarted = DispatchTime.now().uptimeNanoseconds
            do {
                let cpuResult = try await ComputerUseObservationWorker.performConsentRecognition(
                    timeout: 10, coldStartTimeout: 60) {
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.recognitionLanguages = ["en-US"]
                        request.usesLanguageCorrection = true
                        let supported = try request.supportedComputeStageDevices
                        let cpuStages = supported.compactMap { stage, devices -> (VNComputeStage, MLComputeDevice)? in
                            guard let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) else { return nil }
                            return (stage, cpu)
                        }
                        guard !cpuStages.isEmpty else { return ([], nil, nil) as ([String], Int?, Bool?) }
                        for (stage, device) in cpuStages { request.setComputeDevice(device, for: stage) }
                        try VNImageRequestHandler(ciImage: observation.image, options: [:]).perform([request])
                        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                            .joined(separator: " ")
                        return (cpuStages.map { String(describing: $0.0) }.sorted(), request.results?.count,
                            Optional(ComputerUseScreenCaptureConsentDetector.requiresUserIntervention(inRecognizedText: text)))
                    }
                try Task.checkCancellation()
                record["cpuComparison"] = [
                    "stage": cpuResult.0.isEmpty ? "unsupported" : "VNRecognizeTextRequest with supported CPU compute stages",
                    "assignedComputeStages": cpuResult.0,
                    "resultCount": cpuResult.1.map { $0 as Any } ?? NSNull(),
                    "requiresIntervention": cpuResult.2.map { $0 as Any } ?? NSNull(),
                    "elapsedMilliseconds": Int((DispatchTime.now().uptimeNanoseconds - cpuStarted) / 1_000_000),
                    "settings": ["recognitionLevel": "accurate", "recognitionLanguages": ["en-US"],
                        "usesLanguageCorrection": true],
                ]
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                var diagnostic = Self.errorDiagnostic(
                    stage: "VNRecognizeTextRequest with supported CPU compute stages", error: error)
                diagnostic["elapsedMilliseconds"] = Int(
                    (DispatchTime.now().uptimeNanoseconds - cpuStarted) / 1_000_000)
                record["cpuComparison"] = diagnostic
            }
        }

        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "live-safari-consent-vision-diagnostic.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Runs exactly the production consent detector once on a single foreground
    /// Safari capture. The retained attachment contains geometry and error codes,
    /// never recognized text or image pixels.
    func testOptInLiveSafariProductionConsentDetectorOnSingleCapture() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_SAFARI_PRODUCTION_CONSENT_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_SAFARI_PRODUCTION_CONSENT_DIAGNOSTIC=1 to inspect one foreground Safari frame.")
        }
        guard let safari = NSWorkspace.shared.frontmostApplication,
              safari.bundleIdentifier == "com.apple.Safari" else {
            throw XCTSkip("Bring the intended Safari window to the foreground before running this diagnostic.")
        }
        let pid = safari.processIdentifier
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        })
        try tools.requireActive()
        let before = tools.frontmostApplicationSnapshot()
        guard before.identity?.bundleIdentifier == "com.apple.Safari",
              before.identity?.processIdentifier == pid else {
            throw XCTSkip("The foreground application changed before capture.")
        }
        let observation = try tools.currentScreen()
        try tools.requireActive()
        let afterCapture = tools.frontmostApplicationSnapshot()
        guard afterCapture.identity == before.identity else {
            throw XCTSkip("The foreground Safari identity changed during capture.")
        }

        var record: [String: Any] = [
            "captureSource": "ComputerUseHostTools.currentScreen",
            "captureCount": 1,
            "bundleIdentifier": "com.apple.Safari",
            "imageExtent": ["x": Double(observation.image.extent.origin.x),
                "y": Double(observation.image.extent.origin.y),
                "width": Double(observation.image.extent.width),
                "height": Double(observation.image.extent.height)],
            "displayBounds": Self.rectDiagnostic(observation.displayBounds),
            "frontmostWindowBounds": observation.frontmostWindowBounds.map { Self.rectDiagnostic($0) as Any } ?? NSNull(),
        ]
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            try Task.checkCancellation()
            let requiresIntervention = try await ComputerUseObservationWorker.performConsentRecognition(
                timeout: 10, coldStartTimeout: 60) {
                    try ComputerUseScreenCaptureConsentDetector.requiresUserIntervention(from: observation.image)
                }
            try Task.checkCancellation()
            record["productionDetector"] = [
                "result": requiresIntervention,
                "elapsedMs": Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000),
            ]
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var diagnostic = Self.errorDiagnostic(stage: "production consent detector", error: error)
            diagnostic["elapsedMs"] = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            record["productionDetector"] = diagnostic
        }
        try Task.checkCancellation()
        try tools.requireActive()
        let afterRecognition = tools.frontmostApplicationSnapshot()
        guard afterRecognition.identity == before.identity else {
            throw XCTSkip("The foreground Safari identity changed during recognition.")
        }

        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "live-safari-production-consent-diagnostic.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Tests the production-normalized CGImage through Vision's CGImage handler
    /// while retaining only geometry and matcher/error metadata.
    func testOptInLiveSafariConsentCGImageHandlerOnSingleCapture() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_SAFARI_CONSENT_CGIMAGE_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_SAFARI_CONSENT_CGIMAGE_DIAGNOSTIC=1 to inspect one foreground Safari frame.")
        }
        guard let safari = NSWorkspace.shared.frontmostApplication,
              safari.bundleIdentifier == "com.apple.Safari" else {
            throw XCTSkip("Bring the intended Safari window to the foreground before running this diagnostic.")
        }
        let pid = safari.processIdentifier
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        })
        try tools.requireActive()
        let before = tools.frontmostApplicationSnapshot()
        guard before.identity?.bundleIdentifier == "com.apple.Safari",
              before.identity?.processIdentifier == pid else {
            throw XCTSkip("The foreground application changed before capture.")
        }
        let observation = try tools.currentScreen()
        try tools.requireActive()
        let afterCapture = tools.frontmostApplicationSnapshot()
        guard afterCapture.identity == before.identity else {
            throw XCTSkip("The foreground Safari identity changed during capture.")
        }

        var record: [String: Any] = [
            "captureSource": "ComputerUseHostTools.currentScreen",
            "captureCount": 1,
            "bundleIdentifier": "com.apple.Safari",
            "imageExtent": ["x": Double(observation.image.extent.origin.x),
                "y": Double(observation.image.extent.origin.y),
                "width": Double(observation.image.extent.width),
                "height": Double(observation.image.extent.height)],
            "displayBounds": Self.rectDiagnostic(observation.displayBounds),
            "frontmostWindowBounds": observation.frontmostWindowBounds.map { Self.rectDiagnostic($0) as Any } ?? NSNull(),
        ]
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            try Task.checkCancellation()
            let result = try await ComputerUseObservationWorker.perform(timeout: 60) {
                let normalizationStarted = DispatchTime.now().uptimeNanoseconds
                let normalized = try ComputerUseScreenCaptureConsentDetector
                    .materializedRecognitionImage(observation.image)
                guard let cgImage = normalized.cgImage else {
                    throw NSError(domain: "ComputerUseConsentCGImageDiagnostic", code: 1)
                }
                let normalizationMilliseconds = Int(
                    (DispatchTime.now().uptimeNanoseconds - normalizationStarted) / 1_000_000)
                let requestStarted = DispatchTime.now().uptimeNanoseconds
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.usesLanguageCorrection = true
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                let visibleText = (request.results ?? []).compactMap {
                    $0.topCandidates(1).first?.string
                }.joined(separator: " ")
                let requiresIntervention = ComputerUseScreenCaptureConsentDetector
                    .requiresUserIntervention(inRecognizedText: visibleText)
                let requestMilliseconds = Int(
                    (DispatchTime.now().uptimeNanoseconds - requestStarted) / 1_000_000)
                return (Self.CGImageMetadata(cgImage), requiresIntervention,
                    normalizationMilliseconds, requestMilliseconds)
            }
            try Task.checkCancellation()
            record["cgImageHandler"] = [
                "stage": "production materializedRecognitionImage then VNImageRequestHandler(cgImage:)",
                "image": result.0.dictionary,
                "requiresIntervention": result.1,
                "normalizationElapsedMs": result.2,
                "recognitionElapsedMs": result.3,
                "elapsedMs": Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000),
            ]
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var diagnostic = Self.errorDiagnostic(stage: "materialized CGImage Vision handler", error: error)
            diagnostic["elapsedMs"] = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            record["cgImageHandler"] = diagnostic
        }
        try Task.checkCancellation()
        try tools.requireActive()
        let afterRecognition = tools.frontmostApplicationSnapshot()
        guard afterRecognition.identity == before.identity else {
            throw XCTSkip("The foreground Safari identity changed during recognition.")
        }

        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "live-safari-consent-cgimage-handler-diagnostic.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Checks whether normalizing the captured pixel backing changes the exact
    /// production consent-recognition failure. This captures once and records
    /// geometry/bitmap metadata only; no screen text or image is attached.
    func testOptInLiveSafariConsentStandardRGBA8MaterializationOnSingleCapture() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_SAFARI_CONSENT_RGBA8_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_SAFARI_CONSENT_RGBA8_DIAGNOSTIC=1 to inspect one foreground Safari frame.")
        }
        guard let safari = NSWorkspace.shared.frontmostApplication,
              safari.bundleIdentifier == "com.apple.Safari" else {
            throw XCTSkip("Bring the intended Safari window to the foreground before running this diagnostic.")
        }
        let pid = safari.processIdentifier
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        })
        try tools.requireActive()
        let before = tools.frontmostApplicationSnapshot()
        guard before.identity?.bundleIdentifier == "com.apple.Safari",
              before.identity?.processIdentifier == pid else {
            throw XCTSkip("The foreground application changed before capture.")
        }
        let observation = try tools.currentScreen()
        try tools.requireActive()
        let after = tools.frontmostApplicationSnapshot()
        guard after.identity == before.identity else {
            throw XCTSkip("The foreground Safari identity changed during capture.")
        }

        var record: [String: Any] = [
            "captureSource": "ComputerUseHostTools.currentScreen",
            "bundleIdentifier": "com.apple.Safari",
            "captureCount": 1,
            "imageExtent": ["x": Double(observation.image.extent.origin.x),
                "y": Double(observation.image.extent.origin.y),
                "width": Double(observation.image.extent.width),
                "height": Double(observation.image.extent.height)],
            "displayBounds": Self.rectDiagnostic(observation.displayBounds),
            "frontmostWindowBounds": observation.frontmostWindowBounds.map { Self.rectDiagnostic($0) as Any } ?? NSNull(),
            "originalBackingCGImage": observation.image.cgImage.map { Self.cgImageDiagnostic($0) as Any } ?? NSNull(),
        ]

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            try Task.checkCancellation()
            let result = try await ComputerUseObservationWorker.perform(timeout: 60) {
                let materializationStarted = DispatchTime.now().uptimeNanoseconds
                let extent = observation.image.extent
                guard extent.origin.x.isFinite, extent.origin.y.isFinite,
                      extent.width.isFinite, extent.height.isFinite,
                      extent.width > 0, extent.height > 0,
                      extent.width.rounded() == extent.width,
                      extent.height.rounded() == extent.height else {
                    throw NSError(domain: "ComputerUseConsentRGBA8Diagnostic", code: 1)
                }
                let context = CIContext()
                guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                      let rendered = context.createCGImage(observation.image, from: extent,
                          format: .RGBA8, colorSpace: colorSpace),
                      rendered.width == Int(extent.width), rendered.height == Int(extent.height) else {
                    throw NSError(domain: "ComputerUseConsentRGBA8Diagnostic", code: 2)
                }
                let materialized = CIImage(cgImage: rendered)
                let materializationMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - materializationStarted) / 1_000_000)
                let recognitionStarted = DispatchTime.now().uptimeNanoseconds
                let requiresIntervention = try ComputerUseScreenCaptureConsentDetector
                    .requiresUserIntervention(from: materialized)
                let recognitionMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - recognitionStarted) / 1_000_000)
                return (Self.CGImageMetadata(rendered), requiresIntervention,
                    materializationMilliseconds, recognitionMilliseconds)
            }
            try Task.checkCancellation()
            record["standardRGBA8"] = [
                "stage": "CIContext.createCGImage(format: .RGBA8, colorSpace: sRGB) then production consent detector",
                "image": result.0.dictionary,
                "requiresIntervention": result.1,
                "materializationElapsedMilliseconds": result.2,
                "recognitionElapsedMilliseconds": result.3,
                "elapsedMilliseconds": Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000),
            ]
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var diagnostic = Self.errorDiagnostic(
                stage: "CIContext.createCGImage(format: .RGBA8, colorSpace: sRGB) then production consent detector",
                error: error)
            diagnostic["elapsedMilliseconds"] = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            record["standardRGBA8"] = diagnostic
        }
        try Task.checkCancellation()

        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "live-safari-consent-rgba8-materialization-diagnostic.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct CGImageMetadata: Sendable {
        let width: Int
        let height: Int
        let bitsPerComponent: Int
        let bitsPerPixel: Int
        let bitmapInfo: UInt32
        let bytesPerRow: Int
        let colorSpaceName: String?

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            bitsPerComponent = image.bitsPerComponent
            bitsPerPixel = image.bitsPerPixel
            bitmapInfo = image.bitmapInfo.rawValue
            bytesPerRow = image.bytesPerRow
            colorSpaceName = image.colorSpace?.name.map { String(describing: $0) }
        }

        var dictionary: [String: Any] {
            ["width": width, "height": height,
             "bitsPerComponent": bitsPerComponent, "bitsPerPixel": bitsPerPixel,
             "bitmapInfo": bitmapInfo, "bytesPerRow": bytesPerRow,
             "colorSpaceName": colorSpaceName.map { $0 as Any } ?? NSNull()]
        }
    }

    private static func cgImageDiagnostic(_ image: CGImage) -> [String: Any] {
        CGImageMetadata(image).dictionary
    }

    private static func rectDiagnostic(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.origin.x), "y": Double(rect.origin.y),
         "width": Double(rect.width), "height": Double(rect.height)]
    }

    private static func errorDiagnostic(stage: String, error: Error) -> [String: Any] {
        let native = error as NSError
        let workerFailure: String?
        switch error as? ComputerUseObservationWorker.Failure {
        case .some(.busy): workerFailure = "busy"
        case .some(.timedOut): workerFailure = "timedOut"
        default: workerFailure = nil
        }
        var result: [String: Any] = ["stage": stage, "errorDomain": native.domain, "errorCode": native.code]
        if let workerFailure { result["workerFailure"] = workerFailure }
        return result
    }

    func testCancellingAsyncLocalFileOperationDoesNotRequestAnotherProposal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let enteredHandler = expectation(description: "async file handler entered")
        var proposals = 0
        let operation = ComputerUseLocalFileOperation.listFiles(query: .init(), cursor: nil)
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            return .init(response: "list files", action: .localFileOperation(operation))
        }, localFileOperationHandler: { _ in
            enteredHandler.fulfill()
            try await Task.sleep(for: .seconds(30))
            return nil
        })
        let run = Task {
            try await executor.execute(taskID: "async-local-file-cancel", prompt: "List files",
                trustedUserPrompt: "List files", tools: desktopTestTools(), progress: { _ in })
        }
        await fulfillment(of: [enteredHandler], timeout: 2)
        run.cancel()
        do {
            _ = try await run.value
            XCTFail("Cancellation should stop the executor after its awaited local operation")
        } catch is CancellationError { }
        XCTAssertEqual(proposals, 1, "No new proposal may follow a cancelled local file operation")
    }

    func testHostPreparationRunsBeforeEachObservationAndProposalAndStopsWhenCancelledOrPaused() async throws {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let preparations = ConsentDiagnosticCounter(), observations = ConsentDiagnosticCounter()
            let proposals = ConsentDiagnosticCounter(), preparedObservations = ConsentDiagnosticCounter()
            let preparedProposals = ConsentDiagnosticCounter()
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                let proposalIndex = proposals.incrementAndRead()
                if preparations.value == proposalIndex { _ = preparedProposals.incrementAndRead() }
                return proposalIndex == 1
                    ? .init(response: "refresh", decision: .refreshObservation)
                    : .init(response: "handoff", decision: .handoff("Review the page."))
            }, hostPreparation: {
                _ = preparations.incrementAndRead()
            }, screenConsentRecognizer: { _ in
                let observationIndex = observations.value + 1
                if preparations.value == observationIndex { _ = preparedObservations.incrementAndRead() }
                _ = observations.incrementAndRead()
                return false
            })
            let result = try await executor.execute(taskID: "host-preparation-order", prompt: "Review the page",
                trustedUserPrompt: "Review the page", tools: desktopTestTools(), progress: { _ in })
            XCTAssertEqual(result, .userInterventionRequired("Review the page."))
            XCTAssertEqual(preparations.value, 2, "Preparation runs once for each proposed turn")
            XCTAssertEqual(observations.value, 2)
            XCTAssertEqual(preparedObservations.value, 2, "Each fresh observation follows host preparation")
            XCTAssertEqual(proposals.value, 2)
            XCTAssertEqual(preparedProposals.value, 2, "Each proposal follows host preparation")
        }

        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let preparations = ConsentDiagnosticCounter(), observations = ConsentDiagnosticCounter()
            let proposals = ConsentDiagnosticCounter()
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                _ = proposals.incrementAndRead()
                return .init(response: "unexpected", decision: .handoff("Review the page."))
            }, hostPreparation: {
                _ = preparations.incrementAndRead()
                withUnsafeCurrentTask { $0?.cancel() }
            }, screenConsentRecognizer: { _ in _ = observations.incrementAndRead(); return false })
            let run = Task { try await executor.execute(taskID: "host-preparation-cancel", prompt: "Review the page",
                trustedUserPrompt: "Review the page", tools: desktopTestTools(), progress: { _ in }) }
            do {
                _ = try await run.value
                XCTFail("Cancellation in host preparation must stop before a fresh observation")
            } catch is CancellationError { }
            XCTAssertEqual(preparations.value, 1)
            XCTAssertEqual(observations.value, 0)
            XCTAssertEqual(proposals.value, 0)
        }

        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let gate = ConsentDiagnosticCounter(), preparations = ConsentDiagnosticCounter()
            let observations = ConsentDiagnosticCounter(), proposals = ConsentDiagnosticCounter()
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                _ = proposals.incrementAndRead()
                return .init(response: "unexpected", decision: .handoff("Review the page."))
            }, hostPreparation: {
                _ = preparations.incrementAndRead()
                gate.set(1)
            }, screenConsentRecognizer: { _ in _ = observations.incrementAndRead(); return false })
            do {
                _ = try await executor.execute(taskID: "host-preparation-paused", prompt: "Review the page",
                    trustedUserPrompt: "Review the page", tools: desktopTestTools(mayAct: { gate.value == 0 }), progress: { _ in })
                XCTFail("A revoked action gate must stop before a fresh observation")
            } catch ComputerUseHostTools.ToolError.paused { }
            XCTAssertEqual(preparations.value, 1)
            XCTAssertEqual(observations.value, 0)
            XCTAssertEqual(proposals.value, 0)
        }
    }

    func testWillBeginEffectCallbackRunsOnlyAtDispatchAndUncertainResumeDoesNotReplay() async throws {
        enum DispatchFailure: Error { case uncertain }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var proposals = 0, began = 0, succeeded = 0, effects = 0
        let tools = desktopTestTools(perform: { _ in
            effects += 1
            throw DispatchFailure.uncertain
        })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            return .init(response: "Click the observed neutral control.",
                action: .pointer(.leftClick, .init(x: 500, y: 500)))
        }, onSuccessfulDispatch: { _ in succeeded += 1 }, onWillBeginEffect: { _ in began += 1 },
           screenConsentRecognizer: { _ in false })

        do {
            _ = try await executor.execute(taskID: "w2-uncertain-dispatch", prompt: "Click the control",
                trustedUserPrompt: "Click the control", tools: tools, progress: { _ in })
            XCTFail("The native effect error must remain visible to the caller")
        } catch DispatchFailure.uncertain {
            // The executor intentionally propagates a possibly-applied host error.
        }
        XCTAssertEqual(proposals, 1)
        XCTAssertEqual(began, 1, "The latch callback runs immediately before an actual effect attempt")
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(succeeded, 0, "A thrown native action is not a successful dispatch")

        _ = try await executor.execute(taskID: "w2-uncertain-dispatch", prompt: "Resume",
            trustedUserPrompt: "Click the control", tools: tools, progress: { _ in })
        XCTAssertEqual(proposals, 1, "An uncertain native effect cannot be proposed again on Resume")
        XCTAssertEqual(began, 1)
        XCTAssertEqual(effects, 1)

        let approvalDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: approvalDirectory) }
        var approvalBegan = 0, approvalEffects = 0
        let approvalTools = desktopTestTools(accessibilityContext: "Send button",
            perform: { _ in approvalEffects += 1 })
        let approvalExecutor = try ComputerUseDesktopExecutor(journalDirectory: approvalDirectory, propose: { _ in
            .init(response: "Confirm the labeled control.",
                action: .pointer(.leftClick, .init(x: 500, y: 500)))
        }, onWillBeginEffect: { _ in approvalBegan += 1 }, screenConsentRecognizer: { _ in false })
        let pending = try await approvalExecutor.execute(taskID: "w2-approval-not-dispatched", prompt: "Click the button",
            trustedUserPrompt: "Click the button", tools: approvalTools, progress: { _ in })
        guard case .approvalRequired = pending else { return XCTFail("A consequential control must await approval") }
        XCTAssertEqual(approvalBegan, 0, "Approval presentation alone must not latch an upload effect")
        XCTAssertEqual(approvalEffects, 0)
    }

    func testDefaultBrowserFilePanelRequiresTheResolvedCandidateBeforeOpen() {
        let element = AXUIElementCreateSystemWide()
        let panel = ComputerUseDefaultBrowserSession.FileOpenPanel(parentWindowID: "window",
            parentWindowElement: element, accessibilityElement: element,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600), isFocused: true,
            goToFolderBounds: nil, pathTextFieldElement: nil, selectedFileURLs: [],
            primaryActionElement: element, primaryActionBounds: CGRect(x: 700, y: 560, width: 80, height: 30),
            primaryActionEnabled: true)
        let candidate = URL(fileURLWithPath: "/tmp/selected.pptx")
        let open = ComputerUsePredictedAction.click(x: 720, y: 575, button: 1, count: 1)
        let enter = ComputerUsePredictedAction.key(usage: 0x28, modifiers: 0)
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permitsFilePanel(open, within: panel.bounds,
            panel: panel, selectedURL: candidate))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permitsFilePanel(enter, within: panel.bounds,
            panel: panel, selectedURL: candidate))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permitsFilePanel(
            .click(x: 720, y: 575, button: 1, count: 2), within: panel.bounds, panel: panel, selectedURL: candidate))

        let selected = ComputerUseDefaultBrowserSession.FileOpenPanel(parentWindowID: "window",
            parentWindowElement: element, accessibilityElement: element,
            bounds: panel.bounds, isFocused: true, goToFolderBounds: nil, pathTextFieldElement: nil,
            selectedFileURLs: [candidate], primaryActionElement: element,
            primaryActionBounds: panel.primaryActionBounds, primaryActionEnabled: true)
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permitsFilePanel(open, within: selected.bounds,
            panel: selected, selectedURL: candidate))
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permitsFilePanel(enter, within: selected.bounds,
            panel: selected, selectedURL: candidate))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permitsFilePanel(open, within: selected.bounds,
            panel: selected, selectedURL: URL(fileURLWithPath: "/tmp/other.pptx")))
    }

    func testCurrentPanelSelectionRequiresExactSingleResolvedCandidate() {
        let element = AXUIElementCreateSystemWide()
        let candidate = URL(fileURLWithPath: "/tmp/Selected.pptx")
        func panel(selected: [URL], navigating: Bool = false) -> ComputerUseDefaultBrowserSession.FileOpenPanel {
            .init(parentWindowID: "window", parentWindowElement: element, accessibilityElement: element,
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600), isFocused: true,
                goToFolderBounds: navigating ? CGRect(x: 100, y: 100, width: 300, height: 100) : nil,
                pathTextFieldElement: navigating ? element : nil, selectedFileURLs: selected,
                primaryActionElement: element, primaryActionBounds: nil, primaryActionEnabled: true)
        }
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.candidateIsSelected(
            panel: panel(selected: [candidate]), candidateURL: candidate))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.candidateIsSelected(
            panel: panel(selected: [URL(fileURLWithPath: "/tmp/Other.pptx")]), candidateURL: candidate))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.candidateIsSelected(
            panel: panel(selected: [candidate, URL(fileURLWithPath: "/tmp/Other.pptx")]), candidateURL: candidate))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.candidateIsSelected(
            panel: panel(selected: [candidate], navigating: true), candidateURL: candidate))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.candidateIsSelected(
            panel: panel(selected: [candidate]), candidateURL: nil))
    }

    func testNativeFilePickerUsesResolvedPathAndStopsBeforeUpload() {
        let element = AXUIElementCreateSystemWide()
        let candidate = URL(fileURLWithPath: "/tmp/Chosen résumé.pdf")
        func panel(navigating: Bool = true, selected: [URL] = []) -> ComputerUseDefaultBrowserSession.FileOpenPanel {
            .init(parentWindowID: "window", parentWindowElement: element, accessibilityElement: element,
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600), isFocused: true,
                goToFolderBounds: navigating ? CGRect(x: 100, y: 100, width: 400, height: 200) : nil,
                pathTextFieldElement: navigating ? element : nil, selectedFileURLs: selected,
                primaryActionElement: element, primaryActionBounds: CGRect(x: 700, y: 560, width: 80, height: 30),
                primaryActionEnabled: true)
        }
        func next(_ panel: ComputerUseDefaultBrowserSession.FileOpenPanel) -> ComputerUseDesktopProposal? {
            ComputerUseDefaultBrowserActionScope.nativeSelectionProposal(panel: panel, selectedURL: candidate)
        }
        XCTAssertEqual(next(panel(navigating: false))?.action, .key(["Command", "Shift", "g"]))
        var current = panel()
        current.pathFieldIsFocused = true
        current.pathFieldValue = "/tmp/old.pdf"
        current.pathFieldSelection = NSRange(location: 0, length: 0)
        XCTAssertEqual(next(current)?.action, .key(["Command", "a"]))
        current.pathFieldSelection = NSRange(location: 0, length: current.pathFieldValue!.utf16.count)
        XCTAssertEqual(next(current)?.action, .typeText(candidate.path))
        current.pathFieldValue = candidate.path
        current.pathFieldSelection = NSRange(location: candidate.path.utf16.count, length: 0)
        XCTAssertEqual(next(current)?.action, .key(["Return"]))
        current.pathFieldIsFocused = false
        guard case .handoff? = next(current)?.decision else { return XCTFail("Wrong path-field focus must yield") }
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permitsFilePanel(.key(usage: 0x28, modifiers: 0),
            within: current.actionBounds, panel: current, selectedURL: candidate))
        XCTAssertNil(next(panel(navigating: false, selected: [candidate])), "The native path adapter never presses Upload")
        XCTAssertEqual(next(panel(navigating: false, selected: [URL(fileURLWithPath: "/tmp/other.pdf")]))?.action,
            .key(["Command", "Shift", "g"]))
    }

    func testNativeKeyChordsRemainLiteralAndRejectAmbiguousSequences() throws {
        for (keys, usage, modifiers) in [(["Alt", "Left"], 0x50, UInt16(4)), (["Left", "Option"], 0x50, 4),
            (["Control", "a"], 0x04, 2), (["Command", "a"], 0x04, 8), (["Shift", "ArrowRight"], 0x4F, 1),
            (["Backspace"], 0x2A, 0), (["Delete"], 0x4C, 0)] {
            XCTAssertEqual(try ComputerUseNativeKeyChord.action(keys), .key(usage: usage, modifiers: modifiers))
        }
        for keys in [[], ["Command"], ["a", "b"], ["Cmd", "Command", "a"], ["Alt", "Option", "Left"], [""], ["😀"]] {
            XCTAssertThrowsError(try ComputerUseNativeKeyChord.action(keys))
        }
    }

    func testNativeTargetedScrollPreservesPointsAndDirectionAcrossProviders() throws {
        let image = try ComputerUseDesktopImage(observation: .init(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 800)),
            displayBounds: CGRect(x: -640, y: -200, width: 1280, height: 800)))
        for (horizontal, pixels, direction) in [(false, 240, "up"), (false, -240, "down"), (true, 240, "right"), (true, -240, "left")] {
            let name = horizontal ? "hscroll" : "scroll"
            let call = "<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"\(name)\",\"coordinate\":[250,500],\"pixels\":\(pixels)}}</tool_call>"
            let fara = try ComputerUseFaraAction.decode(call)
            let owlData = try JSONSerialization.data(withJSONObject: ["model": ComputerUseGUIOwlModel.modelAlias,
                "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Action: Scroll the observed pane.\n" + call]]]])
            let owl = try XCTUnwrap(ComputerUseGUIOwlModel.decode(owlData).compatibleDesktopProposal().action)
            let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["direction": direction, "distance": abs(pixels), "x": 250, "y": 500]), as: UTF8.self)
            let holoData = try JSONSerialization.data(withJSONObject: ["model": ComputerUseHoloModel.modelAlias,
                "choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": "", "tool_calls": [["id": "scroll-case", "type": "function", "function": ["name": "scroll", "arguments": arguments]]]]]]])
            let holo = try ComputerUseHoloModel.decode(holoData).action
            for action in [fara, owl, holo] {
                XCTAssertEqual(try ComputerUseDesktopExecutor.nativeAction(action, image: image),
                    .scroll(x: -320, y: 200, dx: horizontal ? -pixels : 0, dy: horizontal ? 0 : pixels))
            }
            let legacy = try ComputerUseFaraAction.decode("<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"\(name)\",\"pixels\":\(pixels)}}</tool_call>")
            XCTAssertEqual(legacy, .scroll(horizontal: horizontal, pixels: Double(pixels)))
            XCTAssertThrowsError(try ComputerUseDesktopExecutor.nativeAction(legacy, image: image), "Native scrolling cannot guess a target")
        }
    }

    func testNativeScrollRejectsMalformedAmountsAndPartialOrInvalidPoints() throws {
        func fara(_ arguments: String) -> String { "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + arguments + "}</tool_call>" }
        func holo(_ arguments: String) throws -> ComputerUseFaraModel.Proposal {
            try ComputerUseHoloModel.decode(JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "tool_calls", "message": [
                "role": "assistant", "content": "", "tool_calls": [["id": "edge", "type": "function", "function": ["name": "scroll", "arguments": arguments]]]]]]]))
        }
        let invalidAmounts = ["0", "0.5", "10001", "true", "\"240\"", "null", "1e309"]
        for amount in invalidAmounts {
            let call = fara("{\"action\":\"scroll\",\"pixels\":\(amount),\"coordinate\":[250,500]}")
            XCTAssertThrowsError(try ComputerUseFaraAction.decode(call), amount)
            XCTAssertThrowsError(try ComputerUseGUIOwlModel.decode(JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Action: Scroll.\n" + call]]]])), amount)
            XCTAssertThrowsError(try holo("{\"direction\":\"down\",\"distance\":\(amount),\"x\":250,\"y\":500}"), amount)
        }
        for coordinate in ["null", "[]", "[250]", "[250,500,1]", "[true,500]", "[250,\"500\"]", "[-1,500]", "[250,1001]", "[250,1e309]"] {
            XCTAssertThrowsError(try ComputerUseFaraAction.decode(fara("{\"action\":\"hscroll\",\"pixels\":240,\"coordinate\":\(coordinate)}")), coordinate)
        }
        for point in ["\"x\":250", "\"y\":500", "\"x\":true,\"y\":500", "\"x\":250.5,\"y\":500", "\"x\":-1,\"y\":500", "\"x\":250,\"y\":1001", "\"x\":250,\"y\":null"] {
            XCTAssertThrowsError(try holo("{\"direction\":\"down\",\"distance\":240,\(point)}"), point)
        }
        let image = try ComputerUseDesktopImage(observation: .init(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)), displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400)))
        for amount in [0, 0.5, -0.5, 10_001, -.infinity, .nan] as [Double] {
            XCTAssertThrowsError(try ComputerUseDesktopExecutor.nativeAction(.scrollAt(horizontal: false, pixels: amount, point: .init(x: 500, y: 500)), image: image))
        }
        for point in [ComputerUseFaraAction.Point(x: -1, y: 500), .init(x: 500, y: 1001), .init(x: .nan, y: 500)] {
            XCTAssertThrowsError(try ComputerUseDesktopExecutor.nativeAction(.scrollAt(horizontal: false, pixels: -240, point: point), image: image))
        }
    }

    func testNativeScrollRejectsOutsideWindowAndChangedObservationBeforeInput() async throws {
        for scenario in ["outside", "window moved", "authority changed", "missing point"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var frame = CGRect(x: 100, y: 50, width: 200, height: 200), focus = "pane", calls = 0, effects = 0
            let tools = desktopTestTools(focus: { focus }, window: { frame }, perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
                calls += 1
                if calls == 1 {
                    if scenario == "window moved" { frame.origin.x += 20 }
                    if scenario == "authority changed" { focus = "different pane" }
                    let action: ComputerUseFaraAction = scenario == "missing point" ? .scroll(horizontal: false, pixels: -240) :
                        .scrollAt(horizontal: false, pixels: -240, point: scenario == "outside" ? .init(x: 900, y: 900) : .init(x: 300, y: 300))
                    return .init(response: "scroll", action: action)
                }
                XCTAssertEqual(calls, 2); XCTAssertNotNil(input.actionError, scenario)
                if scenario == "missing point" { XCTAssertTrue(input.actionError?.contains("explicit coordinate") == true) }
                return .init(response: "stop", action: .reportCompletion("No scroll was sent"))
            })
            let result = try await executor.execute(taskID: "scroll-boundary", prompt: "Scroll the observed pane", trustedUserPrompt: "Scroll the observed pane", tools: tools, progress: { _ in })
            XCTAssertEqual(result, .completed("No scroll was sent")); XCTAssertEqual(effects, 0, scenario)
            let journals = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
                .map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            XCTAssertFalse(journals.contains { $0.stepIDs == ["native-dispatch-returned"] }, scenario)
        }
    }

    private final class ScrollInterruptionEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [CGEventType] = []
        private var restored = false
        let stopAfter: Int
        init(stopAfter: Int) { self.stopAfter = stopAfter }
        func record(_ event: CGEvent) { lock.lock(); defer { lock.unlock() }; events.append(event.type) }
        var allowed: Bool { lock.lock(); defer { lock.unlock() }; return restored || events.count < stopAfter }
        var types: [CGEventType] { lock.lock(); defer { lock.unlock() }; return events }
        func restore() { lock.lock(); defer { lock.unlock() }; restored = true }
    }

    func testNativeScrollWithdrawalBetweenPointerAndWheelCannotReplay() async throws {
        for stopAfter in [1, 2] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let events = ScrollInterruptionEvents(stopAfter: stopAfter)
            let tools = desktopTestTools(injector: InputInjector(eventPoster: { events.record($0) }), mayAct: { events.allowed })
            var proposals = 0
            let propose: ComputerUseDesktopExecutor.Propose = { _ in
                proposals += 1
                return .init(response: "scroll", action: .scrollAt(horizontal: false, pixels: -240, point: .init(x: 500, y: 500)))
            }
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: propose)
            do { _ = try await executor.execute(taskID: "scroll-interrupted", prompt: "Scroll down", trustedUserPrompt: "Scroll down", tools: tools, progress: { _ in }); XCTFail("Partial native dispatch must not complete") } catch { }
            XCTAssertEqual(events.types.first, .mouseMoved)
            XCTAssertEqual(events.types.count, stopAfter)
            XCTAssertEqual(events.types.filter { $0 == .scrollWheel }.count, stopAfter - 1)
            events.restore()
            let resumed = try await executor.execute(taskID: "scroll-interrupted", prompt: "Scroll down", trustedUserPrompt: "Scroll down", tools: tools, progress: { _ in })
            guard case .unableToComplete = resumed else { return XCTFail("Uncertain wheel dispatch became successful") }
            let restarted = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: propose)
            do { _ = try await restarted.execute(taskID: "scroll-interrupted", prompt: "Scroll down", trustedUserPrompt: "Scroll down", tools: tools, progress: { _ in }); XCTFail("Restart replayed uncertain wheel dispatch") } catch { }
            XCTAssertEqual(proposals, 1); XCTAssertEqual(events.types.count, stopAfter)
            let journals = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
                .map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            XCTAssertEqual(journals.filter { $0.statuses == [.uncertain] }.count, 1)
        }
    }

    func testScopedDesktopRejectsForeignAppOrWindowBeforeProposing() async throws {
        for (scenario, appMatches, windowMatches) in [("foreign app", false, true), ("foreign window", true, false)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var proposals = 0, effects = 0
            let tools = desktopTestTools(perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                proposals += 1
                return .init(response: "candidate", action: .reportCompletion("Done"))
            }, surfaceScopeCheck: { _ in
                guard appMatches && windowMatches else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
            })
            do {
                _ = try await executor.execute(taskID: "foreign-surface-\(scenario)", prompt: "Click", trustedUserPrompt: "Click", tools: tools, progress: { _ in })
                XCTFail("A foreign app/window must stop before proposal: \(scenario)")
            } catch ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged {}
            XCTAssertEqual(proposals, 0, scenario)
            XCTAssertEqual(effects, 0, scenario)
        }
    }

    func testScopedDesktopStopsAfterEffectWhenOwnedWindowChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var proposals = 0, effects = 0, scopeValid = true
        let tools = desktopTestTools(perform: { _ in effects += 1; scopeValid = false })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            if proposals > 1 { return .init(response: "review", decision: .handoff("Review the page.")) }
            return .init(response: "click", action: .pointer(.leftClick, .init(x: 500, y: 500)))
        }, surfaceScopeCheck: { _ in
            guard scopeValid else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
        })
        do {
            _ = try await executor.execute(taskID: "changed-owned-window", prompt: "Click", trustedUserPrompt: "Click", tools: tools, progress: { _ in })
            XCTFail("A changed owned window must stop before the next proposal or completion")
        } catch ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged {}
        XCTAssertEqual(proposals, 1)
        XCTAssertEqual(effects, 1)
        scopeValid = true
        let resumed = try await executor.execute(taskID: "changed-owned-window", prompt: "Resume", trustedUserPrompt: "Click", tools: tools, progress: { _ in })
        XCTAssertEqual(resumed, .userInterventionRequired("Review the page."))
        XCTAssertEqual(proposals, 2, "Restoring the same window should permit a fresh observation")
        XCTAssertEqual(effects, 1, "Resume must not repeat the prior click")
        XCTAssertEqual(executor.diagnosticHistory.filter { $0.response == "click" }.count, 1)
    }

    func testScopedDesktopWaitsForPostClickTransitionBeforeObservingAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var proposals = 0, effects = 0, scopeValid = true
        let tools = desktopTestTools(perform: { _ in
            effects += 1
            scopeValid = false
            Task { @MainActor in
                // The Session layer may need more than one second to finish its
                // already-bounded fresh AX recapture while a native picker opens.
                try? await Task.sleep(for: .milliseconds(1_300))
                scopeValid = true
            }
        })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            proposals += 1
            if proposals == 1 {
                return .init(response: "click", action: .pointer(.leftClick, .init(x: 500, y: 500)))
            }
            XCTAssertEqual(input.history.count, 1, "The returned click should be recorded before the next proposal")
            XCTAssertEqual(input.history.first?.response, "click")
            return .init(response: "handoff", decision: .handoff("The page is ready for review."))
        }, surfaceScopeCheck: { _ in
            guard scopeValid else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
        })

        let result = try await executor.execute(taskID: "post-click-transition", prompt: "Open the picker", trustedUserPrompt: "Open the picker", tools: tools, progress: { _ in })
        XCTAssertEqual(result, .userInterventionRequired("The page is ready for review."))
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(proposals, 2)
        XCTAssertEqual(executor.diagnosticHistory.filter { $0.response == "click" }.count, 1)
        XCTAssertEqual(executor.diagnosticHistory.first?.response, "click")
    }

    func testScopedDesktopBoundsRepeatedPostActionScopeLossStopsAtRecoveryDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var effects = 0
        var proposals = 0
        var postActionScopeChecks = 0
        var successfulDispatches = 0
        let tools = desktopTestTools(perform: { _ in effects += 1 })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            return .init(response: "click", action: .pointer(.leftClick, .init(x: 500, y: 300)))
        }, surfaceScopeCheck: { _ in
            guard successfulDispatches > 0 else { return }
            postActionScopeChecks += 1
            throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged
        }, onSuccessfulDispatch: { _ in successfulDispatches += 1 }, screenConsentRecognizer: { _ in false })
        let run = Task {
            try await executor.execute(taskID: "repeated-post-action-scope-loss", prompt: "Open the picker",
                trustedUserPrompt: "Open the picker", tools: tools, progress: { _ in })
        }
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(8))
            run.cancel()
        }
        defer { watchdog.cancel(); run.cancel() }

        do {
            _ = try await run.value
            XCTFail("Repeated post-action scope loss must stop at the shared recovery deadline")
        } catch ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged {
            // Expected: repeated failures remain bounded by one recovery deadline.
        } catch {
            XCTFail("Expected bounded scope loss, not watchdog cancellation: \(error)")
        }
        XCTAssertEqual(effects, 1, "Recovery observation must not replay the original click")
        XCTAssertEqual(proposals, 1, "No fresh proposal is safe while scope keeps oscillating")
        XCTAssertGreaterThanOrEqual(postActionScopeChecks, 6,
            "Scope checks must continue after successful dispatch until the recovery deadline")
    }

    func testReadOnlyWaitAcceptsRepaintAndRevalidatesFollowingClick() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 400)
        var repainted = false, proposals = 0, effects = 0, scopeChecks = 0
        var observedFrames: [Data] = []
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
            approvalTargetProvider: { _ in .init(context: "AXTextField Query", applicationID: "fixture", accessibilityIdentity: "editor") },
            actionPerformer: { _ in effects += 1 }, screenProvider: {
                .init(image: CIImage(color: repainted ? .white : .black).cropped(to: bounds),
                    displayBounds: bounds, frontmostWindowBounds: bounds)
            }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "AXTextField Query" },
            authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
            planningAccessibilityIdentityProvider: { "editor" }, frontmostApplicationProvider: { "Fixture" })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            proposals += 1
            observedFrames.append(input.screenshotPNG)
            switch proposals {
            case 1:
                repainted = true
                return .init(response: "wait", action: .wait(0.01))
            case 2:
                XCTAssertNotEqual(input.screenshotPNG, observedFrames[0], "The next proposal must use a fresh frame after waiting through a repaint")
                return .init(response: "click", action: .pointer(.leftClick, .init(x: 500, y: 350)))
            default:
                return .init(response: "handoff", decision: .handoff("The page is ready for review."))
            }
        }, surfaceScopeCheck: { _ in scopeChecks += 1 }, screenConsentRecognizer: { _ in false })

        let result = try await executor.execute(taskID: "repaint-during-wait", prompt: "Wait, then click", trustedUserPrompt: "Wait, then click",
            tools: tools, progress: { _ in })
        XCTAssertEqual(result, .userInterventionRequired("The page is ready for review."))
        XCTAssertEqual(effects, 1, "Only the fresh-frame click should send input")
        XCTAssertEqual(proposals, 3)
        XCTAssertGreaterThan(scopeChecks, 0, "A read-only wait still checks retained-surface authority")
    }

    func testReadOnlyWaitStopsWhenRetainedSurfaceChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 400)
        var scopeValid = true, proposals = 0, effects = 0
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
            approvalTargetProvider: { _ in .init(context: "AXTextField Query", applicationID: "fixture", accessibilityIdentity: "editor") },
            actionPerformer: { _ in effects += 1 }, screenProvider: {
                .init(image: CIImage(color: .black).cropped(to: bounds),
                    displayBounds: bounds, frontmostWindowBounds: bounds)
            }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "AXTextField Query" },
            authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
            planningAccessibilityIdentityProvider: { "editor" }, frontmostApplicationProvider: { "Fixture" })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            guard proposals == 1 else {
                return .init(response: "click", action: .pointer(.leftClick, .init(x: 500, y: 350)))
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(10))
                scopeValid = false
            }
            return .init(response: "wait", action: .wait(0.05))
        }, surfaceScopeCheck: { _ in
            guard scopeValid else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
        }, screenConsentRecognizer: { _ in false })

        do {
            _ = try await executor.execute(taskID: "scope-change-during-wait", prompt: "Wait, then click", trustedUserPrompt: "Wait, then click",
                tools: tools, progress: { _ in })
            XCTFail("A changed retained surface must stop before another proposal")
        } catch ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged {}
        XCTAssertEqual(proposals, 1)
        XCTAssertEqual(effects, 0, "No native input may follow a wait after scope loss")
    }

    func testScopedCompletionUsesOwnedWindowPixelsAndHandoffDoesNotNeedPixelEquality() async throws {
        for scenario in ["outside completion", "inside completion", "outside handoff"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let display = CGRect(x: 0, y: 0, width: 640, height: 400)
            let window = CGRect(x: 100, y: 50, width: 400, height: 300)
            let changedRect = scenario == "inside completion" ? CGRect(x: 200, y: 100, width: 30, height: 30)
                : CGRect(x: 10, y: 10, width: 30, height: 30)
            var changed = false, effects = 0, proposals = 0
            let code = ComputerUseApplicationCodeIdentity(authority: .runningCode, bundleIdentifier: "com.apple.Safari",
                canonicalBundlePath: "/Applications/Safari.app", canonicalExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                designatedRequirement: "test", teamIdentifier: nil, platformIdentifier: nil)
            let app = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 91,
                launchGeneration: 1, codeIdentity: code)!
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, actionPerformer: { _ in effects += 1 },
                screenProvider: {
                    let base = CIImage(color: .black).cropped(to: display)
                    let image = changed ? CIImage(color: .blue).cropped(to: changedRect).composited(over: base) : base
                    return .init(image: image, displayBounds: display, frontmostWindowBounds: window)
                }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "" },
                authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
                planningAccessibilityIdentityProvider: { "safari-window" },
                frontmostApplicationIdentityProvider: { app }, frontmostApplicationProvider: { "Safari" })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                proposals += 1
                changed = true
                if scenario == "outside handoff" { return .init(response: "Pause", decision: .handoff("Please review the sign-in page.")) }
                return .init(response: "Done", action: .reportCompletion("The requested page is open."))
            }, surfaceScopeCheck: { _ in })
            let result = try await executor.execute(taskID: scenario, prompt: "Open the requested page.",
                trustedUserPrompt: "Open the requested page.", tools: tools, progress: { _ in })
            if scenario == "inside completion" {
                XCTAssertEqual(result, .completed("The requested page is open."))
                XCTAssertEqual(proposals, 2, "A stale completion claim should be reconsidered from a stable fresh frame")
            } else if scenario == "outside handoff" {
                XCTAssertEqual(result, .userInterventionRequired("Please review the sign-in page."))
            } else {
                XCTAssertEqual(result, .completed("The requested page is open."))
            }
            XCTAssertEqual(effects, 0, scenario)
            if scenario != "inside completion" {
                XCTAssertEqual(proposals, 1, "A terminal decision must not trigger more actions")
            }
        }
    }

    func testScopedVisualClickWithoutAXTargetIgnoresPixelsOutsideOwnedWindow() async throws {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1050)
        let window = CGRect(x: 0, y: 33, width: 1728, height: 999)
        let code = ComputerUseApplicationCodeIdentity(authority: .runningCode, bundleIdentifier: "com.apple.Safari",
            canonicalBundlePath: "/Applications/Safari.app", canonicalExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            designatedRequirement: "test", teamIdentifier: nil, platformIdentifier: nil)
        let app = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 91,
            launchGeneration: 1, codeIdentity: code)!

        for (mode, scenario) in [("click", "outside"), ("click", "elsewhere in window"), ("click", "target"),
                                 ("key", "elsewhere in window"), ("key", "focus")] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var changed = false, proposals = 0, effects = 0
            var focus = "original-control"
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
                approvalTargetProvider: { _ in .init(context: "AXButton", applicationID: "fixture", accessibilityIdentity: "visual-target", frame: nil) }, actionPerformer: { _ in effects += 1 },
                screenProvider: {
                    let base = CIImage(color: .black).cropped(to: display)
                    let changedRect = scenario == "outside"
                        ? CGRect(x: 5, y: 1030, width: 20, height: 20)
                        : (scenario == "target" ? CGRect(x: 1144, y: 641, width: 20, height: 20)
                            : CGRect(x: 500, y: 200, width: 20, height: 20))
                    let image = changed ? CIImage(color: .blue).cropped(to: changedRect).composited(over: base) : base
                    return .init(image: image, displayBounds: display, frontmostWindowBounds: window)
                }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "AXButton Browse" },
                authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
                planningAccessibilityIdentityProvider: { focus },
                frontmostApplicationIdentityProvider: { app }, frontmostApplicationProvider: { "Safari" })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                proposals += 1
                changed = true
                if proposals == 1 {
                    if scenario == "focus" { focus = "another-control" }
                    if mode == "key" { return .init(response: "tab", action: .key(["Tab"])) }
                    return .init(response: "click", action: .pointer(.leftClick, .init(x: 2000.0 / 3.0, y: 401000.0 / 1050.0)))
                }
                return .init(response: "handoff", decision: .handoff("Review the page."))
            }, surfaceScopeCheck: { _ in })

            let result = try await executor.execute(taskID: "nil-ax-\(scenario)", prompt: "Click in the owned window.",
                trustedUserPrompt: "Click in the owned window.", tools: tools, progress: { _ in })
            if scenario != "target" && scenario != "focus" {
                XCTAssertEqual(result, .userInterventionRequired("Review the page."))
                XCTAssertEqual(effects, 1, "A change outside the click context must not block its visual click")
                XCTAssertEqual(proposals, 2)
            } else {
                XCTAssertEqual(effects, 0, "Changed target pixels or keyboard focus must invalidate the action")
                XCTAssertEqual(proposals, 2)
            }
        }
    }

    func testScopedDesktopCompletesOnlyAfterValidatorAccepts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var proposals = 0, checks = 0, scopeChecks = 0
        let tools = desktopTestTools()
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            return .init(response: "candidate", action: .reportCompletion("Verified"))
        }, surfaceScopeCheck: { _ in scopeChecks += 1 }, completeCheck: { answer in
            checks += 1
            XCTAssertEqual(answer, "Verified")
            return true
        })
        let result = try await executor.execute(taskID: "verified-completion-candidate", prompt: "Finish", trustedUserPrompt: "Finish", tools: tools, progress: { _ in })
        XCTAssertEqual(result, .completed("Verified"))
        XCTAssertEqual(proposals, 1)
        XCTAssertEqual(checks, 1)
        XCTAssertGreaterThan(scopeChecks, 0)
    }

    func testHostCompletionStatusCanCompleteAfterFreshProofDespitePixelChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = CGRect(x: 0, y: 0, width: 640, height: 400)
        let window = CGRect(x: 100, y: 50, width: 400, height: 300)
        let code = ComputerUseApplicationCodeIdentity(authority: .runningCode, bundleIdentifier: "com.apple.Safari",
            canonicalBundlePath: "/Applications/Safari.app", canonicalExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            designatedRequirement: "test", teamIdentifier: nil, platformIdentifier: nil)
        let app = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 91,
            launchGeneration: 1, codeIdentity: code)!
        var screenSamples = 0, proposals = 0, proofChecks = 0, scopeChecks = 0, effects = 0
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, actionPerformer: { _ in effects += 1 },
            screenProvider: {
                screenSamples += 1
                let color = screenSamples.isMultiple(of: 2)
                    ? CIColor(red: 0, green: 0, blue: 1, alpha: 1)
                    : CIColor(red: 0, green: 0, blue: 0, alpha: 1)
                return .init(image: CIImage(color: color).cropped(to: display), displayBounds: display,
                    frontmostWindowBounds: window)
            }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "" },
            authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
            planningAccessibilityIdentityProvider: { "safari-window" },
            frontmostApplicationIdentityProvider: { app }, frontmostApplicationProvider: { "Safari" })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            // Every capture changes pixels while retained scope stays stable.
            return .init(response: "Draft saved", decision: .completionStatus(success: true))
        }, surfaceScopeCheck: { _ in scopeChecks += 1 }, hostCompletionProof: {
            proofChecks += 1
            return true
        })

        let result = try await executor.execute(taskID: "host-read-only-completion-proof",
            prompt: "Save this draft.", trustedUserPrompt: "Save this draft.", tools: tools, progress: { _ in })

        XCTAssertEqual(result, .completed("The model reported completion."))
        XCTAssertEqual(proofChecks, 1, "The host proof must be consulted once before stale-pixel revalidation")
        XCTAssertEqual(proposals, 1)
        XCTAssertGreaterThan(scopeChecks, 0)
        XCTAssertEqual(effects, 0, "Read-only completion proof must not dispatch input")
    }

    func testHostCompletionProofRejectsFalseAndDoesNotReplaceModelReportOrRevokedScope() async throws {
        for scenario in ["false-proof", "nil-proof", "model-report", "scope-revoked", "gate-revoked"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let display = CGRect(x: 0, y: 0, width: 640, height: 400)
            let window = CGRect(x: 100, y: 50, width: 400, height: 300)
            let code = ComputerUseApplicationCodeIdentity(authority: .runningCode, bundleIdentifier: "com.apple.Safari",
                canonicalBundlePath: "/Applications/Safari.app", canonicalExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                designatedRequirement: "test", teamIdentifier: nil, platformIdentifier: nil)
            let app = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 91,
                launchGeneration: 1, codeIdentity: code)!
            var screenSamples = 0, proposals = 0, proofChecks = 0, effects = 0
            var mayAct = true, scopeValid = true
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { mayAct }, actionPerformer: { _ in effects += 1 },
                screenProvider: {
                    screenSamples += 1
                    let color = screenSamples.isMultiple(of: 2)
                        ? CIColor(red: 0, green: 0, blue: 1, alpha: 1)
                        : CIColor(red: 0, green: 0, blue: 0, alpha: 1)
                    return .init(image: CIImage(color: color).cropped(to: display), displayBounds: display,
                        frontmostWindowBounds: window)
                }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "" },
                authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
                planningAccessibilityIdentityProvider: { "safari-window" },
                frontmostApplicationIdentityProvider: { app }, frontmostApplicationProvider: { "Safari" })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                proposals += 1
                if proposals == 1 {
                    return .init(response: "candidate", decision: scenario == "model-report"
                        ? .action(.reportCompletion("Model claim")) : .completionStatus(success: true))
                }
                return .init(response: "stop", decision: .handoff("Review the current page."))
            }, surfaceScopeCheck: { _ in
                if !scopeValid { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
            }, hostCompletionProof: {
                proofChecks += 1
                if scenario == "scope-revoked" { scopeValid = false }
                if scenario == "gate-revoked" { mayAct = false }
                if scenario == "false-proof" { return false }
                if scenario == "nil-proof" { return nil }
                return true
            }, screenConsentRecognizer: { _ in false })

            if scenario == "scope-revoked" || scenario == "gate-revoked" {
                do {
                    _ = try await executor.execute(taskID: "host-proof-\(scenario)", prompt: "Finish",
                        trustedUserPrompt: "Finish", tools: tools, progress: { _ in })
                    XCTFail("A revoked \(scenario) cannot complete")
                } catch { }
            } else {
                let result = try await executor.execute(taskID: "host-proof-\(scenario)", prompt: "Finish",
                    trustedUserPrompt: "Finish", tools: tools, progress: { _ in })
                guard case .userInterventionRequired = result else {
                    return XCTFail("\(scenario) must not complete without fresh host proof")
                }
            }
            XCTAssertEqual(proofChecks, scenario == "model-report" ? 0 : 1, scenario)
            XCTAssertEqual(effects, 0, scenario)
        }
    }

    func testScopedCompletionScreenChangeRequiresFreshEvidenceBeforeCompleting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = CGRect(x: 0, y: 0, width: 640, height: 400)
        let window = CGRect(x: 100, y: 50, width: 400, height: 300)
        var screenChanged = false, proposals = 0, completionChecks = 0, effects = 0
        var firstScreenshot: Data?
        let code = ComputerUseApplicationCodeIdentity(authority: .runningCode, bundleIdentifier: "com.apple.Safari",
            canonicalBundlePath: "/Applications/Safari.app", canonicalExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            designatedRequirement: "test", teamIdentifier: nil, platformIdentifier: nil)
        let app = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 91,
            launchGeneration: 1, codeIdentity: code)!
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, actionPerformer: { _ in effects += 1 },
            screenProvider: {
                let color = screenChanged ? CIColor(red: 0, green: 0, blue: 1, alpha: 1)
                    : CIColor(red: 0, green: 0, blue: 0, alpha: 1)
                return .init(image: CIImage(color: color).cropped(to: display), displayBounds: display,
                    frontmostWindowBounds: window)
            }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "" },
            authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
            planningAccessibilityIdentityProvider: { "safari-window" },
            frontmostApplicationIdentityProvider: { app }, frontmostApplicationProvider: { "Safari" })
        let goal = "Upload the selected presentation and verify it finished uploading."
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            proposals += 1
            XCTAssertEqual(input.goal, goal)
            if proposals == 1 {
                XCTAssertTrue(input.history.isEmpty)
                XCTAssertNil(input.actionError)
                firstScreenshot = input.screenshotPNG
                screenChanged = true // Simulate the completion toast changing while the model was planning.
                return .init(response: "The upload is finished.", action: .reportCompletion("Verified upload"))
            }
            XCTAssertNotEqual(input.screenshotPNG, firstScreenshot, "The rejected claim must be reconsidered against fresh pixels")
            XCTAssertEqual(input.history.count, 1)
            XCTAssertEqual(input.history.first?.response, "The upload is finished.")
            XCTAssertTrue(input.actionError?.localizedCaseInsensitiveContains("completion") == true,
                "A stale completion claim should receive completion-specific feedback")
            return .init(response: "The fresh page confirms the upload.", action: .reportCompletion("Freshly verified upload"))
        }, surfaceScopeCheck: { _ in }, completeCheck: { _ in
            completionChecks += 1
            return true
        })

        let result = try await executor.execute(taskID: "completion-observation-refresh", prompt: goal,
            trustedUserPrompt: goal, tools: tools, progress: { _ in })
        XCTAssertEqual(result, .completed("Freshly verified upload"))
        XCTAssertEqual(proposals, 2, "A changed completion observation must be replanned once from fresh evidence")
        XCTAssertEqual(completionChecks, 1, "Only the stable second completion claim reaches the validator")
        XCTAssertEqual(effects, 0, "Completion recovery must not synthesize input")
    }

    func testScopedCompletionScreenChangesHandOffBoundedlyAndScopeLossFailsSafely() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = CGRect(x: 0, y: 0, width: 640, height: 400)
        let window = CGRect(x: 100, y: 50, width: 400, height: 300)
        var screenChanged = false, proposals = 0, completionChecks = 0, effects = 0
        var scopeValid = true
        let code = ComputerUseApplicationCodeIdentity(authority: .runningCode, bundleIdentifier: "com.apple.Safari",
            canonicalBundlePath: "/Applications/Safari.app", canonicalExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            designatedRequirement: "test", teamIdentifier: nil, platformIdentifier: nil)
        let app = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 91,
            launchGeneration: 1, codeIdentity: code)!
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, actionPerformer: { _ in effects += 1 },
            screenProvider: {
                let color = screenChanged ? CIColor(red: 0, green: 0, blue: 1, alpha: 1)
                    : CIColor(red: 0, green: 0, blue: 0, alpha: 1)
                return .init(image: CIImage(color: color).cropped(to: display), displayBounds: display,
                    frontmostWindowBounds: window)
            }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "" },
            authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
            planningAccessibilityIdentityProvider: { "safari-window" },
            frontmostApplicationIdentityProvider: { app }, frontmostApplicationProvider: { "Safari" })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            screenChanged.toggle()
            return .init(response: "Still uploading.", action: .reportCompletion("Verified upload"))
        }, surfaceScopeCheck: { _ in
            guard scopeValid else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
        }, completeCheck: { _ in
            completionChecks += 1
            return true
        })
        let goal = "Upload the selected presentation and verify it finished uploading."
        let unstable = try await executor.execute(taskID: "unstable-completion-observations", prompt: goal,
            trustedUserPrompt: goal, tools: tools, progress: { _ in })
        XCTAssertEqual(unstable, .userInterventionRequired("I couldn't verify the next desktop action. Complete this step, then choose Resume."))
        XCTAssertEqual(proposals, 3, "Repeated stale completion claims must hit the existing rejection bound")
        XCTAssertEqual(completionChecks, 0)
        XCTAssertEqual(effects, 0)

        let scopeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scopeDirectory) }
        scopeValid = false
        let scopeLostExecutor = try ComputerUseDesktopExecutor(journalDirectory: scopeDirectory, propose: { _ in
            XCTFail("A lost scoped window must fail before asking for completion")
            return .init(response: "Done", action: .reportCompletion("Verified upload"))
        }, surfaceScopeCheck: { _ in
            guard scopeValid else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
        }, completeCheck: { _ in
            completionChecks += 1
            return true
        })
        do {
            _ = try await scopeLostExecutor.execute(taskID: "scope-loss-completion", prompt: goal,
                trustedUserPrompt: goal, tools: tools, progress: { _ in })
            XCTFail("Loss of the scoped window must not accept a completion claim")
        } catch {
            XCTAssertEqual(error as? ComputerUseDesktopExecutor.Failure, .scopedSurfaceChanged)
            XCTAssertEqual(effects, 0)
        }
    }

    func testScopedDesktopRequiresCompletionValidatorAcceptance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var proposals = 0, checks = 0
        let tools = desktopTestTools()
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            if proposals == 1 { return .init(response: "candidate", action: .reportCompletion("Done")) }
            return .init(response: "handoff", decision: .handoff("Please inspect the page."))
        }, surfaceScopeCheck: { _ in }, completeCheck: { answer in
            checks += 1
            XCTAssertEqual(answer, "Done")
            return false
        })
        let result = try await executor.execute(taskID: "completion-candidate", prompt: "Finish", trustedUserPrompt: "Finish", tools: tools, progress: { _ in })
        XCTAssertEqual(result, .userInterventionRequired("Please inspect the page."))
        XCTAssertEqual(proposals, 2)
        XCTAssertEqual(checks, 1)
    }

    func testContextualOutcomeCheckReceivesCurrentProposalEvidenceAndCanRejectCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = "Create an unsent draft and verify it remains open."
        var proposalInput: ComputerUseFaraModel.Input?
        var proposalCount = 0, checks = 0
        let tools = desktopTestTools()
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            proposalCount += 1
            proposalInput = input
            if proposalCount == 1 { return .init(response: "Draft created", action: .reportCompletion("Draft is ready.")) }
            return .init(response: "Need review", decision: .handoff("Please inspect the current draft."))
        }, surfaceScopeCheck: { _ in }, outcomeCheck: { input, answer in
            checks += 1
            let proposed = try XCTUnwrap(proposalInput)
            XCTAssertEqual(input.goal, goal)
            XCTAssertEqual(input.goal, proposed.goal)
            XCTAssertEqual(input.screenshotPNG, proposed.screenshotPNG)
            XCTAssertEqual(input.focusedEditor, proposed.focusedEditor)
            XCTAssertEqual(input.nativeControls, proposed.nativeControls)
            XCTAssertEqual(answer, "Draft is ready.")
            return false
        })
        let result = try await executor.execute(taskID: "contextual-outcome-reject", prompt: goal,
            trustedUserPrompt: goal, tools: tools, progress: { _ in })
        XCTAssertEqual(result, .userInterventionRequired("Please inspect the current draft."))
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(proposalCount, 2)
    }

    func testContextualOutcomeCheckAlsoGuardsCompletionStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let goal = "Open the requested page and verify the result."
        var proposalCount = 0, checks = 0
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposalCount += 1
            if proposalCount == 1 { return .init(response: "Complete", decision: .completionStatus(success: true)) }
            return .init(response: "Need review", decision: .handoff("Please verify the current page."))
        }, surfaceScopeCheck: { _ in }, outcomeCheck: { input, answer in
            checks += 1
            XCTAssertEqual(input.goal, goal)
            XCTAssertEqual(answer, "The model reported completion.")
            return false
        })
        let result = try await executor.execute(taskID: "contextual-status-reject", prompt: goal,
            trustedUserPrompt: goal, tools: desktopTestTools(), progress: { _ in })
        XCTAssertEqual(result, .userInterventionRequired("Please verify the current page."))
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(proposalCount, 2)
    }

    func testContextualOutcomeRejectionCannotBeOverriddenByLegacyCompletionCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var proposals = 0, outcomeChecks = 0, legacyChecks = 0
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            if proposals == 1 { return .init(response: "Candidate", action: .reportCompletion("Done")) }
            return .init(response: "Need review", decision: .handoff("Please inspect the page."))
        }, completeCheck: { _ in
            legacyChecks += 1
            return true
        }, outcomeCheck: { _, _ in
            outcomeChecks += 1
            return false
        })
        let result = try await executor.execute(taskID: "contextual-outcome-no-bypass", prompt: "Finish",
            trustedUserPrompt: "Finish", tools: desktopTestTools(), progress: { _ in })
        XCTAssertEqual(result, .userInterventionRequired("Please inspect the page."))
        XCTAssertEqual(outcomeChecks, 1)
        XCTAssertEqual(legacyChecks, 0, "A rejected contextual outcome cannot be bypassed by the legacy callback")
        XCTAssertEqual(proposals, 2)
    }

    func testContextualOutcomeAcceptanceRevalidatesScreenshotAfterReview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = CGRect(x: 0, y: 0, width: 640, height: 400)
        let window = CGRect(x: 100, y: 50, width: 400, height: 300)
        var screenChanged = false, proposals = 0, checks = 0
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
            screenProvider: {
                .init(image: CIImage(color: screenChanged ? .blue : .black).cropped(to: display),
                    displayBounds: display, frontmostWindowBounds: window)
            }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "AXTextField Query" },
            authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
            planningAccessibilityIdentityProvider: { "window" }, frontmostApplicationProvider: { "Fixture" })
        let goal = "Verify the requested page result."
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            if proposals == 1 { return .init(response: "Complete", action: .reportCompletion("Verified.")) }
            return .init(response: "Need review", decision: .handoff("Please inspect the refreshed page."))
        }, surfaceScopeCheck: { _ in }, outcomeCheck: { _, _ in
            checks += 1
            screenChanged = true
            return true
        })
        let result = try await executor.execute(taskID: "contextual-screen-revalidation", prompt: goal,
            trustedUserPrompt: goal, tools: tools, progress: { _ in })
        XCTAssertEqual(result, .userInterventionRequired("Please inspect the refreshed page."))
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(proposals, 2)
    }

    func testContextualOutcomeCancellationPropagatesWithoutCompleting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewStarted = expectation(description: "The contextual review has started")
        var checks = 0
        var run: Task<ComputerUseExecutionResult, Error>?
        defer { run?.cancel() }
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            .init(response: "Complete", action: .reportCompletion("Verified."))
        }, outcomeCheck: { _, _ in
            checks += 1
            reviewStarted.fulfill()
            try await Task.sleep(for: .seconds(30))
            return true
        })
        run = Task { try await executor.execute(taskID: "contextual-outcome-cancel", prompt: "Finish",
            trustedUserPrompt: "Finish", tools: desktopTestTools(), progress: { _ in }) }
        await fulfillment(of: [reviewStarted], timeout: 2)
        run?.cancel()
        do {
            let result = try await run?.value
            XCTFail("Cancelled outcome review must not complete: \(result)")
        } catch is CancellationError {
            XCTAssertEqual(checks, 1)
        }
    }

    func testContextualOutcomeRuntimeErrorsStayResumableForBothCompletionForms() async throws {
        let goal = "Create the requested unsent draft and verify it is still open."
        for useCompletionStatus in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var reviewFails = true
            var proposals = 0, reviews = 0, effects = 0
            let tools = desktopTestTools(perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
                proposals += 1
                XCTAssertEqual(input.goal, goal)
                XCTAssertEqual(input.history.count, min(proposals - 1, 3), "Each retry or Resume must build a new observation with retained progress")
                if useCompletionStatus {
                    return .init(response: "Candidate", decision: .completionStatus(success: true))
                }
                return .init(response: "Candidate", action: .reportCompletion("Draft appears ready."))
            }, outcomeCheck: { input, _ in
                reviews += 1
                XCTAssertEqual(input.goal, goal)
                if reviewFails { throw OSAtlasLlamaRuntimeError.invalidResponse }
                return true
            })

            let first = try await executor.execute(taskID: "outcome-error-\(useCompletionStatus)", prompt: goal,
                trustedUserPrompt: goal, tools: tools, progress: { _ in })
            XCTAssertEqual(first, .userInterventionRequired("I couldn't verify the next desktop action. Complete this step, then choose Resume."))
            XCTAssertEqual(proposals, 3, "Review errors should use the existing bounded completion retries")
            XCTAssertEqual(reviews, 3)
            XCTAssertEqual(effects, 0)

            reviewFails = false
            let resumed = try await executor.execute(taskID: "outcome-error-\(useCompletionStatus)", prompt: goal,
                trustedUserPrompt: goal, tools: tools, progress: { _ in })
            XCTAssertEqual(resumed, .completed(useCompletionStatus ? "The model reported completion." : "Draft appears ready."))
            XCTAssertEqual(proposals, 4)
            XCTAssertEqual(reviews, 4)
            XCTAssertEqual(effects, 0)
        }
    }

    func testFaraDesktopRequestAdvertisesOnlyImplementedNativeCapabilities() throws {
        let image = try ComputerUseDesktopImage(observation: .init(
            image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)),
            displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400)))
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
            baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        let goal = "Edit the current document."
        let native = ComputerUseFaraModel.Input(goal: goal, screenshotPNG: image.png, surface: .desktop)
        func system(_ input: ComputerUseFaraModel.Input) throws -> String {
            let request = try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: input)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            return try XCTUnwrap(messages.first?["content"] as? String)
        }
        let prompt = try system(native)
        let start = try XCTUnwrap(prompt.range(of: "<tools>\n"))
        let end = try XCTUnwrap(prompt.range(of: "</tools>", range: start.upperBound..<prompt.endIndex))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt[start.upperBound..<end.lowerBound].utf8)) as? [String: Any])
        let function = try XCTUnwrap(schema["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let actions = try XCTUnwrap(properties["action"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(actions["enum"] as? [String])),
            Set(["key", "type", "left_click", "right_click", "double_click", "triple_click", "scroll", "hscroll", "wait", "pause_and_memorize_fact", "ask_user_question", "terminate"]))
        XCTAssertEqual(function["name"] as? String, "computer_use")
        XCTAssertTrue(prompt.contains("macOS")); XCTAssertTrue(prompt.contains("Command"))
        XCTAssertTrue(prompt.contains("<tool_call>"))
        XCTAssertEqual(try system(.init(goal: goal, screenshotPNG: image.png)), try ComputerUseFaraModel.browserSystemPrompt())
        var mixed = native; mixed.currentURL = URL(string: "https://example.com")
        XCTAssertThrowsError(try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: mixed))
        mixed = native; mixed.userResponse = "An answer from another surface"
        XCTAssertThrowsError(try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: mixed))
        XCTAssertThrowsError(try ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: mixed))
        XCTAssertThrowsError(try ComputerUseGUIOwlModel.makeRequest(endpoint: endpoint, input: mixed))
    }

    func testNativePointerIgnoresBackgroundBeyondItsWindowButRejectsChangedTargetContext() async throws {
        let display = CGRect(x: 0, y: 0, width: 640, height: 400)
        let window = CGRect(x: 100, y: 50, width: 300, height: 250)
        for (name, target, change, admitted) in [
            ("left background", CGRect(x: 100, y: 100, width: 300, height: 100), CGRect(x: 90, y: 110, width: 9, height: 40), true),
            ("right background", CGRect(x: 100, y: 100, width: 300, height: 100), CGRect(x: 401, y: 110, width: 9, height: 40), true),
            ("top background", CGRect(x: 150, y: 50, width: 100, height: 250), CGRect(x: 160, y: 40, width: 40, height: 9), true),
            ("bottom background", CGRect(x: 150, y: 50, width: 100, height: 250), CGRect(x: 160, y: 301, width: 40, height: 9), true),
            ("target content", CGRect(x: 100, y: 100, width: 300, height: 100), CGRect(x: 160, y: 120, width: 10, height: 20), false),
            ("surrounding context", CGRect(x: 100, y: 100, width: 300, height: 100), CGRect(x: 160, y: 70, width: 40, height: 10), false)
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var changed = false, calls = 0, effects = 0
            var rejectionPairs: [(ComputerUseDesktopImage, ComputerUseDesktopImage, ComputerUsePredictedAction?, [String: String])] = []
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
                approvalTargetProvider: { _ in .init(context: "AXTextField Query", applicationID: "fixture", accessibilityIdentity: "editor", frame: target) },
                actionPerformer: { _ in effects += 1 }, screenProvider: {
                    let base = CIImage(color: .white).cropped(to: display)
                    let local = CGRect(x: change.minX, y: display.maxY - change.maxY, width: change.width, height: change.height)
                    let image = changed ? CIImage(color: .blue).cropped(to: local).composited(over: base) : base
                    return .init(image: image, displayBounds: display, frontmostWindowBounds: window)
                }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "AXTextField Query" },
                authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
                planningAccessibilityIdentityProvider: { "editor" }, frontmostApplicationProvider: { "Fixture" })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
                calls += 1
                if calls == 1 {
                    changed = true
                    return .init(response: "click", action: .pointer(.leftClick,
                        .init(x: target.midX / display.width * 1000, y: target.midY / display.height * 1000)))
                }
                XCTAssertEqual(calls, 2, name); XCTAssertEqual(input.actionError == nil, admitted, name)
                return .init(response: "done", action: .reportCompletion("Checked"))
            }, revalidationFailureObserver: { expected, fresh, action, diagnostic in
                rejectionPairs.append((expected, fresh, action, diagnostic))
            })
            let result = try await executor.execute(taskID: "pointer-region", prompt: "Click Query", trustedUserPrompt: "Click Query", tools: tools, progress: { _ in })
            XCTAssertEqual(result, .completed("Checked"), name); XCTAssertEqual(effects, admitted ? 1 : 0, name)
            XCTAssertEqual(rejectionPairs.count, admitted ? 0 : 1, name)
            if !admitted, let pair = rejectionPairs.first {
                XCTAssertNotEqual(pair.0.png, pair.1.png, name)
                XCTAssertNotNil(pair.2, name)
                XCTAssertEqual(pair.3["screenMatches"], "false", name)
            }
        }
    }

    private func desktopTestTools(focus: @escaping () -> String = { "field" },
        approvalTarget: ((ComputerUsePredictedAction) throws -> ComputerUseApprovalTargetSnapshot)? = nil,
        injector: InputInjector = InputInjector(), mayAct: @escaping () -> Bool = { true },
        window: @escaping () -> CGRect = { CGRect(x: 0, y: 0, width: 640, height: 400) },
        accessibilityContext: String = "AXTextField Query",
        perform: ((ComputerUsePredictedAction) throws -> Void)? = nil) -> ComputerUseHostTools {
        ComputerUseHostTools(injector: injector, mayAct: mayAct,
            approvalTargetProvider: approvalTarget ?? { _ in .init(context: "AXTextField Query", applicationID: "fixture", accessibilityIdentity: focus()) },
            actionPerformer: perform,
            screenProvider: { .init(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)),
                displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400), frontmostWindowBounds: window()) },
            transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in accessibilityContext },
            authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
            planningAccessibilityIdentityProvider: focus, frontmostApplicationProvider: { "Fixture" })
    }

    func testDesktopScreenConsentRecognitionFailureReturnsRecoverableHandoffBeforePlanning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var proposals = 0, effects = 0
        let tools = desktopTestTools(perform: { _ in effects += 1 })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            return .init(response: "unexpected", decision: .handoff("Unexpected proposal."))
        }, screenConsentRecognizer: { _ in
            throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1)
        })

        let result = try await executor.execute(taskID: "consent-recognition-failure",
            prompt: "Review the page.", trustedUserPrompt: "Review the page.",
            tools: tools, progress: { _ in })

        XCTAssertEqual(result, .userInterventionRequired(
            "The current screen could not be verified for a system permission dialog. Computer use is paused before the next action. Review any dialog, then choose Resume. If this repeats, restart the app."))
        XCTAssertEqual(executor.lastRevalidationDiagnostic, [
            "blockedAt": "screen-consent-recognition",
            "recognitionErrorDomain": "TextRecognition.CRImageReaderError",
            "recognitionErrorCode": "1",
        ])
        XCTAssertEqual(proposals, 0)
        XCTAssertEqual(effects, 0)
    }

    func testDesktopConsentRecognitionFailureDuringRevalidationStopsBeforeInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recognitionCalls = ConsentDiagnosticCounter()
        var proposals = 0, effects = 0
        let tools = desktopTestTools(perform: { _ in effects += 1 })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            return .init(response: "click", action: .pointer(.leftClick, .init(x: 500, y: 500)))
        }, screenConsentRecognizer: { _ in
            let call = recognitionCalls.incrementAndRead()
            if call == 2 {
                throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1)
            }
            return false
        })

        let result = try await executor.execute(taskID: "consent-revalidation-failure",
            prompt: "Review the page.", trustedUserPrompt: "Review the page.",
            tools: tools, progress: { _ in })

        XCTAssertEqual(result, .userInterventionRequired(
            "The current screen could not be verified for a system permission dialog. Computer use is paused before the next action. Review any dialog, then choose Resume. If this repeats, restart the app."))
        XCTAssertEqual(executor.lastRevalidationDiagnostic, [
            "blockedAt": "screen-consent-recognition",
            "recognitionErrorDomain": "TextRecognition.CRImageReaderError",
            "recognitionErrorCode": "1",
        ])
        XCTAssertEqual(recognitionCalls.value, 2)
        XCTAssertEqual(proposals, 1)
        XCTAssertEqual(effects, 0, "A failed revalidation must stop before input dispatch")
    }

    func testDesktopConsentRecognitionFailureCanResumeSameTaskAndGoal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recognitionCalls = ConsentDiagnosticCounter()
        var proposals = 0, effects = 0
        let tools = desktopTestTools(perform: { _ in effects += 1 })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            proposals += 1
            XCTAssertEqual(input.goal, "Review the page.")
            return .init(response: "review", decision: .handoff("Review the current page."))
        }, screenConsentRecognizer: { _ in
            let call = recognitionCalls.incrementAndRead()
            if call == 1 {
                throw NSError(domain: "TextRecognition.CRImageReaderError", code: 1)
            }
            return false
        })

        let first = try await executor.execute(taskID: "consent-recognition-resume",
            prompt: "Review the page.", trustedUserPrompt: "Review the page.",
            tools: tools, progress: { _ in })
        XCTAssertEqual(first, .userInterventionRequired(
            "The current screen could not be verified for a system permission dialog. Computer use is paused before the next action. Review any dialog, then choose Resume. If this repeats, restart the app."))

        let resumed = try await executor.execute(taskID: "consent-recognition-resume",
            prompt: "Review the page.", trustedUserPrompt: "Review the page.",
            tools: tools, progress: { _ in })

        XCTAssertEqual(resumed, .userInterventionRequired("Review the current page."))
        XCTAssertEqual(recognitionCalls.value, 2)
        XCTAssertEqual(proposals, 1)
        XCTAssertEqual(effects, 0)
    }

    func testDesktopScreenConsentRecognitionRunsOffMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var proposals = 0, effects = 0
        let tools = desktopTestTools(perform: { _ in effects += 1 })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            return .init(response: "review", decision: .handoff("Review the current screen."))
        }, screenConsentRecognizer: { _ in Thread.isMainThread })

        let result = try await executor.execute(taskID: "off-main-screen-consent", prompt: "Review the page.",
            trustedUserPrompt: "Review the page.", tools: tools, progress: { _ in })

        XCTAssertEqual(result, .userInterventionRequired("Review the current screen."),
            "A recognizer running on the main thread returns true and must fail closed")
        XCTAssertEqual(proposals, 1)
        XCTAssertEqual(effects, 0)
    }

    func testDesktopScreenConsentRecognitionTimeoutIsBoundedAndNoEffect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let recognitionCalls = ConsentDiagnosticCounter()
        var proposals = 0, effects = 0
        let tools = desktopTestTools(perform: { _ in effects += 1 })
        defer { release.signal() }
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            return .init(response: "review", decision: .handoff("Review the current screen."))
        }, screenConsentRecognizer: { _ in
            if recognitionCalls.incrementAndRead() == 1 {
                _ = release.wait()
                finished.signal()
            }
            return false
        }, screenConsentTimeout: 0.1)
        let started = ContinuousClock.now
        let timeout = try await executor.execute(taskID: "screen-consent-timeout", prompt: "Review the page.",
            trustedUserPrompt: "Review the page.", tools: tools, progress: { _ in })
        let elapsed = ContinuousClock.now - started
        let guidance = "Screen verification is unavailable because a previous check is still running or timed out. No further action was taken. Wait a moment, then choose Resume to verify a fresh screen."
        XCTAssertEqual(timeout, .userInterventionRequired(guidance))
        XCTAssertLessThan(elapsed, .milliseconds(300), "The main executor must not wait for blocked recognition")
        let busy = try await executor.execute(taskID: "screen-consent-timeout", prompt: "Review the page.",
            trustedUserPrompt: "Review the page.", tools: tools, progress: { _ in })
        XCTAssertEqual(busy, .userInterventionRequired(guidance),
            "Resume during an outstanding screen check must pause without using a cached image")
        XCTAssertEqual(recognitionCalls.value, 1, "The busy result must not invoke another screen recognizer")
        XCTAssertEqual(proposals, 0)
        XCTAssertEqual(effects, 0)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + .seconds(1)), .success)
        try await waitForScreenConsentRecognizerWorker()
        let resumed = try await executor.execute(taskID: "screen-consent-timeout", prompt: "Review the page.",
            trustedUserPrompt: "Review the page.", tools: tools, progress: { _ in })
        XCTAssertEqual(resumed, .userInterventionRequired("Review the current screen."))
        XCTAssertEqual(recognitionCalls.value, 2, "Resume must perform a fresh screen check")
        XCTAssertEqual(proposals, 1)
        XCTAssertEqual(effects, 0)
    }

    func testDesktopScreenConsentCancellationOrScopeLossStopsBeforePlanning() async throws {
        for scenario in ["cancel", "scope"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let invalidatedScope = DispatchSemaphore(value: 0)
            var run: Task<ComputerUseExecutionResult, Error>?
            var proposals = 0, effects = 0
            defer { run?.cancel(); release.signal() }
            let tools = desktopTestTools(perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                proposals += 1
                return .init(response: "unexpected", decision: .handoff("Stop."))
            }, surfaceScopeCheck: { _ in
                if invalidatedScope.wait(timeout: .now()) == .success {
                    invalidatedScope.signal()
                    throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged
                }
            }, screenConsentRecognizer: { _ in
                _ = release.wait(timeout: .now() + .seconds(1))
                finished.signal()
                return false
            }, screenConsentTimeout: 2)
            let releaseTask = Task.detached(priority: .userInitiated) {
                try? await Task.sleep(for: .milliseconds(350))
                release.signal()
            }
            run = Task { try await executor.execute(taskID: "screen-consent-\(scenario)",
                prompt: "Review the page.", trustedUserPrompt: "Review the page.", tools: tools, progress: { _ in }) }
            if scenario == "cancel" {
                let cancelTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    run?.cancel()
                }
                do { _ = try await run?.value; XCTFail("Cancellation during recognition must stop planning") }
                catch { XCTAssertTrue(error is CancellationError) }
                cancelTask.cancel()
            } else {
                let invalidateTask = Task.detached(priority: .userInitiated) {
                    try? await Task.sleep(for: .milliseconds(100))
                    invalidatedScope.signal()
                }
                do { _ = try await run?.value; XCTFail("Scope loss during recognition must stop planning") }
                catch { XCTAssertEqual(error as? ComputerUseDesktopExecutor.Failure, .scopedSurfaceChanged) }
                await invalidateTask.value
            }
            await releaseTask.value
            XCTAssertEqual(finished.wait(timeout: .now() + .seconds(1)), .success)
            try await waitForScreenConsentRecognizerWorker()
            XCTAssertEqual(proposals, 0, scenario)
            XCTAssertEqual(effects, 0, scenario)
        }
    }

    private func waitForScreenConsentRecognizerWorker() async throws {
        for _ in 0..<100 {
            do {
                _ = try await ComputerUseObservationWorker.perform { true }
                return
            } catch ComputerUseObservationWorker.Failure.busy {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        XCTFail("The finished consent recognizer did not release worker capacity")
    }

    func testGUIOwlNativeStatusAndManualHandoffRemainDistinct() async throws {
        for mode in ["success", "failure", "handoff"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var calls = 0, effects = 0, firstResponse: String?
            let tools = desktopTestTools(perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
                calls += 1
                guard calls <= 2 else { throw ComputerUseDesktopExecutor.Failure.stepLimit }
                let arguments: [String: String]
                if calls == 2 {
                    XCTAssertEqual(mode, "handoff"); XCTAssertEqual(input.history.count, 1)
                    XCTAssertEqual(input.history.first?.response, firstResponse)
                    XCTAssertNil(input.history.first?.action); XCTAssertNil(input.userResponse)
                    arguments = ["action": "answer", "text": "The requested step is finished."]
                } else if mode == "handoff" {
                    arguments = ["action": "interact", "text": "Complete the local step – 東京, then Resume."]
                } else { arguments = ["action": "terminate", "status": mode] }
                let body = try JSONSerialization.data(withJSONObject: ["name": "computer_use", "arguments": arguments])
                let response = "Action: Follow the current task.\n<tool_call>" + String(decoding: body, as: UTF8.self) + "</tool_call>"
                if calls == 1 { firstResponse = response }
                let packet = try JSONSerialization.data(withJSONObject: ["model": ComputerUseGUIOwlModel.modelAlias,
                    "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": response]]]])
                return try ComputerUseGUIOwlModel.decode(packet).compatibleDesktopProposal()
            })
            do {
                let result = try await executor.execute(taskID: mode, prompt: "Complete the current local step", trustedUserPrompt: "Complete the current local step", tools: tools, progress: { _ in })
                switch (mode, result) {
                case ("success", .completed): break
                case ("failure", .unableToComplete): break
                case ("handoff", .userInterventionRequired(let message)):
                    XCTAssertEqual(message, "Complete the local step – 東京, then Resume."); XCTAssertEqual(calls, 1)
                    let resumed = try await executor.execute(taskID: mode, prompt: "Complete the current local step", trustedUserPrompt: "Complete the current local step", tools: tools, progress: { _ in })
                    XCTAssertEqual(resumed, .completed("The requested step is finished.")); XCTAssertEqual(calls, 2)
                default: XCTFail("Incorrect native outcome for \(mode): \(result)")
                }
                let count = calls
                _ = try await executor.execute(taskID: mode, prompt: "Complete the current local step", trustedUserPrompt: "Complete the current local step", tools: tools, progress: { _ in })
                XCTAssertEqual(calls, count); XCTAssertEqual(effects, 0)
            } catch { XCTFail("Native GUI-Owl \(mode) could not continue: \(error)") }
        }
    }

    func testNativeCandidateProfilesDeclareMacEffectsAndKeepSeparateProtocols() throws {
        let image = try ComputerUseDesktopImage(observation: .init(
            image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)),
            displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400)))
        let input = ComputerUseFaraModel.Input(goal: "Edit the current form.", screenshotPNG: image.png, surface: .desktop)
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
            baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        let holo = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: input).httpBody)) as? [String: Any])
        let holoTools = try XCTUnwrap(holo["tools"] as? [[String: Any]]).compactMap { $0["function"] as? [String: Any] }
        XCTAssertEqual(Set(holoTools.compactMap { $0["name"] as? String }), Set(["click", "type", "key", "scroll", "wait", "answer"]))
        let key = try XCTUnwrap(holoTools.first { $0["name"] as? String == "key" }?["description"] as? String)
        XCTAssertTrue(key.contains("Command")); XCTAssertTrue(key.contains("Control")); XCTAssertFalse(key.contains("browser"))
        let owl = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(ComputerUseGUIOwlModel.makeRequest(endpoint: endpoint, input: input).httpBody)) as? [String: Any])
        XCTAssertNil(owl["tools"], "GUI-Owl must keep its XML protocol")
        let messages = try XCTUnwrap(owl["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let prompt = try XCTUnwrap(content.first?["text"] as? String)
        let start = try XCTUnwrap(prompt.range(of: "<tools>\n"))
        let end = try XCTUnwrap(prompt.range(of: "</tools>", range: start.upperBound..<prompt.endIndex))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt[start.upperBound..<end.lowerBound].utf8)) as? [String: Any])
        let function = try XCTUnwrap(schema["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let action = try XCTUnwrap(properties["action"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(action["enum"] as? [String])),
            Set(["key", "type", "left_click", "right_click", "double_click", "triple_click", "scroll", "hscroll", "wait", "answer", "terminate", "interact"]))
        XCTAssertNil(properties["answer"]); XCTAssertNil(properties["fact"])
        let status = try XCTUnwrap(properties["status"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(status["enum"] as? [String])), Set(["success", "failure"]))
    }

    func testNativeProvidersRetainObservedEditorWithItsScreenshot() throws {
        let image = try ComputerUseDesktopImage(observation: .init(
            image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)),
            displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400)))
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
            baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        let previousEditor = "Archive – 東京", currentEditor = "Search – e\u{301}"
        let fara = "<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":0}}</tool_call>"
        let holo = "{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"focus-1\",\"type\":\"function\",\"function\":{\"name\":\"wait\",\"arguments\":\"{\\\"time\\\":0}\"}}]}"
        let variants: [(String, String, (OSAtlasLlamaEndpoint, ComputerUseFaraModel.Input) throws -> URLRequest)] = [
            ("Fara", fara, ComputerUseFaraModel.makeRequest),
            ("GUI-Owl", "Action: Wait for the interface.\n" + fara, ComputerUseGUIOwlModel.makeRequest),
            ("Holo", holo, ComputerUseHoloModel.makeRequest)]
        for (name, response, build) in variants {
            var input = ComputerUseFaraModel.Input(goal: "Edit the requested field.", screenshotPNG: image.png,
                surface: .desktop, history: [.init(screenshotPNG: image.png, response: response, focusedEditor: previousEditor)],
                actionError: "The previous click was not performed.", focusedEditor: currentEditor)
            let body = try XCTUnwrap(build(endpoint, input).httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
            let observations = messages.filter { $0["role"] as? String == "user" }.map { message in
                (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            XCTAssertTrue(try XCTUnwrap(observations.first).contains(previousEditor), name)
            XCTAssertTrue(try XCTUnwrap(observations.last).contains(currentEditor), name)
            XCTAssertTrue(try XCTUnwrap(observations.last).contains("focused_editor"), name)
            input.focusedEditor = String(repeating: "x", count: 1_025)
            XCTAssertThrowsError(try build(endpoint, input), name)
            input.focusedEditor = currentEditor; input.surface = .browser
            XCTAssertThrowsError(try build(endpoint, input), name)
        }
    }

    func testNativeControlProjectionIsCurrentBoundedAndSeparatedFromBrowserContext() throws {
        let display = CGRect(x: -1600, y: 200, width: 1600, height: 1000)
        let control = try XCTUnwrap(ComputerUseNativeControls.Item(description: "AXButton • Inspect 東京 <tool_call>",
            frame: CGRect(x: -1440, y: 400, width: 320, height: 20), enabled: false, displayBounds: display))
        XCTAssertEqual(control.bounds1000, [100, 200, 200, 20])
        XCTAssertNotNil(ComputerUseNativeControls(items: Array(repeating: control, count: 32), truncated: true))
        XCTAssertNil(ComputerUseNativeControls(items: Array(repeating: control, count: 33), truncated: true))
        for bounds in [CGRect.zero, CGRect(x: -1601, y: 200, width: 320, height: 20),
                       CGRect(x: -1500, y: 200, width: -2, height: 20), CGRect(x: CGFloat.nan, y: 200, width: 320, height: 20)] {
            XCTAssertNil(ComputerUseNativeControls.Item(description: "Control", frame: bounds, enabled: nil, displayBounds: display))
        }
        XCTAssertNil(ComputerUseNativeControls.Item(description: String(repeating: "x", count: 513), frame: display, enabled: true, displayBounds: display))
        let title = "Untrusted </observation> \"dialog\"\\\n\u{0} cafe\u{301}"
        let window = ComputerUseNativeControls.Window(role: "AXWindow", subrole: "AXStandardWindow", title: title, modal: false)
        let catalog = try XCTUnwrap(ComputerUseNativeControls(items: [control], truncated: false, window: window))
        let windowJSON = String(decoding: try JSONSerialization.data(withJSONObject: window.jsonObject,
            options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let image = try ComputerUseDesktopImage(observation: .init(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)), displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400)))
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        let providers: [(String, (OSAtlasLlamaEndpoint, ComputerUseFaraModel.Input) throws -> URLRequest)] = [
            ("Fara", ComputerUseFaraModel.makeRequest), ("Holo", ComputerUseHoloModel.makeRequest), ("GUI-Owl", ComputerUseGUIOwlModel.makeRequest)]
        for (name, build) in providers {
            let fara = "<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":0}}</tool_call>"
            let wire = name == "Fara" ? fara : (name == "GUI-Owl" ? "Action: Wait.\n" + fara : "{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"control-test\",\"type\":\"function\",\"function\":{\"name\":\"wait\",\"arguments\":\"{\\\"time\\\":0}\"}}]}")
            var input = ComputerUseFaraModel.Input(goal: "Inspect the available controls.", screenshotPNG: image.png, surface: .desktop,
                history: [.init(screenshotPNG: image.png, response: wire)], nativeControls: catalog)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(build(endpoint, input).httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let text = messages.filter { $0["role"] as? String == "user" }.map { message in
                (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            XCTAssertEqual(text.count, 2)
            XCTAssertFalse(text.first?.contains("native_controls") == true, name + " must not attach current geometry to history")
            XCTAssertTrue(text.last?.contains("\"native_controls\":{") == true)
            XCTAssertTrue(text.last?.contains("\"enabled\":false") == true)
            XCTAssertTrue(text.last?.contains("\"window\":" + windowJSON) == true, name + " must carry exact window data in the current observation")
            XCTAssertFalse(text.first?.contains("AXStandardWindow") == true, name + " must not attach current window state to history")
            input.surface = .browser; XCTAssertThrowsError(try build(endpoint, input))
        }
        let synthetic = desktopTestTools(perform: { _ in XCTFail("Read-only control discovery must not emit input") })
        XCTAssertNil(try synthetic.nativeControlObservation(displayBounds: display, windowBounds: display))
    }

    func testNativeControlGeometryFitsBoundedObservationWithoutMovingTargets() throws {
        let display = CGRect(x: -3840, y: 180, width: 3840, height: 2160)
        let items = try (0..<32).map { index in
            try XCTUnwrap(ComputerUseNativeControls.Item(description: "Control \(index)",
                frame: CGRect(x: -3600.123456789 + Double(index) * 13.333333333,
                    y: 531.234567891, width: 25.123456789, height: 38.987654321),
                enabled: true, displayBounds: display))
        }
        let controls = try XCTUnwrap(ComputerUseNativeControls(items: items, truncated: true))
        let data = try JSONSerialization.data(withJSONObject: controls.jsonObject)
        XCTAssertLessThanOrEqual(data.count, 5_000,
            "A full control catalogue should not consume the visual model budget with decimal noise")
        for item in items {
            let center = try XCTUnwrap(item.jsonObject["center_1000"] as? [Double])
            let bounds = try XCTUnwrap(item.jsonObject["bounds_1000"] as? [Double])
            XCTAssertEqual(center.count, 2); XCTAssertEqual(bounds.count, 4)
            for axis in 0..<2 {
                XCTAssertGreaterThanOrEqual(center[axis], item.bounds1000[axis])
                XCTAssertLessThan(center[axis], item.bounds1000[axis] + item.bounds1000[axis + 2])
                XCTAssertGreaterThanOrEqual(center[axis], bounds[axis])
                XCTAssertLessThan(center[axis], bounds[axis] + bounds[axis + 2])
                XCTAssertEqual(center[axis], item.bounds1000[axis] + item.bounds1000[axis + 2] / 2,
                    accuracy: 0.001)
            }
        }
    }

    func testNativeControlGeometryRetainsTinyAndDisplayEdgeTargets() throws {
        let display = CGRect(x: -1600, y: 300, width: 1600, height: 1000)
        for frame in [CGRect(x: -1599.999999, y: 300.000001, width: 0.000001, height: 0.000001),
                      CGRect(x: -0.000002, y: 1299.999998, width: 0.000001, height: 0.000001),
                      CGRect(x: -1600, y: 300, width: 1600, height: 1000)] {
            let item = try XCTUnwrap(ComputerUseNativeControls.Item(description: "Target",
                frame: frame, enabled: nil, displayBounds: display))
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(
                with: JSONSerialization.data(withJSONObject: item.jsonObject)) as? [String: Any])
            let center = try XCTUnwrap(decoded["center_1000"] as? [Double])
            let bounds = try XCTUnwrap(decoded["bounds_1000"] as? [Double])
            for axis in 0..<2 {
                XCTAssertGreaterThan(bounds[axis + 2], 0)
                XCTAssertGreaterThanOrEqual(center[axis], item.bounds1000[axis])
                XCTAssertLessThan(center[axis], item.bounds1000[axis] + item.bounds1000[axis + 2])
                XCTAssertGreaterThanOrEqual(center[axis], bounds[axis])
                XCTAssertLessThan(center[axis], bounds[axis] + bounds[axis + 2])
            }
        }
    }

    func testNativeTextStateBoundsUnicodeAndRejectsInvalidOrProtectedSnapshots() throws {
        for value in ["", "\t", " \n\r ", "e\u{301} 👩🏽‍💻", "\"\\\u{0}</observation>"] {
            let range = NSRange(location: value.utf16.count, length: 0)
            let state = try XCTUnwrap(ComputerUseNativeTextState(snapshot: .init(targetID: "field", value: value, selection: range, isEditable: true, isSecure: false)))
            XCTAssertTrue(state.valuePrefix.utf8.elementsEqual(value.utf8)); XCTAssertFalse(state.truncated)
            XCTAssertEqual(state.valueUTF8Bytes, value.utf8.count); XCTAssertEqual(state.valueUTF16Units, value.utf16.count)
            XCTAssertEqual(state.selection, range)
            let wire = try JSONSerialization.data(withJSONObject: state.jsonObject)
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
            XCTAssertTrue(try XCTUnwrap(decoded["value_prefix"] as? String).utf8.elementsEqual(value.utf8))
        }
        let long = String(repeating: "👩🏽‍💻", count: 35)
        let bounded = try XCTUnwrap(ComputerUseNativeTextState(snapshot: .init(targetID: "field", value: long, selection: NSRange(location: 240, length: 5), isEditable: true, isSecure: false)))
        XCTAssertEqual(bounded.valuePrefix, String(repeating: "👩🏽‍💻", count: 34)); XCTAssertTrue(bounded.truncated)
        XCTAssertEqual(bounded.valueUTF8Bytes, 525); XCTAssertEqual(bounded.valueUTF16Units, 245)
        let hugeCharacter = "a" + String(repeating: "\u{301}", count: 512)
        let omitted = try XCTUnwrap(ComputerUseNativeTextState(snapshot: .init(targetID: "field", value: hugeCharacter, selection: .init(location: 0, length: 0), isEditable: true, isSecure: false)))
        XCTAssertEqual(omitted.valuePrefix, ""); XCTAssertTrue(omitted.truncated); XCTAssertEqual(omitted.valueUTF8Bytes, 1025)
        for (editable, secure, range, value) in [
            (true, true, NSRange(location: 0, length: 0), "private"), (false, false, NSRange(location: 0, length: 0), "disabled"),
            (true, false, NSRange(location: -1, length: 0), "x"), (true, false, NSRange(location: 0, length: -1), "x"),
            (true, false, NSRange(location: Int.max, length: Int.max), "x"), (true, false, NSRange(location: 1, length: 1), "x"),
            (true, false, NSRange(location: 0, length: 0), String(repeating: "x", count: 1_048_577))] {
            XCTAssertNil(ComputerUseNativeTextState(snapshot: .init(targetID: "field", value: value, selection: range, isEditable: editable, isSecure: secure)))
        }
    }

    func testNativeTextHistoryKeepsOriginalOutcomesAndRejectsOrphanedOrOversizedState() throws {
        let image = try ComputerUseDesktopImage(observation: .init(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)), displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400)))
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        func state(_ value: String) throws -> ComputerUseNativeTextState {
            try XCTUnwrap(.init(snapshot: .init(targetID: "field", value: value, selection: .init(location: value.utf16.count, length: 0), isEditable: true, isSecure: false)))
        }
        let providers: [(String, (OSAtlasLlamaEndpoint, ComputerUseFaraModel.Input) throws -> URLRequest)] = [
            ("Fara", ComputerUseFaraModel.makeRequest), ("GUI-Owl", ComputerUseGUIOwlModel.makeRequest), ("Holo", ComputerUseHoloModel.makeRequest)]
        for (name, build) in providers {
            func wire(_ index: Int) throws -> String {
                let fara = "<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":0}}</tool_call>"
                if name == "Fara" { return fara }
                if name == "GUI-Owl" { return "Action: Inspect current state.\n" + fara }
                return String(decoding: try JSONSerialization.data(withJSONObject: ["role": "assistant", "content": "", "tool_calls": [["id": "state-\(index)", "type": "function", "function": ["name": "wait", "arguments": "{\"time\":0}"]]]]), as: UTF8.self)
            }
            var history: [ComputerUseFaraModel.Step] = try (0..<3).map { .init(screenshotPNG: image.png, response: try wire($0), focusedEditor: "Earlier editor \($0)", focusedTextState: try state($0 == 0 ? "\t" : "earlier-\($0)")) }
            history[0].resultObservation = .init(currentURL: nil, userResponse: nil, actionError: "Original feedback", focusedEditor: "Original next editor", focusedTextState: try state("original-next\n\t"))
            var input = ComputerUseFaraModel.Input(goal: "Inspect the editor state.", screenshotPNG: image.png, surface: .desktop,
                history: history, focusedEditor: "Current editor", focusedTextState: try state("current-e\u{301}"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(build(endpoint, input).httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let text = messages.flatMap { message -> [String] in
                if let value = message["content"] as? String { return [value] }
                return (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            }.joined(separator: "\n")
            for value in ["\t", "original-next\n\t", "current-e\u{301}"] {
                let expected = String(decoding: try JSONSerialization.data(withJSONObject: ["value_prefix": value], options: .withoutEscapingSlashes), as: UTF8.self).dropFirst().dropLast()
                XCTAssertTrue(text.contains(expected), name + " lost a native observation: \(value.debugDescription)")
            }
            input.focusedEditor = nil; XCTAssertThrowsError(try build(endpoint, input), "State without its editor is ambiguous")
            input.focusedEditor = "Current editor"; input.surface = .browser; XCTAssertThrowsError(try build(endpoint, input))
            input.surface = .desktop; input.history[0].resultObservation?.focusedEditor = nil; XCTAssertThrowsError(try build(endpoint, input))
            input.history[0].resultObservation = .init(currentURL: nil, userResponse: nil, actionError: String(repeating: "x", count: 16_385),
                focusedEditor: "Original next editor", focusedTextState: try state("original-next\n\t"))
            XCTAssertThrowsError(try build(endpoint, input), name + " must bound the captured outcome error")
            input.history = try (0..<20).map { .init(screenshotPNG: image.png, response: try wire($0), focusedEditor: String(repeating: "x", count: 1024), focusedTextState: try state(String(repeating: "\u{0}", count: 512))) }
            XCTAssertThrowsError(try build(endpoint, input), name + " must bound serialized text including JSON escaping")
        }
    }

    func testKeyboardCheckpointUsesVisiblePartOfScrollableFocus() {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let window = CGRect(x: 400, y: 200, width: 950, height: 650)
        let outline = CGRect(x: 598, y: 426, width: 707, height: 3857)
        let point = ComputerUseHostTools.nativeKeyboardCheckpoint(focusedFrame: outline,
            windowBounds: window, displayBounds: display)
        XCTAssertEqual(point, CGPoint(x: 951.5, y: 638))
        XCTAssertTrue(display.contains(point)); XCTAssertTrue(window.contains(point))
        for frame in [nil, CGRect.zero, CGRect(x: 0, y: 2000, width: 50, height: 50)] as [CGRect?] {
            XCTAssertEqual(ComputerUseHostTools.nativeKeyboardCheckpoint(focusedFrame: frame,
                windowBounds: window, displayBounds: display), CGPoint(x: 875, y: 525))
        }
    }

    func testNativeWindowComparisonExcludesPartialPixelsFromOutsideItsBounds() throws {
        let bounds = CGRect(x: -400, y: 100, width: 1728, height: 1117)
        for window in [CGRect(x: -180, y: 625, width: 640, height: 332),
                       CGRect(x: -80.25, y: 300.75, width: 450.5, height: 280.5)] {
            let field = CGRect(x: window.minX + 30, y: window.minY + 100, width: 250, height: 25)
            func image(changing rect: CGRect? = nil) throws -> ComputerUseDesktopImage {
                var image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: bounds.width * 2, height: bounds.height * 2))
                if let rect {
                    let local = CGRect(x: (rect.minX - bounds.minX) * 2, y: (bounds.maxY - rect.maxY) * 2,
                        width: rect.width * 2, height: rect.height * 2)
                    image = CIImage(color: .blue).cropped(to: local).composited(over: image)
                }
                return try .init(observation: .init(image: image, displayBounds: bounds))
            }
            let before = try image()
            for outside in [CGRect(x: window.maxX, y: window.minY + 20, width: 4, height: 160),
                            CGRect(x: window.minX - 4, y: window.minY + 20, width: 4, height: 160),
                            CGRect(x: window.minX + 20, y: window.minY - 4, width: 160, height: 4),
                            CGRect(x: window.minX + 20, y: window.maxY, width: 160, height: 4)] {
                XCTAssertTrue(try before.matchesInsertionPointPixels(of: image(changing: outside), window: window, field: field),
                    "Resampling must not import an adjacent window's pixels into the current window: \(outside)")
            }
            for inside in [CGRect(x: window.maxX - 3, y: window.minY + 20, width: 2, height: 160),
                           CGRect(x: window.minX + 1, y: window.minY + 20, width: 2, height: 160),
                           CGRect(x: field.minX + 20, y: field.minY, width: 10, height: 20)] {
                XCTAssertFalse(try before.matchesInsertionPointPixels(of: image(changing: inside), window: window, field: field),
                    "Visible edge content and text changes remain significant: \(inside)")
            }
        }
    }

    func testApprovalPixelsIgnoreOnlyBackgroundOutsideAStableOwningWindow() throws {
        for scale in [1, 2] {
            let display = CGRect(x: -100, y: 20, width: 640, height: 400)
            let window = ComputerUseFrontmostWindowCaptureIdentity(applicationProcessIdentifier: 42,
                accessibilityWindowHash: 123, bounds: CGRect(x: 0, y: 70, width: 300, height: 250))
            func digest(_ point: CGPoint, change: CGRect?, owner: ComputerUseFrontmostWindowCaptureIdentity?) throws -> String? {
                let context = try XCTUnwrap(CGContext(data: nil, width: 640 * scale, height: 400 * scale,
                    bitsPerComponent: 8, bytesPerRow: 640 * scale * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640 * scale, height: 400 * scale))
                if let change {
                    context.setFillColor(CGColor(gray: 0, alpha: 1))
                    context.fill(CGRect(x: (change.minX - display.minX) * CGFloat(scale),
                        y: (display.maxY - change.maxY) * CGFloat(scale), width: change.width * CGFloat(scale), height: change.height * CGFloat(scale)))
                }
                return try ComputerUseHostTools.approvalVisualDigest(around: [point], image: XCTUnwrap(context.makeImage()),
                    displayBounds: display, window: owner)
            }
            for (point, outside, inside) in [
                (CGPoint(x: 10, y: 150), CGRect(x: -8, y: 145, width: 7, height: 10), CGRect(x: 1, y: 145, width: 7, height: 10)),
                (CGPoint(x: 290, y: 150), CGRect(x: 301, y: 145, width: 7, height: 10), CGRect(x: 292, y: 145, width: 7, height: 10)),
                (CGPoint(x: 150, y: 80), CGRect(x: 145, y: 62, width: 10, height: 7), CGRect(x: 145, y: 71, width: 10, height: 7)),
                (CGPoint(x: 150, y: 310), CGRect(x: 145, y: 321, width: 10, height: 7), CGRect(x: 145, y: 312, width: 10, height: 7))
            ] {
                let base = try digest(point, change: nil, owner: window)
                XCTAssertEqual(try digest(point, change: outside, owner: window), base, "Outside window at \(scale)x, \(point)")
                XCTAssertNotEqual(try digest(point, change: inside, owner: window), base, "Changed target must invalidate approval")
                XCTAssertNotEqual(try digest(point, change: outside, owner: nil), try digest(point, change: nil, owner: nil), "Unknown owner must retain display pixels")
            }
            let outsidePoint = CGPoint(x: -10, y: 150), outsideChange = CGRect(x: -12, y: 145, width: 7, height: 10)
            XCTAssertNotEqual(try digest(outsidePoint, change: outsideChange, owner: window), try digest(outsidePoint, change: nil, owner: window),
                "A target outside the frontmost window must retain its display pixels")
            let point = CGPoint(x: 150, y: 150), base = try digest(point, change: nil, owner: window)
            for changed in [
                ComputerUseFrontmostWindowCaptureIdentity(applicationProcessIdentifier: 43, accessibilityWindowHash: 123, bounds: window.bounds),
                .init(applicationProcessIdentifier: 42, accessibilityWindowHash: 124, bounds: window.bounds),
                .init(applicationProcessIdentifier: 42, accessibilityWindowHash: 123, bounds: window.bounds.offsetBy(dx: 1, dy: 0))
            ] {
                XCTAssertNotEqual(try digest(point, change: nil, owner: changed), base, "Identical pixels cannot revive a different owning window")
            }
            XCTAssertNotEqual(try digest(point, change: nil, owner: nil), base, "Lost window authority must invalidate approval")
        }
    }

    func testNativeDesktopApprovalIsSingleUseAndCannotReviveAfterTargetRejection() async throws {
        for changed in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var focus = "field", effects = 0, calls = 0
            let tools = desktopTestTools(focus: { focus }, perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                calls += 1
                return calls == 1 ? .init(response: "return", action: .key(["Return"])) : .init(response: "done", action: .reportCompletion("Done"))
            })
            let pending = try await executor.execute(taskID: "approval", prompt: "Press Return", trustedUserPrompt: "Press Return", tools: tools, progress: { _ in })
            guard case .approvalRequired(_, let action, let token) = pending else { return XCTFail("Expected native approval") }
            let fingerprint = try tools.prepareNativeActionFingerprint(for: action)
            if changed {
                focus = "changed field"
                do { try await executor.performApprovedVisualAction(token, action: action, fingerprint: fingerprint, tools: tools, willBeginEffect: {}); XCTFail("Changed target executed") } catch { }
                focus = "field"
                do { try await executor.performApprovedVisualAction(token, action: action, fingerprint: fingerprint, tools: tools, willBeginEffect: {}); XCTFail("Rejected approval revived") } catch { }
                XCTAssertEqual(effects, 0)
            } else {
                try await executor.performApprovedVisualAction(token, action: action, fingerprint: fingerprint, tools: tools, willBeginEffect: {})
                do { try await executor.performApprovedVisualAction(token, action: action, fingerprint: fingerprint, tools: tools, willBeginEffect: {}); XCTFail("Approval replay executed") } catch { }
                do { _ = try await executor.execute(taskID: "approval", prompt: "Press Return", trustedUserPrompt: "Press Return", tools: tools, progress: { _ in }); XCTFail("Performed approval was offered again") } catch { }
                let result = try await executor.continueAfterApprovedVisualAction(token, action: action, tools: tools, progress: { _ in })
                XCTAssertEqual(result, .completed("Done")); XCTAssertEqual(effects, 1); XCTAssertEqual(calls, 2)
            }
        }
    }

    func testNativeApprovedSuccessClearsThePriorErrorAndResetsConsecutiveRejections() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var effects = 0, calls = 0
        let tools = desktopTestTools(perform: { _ in effects += 1 })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            calls += 1
            XCTAssertEqual(input.goal, "Continue the same task")
            switch calls {
            case 1: return .init(response: "unsupported before approval", decision: .unsupported)
            case 2:
                XCTAssertNotNil(input.actionError)
                return .init(response: "approved Return", action: .key(["Return"]))
            case 3:
                XCTAssertNil(input.actionError, "A verified approved effect must not be reported as the previous failure")
                XCTAssertEqual(input.history.map(\.response), ["unsupported before approval", "approved Return"])
                return .init(response: "first rejection after success", decision: .unsupported)
            case 4: return .init(response: "second rejection after success", decision: .unsupported)
            case 5: return .init(response: "done", action: .reportCompletion("Done"))
            default: throw ComputerUseDesktopExecutor.Failure.stepLimit
            }
        })
        let pending = try await executor.execute(taskID: "approval-recovery", prompt: "Continue the same task",
            trustedUserPrompt: "Continue the same task", tools: tools, progress: { _ in })
        guard case .approvalRequired(_, let action, let token) = pending else { return XCTFail("Expected native approval") }
        try await executor.performApprovedVisualAction(token, action: action,
            fingerprint: tools.prepareNativeActionFingerprint(for: action), tools: tools, willBeginEffect: {})
        let result = try await executor.continueAfterApprovedVisualAction(token, action: action, tools: tools, progress: { _ in })
        XCTAssertEqual(result, .completed("Done"), "Only consecutive failures may exhaust the rejection allowance")
        XCTAssertEqual(calls, 5); XCTAssertEqual(effects, 1)
    }

    func testDesktopUncertainEffectCannotReplayOnResumeOrRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var effects = 0, proposals = 0
        let tools = desktopTestTools(perform: { _ in
            effects += 1
            throw ComputerUseHostTools.ToolError.approvalTargetChanged
        })
        let propose: ComputerUseDesktopExecutor.Propose = { _ in
            proposals += 1
            return .init(response: "key", action: .key(["Tab"]))
        }
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: propose)
        do { _ = try await executor.execute(taskID: "uncertain", prompt: "Press Tab", trustedUserPrompt: "Press Tab", tools: tools, progress: { _ in }); XCTFail("Expected uncertain effect") } catch { }
        let resumed = try await executor.execute(taskID: "uncertain", prompt: "Press Tab", trustedUserPrompt: "Press Tab", tools: tools, progress: { _ in })
        guard case .unableToComplete = resumed else { return XCTFail("Uncertain action became complete") }
        let restarted = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: propose)
        do { _ = try await restarted.execute(taskID: "uncertain", prompt: "Press Tab", trustedUserPrompt: "Press Tab", tools: tools, progress: { _ in }); XCTFail("Recovered uncertain action executed") } catch { }
        XCTAssertEqual(effects, 1); XCTAssertEqual(proposals, 1)
        let journals = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(journals.filter { $0.statuses == [.uncertain] }.count, 1)
    }

    func testDesktopCancellationRejectsLateProposalAndConcurrentExecution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "Native proposal entered")
        let returned = expectation(description: "Late proposal returned")
        var release: CheckedContinuation<ComputerUseDesktopProposal, Never>?
        var effects = 0, finishes = 0
        let tools = desktopTestTools(perform: { _ in effects += 1 })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            let result = await withCheckedContinuation { release = $0; started.fulfill() }
            returned.fulfill()
            return result
        }, finishRun: { finishes += 1 })
        let run = Task { try await executor.execute(taskID: "cancel", prompt: "Press Tab", trustedUserPrompt: "Press Tab", tools: tools, progress: { _ in }) }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await executor.execute(taskID: "other", prompt: "Other", trustedUserPrompt: "Other", tools: tools, progress: { _ in }); XCTFail("Concurrent task entered") }
        catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .alreadyExecuting) }
        run.cancel()
        do { _ = try await run.value; XCTFail("Cancelled task returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        release?.resume(returning: .init(response: "late", action: .key(["Tab"])))
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(effects, 0); XCTAssertEqual(finishes, 1)
        let journals = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
        XCTAssertFalse(journals.contains { $0.stepIDs == ["native-dispatch-returned"] })
    }

    func testNativeDiagnosticCancellationJoinsItsProcessBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("probe.sh")
        let started = directory.appendingPathComponent("started"), cleaned = directory.appendingPathComponent("cleaned")
        try """
        started_path=$1
        cleaned_path=$2
        cleanup() {
            trap '' TERM
            kill "$child" 2>/dev/null
            wait "$child" 2>/dev/null
            sleep 0.3
            printf joined > "$cleaned_path"
            exit 0
        }
        trap cleanup TERM
        sleep 30 &
        child=$!
        printf started > "$started_path"
        wait "$child"
        cleanup
        """.write(to: script, atomically: true, encoding: .utf8)
        let probe = HoloProbeProcess()
        let returned = expectation(description: "Diagnostic process joined")
        var effects = 0
        let tools = desktopTestTools(perform: { _ in effects += 1 })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory.appendingPathComponent("journal"), propose: { _ in
            defer { returned.fulfill() }
            try probe.start(python: "/bin/sh", script: script.path, arguments: [started.path, cleaned.path])
            _ = try await probe.finish()
            return .init(response: "late", action: .key(["Tab"]))
        }, finishRun: { await probe.cancelAndWait() })
        let run = Task { try await executor.execute(taskID: "probe-cancel", prompt: "Press Tab", trustedUserPrompt: "Press Tab", tools: tools, progress: { _ in }) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        run.cancel()
        do { _ = try await run.value; XCTFail("Cancelled diagnostic returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleaned.path), "The executor must join its diagnostic process before returning")
        await fulfillment(of: [returned], timeout: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleaned.path))
        XCTAssertEqual(effects, 0)
    }

    func testDesktopCancellationAfterDispatchRetainsHistoryOnResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var run: Task<ComputerUseExecutionResult, Error>?
        var effects = 0, proposals = 0
        let tools = desktopTestTools(perform: { _ in effects += 1; run?.cancel() })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            proposals += 1
            if proposals == 1 { return .init(response: "key", action: .key(["Tab"])) }
            XCTAssertEqual(input.history.count, 1)
            let previousAction = try XCTUnwrap(try XCTUnwrap(input.history.first).action)
            XCTAssertEqual(previousAction, ComputerUseFaraAction.key(["Tab"]))
            return .init(response: "done", action: .reportCompletion("Done"))
        })
        run = Task { try await executor.execute(taskID: "after", prompt: "One edit", trustedUserPrompt: "One edit", tools: tools, progress: { _ in }) }
        do { _ = try await run?.value; XCTFail("Post-dispatch cancellation returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        let resumed = try await executor.execute(taskID: "after", prompt: "One edit", trustedUserPrompt: "One edit", tools: tools, progress: { _ in })
        XCTAssertEqual(resumed, ComputerUseExecutionResult.completed("Done")); XCTAssertEqual(effects, 1); XCTAssertEqual(proposals, 2)
        do { _ = try await executor.execute(taskID: "after", prompt: "New goal", trustedUserPrompt: "New goal", tools: tools, progress: { _ in }); XCTFail("Task identity accepted a changed goal") }
        catch { XCTAssertEqual(error as? ComputerUseDesktopExecutor.Failure, .changedTask) }
    }

    func testApprovalTargetChangedBeforeDispatchBecomesRejectedActionFeedback() async throws {
        for failureStage in ["preparation", "dispatch"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var approvalQueries = 0, identity = "observed-target", calls = 0, effects = 0
            let tools = desktopTestTools(approvalTarget: { _ in
                approvalQueries += 1
                if failureStage == "preparation", approvalQueries == 1 {
                    throw ComputerUseHostTools.ToolError.approvalTargetChanged
                }
                return .init(context: "AXTextField Query", applicationID: "fixture", accessibilityIdentity: identity)
            }, perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
                calls += 1
                if calls == 1 { return .init(response: "tab", action: .key(["Tab"])) }
                XCTAssertEqual(input.history.count, 1)
                XCTAssertEqual(input.history.first?.action, .key(["Tab"]))
                XCTAssertTrue(input.actionError?.contains("No mouse or keyboard input was sent") == true)
                return .init(response: "handoff", decision: .handoff("Review the current field."))
            })
            let result = try await executor.execute(taskID: "approval-target-\(failureStage)", prompt: "Continue",
                trustedUserPrompt: "Continue", tools: tools, progress: { message in
                    if failureStage == "dispatch", message == "Using the desktop…" { identity = "changed-target" }
                })
            XCTAssertEqual(result, .userInterventionRequired("Review the current field."))
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(effects, 0)
            XCTAssertEqual(executor.lastRevalidationDiagnostic["blockedAt"],
                failureStage == "preparation" ? "approval-fingerprint-preparation" : "approval-fingerprint-dispatch")
        }
    }

    func testApprovalTargetChangedAfterDispatchRemainsUncertainAndCannotReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0, effects = 0
        let tools = desktopTestTools(perform: { _ in
            effects += 1
            throw ComputerUseHostTools.ToolError.approvalTargetChanged
        })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            calls += 1
            return .init(response: "tab", action: .key(["Tab"]))
        })
        do {
            _ = try await executor.execute(taskID: "approval-target-after-effect", prompt: "Continue",
                trustedUserPrompt: "Continue", tools: tools, progress: { _ in })
            XCTFail("A target change after dispatch must remain uncertain")
        } catch ComputerUseHostTools.ToolError.approvalTargetChanged {
        }
        let resumed = try await executor.execute(taskID: "approval-target-after-effect", prompt: "Continue",
            trustedUserPrompt: "Continue", tools: tools, progress: { _ in })
        guard case .unableToComplete = resumed else { return XCTFail("An uncertain target change must not be replayed") }
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(calls, 1)
    }

    func testSuccessfulDispatchObserverRunsOnceOnlyAfterInputReturnsVerified() async throws {
        // Ordinary native dispatch reports only after its verified journal save.
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var calls = 0, effects = 0
            var observed: [ComputerUsePredictedAction] = []
            let tools = desktopTestTools(perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                calls += 1
                if calls == 1 { return .init(response: "tab", action: .key(["Tab"])) }
                return .init(response: "handoff", decision: .handoff("Review the current field."))
            }, onSuccessfulDispatch: { observed.append($0) })
            let result = try await executor.execute(taskID: "observer-ordinary", prompt: "Continue",
                trustedUserPrompt: "Continue", tools: tools, progress: { _ in })
            XCTAssertEqual(result, .userInterventionRequired("Review the current field."))
            XCTAssertEqual(effects, 1)
            XCTAssertEqual(observed, [.key(usage: 0x2B, modifiers: 0)])
        }

        // An approval request alone reports no dispatch. A successful approved
        // dispatch reports once; retrying the same continuation cannot replay it.
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var effects = 0
            var observed: [ComputerUsePredictedAction] = []
            let tools = desktopTestTools(perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                .init(response: "return", action: .key(["Return"]))
            }, onSuccessfulDispatch: { observed.append($0) })
            let pending = try await executor.execute(taskID: "observer-approved", prompt: "Submit",
                trustedUserPrompt: "Submit", tools: tools, progress: { _ in })
            guard case .approvalRequired(_, let action, let continuation) = pending else {
                return XCTFail("Expected pending approval")
            }
            XCTAssertTrue(observed.isEmpty, "Approval pending is not evidence that input was dispatched")
            let fingerprint = try tools.prepareNativeActionFingerprint(for: action)
            try await executor.performApprovedVisualAction(continuation, action: action, fingerprint: fingerprint,
                tools: tools, willBeginEffect: {})
            XCTAssertEqual(effects, 1)
            XCTAssertEqual(observed, [.key(usage: 0x28, modifiers: 0)])
            do {
                try await executor.performApprovedVisualAction(continuation, action: action, fingerprint: fingerprint,
                    tools: tools, willBeginEffect: {})
                XCTFail("A completed approval continuation must not replay input")
            } catch {}
            XCTAssertEqual(effects, 1)
            XCTAssertEqual(observed, [.key(usage: 0x28, modifiers: 0)])
        }

        // Rejected-before-input and throwing-after-begin dispatches never report
        // a successful completion; the latter remains uncertain and cannot replay.
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var focus = "first", calls = 0, effects = 0
            var observed: [ComputerUsePredictedAction] = []
            let tools = desktopTestTools(focus: { focus }, perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                calls += 1
                if calls == 1 { focus = "changed"; return .init(response: "tab", action: .key(["Tab"])) }
                XCTAssertTrue(observed.isEmpty)
                return .init(response: "handoff", decision: .handoff("Review the current field."))
            }, onSuccessfulDispatch: { observed.append($0) })
            _ = try await executor.execute(taskID: "observer-rejected", prompt: "Continue",
                trustedUserPrompt: "Continue", tools: tools, progress: { _ in })
            XCTAssertEqual(effects, 0)
            XCTAssertTrue(observed.isEmpty)
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var calls = 0, effects = 0
            var observed: [ComputerUsePredictedAction] = []
            let tools = desktopTestTools(perform: { _ in
                effects += 1
                throw ComputerUseHostTools.ToolError.approvalTargetChanged
            })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                calls += 1
                return .init(response: "tab", action: .key(["Tab"]))
            }, onSuccessfulDispatch: { observed.append($0) })
            do {
                _ = try await executor.execute(taskID: "observer-uncertain", prompt: "Continue",
                    trustedUserPrompt: "Continue", tools: tools, progress: { _ in })
                XCTFail("A post-input dispatch error must remain uncertain")
            } catch ComputerUseHostTools.ToolError.approvalTargetChanged {}
            let resumed = try await executor.execute(taskID: "observer-uncertain", prompt: "Continue",
                trustedUserPrompt: "Continue", tools: tools, progress: { _ in })
            guard case .unableToComplete = resumed else { return XCTFail("Uncertain input must not replay") }
            XCTAssertEqual(effects, 1)
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(observed.isEmpty, "An uncertain effect is not a successful dispatch receipt")
        }
    }

    func testNativeDesktopHistoryRetainsRejectedActionFeedbackWithItsObservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var focus = "first field", effects = 0, calls = 0
        var rejectedFeedback: String?
        let tools = desktopTestTools(focus: { focus }, perform: { _ in effects += 1 })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            calls += 1
            switch calls {
            case 1:
                focus = "another field"
                return .init(response: "key", action: .key(["a"]))
            case 2:
                rejectedFeedback = try XCTUnwrap(input.actionError)
                XCTAssertTrue(rejectedFeedback?.contains("No mouse or keyboard input was sent") == true)
                XCTAssertTrue(rejectedFeedback?.localizedCaseInsensitiveContains("waiting will not complete the rejected action") == true)
                XCTAssertEqual(input.history.count, 1)
                XCTAssertNil(input.history.first?.actionError)
                return .init(response: "wait", action: .wait(0))
            case 3:
                XCTAssertEqual(input.actionError, rejectedFeedback,
                    "A passive wait must not clear an unresolved rejected-action result")
                XCTAssertEqual(input.history.count, 2)
                XCTAssertEqual(input.history[1].actionError, rejectedFeedback,
                    "The observation after rejection must retain that result when it becomes history")
                return .init(response: "remember", action: .remember("The rejected input was not sent"))
            case 4:
                XCTAssertEqual(input.actionError, rejectedFeedback,
                    "A passive remember step must not clear an unresolved rejected-action result")
                return .init(response: "", decision: .refreshObservation, includeInModelHistory: false)
            case 5:
                XCTAssertEqual(input.actionError, rejectedFeedback,
                    "Refreshing a specialist's screenshot must preserve unresolved rejection feedback")
                XCTAssertEqual(input.history.count, 3, "A host observation refresh is not a model action")
                XCTAssertEqual(effects, 0, "Refreshing the screen must not replay the rejected input")
                return .init(response: "fresh key", action: .key(["a"]))
            case 6:
                XCTAssertNil(input.actionError, "A successfully dispatched input resolves the prior rejection")
                XCTAssertEqual(input.history.last?.action, .key(["a"]))
                return .init(response: "done", action: .reportCompletion("Done"))
            default: throw ComputerUseDesktopExecutor.Failure.stepLimit
            }
        })
        let result = try await executor.execute(taskID: "feedback", prompt: "Use the current field", trustedUserPrompt: "Use the current field", tools: tools, progress: { _ in })
        XCTAssertEqual(result, .completed("Done")); XCTAssertEqual(calls, 6); XCTAssertEqual(effects, 1)
    }

    func testDesktopImagePreservesOrientationAndFullOffsetDisplayCoordinates() throws {
        let extent = CGRect(x: 0, y: 0, width: 640, height: 320)
        let redTop = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 160, width: 640, height: 160))
        let blueBottom = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 160))
        let source = redTop.composited(over: blueBottom).cropped(to: extent)
            .transformed(by: CGAffineTransform(translationX: 90, y: -30))
        let frame = try ComputerUseDesktopImage(observation: .init(image: source,
            displayBounds: CGRect(x: -1920, y: 120, width: 1920, height: 960),
            frontmostWindowBounds: CGRect(x: -1500, y: 300, width: 300, height: 200)))
        XCTAssertEqual(frame.pixelWidth, 640); XCTAssertEqual(frame.pixelHeight, 320)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: frame.png))
        let top = try XCTUnwrap(bitmap.colorAt(x: 40, y: 40)?.usingColorSpace(.deviceRGB))
        let bottom = try XCTUnwrap(bitmap.colorAt(x: 40, y: 280)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(top.redComponent, 0.9); XCTAssertLessThan(top.blueComponent, 0.1)
        XCTAssertGreaterThan(bottom.blueComponent, 0.9); XCTAssertLessThan(bottom.redComponent, 0.1)
        for (x, y, expectedX, expectedY) in [(0.0, 0.0, -1920, 120), (250, 250, -1440, 360),
                (500, 500, -960, 600), (1000, 1000, -1, 1079), (12.5, 87.5, -1896, 204)] {
            let point = try frame.displayPoint(normalizedX: x, normalizedY: y)
            XCTAssertEqual(point.x, expectedX); XCTAssertEqual(point.y, expectedY)
        }
        for value in [-0.01, 1000.01, Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try frame.displayPoint(normalizedX: value, normalizedY: 500))
            XCTAssertThrowsError(try frame.displayPoint(normalizedX: 500, normalizedY: value))
        }
    }

    func testDesktopImageBoundsRetinaSizeAndRejectsInvalidGeometry() throws {
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 5000, height: 3000))
        let bounds = CGRect(x: 200, y: -1500, width: 2500, height: 1500)
        let frame = try ComputerUseDesktopImage(observation: .init(image: source, displayBounds: bounds))
        XCTAssertEqual(frame.pixelWidth, 2048); XCTAssertEqual(frame.pixelHeight, 1228)
        XCTAssertLessThanOrEqual(frame.png.count, ComputerUseModelImagePolicy.maximumPNGBytes)
        try ComputerUseFaraModel.validatePNG(frame.png)
        let point = try frame.displayPoint(normalizedX: 1000, normalizedY: 1000)
        XCTAssertEqual(point.x, 2699); XCTAssertEqual(point.y, -1)
        for invalid in [CGRect.zero, .infinite, CGRect(x: 0, y: 0, width: 100, height: 100),
                        CGRect(x: 0.5, y: 0, width: 2500, height: 1500)] {
            XCTAssertThrowsError(try ComputerUseDesktopImage(observation: .init(image: source, displayBounds: invalid)))
        }
        XCTAssertThrowsError(try ComputerUseDesktopImage(observation: .init(image: .empty(), displayBounds: bounds)))
        XCTAssertThrowsError(try ComputerUseDesktopImage(observation: .init(image: CIImage(color: .white), displayBounds: bounds)))
    }

    func testDesktopImageShrinksBusyPixelsToTheEncodedByteBudget() throws {
        let side = 1024
        var bytes = Data(count: side * side * 4)
        bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var random: UInt32 = 0x517CC1B7
            for i in 0..<buffer.count {
                random = random &* 1664525 &+ 1013904223
                buffer[i] = i % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: random >> 24)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let frame = try ComputerUseDesktopImage(observation: .init(image: CIImage(cgImage: image),
            displayBounds: CGRect(x: 0, y: 0, width: side, height: side)))
        XCTAssertLessThan(frame.pixelWidth, side, "The initial random PNG exceeds the byte cap")
        XCTAssertEqual(frame.pixelWidth, frame.pixelHeight)
        XCTAssertLessThanOrEqual(frame.png.count, ComputerUseModelImagePolicy.maximumPNGBytes)
        try ComputerUseFaraModel.validatePNG(frame.png)
    }

}
