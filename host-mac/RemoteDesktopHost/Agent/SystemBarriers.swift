import CoreImage
import Foundation
import ImageIO
import Vision

/// Reuses the host's high-confidence permission and authentication detectors
/// before an observation can reach the model. OCR is best-effort; failure does
/// not create a new generic observation guard.
enum SystemBarriers {
    private struct OCRWord {
        let text: String
        let bounds: CGRect
        let line: Int
    }

    private struct OCRLabel {
        let text: String
        let bounds: CGRect
    }

    static func handoffReason(
        screenshot: Data,
        elements: [AgentElement],
        focus: AgentFocus?,
        consentRecognition: (@Sendable (Data) throws -> Bool)? = nil
    ) async throws -> String? {
        try Task.checkCancellation()
        let labels = elements.prefix(60).map { "\($0.role) \($0.name)" }.joined(separator: "\n")
        let focused = focus.map { "\($0.role) \($0.name)" }
        let context = ComputerUseAuthenticationContextSnapshot(focusedElement: focused, boundedWindowContext: labels)
        if ComputerUseAuthenticationBarrierDetector.requiresUserIntervention(context) {
            try Task.checkCancellation()
            return "A sign-in or verification screen needs your attention."
        }
        do {
            let requiresIntervention = try await ComputerUseObservationWorker.performConsentRecognition {
                if let consentRecognition { return try consentRecognition(screenshot) }
                guard let image = CIImage(data: screenshot) else { return false }
                return try ComputerUseScreenCaptureConsentDetector.requiresUserIntervention(from: image)
            }
            try Task.checkCancellation()
            return requiresIntervention
                ? "Approve the screen-capture request in macOS to continue."
                : nil
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ComputerUseObservationWorker.Failure {
            switch failure {
            case .busy, .timedOut:
                // A missing consent result must not publish an unchecked frame.
                throw failure
            case .recognitionFailed:
                // Preserve the prior best-effort behavior for OCR failures.
                return nil
            }
        } catch {
            // Preserve the prior best-effort behavior for other OCR failures.
            return nil
        }
    }

    static func targetLabel(screenshot: String, x: Double, y: Double) -> String? {
        guard x.isFinite, y.isFinite, let data = Data(base64Encoded: screenshot),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let point = CGPoint(x: x, y: y)
        guard imageBounds.contains(point) else { return nil }
        let requested = CGRect(x: x - 120, y: y - 40, width: 240, height: 80).integral
        let crop = requested.intersection(imageBounds)
        guard !crop.isNull, !crop.isEmpty, let region = image.cropping(to: crop) else { return nil }
        let scale = 3
        let scaledWidth = max(1, Int(crop.width) * scale)
        let scaledHeight = max(1, Int(crop.height) * scale)
        guard let context = CGContext(data: nil, width: scaledWidth, height: scaledHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(region, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
        guard let scaledRegion = context.makeImage() else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: scaledRegion, options: [:]).perform([request]) }
        catch { return nil }
        let words = recognizedWords(request.results ?? [], crop: crop)
        let labels = groupedLabels(words)
        return selectTargetLabel(candidates: labels.map { ($0.text, $0.bounds) }, at: point)
    }

    static func selectTargetLabel(candidates: [(text: String, bounds: CGRect)], at point: CGPoint) -> String? {
        let ranked = candidates.map { ($0, distance(from: point, to: $0.bounds)) }
            .sorted { $0.1 < $1.1 }
        guard let best = ranked.first, best.1 <= 72 else { return nil }
        if ranked.count > 1, ranked[1].1 - best.1 <= 1 { return nil }
        let label = best.0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : String(label.prefix(128))
    }

    private static func recognizedWords(
        _ observations: [VNRecognizedTextObservation], crop: CGRect
    ) -> [OCRWord] {
        let tokenPattern = try! NSRegularExpression(pattern: #"\S+"#)
        return observations.enumerated().flatMap { line, observation -> [OCRWord] in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.35 else { return [] }
            let string = candidate.string
            let fullRange = NSRange(string.startIndex..<string.endIndex, in: string)
            return tokenPattern.matches(in: string, range: fullRange).compactMap { match in
                guard let range = Range(match.range, in: string),
                      let box = try? candidate.boundingBox(for: range) else { return nil }
                let normalized = box.boundingBox
                let bounds = CGRect(
                    x: crop.minX + normalized.minX * crop.width,
                    y: crop.minY + (1 - normalized.maxY) * crop.height,
                    width: normalized.width * crop.width,
                    height: normalized.height * crop.height)
                guard bounds.width > 0, bounds.height > 0 else { return nil }
                return OCRWord(text: String(string[range]), bounds: bounds, line: line)
            }
        }
    }

    private static func groupedLabels(_ words: [OCRWord]) -> [OCRLabel] {
        let sorted = words.sorted {
            $0.line == $1.line ? $0.bounds.minX < $1.bounds.minX : $0.line < $1.line
        }
        var labels: [OCRLabel] = []
        var current: [OCRWord] = []
        func appendCurrent() {
            guard !current.isEmpty else { return }
            let bounds = current.dropFirst().reduce(current[0].bounds) { $0.union($1.bounds) }
            labels.append(OCRLabel(text: current.map(\.text).joined(separator: " "), bounds: bounds))
            current.removeAll(keepingCapacity: true)
        }
        for word in sorted {
            guard let previous = current.last else { current = [word]; continue }
            let gap = word.bounds.minX - previous.bounds.maxX
            let sameLabel = word.line == previous.line
                && gap <= max(5, max(word.bounds.height, previous.bounds.height) * 0.6)
            if sameLabel { current.append(word) }
            else { appendCurrent(); current = [word] }
        }
        appendCurrent()
        return labels
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(0, max(rect.minX - point.x, point.x - rect.maxX))
        let dy = max(0, max(rect.minY - point.y, point.y - rect.maxY))
        return hypot(dx, dy)
    }
}
