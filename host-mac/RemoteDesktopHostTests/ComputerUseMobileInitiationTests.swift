import Foundation
import AppKit
import WebKit
import XCTest
import CryptoKit
#if canImport(FoundationModels) && compiler(>=6.3)
import FoundationModels
#endif
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseMobileInitiationTests: XCTestCase {

    private struct ManagedNativeModelCandidateDescriptor: Decodable {
        let label: String
        let modelPath: String
        let modelSHA256: String
        let modelBytes: Int64
    }

    private struct ManagedNativeModelCandidate {
        let descriptor: ManagedNativeModelCandidateDescriptor
        let inputs: ComputerUseNativeTextRuntimeInputs
    }

    private enum ManagedNativeModelCandidateError: Error {
        case invalidDescriptor
        case invalidModelFile
        case modelHashMismatch
    }

    func testManagedNativeModelCandidateAcceptsPinnedLocalFixtureAndUsesSignedRuntime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedNativeCandidateValid-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("fixture.gguf")
        let payload = Data("small pinned model fixture".utf8)
        try payload.write(to: model)
        let descriptorPath = try writeManagedNativeModelCandidateDescriptor(directory: directory,
            label: "fixture-model", modelPath: model.path, modelSHA256: Self.sha256(payload), modelBytes: payload.count)
        let signedRuntime = directory.appendingPathComponent("signed-runtime/llama-server")
        let candidate = try managedNativeModelCandidate(descriptorPath: descriptorPath, llamaServerURL: signedRuntime)
        XCTAssertEqual(candidate.descriptor.label, "fixture-model")
        XCTAssertEqual(candidate.descriptor.modelPath, model.path)
        XCTAssertEqual(candidate.descriptor.modelSHA256, Self.sha256(payload))
        XCTAssertEqual(candidate.descriptor.modelBytes, Int64(payload.count))
        XCTAssertEqual(candidate.inputs.modelURL, model.standardizedFileURL)
        XCTAssertEqual(candidate.inputs.expectedModelFileName, model.lastPathComponent)
        XCTAssertEqual(candidate.inputs.llamaServerURL, signedRuntime.standardizedFileURL,
            "Candidate selection must retain the installed signed runtime executable")
    }

    func testManagedNativeModelCandidateRejectsByteAndHashMismatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedNativeCandidateMismatch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("fixture.gguf")
        let payload = Data("fixture bytes".utf8)
        try payload.write(to: model)
        let wrongHash = String(repeating: "0", count: 64)
        for (name, hash, bytes) in [("bytes", Self.sha256(payload), payload.count + 1),
                                    ("hash", wrongHash, payload.count)] {
            let descriptorPath = try writeManagedNativeModelCandidateDescriptor(directory: directory,
                label: name, modelPath: model.path, modelSHA256: hash, modelBytes: bytes)
            XCTAssertThrowsError(try managedNativeModelCandidate(descriptorPath: descriptorPath,
                llamaServerURL: directory.appendingPathComponent("llama-server")), name)
        }
    }

    func testManagedNativeModelCandidateRejectsMalformedDescriptors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedNativeCandidateMalformed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("fixture.gguf")
        let payload = Data("fixture bytes".utf8)
        try payload.write(to: model)
        let valid: [String: Any] = ["label": "fixture", "modelPath": model.path,
            "modelSHA256": Self.sha256(payload), "modelBytes": payload.count]
        let cases: [(String, [String: Any])] = [
            ("extra key", valid.merging(["extra": true]) { _, new in new }),
            ("relative model path", ["label": "fixture", "modelPath": "fixture.gguf",
                "modelSHA256": Self.sha256(payload), "modelBytes": payload.count]),
            ("uppercase digest", ["label": "fixture", "modelPath": model.path,
                "modelSHA256": Self.sha256(payload).uppercased(), "modelBytes": payload.count]),
            ("zero byte count", ["label": "fixture", "modelPath": model.path,
                "modelSHA256": Self.sha256(payload), "modelBytes": 0]),
            ("boolean byte count", ["label": "fixture", "modelPath": model.path,
                "modelSHA256": Self.sha256(payload), "modelBytes": true])
        ]
        for (name, object) in cases {
            let descriptorPath = directory.appendingPathComponent("\(name.replacingOccurrences(of: " ", with: "-" )).json")
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: descriptorPath)
            XCTAssertThrowsError(try managedNativeModelCandidate(descriptorPath: descriptorPath.path,
                llamaServerURL: directory.appendingPathComponent("llama-server")), name)
        }
    }

    // Diagnostic compatibility only: makeRequest/decode retain the earlier
    // monolithic wire format for captured exchange replay; production propose
    // uses separate goal interpretation and retained page-decision requests.
    // Diagnostic compatibility only: this exports/replays the previous
    // monolithic makeRequest/decode exchange, not production propose parity.

    private func managedNativeModelCandidate(descriptorPath: String,
                                             llamaServerURL: URL) throws -> ManagedNativeModelCandidate {
        let descriptorFile = try FileHandle(forReadingFrom: URL(fileURLWithPath: descriptorPath))
        let descriptorData: Data
        do {
            guard let boundedData = try descriptorFile.read(upToCount: 4 * 1024 + 1), boundedData.count <= 4 * 1024 else {
                try? descriptorFile.close()
                throw ManagedNativeModelCandidateError.invalidDescriptor
            }
            descriptorData = boundedData
            try descriptorFile.close()
        } catch {
            try? descriptorFile.close()
            throw error
        }
        let expectedKeys = Set(["label", "modelPath", "modelSHA256", "modelBytes"])
        guard let object = try JSONSerialization.jsonObject(with: descriptorData) as? [String: Any],
              Set(object.keys) == expectedKeys else {
            throw ManagedNativeModelCandidateError.invalidDescriptor
        }
        let descriptor = try JSONDecoder().decode(ManagedNativeModelCandidateDescriptor.self, from: descriptorData)
        let digestBytes = Array(descriptor.modelSHA256.utf8)
        guard !descriptor.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (descriptor.modelPath as NSString).isAbsolutePath,
              digestBytes.count == 64,
              digestBytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              descriptor.modelBytes > 0, descriptor.modelBytes <= Int64(Int.max) else {
            throw ManagedNativeModelCandidateError.invalidDescriptor
        }
        let modelURL = URL(fileURLWithPath: descriptor.modelPath).standardizedFileURL
        let values = try modelURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == descriptor.modelBytes else {
            throw ManagedNativeModelCandidateError.invalidModelFile
        }
        let file = try FileHandle(forReadingFrom: modelURL)
        defer { try? file.close() }
        var hasher = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actualHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualHash == descriptor.modelSHA256 else { throw ManagedNativeModelCandidateError.modelHashMismatch }
        return ManagedNativeModelCandidate(descriptor: descriptor,
            inputs: ComputerUseNativeTextRuntimeInputs(modelURL: modelURL, llamaServerURL: llamaServerURL,
                expectedModelFileName: modelURL.lastPathComponent))
    }

    private nonisolated static func safeNativeResponseProjection(_ responseData: Data) -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return ["responseUTF8Bytes": responseData.count]
        }
        var result: [String: Any] = [:]
        if let model = root["model"] { result["model"] = model }
        if let usage = root["usage"] { result["usage"] = usage }
        let choices = root["choices"] as? [[String: Any]] ?? []
        result["choices"] = choices.map { choice -> [String: Any] in
            var projected: [String: Any] = [:]
            if let finishReason = choice["finish_reason"] { projected["finish_reason"] = finishReason }
            if let message = choice["message"] as? [String: Any] {
                var projectedMessage: [String: Any] = [:]
                if let content = message["content"] as? String {
                    let contentData = Data(content.utf8)
                    if let value = try? JSONSerialization.jsonObject(with: contentData),
                       value is [String: Any] || value is [Any] {
                        projectedMessage["content"] = value
                    } else {
                        projectedMessage["contentUTF8Bytes"] = contentData.count
                    }
                }
                if let calls = message["tool_calls"] as? [[String: Any]] {
                    projectedMessage["tool_calls"] = calls.compactMap { call -> [String: Any]? in
                        guard let function = call["function"] as? [String: Any],
                              let name = function["name"] as? String else { return nil }
                        var safeFunction: [String: Any] = ["name": name]
                        if let rawArguments = function["arguments"] as? String {
                            safeFunction["arguments"] = rawArguments
                        } else if let arguments = function["arguments"] {
                            safeFunction["arguments"] = arguments
                        }
                        return ["function": safeFunction]
                    }
                }
                projected["message"] = projectedMessage
            }
            return projected
        }
        return result
    }

    private func writeManagedNativeModelCandidateDescriptor(directory: URL, label: String,
                                                              modelPath: String, modelSHA256: String,
                                                              modelBytes: Int) throws -> String {
        let url = directory.appendingPathComponent("candidate-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: ["label": label, "modelPath": modelPath,
            "modelSHA256": modelSHA256, "modelBytes": modelBytes], options: [.sortedKeys])
        try data.write(to: url, options: .withoutOverwriting)
        return url.path
    }

    private func writeExchangeArtifact(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .withoutOverwriting)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testNativeFileNameFilterFindsLateTargetBeforeMatchingCandidateCap() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        for index in 0..<8 {
            try Data([UInt8(index)]).write(to: directory.appendingPathComponent(String(format: "Unrelated-%02d.xlsx", index)))
        }
        let target = "ZZZ Requested Portfolio.pptx"
        try Data([99]).write(to: directory.appendingPathComponent(target))

        var fullCatalog = try ComputerUseLocalFileCatalog(taskID: "named-filter-task", approvedDirectory: directory, pageSize: 1)
        var fullPage = try fullCatalog.discover()
        var fullNames = fullPage.candidates.map(\.displayName)
        while let cursor = fullPage.nextCursor {
            fullPage = try fullCatalog.nextPage(after: cursor)
            fullNames.append(contentsOf: fullPage.candidates.map(\.displayName))
        }
        let lateTarget = try XCTUnwrap(fullNames.last)
        XCTAssertGreaterThan(fullNames.firstIndex(of: lateTarget) ?? 0, 2,
            "Use a target beyond both the raw first page and the matching candidate cap")

        let query = ComputerUseLocalFileCatalog.Query(nameContains: lateTarget)
        var boundedCatalog = try ComputerUseLocalFileCatalog(taskID: "named-filter-task", approvedDirectory: directory,
            pageSize: 1, maximumCandidates: 2, maximumEntriesScanned: 64)
        let page = try boundedCatalog.discover(query: query)
        XCTAssertEqual(page.candidates.map(\.displayName), [lateTarget])
        XCTAssertTrue(page.isComplete)
        XCTAssertNil(page.nextCursor)
    }

    func testNativeFileNameFilterFoldsCaseAndDiacriticsAndKeepsAmbiguousMatches() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        for name in ["Résumé deck.pptx", "resume copy.xlsx", "Other notes.txt"] {
            try Data([1]).write(to: directory.appendingPathComponent(name))
        }
        let query = ComputerUseLocalFileCatalog.Query(nameContains: "RESUME")
        var catalog = try ComputerUseLocalFileCatalog(taskID: "name-fold-task", approvedDirectory: directory, pageSize: 8)
        let page = try catalog.discover(query: query)
        XCTAssertEqual(Set(page.candidates.map(\.displayName)), Set(["Résumé deck.pptx", "resume copy.xlsx"]))
        XCTAssertEqual(page.candidates.count, 2, "Filtering must preserve multiple matches for explicit ambiguity handling")
    }

    private func syntheticEvidenceReferences(texts: [String], sources: Set<String> = []) -> [String: String] {
        var references = Dictionary(uniqueKeysWithValues: texts.enumerated().map { index, text in
            ("text:t\(index + 1)", text)
        })
        if let source = sources.sorted().first { references["source"] = source }
        return references
    }

    private func assessmentValue(_ requirements: [(String, String, String, String)],
                                 objective: String = "Complete the full user goal", constraints: String = "",
                                 workerObjective: String = "") -> MCPJSONValue {
        .object(["objective": .string(objective), "constraints": .string(constraints),
            "workerObjective": .string(workerObjective),
            "requirements": .array(requirements.map { instruction, kind, state, evidence in
                .object(["instruction": .string(instruction), "kind": .string(kind), "state": .string(state),
                    "evidence": .string(evidence)])
            })])
    }

    private func waitForCapabilityReady(_ manager: HostComputerUseManager, timeoutIterations: Int = 200) async {
        for _ in 0 ..< timeoutIterations {
            if manager.capability.state == .ready { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the structured capability; modelState=\(String(reflecting: manager.modelState)), capability=\(manager.capability.state) (\(manager.capability.detail)), activity=\(String(reflecting: manager.activity)), needsAdditionalSetup=\(manager.needsAdditionalSetup)")
    }

    func testSetupCannotReplaceRunningOrPausedNativeTask() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let nativeInstaller = MobileInitiationModelInstaller(receipt: nativeReceipt)
        let visual = MobileInitiationVisualLoader()
        let channel = MobileInitiationTestChannel()
        var calls = 0
        var release = false
        let native = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in
            calls += 1
            while !release { try await Task.sleep(for: .milliseconds(10)) }
            return .completed("verified")
        })
        let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(), executor: native,
            installer: MobileInitiationModelInstaller(receipt: mobileInitiationModelReceipt()),
            nativeTextInstaller: nativeInstaller,
            macControlInstaller: MobileInitiationMacControlInstaller(status: .notInstalled),
            visualExecutorLoader: visual, taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        defer { release = true; manager.stop() }
        manager.start(pairingCode: "123456")
        manager.authorizePeer(senderID: "IOS-PEER")
        let prompt = nativeTestPrompt(id: "retained-native-task")
        XCTAssertTrue(manager.handle(prompt, channel: channel))
        await waitUntil { calls == 1 }
        XCTAssertTrue(manager.handle(try setupEnvelope(requestID: "setup-while-running"), channel: channel))
        let runningFailure = await waitForSetupProgress(channel: channel)
        XCTAssertTrue(runningFailure.contains { $0.requestID == "setup-while-running" && $0.phase == .failed })
        guard case .working = manager.activity else { return XCTFail("Setup cannot stop the active task") }

        manager.userIntervened()
        await waitUntil { manager.activity == .paused }
        XCTAssertTrue(manager.handle(try setupEnvelope(requestID: "setup-while-paused"), channel: channel))
        for _ in 0..<200 {
            if await channel.setupProgress().contains(where: { $0.requestID == "setup-while-paused" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let failures = await channel.setupProgress()
        XCTAssertEqual(failures.filter { $0.phase == .failed }.count, 2)
        XCTAssertEqual(manager.activity, .paused)
        let installs = await nativeInstaller.installCallCount()
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(visual.loadCount, 0)
        XCTAssertEqual(calls, 1)
        release = true
        let resume = ComputerUseEnvelope(senderID: "IOS-PEER", targetID: "HOST-ID", pairingCode: "123456",
            sessionID: "SESSION-1", kind: .resume,
            body: try ComputerUseControlRequest(taskID: prompt.id, revision: 1, observedHostControlEpoch: 1).encodedBody())
        XCTAssertTrue(manager.handle(resume, channel: channel))
        let completed = await waitForTaskUpdate(channel: channel, taskID: prompt.id, outcome: .taskCompleted)
        XCTAssertEqual(completed?.text, "verified")
        XCTAssertEqual(calls, 2, "Resume must still reach the same retained coordinator")
        await manager.shutdown()
    }

    func testNewPromptDuringAdditionalSetupIsTerminalWithoutExecutionOrLaterReplay() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let nativeInstaller = MobileInitiationModelInstaller(receipt: nativeReceipt)
        let channel = MobileInitiationTestChannel()
        var calls = 0
        var loadStarted = false
        var releaseLoad = false
        let native = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in
            calls += 1; return .completed("verified")
        })
        let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(), executor: native,
            installer: MobileInitiationModelInstaller(receipt: mobileInitiationModelReceipt()),
            nativeTextInstaller: nativeInstaller, nativeTextLoader: { _, _, _ in
                loadStarted = true
                while !releaseLoad { try await Task.sleep(for: .milliseconds(10)) }
                return native
            }, macControlInstaller: MobileInitiationMacControlInstaller(status: .notInstalled),
            visualExecutorLoader: MobileInitiationVisualLoader(throwsLoadFailure: true),
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger), channelFactory: { _ in channel })
        defer { releaseLoad = true; manager.stop() }
        manager.start(pairingCode: "123456")
        manager.authorizePeer(senderID: "IOS-PEER")
        XCTAssertTrue(manager.handle(try setupEnvelope(requestID: "upgrade"), channel: channel))
        await waitUntil { loadStarted }
        XCTAssertEqual(manager.capability.state, .installing,
                       "Discovery must reflect that setup currently owns the executor")
        let blocked = nativeTestPrompt(id: "prompt-during-upgrade")
        XCTAssertTrue(manager.handle(blocked, channel: channel))
        let rejected = await waitForTaskUpdate(channel: channel, taskID: blocked.id, outcome: .userInterventionRequired)
        XCTAssertTrue(rejected?.text.contains("setup is still running") == true)
        XCTAssertEqual(calls, 0)
        releaseLoad = true
        _ = await waitForSetupProgress(channel: channel)
        XCTAssertEqual(manager.capability.state, .ready)
        XCTAssertTrue(manager.handle(blocked, channel: channel))
        XCTAssertEqual(calls, 0, "Completing setup cannot auto-run a previously rejected task ID")
        let fresh = nativeTestPrompt(id: "new-prompt-after-upgrade")
        XCTAssertTrue(manager.handle(fresh, channel: channel))
        _ = await waitForTaskUpdate(channel: channel, taskID: fresh.id, outcome: .taskCompleted)
        XCTAssertEqual(calls, 1)
        await manager.shutdown()
    }

    private func nativeTestPrompt(id: String) -> ComputerUseEnvelope {
        ComputerUseEnvelope(id: id, senderID: "IOS-PEER", targetID: "HOST-ID", pairingCode: "123456",
            sessionID: "SESSION-1", kind: .prompt, body: "Set Origin to Oslo.")
    }

    private func waitForTaskUpdate(channel: MobileInitiationTestChannel, taskID: String,
                                   outcome: ComputerUseTerminalOutcome) async -> ComputerUseTaskUpdate? {
        for _ in 0..<200 {
            if let update = await channel.taskUpdates().first(where: { $0.taskID == taskID && $0.outcome == outcome }) {
                return update
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the exact task outcome")
        return nil
    }

    func testInstalledNativeFormsActivateWithoutHelperVisualModelOrDownloads() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let nativeInstaller = MobileInitiationModelInstaller(receipt: nativeReceipt, alreadyInstalled: true)
        let visualInstaller = MobileInitiationModelInstaller(receipt: mobileInitiationModelReceipt())
        let helper = MobileInitiationMacControlInstaller(status: .notInstalled)
        let visual = MobileInitiationVisualLoader()
        var nativeLoads = 0
        let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(), installer: visualInstaller,
            nativeTextInstaller: nativeInstaller, nativeTextLoader: { receipt, _, _ in
                XCTAssertEqual(receipt.modelVariant, .nativeText4B)
                nativeLoads += 1
                return ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in .completed("verified") })
            }, macControlInstaller: helper, visualExecutorLoader: visual,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in MobileInitiationTestChannel() })
        await waitUntil { manager.capability.state == .ready }
        XCTAssertEqual(nativeLoads, 1)
        XCTAssertTrue(manager.needsAdditionalSetup)
        XCTAssertTrue(manager.capability.detail.contains("Form editing"))
        XCTAssertEqual(visual.loadCount, 0)
        let nativeInstalls = await nativeInstaller.installCallCount()
        let visualInstalls = await visualInstaller.installCallCount()
        let helperInstalls = await helper.installCallCount()
        XCTAssertEqual(nativeInstalls + visualInstalls + helperInstalls, 0)
        await manager.shutdown()
    }

    func testInstalledNativeAndDesktopPackagesComposeWithoutEagerVisualLoad() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let helper = MobileInitiationMacControlInstaller(status: .ready(mobileInitiationMacControlReceipt))
        let visual = MobileInitiationVisualLoader()
        var coordinator: ComputerUseCapabilityExecutor?
        let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(),
            installer: MobileInitiationModelInstaller(receipt: mobileInitiationModelReceipt(), alreadyInstalled: true),
            nativeTextInstaller: MobileInitiationModelInstaller(receipt: nativeReceipt, alreadyInstalled: true),
            nativeTextLoader: { _, _, _ in
                let result = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil })
                coordinator = result
                return result
            }, macControlInstaller: helper, visualExecutorLoader: visual,
            executorComposer: { _, fallback in fallback }, taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in MobileInitiationTestChannel() })
        await waitUntil { manager.capability.state == .ready }
        XCTAssertEqual(visual.loadCount, 0)
        XCTAssertFalse(manager.needsAdditionalSetup)
        let executor = try XCTUnwrap(coordinator)
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { false })
        _ = try await executor.execute(taskID: "desktop", prompt: "Open an app.",
            trustedUserPrompt: "Open an app.", tools: tools, progress: { _ in })
        XCTAssertEqual(visual.loadCount, 1)
        await manager.shutdown()
    }

    func testPassiveNativePreparationDoesNotLoadRuntimeOrCommitActivationButExplicitSetupDoes() async throws {
        for helperInstalled in [false, true] {
            let fixture = try makeFixture(markerPresent: false)
            defer { try? FileManager.default.removeItem(at: fixture.parent) }
            let native = MobileInitiationModelInstaller(receipt: nativeReceipt, alreadyInstalled: true)
            let visual = MobileInitiationVisualLoader()
            let channel = MobileInitiationTestChannel()
            var preparations = 0, runtimeLoads = 0, nativeExecutions = 0
            let makeNative = {
                ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nativeExecutions += 1; return nil })
            }
            let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(),
                installer: MobileInitiationModelInstaller(receipt: mobileInitiationModelReceipt()),
                nativeTextInstaller: native, nativeTextLoader: { _, _, _ in runtimeLoads += 1; return makeNative() },
                nativeTextPreparer: { _, _, _ in preparations += 1; return makeNative() },
                macControlInstaller: MobileInitiationMacControlInstaller(status: helperInstalled ? .ready(mobileInitiationMacControlReceipt) : .notInstalled),
                visualExecutorLoader: visual, executorComposer: { _, fallback in fallback }, taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger), channelFactory: { _ in channel })
            manager.start(pairingCode: "123456")
            await waitForCapabilityReady(manager)
            XCTAssertEqual(preparations, 1)
            XCTAssertEqual(runtimeLoads, 0, "Passive startup only prepares a capability")
            let passiveActivations = await native.recordedSuccessfulActivations()
            XCTAssertTrue(passiveActivations.isEmpty, "Preparation cannot certify that a model loaded")
            XCTAssertEqual(visual.loadCount, 0)
            XCTAssertTrue(manager.handle(try setupEnvelope(requestID: "verify-model-runtime"), channel: channel))
            let progress = await waitForSetupProgress(channel: channel, terminalPhase: .ready)
            XCTAssertTrue(progress.contains { $0.phase == .ready })
            XCTAssertEqual(runtimeLoads, 1, "Explicit setup must still validate the installed native runtime")
            let setupActivations = await native.recordedSuccessfulActivations()
            XCTAssertEqual(setupActivations, [nativeReceipt])
            XCTAssertEqual(nativeExecutions, 0)
            await manager.shutdown()
        }
    }

    func testNativePreparationFailureDoesNotActivateOrDownloadWithoutNativeExecutor() async throws {
        for requestDuringPreparation in [false, true] {
            let fixture = try makeFixture(markerPresent: false)
            defer { try? FileManager.default.removeItem(at: fixture.parent) }
            let native = MobileInitiationModelInstaller(receipt: nativeReceipt, alreadyInstalled: true)
            let visual = MobileInitiationVisualLoader()
            let channel = MobileInitiationTestChannel()
            let helper = MobileInitiationMacControlInstaller(status: .ready(mobileInitiationMacControlReceipt))
            var preparations = 0, runtimeLoads = 0
            var releasePreparation = false
            let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(),
                installer: MobileInitiationModelInstaller(receipt: mobileInitiationModelReceipt()),
                nativeTextInstaller: native, nativeTextLoader: { _, _, _ in
                    runtimeLoads += 1
                    return ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in XCTFail("Invalid native capability executed"); return nil })
                }, nativeTextPreparer: { _, _, _ in
                    preparations += 1
                    while !releasePreparation { try await Task.sleep(for: .milliseconds(10)) }
                    throw CocoaError(.fileReadCorruptFile)
                },
                macControlInstaller: helper,
                visualExecutorLoader: visual, executorComposer: { _, fallback in fallback }, taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger), channelFactory: { _ in channel })
            defer { releasePreparation = true; manager.stop() }
            manager.start(pairingCode: "123456")
            await waitUntil { preparations == 1 }
            if requestDuringPreparation {
                XCTAssertTrue(manager.handle(try setupEnvelope(requestID: "native-preparation-failed"), channel: channel))
            }
            releasePreparation = true
            await waitUntil {
                if case .ready = manager.modelState { return true }
                return false
            }
            if requestDuringPreparation {
                let progress = await waitForSetupProgress(channel: channel)
                XCTAssertTrue(progress.contains { $0.phase == .failed })
                XCTAssertFalse(progress.contains { $0.phase == .ready })
            }
            let installCount = await native.installCallCount()
            XCTAssertEqual(installCount, 0, "A failed passive preparation cannot start a download loop")
            let helperInstallCount = await helper.installCallCount()
            XCTAssertEqual(helperInstallCount, 0, "An already-installed helper must not be reinstalled")
            XCTAssertEqual(preparations, 1); XCTAssertEqual(runtimeLoads, 0)
            XCTAssertEqual(manager.capability.state, .setupRequired,
                "The installed helper alone cannot supply an active executor")
            XCTAssertTrue(manager.needsAdditionalSetup)
            let activations = await native.recordedSuccessfulActivations()
            XCTAssertTrue(activations.isEmpty); XCTAssertEqual(visual.loadCount, 0)
            await manager.shutdown()
        }
    }

    func testVisualSetupFailureKeepsNewlyInstalledNativeCapabilityAvailable() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let visual = MobileInitiationVisualLoader(throwsLoadFailure: true)
        let channel = MobileInitiationTestChannel()
        let helper = MobileInitiationMacControlInstaller(status: .notInstalled)
        let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(),
            installer: MobileInitiationModelInstaller(receipt: mobileInitiationModelReceipt()),
            nativeTextInstaller: MobileInitiationModelInstaller(receipt: nativeReceipt), nativeTextLoader: { _, _, _ in
                ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in nil })
            }, macControlInstaller: helper, visualExecutorLoader: visual, executorComposer: { _, fallback in fallback }, taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger), channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        await waitForStatusCheck(helper)
        XCTAssertTrue(manager.handle(try setupEnvelope(requestID: "visual-load-fails"), channel: channel))
        let progress = await waitForSetupProgress(channel: channel)
        XCTAssertFalse(progress.contains { $0.phase == .ready })
        XCTAssertTrue(manager.needsAdditionalSetup)
        XCTAssertEqual(manager.capability.state, .ready)
        XCTAssertTrue(manager.capability.detail.contains("Form editing and Mac tools"))
        XCTAssertEqual(visual.loadCount, 1, "Retained native capability cannot retry the failed visual activation")
        await manager.shutdown()
    }

    func testFailedPassiveActivationTerminatesPendingFullSetupRequest() async throws {
        for nativeInstalled in [false, true] {
            let fixture = try makeFixture(markerPresent: false)
            defer { try? FileManager.default.removeItem(at: fixture.parent) }
            let native = MobileInitiationModelInstaller(receipt: nativeReceipt, alreadyInstalled: nativeInstalled)
            let channel = MobileInitiationTestChannel()
            var loadStarted = false
            var releaseLoad = false
            let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(),
                installer: MobileInitiationModelInstaller(receipt: mobileInitiationModelReceipt()),
                nativeTextInstaller: native, nativeTextLoader: { _, _, _ in
                    loadStarted = true
                    while !releaseLoad { try await Task.sleep(for: .milliseconds(10)) }
                    throw CocoaError(.fileReadCorruptFile)
                }, macControlInstaller: MobileInitiationMacControlInstaller(status: .ready(mobileInitiationMacControlReceipt)),
                visualExecutorLoader: MobileInitiationVisualLoader(), executorComposer: { _, _ in
                    loadStarted = true
                    while !releaseLoad { try await Task.sleep(for: .milliseconds(10)) }
                    throw CocoaError(.fileReadCorruptFile)
                }, taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger), channelFactory: { _ in channel })
            defer { releaseLoad = true; manager.stop() }
            manager.start(pairingCode: "123456")
            await waitUntil { loadStarted }
            XCTAssertTrue(manager.handle(try setupEnvelope(requestID: "request-during-activation"), channel: channel))
            releaseLoad = true
            let progress = await waitForSetupProgress(channel: channel)
            XCTAssertTrue(progress.contains { $0.requestID == "request-during-activation" && $0.phase == .failed })
            XCTAssertFalse(progress.contains { $0.phase == .ready })
            XCTAssertEqual(manager.capability.state, .setupRequired)
            let installs = await native.installCallCount()
            XCTAssertEqual(installs, 0, "Failed passive activation cannot loop into unattended downloads")
            await manager.shutdown()
        }
    }

    func testInstalledNativeCapabilityResumesOnlyPreviouslyStartedDesktopSetup() async throws {
        let cases: [(MacControlMCPInstaller.DurableStatus, Bool, Bool)] = [
            (.ready(mobileInitiationMacControlReceipt), true, true),
            (.downloadPresent(downloadedByteCount: 100, totalByteCount: 1_000), false, true),
            (.downloadPresent(downloadedByteCount: 0, totalByteCount: 1_000), false, false),
            (.notInstalled, true, false),
            (.ready(mobileInitiationMacControlReceipt), false, false),
        ]
        for (helperStatus, interruptedVisual, shouldResume) in cases {
            let fixture = try makeFixture(markerPresent: false)
            defer { try? FileManager.default.removeItem(at: fixture.parent) }
            let nativeInstaller = MobileInitiationModelInstaller(receipt: nativeReceipt, alreadyInstalled: true)
            let visualInstaller = MobileInitiationModelInstaller(receipt: mobileInitiationModelReceipt(),
                interrupted: interruptedVisual)
            let visual = MobileInitiationVisualLoader(throwsLoadFailure: true)
            var nativeLoads = 0
            let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(), installer: visualInstaller,
                nativeTextInstaller: nativeInstaller, nativeTextLoader: { _, _, _ in
                    nativeLoads += 1
                    return ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in .completed("verified") })
                }, macControlInstaller: MobileInitiationMacControlInstaller(status: helperStatus),
                visualExecutorLoader: visual, executorComposer: { _, fallback in fallback },
                taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
                channelFactory: { _ in MobileInitiationTestChannel() })
            if shouldResume { await waitUntil { visual.loadCount == 1 } }
            await waitUntil { manager.capability.state == .ready }
            let installs = await nativeInstaller.installCallCount()
            XCTAssertEqual(installs, shouldResume ? 1 : 0)
            XCTAssertEqual(nativeLoads, shouldResume ? 2 : 1)
            XCTAssertEqual(visual.loadCount, shouldResume ? 1 : 0)
            XCTAssertTrue(manager.needsAdditionalSetup)
            await manager.shutdown()
        }
    }

    func testPartialNativeActivationNeverCompletesExplicitFullSetup() async throws {
        for requestDuringActivation in [false, true] {
            let fixture = try makeFixture(markerPresent: false)
            defer { try? FileManager.default.removeItem(at: fixture.parent) }
            let nativeInstaller = MobileInitiationModelInstaller(receipt: nativeReceipt, alreadyInstalled: true)
            let channel = MobileInitiationTestChannel()
            var loadCount = 0
            var releaseInitialLoad = false
            let visual = MobileInitiationVisualLoader(throwsLoadFailure: true)
            let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(),
                installer: MobileInitiationModelInstaller(receipt: mobileInitiationModelReceipt()),
                nativeTextInstaller: nativeInstaller, nativeTextLoader: { _, _, _ in
                    loadCount += 1
                    while !releaseInitialLoad { try await Task.sleep(for: .milliseconds(10)) }
                    return ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in .completed("verified") })
                }, macControlInstaller: MobileInitiationMacControlInstaller(status: .notInstalled),
                visualExecutorLoader: visual, executorComposer: { _, fallback in fallback },
                taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
                channelFactory: { _ in channel })
            defer { releaseInitialLoad = true; manager.stop() }
            manager.start(pairingCode: "123456")
            await waitUntil { loadCount == 1 }
            if !requestDuringActivation {
                releaseInitialLoad = true
                await waitUntil { manager.capability.state == .ready }
            }
            XCTAssertTrue(manager.handle(try setupEnvelope(requestID: "finish-all-setup"), channel: channel))
            releaseInitialLoad = true
            let progress = await waitForSetupProgress(channel: channel)
            XCTAssertFalse(progress.contains { $0.phase == .ready },
                           "A partial native capability must never send terminal full-setup success")
            XCTAssertTrue(progress.contains { $0.phase == .failed })
            let installs = await nativeInstaller.installCallCount()
            XCTAssertEqual(installs, 1, "The explicit request must actually enter full setup")
            XCTAssertEqual(visual.loadCount, 1)
            XCTAssertEqual(loadCount, 2)
            XCTAssertEqual(manager.capability.state, .ready)
            XCTAssertTrue(manager.needsAdditionalSetup)
            await manager.shutdown()
        }
    }

    func testDesktopSetupFailurePreservesVerifiedNativeCapability() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let nativeInstaller = MobileInitiationModelInstaller(receipt: nativeReceipt)
        let helper = MobileInitiationMacControlInstaller(status: .notInstalled)
        let channel = MobileInitiationTestChannel()
        let visual = MobileInitiationVisualLoader(throwsLoadFailure: true)
        let manager = HostComputerUseManager(experimentalEnabled: { true }, injector: InputInjector(),
            installer: MobileInitiationModelInstaller(receipt: mobileInitiationModelReceipt()),
            nativeTextInstaller: nativeInstaller, nativeTextLoader: { _, _, _ in
                ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in .completed("verified") })
            }, macControlInstaller: helper, visualExecutorLoader: visual,
            executorComposer: { _, fallback in fallback },
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger), channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        await waitForStatusCheck(helper)
        XCTAssertTrue(manager.handle(try setupEnvelope(requestID: "native-partial"), channel: channel))
        let progress = await waitForSetupProgress(channel: channel, terminalPhase: .failed)
        XCTAssertTrue(progress.contains { $0.phase == .failed })
        XCTAssertEqual(visual.loadCount, 1, "This fixture must reach the intended visual activation failure")
        XCTAssertEqual(manager.capability.state, .ready)
        XCTAssertTrue(manager.needsAdditionalSetup)
        let nativeInstalls = await nativeInstaller.installCallCount()
        XCTAssertEqual(nativeInstalls, 1)
        let activations = await nativeInstaller.recordedSuccessfulActivations()
        XCTAssertEqual(activations, [nativeReceipt])
        let fractions = progress.compactMap(\.fractionCompleted)
        for (earlier, later) in zip(fractions, fractions.dropFirst()) { XCTAssertLessThanOrEqual(earlier, later) }
        await manager.shutdown()
    }

    private var nativeReceipt: ComputerUseInstallationReceipt {
        ComputerUseInstallationReceipt(installationVersion: ComputerUseArtifactManifest.nativeTextV2.installationVersion,
            modelVariant: .nativeText4B, modelDirectory: "/test/native-text", installedAt: Date(timeIntervalSince1970: 0))
    }

    func testMobileRequestInstallsModelActivatesOSAtlasAndPublishesContinuousProgress() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let receipt = mobileInitiationModelReceipt()
        let modelInstaller = MobileInitiationModelInstaller(receipt: receipt)
        let visualLoader = MobileInitiationVisualLoader()
        let macControlInstaller = MobileInitiationMacControlInstaller(
            status: .notInstalled)
        let channel = MobileInitiationTestChannel(delayedFraction: 0.99)
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: modelInstaller,
            macControlInstaller: macControlInstaller,
            visualExecutorLoader: visualLoader,
            executorComposer: { _, visualFallback in visualFallback },
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        defer { manager.stop() }

        await waitForStatusCheck(macControlInstaller)
        let installsBeforeRequest = await modelInstaller.installCallCount()
        XCTAssertEqual(installsBeforeRequest, 0)
        XCTAssertEqual(visualLoader.loadCount, 0)

        XCTAssertTrue(manager.handle(
            try setupEnvelope(requestID: "mobile-e2e"),
            channel: channel))
        await waitUntil {
            if case .ready = manager.modelState { return true }
            return false
        }

        let helperInstallCount = await macControlInstaller.installCallCount()
        let modelInstallCount = await modelInstaller.installCallCount()
        XCTAssertEqual(helperInstallCount, 1)
        XCTAssertEqual(modelInstallCount, 1)
        XCTAssertEqual(visualLoader.loadedReceipts, [receipt])
        XCTAssertEqual(visualLoader.maximumConcurrentLoads, 1)
        XCTAssertEqual(manager.modelState, .ready(runtimeName: "OS-Atlas Pro test runtime"))
        XCTAssertEqual(manager.capability.state, .ready)
        let successfulActivations = await modelInstaller
            .recordedSuccessfulActivations()
        let failedActivations = await modelInstaller.recordedFailedActivations()
        XCTAssertEqual(successfulActivations, [receipt])
        XCTAssertTrue(failedActivations.isEmpty)

        let progress = await waitForSetupProgress(
            channel: channel,
            terminalPhase: .ready)
        XCTAssertTrue(progress.contains {
            $0.phase == .downloadingModel
                && $0.detail.contains("2 GB of 4 GB")
        })
        XCTAssertTrue(progress.contains {
            $0.phase == .installingPackages
                && $0.fractionCompleted == 0.99
                && $0.detail.contains("OS-Atlas Pro")
        })
        let fractions = progress.compactMap(\.fractionCompleted)
        XCTAssertEqual(fractions.last, 1)
        for (earlier, later) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later)
        }

        // A second phone request replays readiness; it must not install or
        // activate another model process.
        XCTAssertTrue(manager.handle(
            try setupEnvelope(requestID: "mobile-e2e-retry"),
            channel: channel))
        await Task.yield()
        let modelInstallCountAfterRetry = await modelInstaller.installCallCount()
        XCTAssertEqual(modelInstallCountAfterRetry, 1)
        XCTAssertEqual(visualLoader.loadCount, 1)
        XCTAssertEqual(visualLoader.maximumConcurrentLoads, 1)
    }

    func testRelaunchedMobileMonitorPrunesOnlyItsSupersededCloudKitSession() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let channel = MobileInitiationTestChannel()
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: MobileInitiationModelInstaller(
                receipt: mobileInitiationModelReceipt()),
            macControlInstaller: MobileInitiationMacControlInstaller(
                status: .notInstalled),
            visualExecutorLoader: MobileInitiationVisualLoader(),
            executorComposer: { _, visualFallback in visualFallback },
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        defer { manager.stop() }

        // These arrive synchronously before the installer task gets its first
        // turn. The second request is a relaunch of IOS-PEER; IOS-PEER-2 is a
        // distinct device that must continue receiving the same setup.
        XCTAssertTrue(manager.handle(
            try setupEnvelope(
                requestID: "old-monitor",
                senderID: "IOS-PEER",
                sessionID: "SESSION-OLD"),
            channel: channel))
        XCTAssertTrue(manager.handle(
            try setupEnvelope(
                requestID: "new-monitor",
                senderID: "IOS-PEER",
                sessionID: "SESSION-NEW"),
            channel: channel))
        XCTAssertTrue(manager.handle(
            try setupEnvelope(
                requestID: "other-device",
                senderID: "IOS-PEER-2",
                sessionID: "SESSION-OTHER"),
            channel: channel))

        await waitUntil {
            if case .ready = manager.modelState { return true }
            return false
        }
        let readyEnvelopes = await channel.setupProgressEnvelopes(phase: .ready)
        XCTAssertEqual(
            Set(readyEnvelopes.map(\.sessionID)),
            Set(["SESSION-NEW", "SESSION-OTHER"]))
        XCTAssertFalse(readyEnvelopes.contains { $0.sessionID == "SESSION-OLD" })
        let readyProgress = readyEnvelopes.compactMap {
            try? ComputerUseSetupProgress.decodeBody($0.body)
        }
        XCTAssertEqual(
            Set(readyProgress.map(\.requestID)),
            Set(["new-monitor", "other-device"]))
    }

    func testCancelledOSAtlasActivationFailsClosedAndDeactivatesRuntime() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let modelInstaller = MobileInitiationModelInstaller(
            receipt: mobileInitiationModelReceipt())
        let visualLoader = MobileInitiationVisualLoader(throwsCancellation: true)
        let composerRecorder = MobileInitiationComposerRecorder()
        let channel = MobileInitiationTestChannel()
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: modelInstaller,
            macControlInstaller: MobileInitiationMacControlInstaller(
                status: .notInstalled),
            visualExecutorLoader: visualLoader,
            executorComposer: { _, visualFallback in
                await composerRecorder.recordCall()
                return visualFallback
            },
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        defer { manager.stop() }

        XCTAssertTrue(manager.handle(
            try setupEnvelope(requestID: "cancelled-activation"),
            channel: channel))
        let progress = await waitForSetupProgress(
            channel: channel,
            terminalPhase: .failed)

        XCTAssertEqual(manager.modelState, .downloadRequired)
        XCTAssertEqual(manager.capability.state, .setupRequired)
        XCTAssertEqual(visualLoader.loadCount, 1)
        XCTAssertEqual(visualLoader.deactivationCount, 1)
        let composerCalls = await composerRecorder.callCount()
        XCTAssertEqual(composerCalls, 0)
        XCTAssertEqual(progress.last?.phase, .failed)
        XCTAssertTrue(progress.last?.detail.contains("stopped") == true)
        let successfulActivations = await modelInstaller
            .recordedSuccessfulActivations()
        let failedActivations = await modelInstaller.recordedFailedActivations()
        XCTAssertTrue(successfulActivations.isEmpty)
        XCTAssertEqual(failedActivations, [mobileInitiationModelReceipt()])
    }

    func testFailedFirstModelLoadRequestsVerifiedInstallationRollback() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let receipt = mobileInitiationModelReceipt()
        let modelInstaller = MobileInitiationModelInstaller(receipt: receipt)
        let visualLoader = MobileInitiationVisualLoader(throwsLoadFailure: true)
        let channel = MobileInitiationTestChannel()
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: modelInstaller,
            macControlInstaller: MobileInitiationMacControlInstaller(
                status: .notInstalled),
            visualExecutorLoader: visualLoader,
            executorComposer: { _, visualFallback in visualFallback },
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        defer { manager.stop() }

        XCTAssertTrue(manager.handle(
            try setupEnvelope(requestID: "failed-first-load"),
            channel: channel))
        _ = await waitForSetupProgress(
            channel: channel,
            terminalPhase: .failed)

        XCTAssertEqual(visualLoader.loadCount, 1)
        XCTAssertEqual(visualLoader.deactivationCount, 1)
        let failedActivations = await modelInstaller.recordedFailedActivations()
        let successfulActivations = await modelInstaller
            .recordedSuccessfulActivations()
        XCTAssertEqual(failedActivations, [receipt])
        XCTAssertTrue(successfulActivations.isEmpty)
        guard case .error = manager.modelState else {
            return XCTFail("A failed first model load must stay fail-closed")
        }
    }

    func testFailedExecutorCompositionRequestsVerifiedInstallationRollback()
        async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let receipt = mobileInitiationModelReceipt()
        let modelInstaller = MobileInitiationModelInstaller(receipt: receipt)
        let visualLoader = MobileInitiationVisualLoader()
        let channel = MobileInitiationTestChannel()
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: modelInstaller,
            macControlInstaller: MobileInitiationMacControlInstaller(
                status: .notInstalled),
            visualExecutorLoader: visualLoader,
            executorComposer: { _, _ in
                throw CocoaError(.fileReadCorruptFile)
            },
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        defer { manager.stop() }

        XCTAssertTrue(manager.handle(
            try setupEnvelope(requestID: "failed-composition"),
            channel: channel))
        _ = await waitForSetupProgress(
            channel: channel,
            terminalPhase: .failed)

        XCTAssertEqual(visualLoader.loadCount, 1)
        XCTAssertEqual(visualLoader.deactivationCount, 1)
        let failedActivations = await modelInstaller.recordedFailedActivations()
        let successfulActivations = await modelInstaller
            .recordedSuccessfulActivations()
        XCTAssertEqual(failedActivations, [receipt])
        XCTAssertTrue(successfulActivations.isEmpty)
        guard case .error = manager.modelState else {
            return XCTFail("A failed composition must stay fail-closed")
        }
    }

    func testFreshHostWaitsForMobileSetupRequestBeforeStartingInstaller() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let installer = ComputerUseInstaller(
            manifest: preflightFailureManifest,
            rootDirectory: fixture.root)
        let macControlInstaller = MobileInitiationMacControlInstaller(
            status: .notInstalled)
        let channel = MobileInitiationTestChannel()
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: installer,
            macControlInstaller: macControlInstaller,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })
        manager.start(pairingCode: "123456")
        defer { manager.stop() }

        await waitForStatusCheck(macControlInstaller)

        XCTAssertEqual(manager.modelState, .downloadRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        let installCallsBeforeRequest = await macControlInstaller.installCallCount()
        XCTAssertEqual(installCallsBeforeRequest, 0)

        let request = ComputerUseSetupRequest(requestID: "mobile-request")
        let envelope = ComputerUseEnvelope(
            senderID: "IOS-PEER",
            targetID: "HOST-ID",
            pairingCode: "123456",
            sessionID: "SESSION-1",
            kind: .setupRequest,
            body: try request.encodedBody())

        XCTAssertTrue(manager.handle(envelope, channel: channel))
        guard case .installing(let detail, _) = manager.modelState else {
            return XCTFail("A valid mobile setup request must start the installer pipeline")
        }
        XCTAssertEqual(detail, "Checking this Mac…")

        await waitUntil {
            if case .error = manager.modelState { return true }
            return false
        }
        guard case .error(let message) = manager.modelState else {
            return XCTFail("The controlled preflight failure did not arrive")
        }
        XCTAssertTrue(message.contains("at least"), message)
        let installCallsAfterRequest = await macControlInstaller.installCallCount()
        XCTAssertEqual(installCallsAfterRequest, 1)

        let progress = await waitForSetupProgress(channel: channel)
        let helperProgress = progress.filter {
            $0.phase == .installingPackages
                && $0.detail.contains("Downloading Mac control")
        }
        XCTAssertFalse(helperProgress.isEmpty)
        XCTAssertTrue(helperProgress.contains {
            $0.detail.contains("250 bytes of 1,000 bytes")
        })
        let fractions = progress.compactMap(\.fractionCompleted)
        for (earlier, later) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later)
        }
    }

    func testInterruptedMobileAuthorizedInstallResumesOnHostRelaunch() async throws {
        let fixture = try makeFixture(markerPresent: true)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let installer = ComputerUseInstaller(
            manifest: preflightFailureManifest,
            rootDirectory: fixture.root)
        let macControlInstaller = MobileInitiationMacControlInstaller(
            status: .ready(mobileInitiationMacControlReceipt))
        let channel = MobileInitiationTestChannel()
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: installer,
            macControlInstaller: macControlInstaller,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in channel })

        await waitUntil {
            if case .error = manager.modelState { return true }
            return false
        }

        guard case .error(let message) = manager.modelState else {
            return XCTFail("The interrupted mobile-authorized install did not resume")
        }
        XCTAssertTrue(message.contains("at least"), message)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.marker.path),
            "A controlled failure must clear the resume marker")
        let resumedModelInstallCalls = await macControlInstaller.installCallCount()
        XCTAssertEqual(resumedModelInstallCalls, 1)
    }

    func testDurablePartialHelperDownloadResumesWithoutAnotherTap() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let installer = ComputerUseInstaller(
            manifest: preflightFailureManifest,
            rootDirectory: fixture.root)
        let macControlInstaller = MobileInitiationMacControlInstaller(
            status: .downloadPresent(
                downloadedByteCount: 250,
                totalByteCount: 1_000))
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: installer,
            macControlInstaller: macControlInstaller,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in MobileInitiationTestChannel() })

        await waitUntil {
            if case .error = manager.modelState { return true }
            return false
        }

        let resumedHelperInstallCalls = await macControlInstaller.installCallCount()
        XCTAssertEqual(resumedHelperInstallCalls, 1)
        guard case .error(let message) = manager.modelState else {
            return XCTFail("The resumed helper did not continue into model preflight")
        }
        XCTAssertTrue(message.contains("at least"), message)
    }

    func testLoadedModelIsNotAdvertisedReadyWithoutHelperReceipt() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let macControlInstaller = MobileInitiationMacControlInstaller(
            status: .notInstalled)
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            executor: MobileInitiationReadyExecutor(),
            installer: ComputerUseInstaller(
                manifest: preflightFailureManifest,
                rootDirectory: fixture.root),
            macControlInstaller: macControlInstaller,
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in MobileInitiationTestChannel() })

        await waitForStatusCheck(macControlInstaller)

        XCTAssertEqual(manager.modelState, .downloadRequired)
        XCTAssertEqual(manager.capability.state, .setupRequired)
        let installCalls = await macControlInstaller.installCallCount()
        XCTAssertEqual(installCalls, 0)
    }

    func testApplicationShutdownDeactivatesVisualRuntimeBeforeReturning() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let visualLoader = MobileInitiationVisualLoader()
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: MobileInitiationModelInstaller(
                receipt: mobileInitiationModelReceipt()),
            macControlInstaller: MobileInitiationMacControlInstaller(
                status: .notInstalled),
            visualExecutorLoader: visualLoader,
            executorComposer: { _, visualFallback in visualFallback },
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            channelFactory: { _ in MobileInitiationTestChannel() })

        await manager.shutdown()

        XCTAssertEqual(visualLoader.deactivationCount, 1)
        XCTAssertEqual(manager.activity, .idle)
    }

    func testExternalServiceGuardSuppressesAllAutomaticTestHostWork() async throws {
        let fixture = try makeFixture(markerPresent: false)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        let modelInstaller = MobileInitiationModelInstaller(
            receipt: mobileInitiationModelReceipt())
        let macControlInstaller = MobileInitiationMacControlInstaller(
            status: .ready(mobileInitiationMacControlReceipt))
        let visualLoader = MobileInitiationVisualLoader()
        let channel = MobileInitiationTestChannel()
        var channelFactoryCalls = 0
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            installer: modelInstaller,
            macControlInstaller: macControlInstaller,
            visualExecutorLoader: visualLoader,
            executorComposer: { _, visualFallback in visualFallback },
            taskLedger: ComputerUseTaskLedger(fileURL: fixture.ledger),
            allowsExternalServices: false,
            channelFactory: { _ in
                channelFactoryCalls += 1
                return channel
            })

        manager.refreshModelState()
        manager.start(pairingCode: "123456")
        XCTAssertTrue(manager.handle(
            try setupEnvelope(requestID: "app-hosted-unit-test"),
            channel: channel))
        for _ in 0 ..< 5 { await Task.yield() }

        let statusChecks = await macControlInstaller.statusCheckCount()
        let helperInstalls = await macControlInstaller.installCallCount()
        let modelInstalls = await modelInstaller.installCallCount()
        XCTAssertFalse(manager.allowsExternalServices)
        XCTAssertEqual(statusChecks, 0)
        XCTAssertEqual(helperInstalls, 0)
        XCTAssertEqual(modelInstalls, 0)
        XCTAssertEqual(visualLoader.loadCount, 0)
        XCTAssertEqual(channelFactoryCalls, 0)
        XCTAssertEqual(manager.modelState, .downloadRequired)
    }

    private struct Fixture {
        let parent: URL
        let root: URL
        let marker: URL
        let ledger: URL
    }

    private func makeFixture(markerPresent: Bool) throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ComputerUseMobileInitiation-\(UUID().uuidString)",
            isDirectory: true)
        let root = parent.appendingPathComponent("Computer Use Model", isDirectory: true)
        let marker = root.appendingPathComponent(
            ComputerUseInstaller.interruptedInstallationMarkerName)
        let ledger = parent.appendingPathComponent("ledger.json")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if markerPresent {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("installing\n".utf8).write(to: marker, options: .atomic)
        }
        return Fixture(parent: parent, root: root, marker: marker, ledger: ledger)
    }

    /// Fails deterministically inside installer preflight, before any file or
    /// network download, so the test can prove pipeline entry without fetching
    /// the multi-gigabyte production model.
    private var preflightFailureManifest: ComputerUseArtifactManifest {
        ComputerUseArtifactManifest(
            installationVersion: "mobile-initiation-test-v1",
            modelVariant: .pro4B,
            modelRepository: "invalid/model",
            modelRevision: "revision",
            modelArtifacts: [.init(
                kind: .textModelShard,
                fileName: "model.gguf",
                byteCount: 1,
                sha256: String(repeating: "a", count: 64),
                downloadURL: URL(string: "https://example.invalid/model.gguf")!)],
            minimumMemoryBytes: .max)
    }

    private func waitUntil(
        timeoutIterations: Int = 200,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0 ..< timeoutIterations {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for Computer Use state")
    }

    private func waitForSetupProgress(
        channel: MobileInitiationTestChannel,
        terminalPhase: ComputerUseSetupProgress.Phase = .failed,
        timeoutIterations: Int = 200
    ) async -> [ComputerUseSetupProgress] {
        for _ in 0 ..< timeoutIterations {
            let progress = await channel.setupProgress()
            if progress.contains(where: { $0.phase == terminalPhase }) {
                return progress
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for setup progress delivery")
        return await channel.setupProgress()
    }

    private func waitForStatusCheck(
        _ installer: MobileInitiationMacControlInstaller,
        timeoutIterations: Int = 200
    ) async {
        for _ in 0 ..< timeoutIterations {
            if await installer.statusCheckCount() > 0 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the read-only helper status check")
    }

    private func setupEnvelope(
        requestID: String,
        senderID: String = "IOS-PEER",
        sessionID: String = "SESSION-1"
    ) throws -> ComputerUseEnvelope {
        ComputerUseEnvelope(
            senderID: senderID,
            targetID: "HOST-ID",
            pairingCode: "123456",
            sessionID: sessionID,
            kind: .setupRequest,
            body: try ComputerUseSetupRequest(
                requestID: requestID).encodedBody())
    }

    private func mobileInitiationModelReceipt() -> ComputerUseInstallationReceipt {
        ComputerUseInstallationReceipt(
            installationVersion: "os-atlas-mobile-test-v1",
            modelVariant: .pro4B,
            modelDirectory: "/test/OS-Atlas-Pro-4B",
            installedAt: Date(timeIntervalSince1970: 0))
    }
}

private let mobileInitiationMacControlReceipt = MacControlMCPInstallationReceipt(
    packageVersion: "test",
    archiveSHA256: "test",
    appBundlePath: "/test/MacControlMCP.app",
    binaryPath: "/test/MacControlMCP.app/Contents/MacOS/MacControlMCP",
    bundleIdentifier: "dev.macmcp.server",
    teamIdentifier: "TEST",
    signingIdentity: "Test Identity",
    installedAt: Date(timeIntervalSince1970: 0))

private actor MobileInitiationMacControlInstaller: MacControlMCPProvisioning {
    private var status: MacControlMCPInstaller.DurableStatus
    private var installs = 0
    private var statusChecks = 0

    init(status: MacControlMCPInstaller.DurableStatus) {
        self.status = status
    }

    func durableStatus() async -> MacControlMCPInstaller.DurableStatus {
        statusChecks += 1
        return status
    }

    func install(
        progress: @MainActor @Sendable @escaping (MacControlMCPInstaller.Update) -> Void
    ) async throws -> MacControlMCPInstallationReceipt {
        installs += 1
        let updates: [MacControlMCPInstaller.Update] = [
            .init(
                phase: .preparing,
                fraction: 0,
                downloadedByteCount: 0,
                totalByteCount: 1_000,
                detail: "Preparing Mac control…"),
            .init(
                phase: .downloading,
                fraction: 0.25,
                downloadedByteCount: 250,
                totalByteCount: 1_000,
                detail: "Downloading Mac control… 250 bytes of 1,000 bytes"),
            .init(
                phase: .downloading,
                fraction: 0.75,
                downloadedByteCount: 750,
                totalByteCount: 1_000,
                detail: "Downloading Mac control… 750 bytes of 1,000 bytes"),
            .init(
                phase: .ready,
                fraction: 1,
                downloadedByteCount: 1_000,
                totalByteCount: 1_000,
                detail: "Mac control is installed"),
        ]
        for update in updates {
            await progress(update)
        }
        status = .ready(mobileInitiationMacControlReceipt)
        return mobileInitiationMacControlReceipt
    }

    func installCallCount() -> Int { installs }
    func statusCheckCount() -> Int { statusChecks }
}

private actor MobileInitiationModelInstaller: ComputerUseModelProvisioning {
    private let receipt: ComputerUseInstallationReceipt
    private let alreadyInstalled: Bool
    private let throwsInstallFailure: Bool
    private var interrupted: Bool
    private var installs = 0
    private var clearedMarkers = 0
    private var successfulActivations: [ComputerUseInstallationReceipt] = []
    private var failedActivations: [ComputerUseInstallationReceipt] = []

    init(receipt: ComputerUseInstallationReceipt, alreadyInstalled: Bool = false, interrupted: Bool = false,
         throwsInstallFailure: Bool = false) {
        self.receipt = receipt
        self.alreadyInstalled = alreadyInstalled
        self.interrupted = interrupted
        self.throwsInstallFailure = throwsInstallFailure
    }

    func currentInstallation() -> ComputerUseInstallationReceipt? { alreadyInstalled ? receipt : nil }

    func interruptedInstallationExists() -> Bool { interrupted }

    func clearInterruptedInstallationMarker() {
        clearedMarkers += 1
        interrupted = false
    }

    func recordRuntimeActivationSuccess(
        for receipt: ComputerUseInstallationReceipt
    ) {
        successfulActivations.append(receipt)
    }

    func restorePreviousInstallation(
        afterFailedActivationOf receipt: ComputerUseInstallationReceipt
    ) {
        failedActivations.append(receipt)
    }

    func install(
        progress: @MainActor @Sendable @escaping (ComputerUseInstaller.Update) -> Void
    ) async throws -> ComputerUseInstallationReceipt {
        installs += 1
        if throwsInstallFailure { throw CocoaError(.fileWriteOutOfSpace) }
        let updates: [ComputerUseInstaller.Update] = [
            .init(
                phase: .preparing,
                fraction: 0,
                detail: "Checking model storage…"),
            .init(
                phase: .downloadingModel,
                fraction: 0.5,
                detail: "Downloading OS-Atlas Pro… 2 GB of 4 GB"),
            .init(
                phase: .verifying,
                fraction: 0.96,
                detail: "Verifying OS-Atlas Pro…"),
            .init(
                phase: .ready,
                fraction: 1,
                detail: "OS-Atlas Pro is installed"),
        ]
        for update in updates {
            try Task.checkCancellation()
            await progress(update)
        }
        return receipt
    }

    func installCallCount() -> Int { installs }
    func clearedMarkerCount() -> Int { clearedMarkers }
    func recordedSuccessfulActivations() -> [ComputerUseInstallationReceipt] {
        successfulActivations
    }
    func recordedFailedActivations() -> [ComputerUseInstallationReceipt] {
        failedActivations
    }
}

@MainActor
private final class MobileInitiationVisualLoader: ComputerUseVisualExecutorLoading {
    private(set) var loadedReceipts: [ComputerUseInstallationReceipt] = []
    private(set) var deactivationCount = 0
    private(set) var maximumConcurrentLoads = 0
    private var activeLoads = 0
    private let throwsCancellation: Bool
    private let throwsLoadFailure: Bool

    var loadCount: Int { loadedReceipts.count }

    init(
        throwsCancellation: Bool = false,
        throwsLoadFailure: Bool = false
    ) {
        self.throwsCancellation = throwsCancellation
        self.throwsLoadFailure = throwsLoadFailure
    }

    func load(
        receipt: ComputerUseInstallationReceipt,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> any ComputerUseExecuting {
        loadedReceipts.append(receipt)
        activeLoads += 1
        maximumConcurrentLoads = max(maximumConcurrentLoads, activeLoads)
        defer { activeLoads -= 1 }
        progress("Starting OS-Atlas Pro test runtime…")
        if throwsCancellation { throw CancellationError() }
        if throwsLoadFailure { throw CocoaError(.fileReadCorruptFile) }
        return MobileInitiationReadyExecutor(
            runtimeName: "OS-Atlas Pro test runtime")
    }

    func deactivate() async {
        deactivationCount += 1
    }
}

private actor MobileInitiationComposerRecorder {
    private var calls = 0

    func recordCall() { calls += 1 }
    func callCount() -> Int { calls }
}

@MainActor
private final class MobileInitiationReadyExecutor: ComputerUseExecuting {
    let isReady = true
    let runtimeName: String

    init(runtimeName: String = "Test local model") {
        self.runtimeName = runtimeName
    }

    func execute(
        prompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        .completed("Done")
    }
}

private actor MobileInitiationTestChannel: HostComputerUseChannel {
    private var sent: [ComputerUseEnvelope] = []
    private let delayedFraction: Double?

    init(delayedFraction: Double? = nil) {
        self.delayedFraction = delayedFraction
    }

    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        if kind == .setupProgress,
           let delayedFraction,
           let progress = try? ComputerUseSetupProgress.decodeBody(body),
           progress.fractionCompleted == delayedFraction {
            try await Task.sleep(for: .milliseconds(50))
        }
        let envelope = ComputerUseEnvelope(
            id: explicitMessageID ?? UUID().uuidString,
            senderID: "HOST-ID",
            targetID: explicitTargetID ?? "IOS-PEER",
            pairingCode: "123456",
            sessionID: explicitSessionID ?? "SESSION-1",
            kind: kind,
            body: body)
        sent.append(envelope)
        return envelope
    }

    func poll() async throws -> [ComputerUseEnvelope] { [] }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}

    func setupProgress() -> [ComputerUseSetupProgress] {
        sent.compactMap { envelope in
            guard envelope.kind == .setupProgress else { return nil }
            return try? ComputerUseSetupProgress.decodeBody(envelope.body)
        }
    }

    func taskUpdates() -> [ComputerUseTaskUpdate] {
        sent.compactMap { envelope in
            guard envelope.kind == .assistant else { return nil }
            return try? ComputerUseTaskUpdate.decodeBody(envelope.body)
        }
    }

    func approvalRequests() -> [ComputerUseApprovalRequest] {
        sent.compactMap { $0.kind == .approvalRequest ? try? ComputerUseApprovalRequest.decodeBody($0.body) : nil }
    }

    func messages() -> [ComputerUseEnvelope] { sent }

    func setupProgressEnvelopes(
        phase: ComputerUseSetupProgress.Phase
    ) -> [ComputerUseEnvelope] {
        sent.filter { envelope in
            guard envelope.kind == .setupProgress,
                  let progress = try? ComputerUseSetupProgress.decodeBody(
                    envelope.body) else {
                return false
            }
            return progress.phase == phase
        }
    }
}
