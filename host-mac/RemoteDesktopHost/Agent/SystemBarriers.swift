import CoreImage
import Foundation
import ImageIO
import Vision

/// Reuses the host's high-confidence permission and authentication detectors
/// before an observation can reach the model. OCR is best-effort; failure does
/// not create a new generic observation guard.
enum SystemBarriers {
    static func handoffReason(screenshot: Data, elements: [AgentElement], focus: AgentFocus?) -> String? {
        let labels = elements.prefix(60).map { "\($0.role) \($0.name)" }.joined(separator: "\n")
        let focused = focus.map { "\($0.role) \($0.name)" }
        let context = ComputerUseAuthenticationContextSnapshot(focusedElement: focused, boundedWindowContext: labels)
        if ComputerUseAuthenticationBarrierDetector.requiresUserIntervention(context) {
            return "A sign-in or verification screen needs your attention."
        }
        guard let image = CIImage(data: screenshot) else { return nil }
        if (try? ComputerUseScreenCaptureConsentDetector.requiresUserIntervention(from: image)) == true {
            return "Approve the screen-capture request in macOS to continue."
        }
        return nil
    }

    static func targetLabel(screenshot: String, x: Double, y: Double) -> String? {
        guard x.isFinite, y.isFinite, let data = Data(base64Encoded: screenshot),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let requested = CGRect(x: x - 120, y: y - 40, width: 240, height: 80).integral
        let crop = requested.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !crop.isNull, !crop.isEmpty, let region = image.cropping(to: crop) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: region, options: [:]).perform([request]) }
        catch { return nil }
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(256))
    }
}
