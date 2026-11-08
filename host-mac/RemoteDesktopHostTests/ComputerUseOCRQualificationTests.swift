import XCTest
import Vision
@testable import RemoteDesktopHost

final class ComputerUseOCRQualificationTests: XCTestCase {
    func testFastOCRCandidatePreservesFixtureTargetsNumbersAndSystemConsent() async throws {
        guard ProcessInfo.processInfo.environment["RUN_COMPUTER_USE_OCR_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt in to compare an unqualified OCR candidate; this is not the production OCR path.")
        }
        let rows: [(ComputerUseScreenObservation, [String])] = [
            (try OSAtlasAcceptanceFixtureRenderer.everydayOperation(.groceryCheckout), ["Place Order"]),
            (try OSAtlasAcceptanceFixtureRenderer.deliveryQuote(),
             ["Pizzeria Uno", "$24.99", "$2.99", "$3.75", "$2.78", "$34.51"]),
            (try OSAtlasAcceptanceFixtureRenderer.localBrowserEvidence(lines: [
                "Library hours: 10:00 AM - 6:00 PM", "Telephone: 415-555-0138"]),
             ["10:00 AM", "6:00 PM", "415-555-0138"]),
        ]
        for (observation, expected) in rows {
            let lines = try await fastLines(observation)
            let text = lines.joined(separator: "\n")
            for value in expected { XCTAssertTrue(text.contains(value), "Missing \(value) in \(text)") }
        }
        let consentLines = try await fastLines(
            OSAtlasAcceptanceFixtureRenderer.screenCaptureConsentPrompt())
        XCTAssertTrue(ComputerUseScreenCaptureConsentDetector.requiresUserIntervention(
            inRecognizedText: consentLines.joined(separator: "\n")))
    }

    private func fastLines(_ observation: ComputerUseScreenObservation) async throws -> [String] {
        try await ComputerUseObservationWorker.perform(timeout: 5) {
            let start = ContinuousClock.now
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(ciImage: observation.image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            print("OCR candidate fast, lines=\(lines.count), elapsed=\(start.duration(to: .now))")
            return lines
        }
    }
}
