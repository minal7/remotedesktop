import CryptoKit
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseSourceBoundTextModelAcceptanceTests: XCTestCase {
    private struct Corpus: Decodable { let schemaVersion: Int; let scope: String; let cases: [Case] }
    private struct Case: Decodable {
        let id: String; let prompt: String; let fields: [String]; let expectedDisposition: String
        let allowedPlans: [[Edit]]?
    }
    private struct Edit: Codable, Equatable {
        let field: Int
        let mode: String
        let value: String?
        let sourceField: Int?
        init(field: Int, mode: String, value: String? = nil, sourceField: Int? = nil) {
            self.field = field; self.mode = mode; self.value = value; self.sourceField = sourceField
        }
        static func == (left: Self, right: Self) -> Bool {
            guard left.field == right.field, left.mode == right.mode, left.sourceField == right.sourceField else { return false }
            switch (left.value, right.value) {
            case (nil, nil): return true
            case (.some(let a), .some(let b)): return a.utf8.elementsEqual(b.utf8)
            default: return false
            }
        }
    }

    func testOperationOracleDistinguishesCopiedSourcesLiteralPayloadsAndExactBytes() {
        let copy = Edit(field: 1, mode: "replaceAll", sourceField: 0)
        XCTAssertNotEqual(copy, Edit(field: 1, mode: "replaceAll", value: "f1"))
        XCTAssertNotEqual(copy, Edit(field: 1, mode: "replaceAll", sourceField: 2))
        XCTAssertNotEqual(Edit(field: 1, mode: "replaceAll", value: "e\u{301}"), Edit(field: 1, mode: "replaceAll", value: "é"))
        XCTAssertEqual(copy, Edit(field: 1, mode: "replaceAll", sourceField: 0))
    }

    func testSignedRuntimeCompilesTheExactCorpusWithoutDesktopEffects() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_SOURCE_BOUND_TEXT_MODEL_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in signed managed-model proposal qualification, with no desktop effects")
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw Failure.invalidInput }
        let corpusURL = URL(fileURLWithPath: try XCTUnwrap(environment["SOURCE_BOUND_TEXT_CORPUS"]))
        let reportURL = URL(fileURLWithPath: try XCTUnwrap(environment["SOURCE_BOUND_TEXT_REPORT"]))
        let contract = try XCTUnwrap(ComputerUseLocalTextGoalPlanner.Contract(rawValue: environment["SOURCE_BOUND_TEXT_CONTRACT"] ?? "source-bound-v3"))
        let allowFieldCopy = environment["SOURCE_BOUND_TEXT_ALLOW_FIELD_COPY"] == "1"
        guard !FileManager.default.fileExists(atPath: reportURL.path) else { throw Failure.invalidInput }
        let data = try Data(contentsOf: corpusURL)
        let corpusHash = Self.sha(data)
        guard data.count <= 1_024 * 1_024, corpusHash == environment["SOURCE_BOUND_TEXT_CORPUS_SHA256"] else { throw Failure.invalidInput }
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        guard corpus.schemaVersion == 1, (1...128).contains(corpus.cases.count),
              Set(corpus.cases.map(\.id)).count == corpus.cases.count,
              corpus.cases.allSatisfy({ item in
                  (1...16).contains(item.fields.count) && ["supported", "unsupported", "clarification"].contains(item.expectedDisposition)
                  && (item.expectedDisposition == "supported" ? !(item.allowedPlans ?? []).isEmpty : item.allowedPlans == nil)
                  && (item.allowedPlans ?? []).allSatisfy { plan in
                      (1...8).contains(plan.count) && plan.allSatisfy { edit in
                          item.fields.indices.contains(edit.field) && ComputerUseTextEditMode(rawValue: edit.mode) != nil
                          && (edit.value != nil) != (edit.sourceField != nil)
                          && (edit.sourceField.map { item.fields.indices.contains($0) } ?? true)
                      }
                  }
              }) else { throw Failure.invalidInput }
        let receipt = try await ComputerUseInstaller.nativeText().install { _ in }
        let directory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
        let inputs = try OSAtlasRuntimeInputResolver(manifest: .nativeTextV2).resolveNativeText(
            receipt: receipt, runtimeDirectoryURL: directory, enclosingBundleURL: Bundle.main.bundleURL)
        let runtimeHash = Self.sha(try Data(contentsOf: directory.appendingPathComponent("llama-server")))
        let runtime = OSAtlasLlamaRuntime.shared
        var rows: [[String: Any]] = []
        func save() throws {
            let result: [String: Any] = ["schemaVersion": 1, "scope": corpus.scope, "contract": contract.rawValue,
                "corpusSHA256": corpusHash, "runtimeBinarySHA256": runtimeHash,
                "modelSHA256FromVerifiedManifest": ComputerUseArtifactManifest.nativeTextV2.modelArtifacts[0].sha256,
                "expectedCaseIDs": corpus.cases.map(\.id), "cases": rows,
                "oracle": "exact-disposition-and-complete-operation-sequences-including-count-mode-target-payload-origin-exact-bytes-and-order",
                "desktopEffects": false, "quotedCommandFastPath": false, "allowFieldCopy": allowFieldCopy]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        }
        do {
            for item in corpus.cases {
                let started = ProcessInfo.processInfo.systemUptime
                let recorder = ProposalRecorder()
                var row: [String: Any] = ["id": item.id, "verified": false]
                do {
                    // After a malformed proposal the owner retires that server.
                    // Reactivation is for a new, effect-free corpus request.
                    let endpoint = try await runtime.activateNativeText(inputs)
                    let fields: [ComputerUseTextField] = item.fields.enumerated().map { index, label in
                        .init(label: label, snapshot: .init(targetID: "fixture-\(index)", value: "private existing fixture value",
                            selection: NSRange(location: 0, length: 0), isEditable: true, isSecure: false))
                    }
                    let result = try await runtime.proposeNativeText(endpoint: endpoint, prompt: item.prompt, fields: fields,
                        contract: contract, allowFieldCopy: allowFieldCopy, inspectProposal: { recorder.record($0) })
                    let disposition: String
                    var edits: [Edit] = []
                    switch result {
                    case .unsupported: disposition = "unsupported"
                    case .clarification: disposition = "clarification"
                    case .fieldOperations(let operations, let unchanged):
                        disposition = "supported"
                        for operation in operations {
                            let index = try XCTUnwrap(fields.firstIndex(where: { $0.snapshot.targetID == operation.targetID }))
                            switch operation {
                            case .enterText(let edit): edits.append(.init(field: index, mode: edit.mode.rawValue, value: edit.text))
                            case .copyField(let sourceID, _, let mode):
                                let source = try XCTUnwrap(fields.firstIndex(where: { $0.snapshot.targetID == sourceID }))
                                edits.append(.init(field: index, mode: mode.rawValue, sourceField: source))
                            }
                        }
                        let edited = Set(operations.map(\.targetID))
                        guard Set(unchanged) == Set(fields.map { $0.snapshot.targetID }).subtracting(edited) else { throw Failure.missingConstraint }
                    case .edits(let proposed, let unchanged):
                        disposition = "supported"
                        for edit in proposed {
                            let index = try XCTUnwrap(fields.firstIndex(where: { $0.snapshot.targetID == edit.targetID }))
                            edits.append(.init(field: index, mode: edit.mode.rawValue, value: edit.text))
                        }
                        let edited = Set(proposed.map(\.targetID))
                        guard Set(unchanged) == Set(fields.map { $0.snapshot.targetID }).subtracting(edited) else { throw Failure.missingConstraint }
                    }
                    let passed = disposition == item.expectedDisposition && (disposition != "supported" || (item.allowedPlans ?? []).contains(edits))
                    row["verified"] = passed
                    row["disposition"] = disposition
                    row["edits"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edits))
                    XCTAssertTrue(passed, "\(item.id): disposition or complete edit sequence did not match the independent corpus")
                } catch {
                    row["error"] = String(describing: error)
                    XCTFail("\(item.id): \(error)")
                }
                let attempts = recorder.snapshot()
                row["proposals"] = attempts
                row["modelResponses"] = attempts.count
                row["proposal"] = attempts.last ?? [:]
                row["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
                rows.append(row)
                try save()
                FileHandle.standardError.write(Data("Source-bound model: \(item.id) \(row["verified"] as? Bool == true ? "verified" : "FAILED")\n".utf8))
            }
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }

    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private enum Failure: Error { case invalidInput, missingConstraint }
}

/// Fixture diagnostics retain only the final structured proposal and finish
/// reason. Reasoning text, requests and runtime credentials are not recorded.
private final class ProposalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String: String]] = []
    func record(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]], choices.count == 1,
              let message = choices[0]["message"] as? [String: Any] else { return }
        let snapshot = ["finishReason": choices[0]["finish_reason"] as? String ?? "missing",
                        "content": message["content"] as? String ?? "missing"]
        lock.withLock { values.append(snapshot) }
    }
    func snapshot() -> [[String: String]] { lock.withLock { values } }
}
