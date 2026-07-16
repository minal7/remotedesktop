import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import os

enum CaptureSizing {
    static let targetFramesPerSecond = Int32(DesktopVideoQuality.targetFramesPerSecond)

    static func normalized(width: Int, height: Int) -> (width: Int, height: Int) {
        (normalize(width), normalize(height))
    }

    static func backingPixelSize(
        widthInPoints: Double,
        heightInPoints: Double,
        pointPixelScale: Double
    ) -> (width: Int, height: Int) {
        let scale = max(1, pointPixelScale)
        return normalized(
            width: Int((widthInPoints * scale).rounded()),
            height: Int((heightInPoints * scale).rounded()))
    }

    /// Returns the largest even-sized rectangle with the source aspect ratio
    /// that fits the negotiated codec. Searching the small macroblock grid
    /// avoids accidentally crossing an H.264 level limit after 16-pixel
    /// alignment.
    static func encoderSafe(
        width: Int,
        height: Int,
        maximumMacroblocksPerFrame: Int
    ) -> (width: Int, height: Int) {
        let source = normalized(width: width, height: height)
        guard macroblockCount(width: source.width, height: source.height)
                > maximumMacroblocksPerFrame
                || source.width > DesktopVideoQuality.maximumEncodedDimension
                || source.height > DesktopVideoQuality.maximumEncodedDimension else {
            return source
        }

        var best = (width: 2, height: 2)
        var bestArea = 4

        for macroblockHeight in 1...maximumMacroblocksPerFrame {
            let macroblockWidth = maximumMacroblocksPerFrame / macroblockHeight
            guard macroblockWidth > 0 else { continue }

            let scale = min(
                1,
                Double(macroblockWidth * 16) / Double(source.width),
                Double(macroblockHeight * 16) / Double(source.height),
                Double(DesktopVideoQuality.maximumEncodedDimension) / Double(source.width),
                Double(DesktopVideoQuality.maximumEncodedDimension) / Double(source.height))
            let candidate = normalized(
                width: Int((Double(source.width) * scale).rounded(.down)),
                height: Int((Double(source.height) * scale).rounded(.down)))
            let area = candidate.width * candidate.height

            guard macroblockCount(width: candidate.width, height: candidate.height)
                    <= maximumMacroblocksPerFrame,
                  area > bestArea else {
                continue
            }
            best = candidate
            bestArea = area
        }

        return best
    }

    static func macroblockCount(width: Int, height: Int) -> Int {
        ((max(1, width) + 15) / 16) * ((max(1, height) + 15) / 16)
    }

    private static func normalize(_ value: Int) -> Int {
        let even = value & ~1
        return max(2, even == 0 ? 2 : even)
    }
}

/// Thin wrapper around `SCStream` that captures the main display and,
/// when the user opted in, system audio as `CMSampleBuffer`s delivered on the
/// capture queues. Consumers — the WebRTC video/audio encoders in
/// Phase 3 — handle their own marshalling.
///
/// Not `@MainActor`: callbacks fire on the capture queue and we don't
/// want a per-frame actor hop at 30 fps.
final class ScreenCapture: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var stopping = false
    private let videoQueue = DispatchQueue(
        label: "com.threadmark.remotedesktop.host.capture.video",
        qos: .userInteractive)
    private let audioQueue = DispatchQueue(
        label: "com.threadmark.remotedesktop.host.capture.audio",
        qos: .userInteractive)
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "capture")
    private var loggedFirstVideoSample = false
    private var loggedFirstAudioSample = false

    /// Invoked on `videoQueue` for each captured frame.
    var onVideoSample: (@Sendable (CMSampleBuffer) -> Void)?
    /// Invoked on `audioQueue` for each captured audio chunk.
    var onAudioSample: (@Sendable (CMSampleBuffer) -> Void)?
    /// Invoked on an arbitrary queue when the stream ends unexpectedly.
    var onStopped: (@Sendable (Error?) -> Void)?

    enum CaptureError: Error { case noDisplay }

    /// Picks the display containing the menu bar and starts capturing
    /// at up to 30 fps, adding system audio only when enabled. Throws if ScreenCaptureKit
    /// can't start (typically: missing TCC approval).
    func start(
        audioEnabled: Bool,
        maximumMacroblocksPerFrame: Int
    ) async throws {
        guard stream == nil else { return }
        stopping = false
        loggedFirstVideoSample = false
        loggedFirstAudioSample = false
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: {
            $0.displayID == CGMainDisplayID()
        }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: [])
        let contentInfo = SCShareableContent.info(for: filter)
        let sourceSize = CaptureSizing.backingPixelSize(
            widthInPoints: Double(contentInfo.contentRect.width),
            heightInPoints: Double(contentInfo.contentRect.height),
            pointPixelScale: Double(contentInfo.pointPixelScale))
        let captureSize = CaptureSizing.encoderSafe(
            width: sourceSize.width,
            height: sourceSize.height,
            maximumMacroblocksPerFrame: maximumMacroblocksPerFrame)

        let config = Self.streamConfiguration(
            width: captureSize.width,
            height: captureSize.height,
            audioEnabled: audioEnabled)

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if audioEnabled {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }

        try await s.startCapture()
        stream = s
        log.info(
            "capture started points=\(display.width, privacy: .public)x\(display.height, privacy: .public) backing=\(sourceSize.width, privacy: .public)x\(sourceSize.height, privacy: .public) output=\(captureSize.width, privacy: .public)x\(captureSize.height, privacy: .public) macroblockLimit=\(maximumMacroblocksPerFrame, privacy: .public) fps=\(CaptureSizing.targetFramesPerSecond, privacy: .public) audio=\(audioEnabled, privacy: .public)")
    }

    func stop() async {
        guard let s = stream else { return }
        stopping = true
        stream = nil
        do { try await s.stopCapture() }
        catch {
            guard !Self.isAlreadyStopped(error) else {
                stopping = false
                return
            }
            log.error("stop failed: \(String(describing: error), privacy: .public)")
        }
        stopping = false
    }
}

extension ScreenCapture {
    /// Kept as a pure configuration factory so tests can prove that declining
    /// optional microphone access also disables ScreenCaptureKit audio capture.
    static func streamConfiguration(
        width: Int,
        height: Int,
        audioEnabled: Bool
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CaptureSizing.targetFramesPerSecond)
        config.queueDepth = DesktopVideoQuality.captureQueueDepth
        config.showsCursor = true
        config.capturesAudio = audioEnabled
        if audioEnabled {
            config.sampleRate = 48_000
            config.channelCount = 2
        }
        return config
    }
}

extension ScreenCapture: SCStreamDelegate, SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            if !loggedFirstVideoSample,
               let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                loggedFirstVideoSample = true
                let width = CVPixelBufferGetWidth(imageBuffer)
                let height = CVPixelBufferGetHeight(imageBuffer)
                let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
                let macroblocks = CaptureSizing.macroblockCount(width: width, height: height)
                log.info(
                    "received first video sample effective=\(width, privacy: .public)x\(height, privacy: .public) macroblocks=\(macroblocks, privacy: .public) pixelFormat=\(pixelFormat, privacy: .public)")
            }
            onVideoSample?(sampleBuffer)
        case .audio:
            if !loggedFirstAudioSample,
               let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                loggedFirstAudioSample = true
                let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
                log.info(
                    "received first system audio sample sr=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public) frames=\(CMSampleBufferGetNumSamples(sampleBuffer), privacy: .public)")
            }
            onAudioSample?(sampleBuffer)
        case .microphone: break
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if self.stream === stream {
            self.stream = nil
        }
        guard !Self.isAlreadyStopped(error) else { return }
        if Self.isSystemStopped(error) {
            log.warning("stream stopped by the system: \(String(describing: error), privacy: .public)")
        } else {
            log.error("stream stopped: \(String(describing: error), privacy: .public)")
        }
        // Don't fire onStopped during an intentional stop() call —
        // the caller already knows and will handle teardown.
        guard !stopping else { return }
        onStopped?(error)
    }
}

extension ScreenCapture {
    static func isAlreadyStopped(_ error: Error) -> Bool {
        let nsError = error as NSError
        return isStreamError(nsError, code: -3808)
    }

    static func isSystemStopped(_ error: Error) -> Bool {
        let nsError = error as NSError
        return isStreamError(nsError, code: -3821)
    }

    private static func isStreamError(_ error: NSError, code: Int) -> Bool {
        error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && error.code == code
    }
}
