import CoreGraphics
import Foundation
import Vision

/// Reads text from pixels for software with no usable accessibility tree: old
/// Java and Qt apps, canvases, remote sessions, some games.
public enum OCRReader {
    public struct Line: Sendable {
        public let text: String
        public let frame: CGRect
    }

    /// Lines in global screen points, top to bottom.
    public static func read(_ frame: ScreenFrame, maximumLines: Int = 160) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: frame.image, options: [:])
        try handler.perform([request])
        var lines: [Line] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence > 0.3 else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // Vision boxes are normalized with a bottom-left origin.
            let box = observation.boundingBox
            let rect = CGRect(x: frame.rect.minX + box.minX * frame.rect.width,
                              y: frame.rect.minY + (1 - box.maxY) * frame.rect.height,
                              width: box.width * frame.rect.width, height: box.height * frame.rect.height)
            lines.append(Line(text: text, frame: rect))
        }
        lines.sort { abs($0.frame.minY - $1.frame.minY) < 6 ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
        return Array(lines.prefix(maximumLines))
    }
}
