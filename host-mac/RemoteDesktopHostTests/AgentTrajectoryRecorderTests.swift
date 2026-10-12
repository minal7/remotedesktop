import AppKit
import Darwin
import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentTrajectoryRecorderTests: XCTestCase {
    func testRecordsExactObservationRawOutputPromptAndFooterWithPrivateFiles() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try tinyPNG()
        let observation = observation(png: png)
        let recorder = try TrajectoryRecorder(root: root, episodeID: "episode-fixture")
        let step = episodeStep(id: recorder.episodeID, observation: observation, raw: "  exact raw output\n")

        try recorder.record(step)
        let footer = AgentEpisodeFooter(episodeID: recorder.episodeID, outcome: "done",
                                        approvals: ["approved-fixture"], corrections: ["clarified-fixture"],
                                        checkerVerdict: "passed")
        try recorder.finish(footer)

        let jsonl = try String(contentsOf: recorder.directory.appendingPathComponent("episode.jsonl"), encoding: .utf8)
        let lines = jsonl.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let decodedStep = try JSONDecoder().decode(AgentEpisodeRecord.self, from: Data(lines[0].utf8))
        let decodedFooter = try JSONDecoder().decode(AgentEpisodeRecord.self, from: Data(lines[1].utf8))
        XCTAssertEqual(decodedStep, .step(step))
        XCTAssertEqual(decodedFooter, .footer(footer))
        XCTAssertEqual(try Data(contentsOf: recorder.directory.appendingPathComponent("step-000.png")), png)
        XCTAssertEqual(try permissions(of: recorder.directory), 0o700)
        XCTAssertEqual(try permissions(of: recorder.directory.appendingPathComponent("episode.jsonl")), 0o600)
        XCTAssertEqual(try permissions(of: recorder.directory.appendingPathComponent("step-000.png")), 0o600)
    }

    func testRejectsInvalidScreenshotAndDoesNotPersistPartialStep() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try TrajectoryRecorder(root: root, episodeID: "invalid-png")
        let badObservation = observation(png: Data("not a PNG".utf8))
        let step = episodeStep(id: recorder.episodeID, observation: badObservation, raw: "raw")

        XCTAssertThrowsError(try recorder.record(step)) { error in
            guard let failure = error as? TrajectoryRecorder.Failure,
                  case .invalidScreenshot = failure else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.directory.appendingPathComponent("step-000.png").path))
        XCTAssertEqual(try String(contentsOf: recorder.directory.appendingPathComponent("episode.jsonl"), encoding: .utf8), "")
    }

    func testRejectsDuplicateStepsAndClosesAfterFooter() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try TrajectoryRecorder(root: root, episodeID: "closed-fixture")
        let step = episodeStep(id: recorder.episodeID, observation: observation(png: try tinyPNG()), raw: "raw")
        try recorder.record(step)
        XCTAssertThrowsError(try recorder.record(step)) { error in
            guard let failure = error as? TrajectoryRecorder.Failure,
                  case .duplicateStep = failure else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try recorder.finish(AgentEpisodeFooter(episodeID: recorder.episodeID, outcome: "done",
                                                approvals: [], corrections: []))
        XCTAssertThrowsError(try recorder.record(step)) { error in
            guard let failure = error as? TrajectoryRecorder.Failure,
                  case .closed = failure else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try recorder.finish(AgentEpisodeFooter(episodeID: recorder.episodeID,
                                                                     outcome: "again", approvals: [], corrections: []))) { error in
            guard let failure = error as? TrajectoryRecorder.Failure,
                  case .closed = failure else { return XCTFail("Unexpected error: \(error)") }
        }
        let lines = try String(contentsOf: recorder.directory.appendingPathComponent("episode.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(AgentEpisodeRecord.self, from: Data(lines[1].utf8)),
                       .footer(AgentEpisodeFooter(episodeID: recorder.episodeID, outcome: "done",
                                                  approvals: [], corrections: [])))
    }

    func testPrunesOnlyOwnedDirectoriesOlderThanSevenDaysAndDoesNotFollowSymlinks() throws {
        let parent = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("episodes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let old = root.appendingPathComponent("old-episode", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -8 * 86_400)],
                                              ofItemAtPath: old.path)
        let external = parent.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("keep".utf8).write(to: external.appendingPathComponent("sentinel"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-episode"),
                                                   withDestinationURL: external)

        let recorder = try TrajectoryRecorder(root: root, episodeID: "new-episode")

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("linked-episode").path))
        XCTAssertEqual(try String(contentsOf: external.appendingPathComponent("sentinel"), encoding: .utf8), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorder.directory.path))
    }

    func testRejectsSymlinkAsRecorderRoot() throws {
        let parent = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let external = parent.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("keep".utf8).write(to: external.appendingPathComponent("sentinel"))
        let link = parent.appendingPathComponent("episodes-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)

        XCTAssertThrowsError(try TrajectoryRecorder(root: link, episodeID: "blocked"))
        XCTAssertEqual(try String(contentsOf: external.appendingPathComponent("sentinel"), encoding: .utf8), "keep")
    }

    func testDeleteHistoryRemovesManagedEpisodesAndPreservesExternalSymlinks() throws {
        let parent = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("episodes", isDirectory: true)
        let recorder = try TrajectoryRecorder(root: root, episodeID: "managed-episode")
        try recorder.record(episodeStep(id: recorder.episodeID, observation: observation(png: try tinyPNG()), raw: "raw"))
        let external = parent.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let sentinel = external.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let link = root.appendingPathComponent("external-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)

        try TrajectoryRecorder.deleteHistory(root: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.directory.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), external.path)
    }

    private func observation(png: Data) -> AgentObservation {
        AgentObservation(task: "Complete a generic task",
            surface: .web(url: "https://example.test/", title: "Fixture"),
            screenshot: png.base64EncodedString(), elements: [], focus: nil, history: [],
            budget: .init(step: 0, maxSteps: 4))
    }

    private func episodeStep(id: String, observation: AgentObservation, raw: String) -> AgentEpisodeStep {
        AgentEpisodeStep(episodeID: id, step: 0, observation: observation, promptVersion: "v1",
            rawModelOutput: raw, action: .click(target: .element(id: 2), button: nil, count: nil),
            gate: .init(decision: .allowed, reason: "allowed fixture"),
            execution: .init(status: .ok, result: "completed fixture"),
            timings: .init(observationMS: 1, policyMS: 2, gateMS: 3,
                           executionMS: 4, recordMS: 5, totalMS: 15))
    }

    private func tinyPNG() throws -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }

    private func makePrivateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func permissions(of url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return info.st_mode & 0o777
    }
}
