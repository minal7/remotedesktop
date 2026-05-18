import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import os

enum CaptureSizing {
    static func normalized(width: Int, height: Int) -> (width: Int, height: Int) {
        (normalize(width), normalize(height))
    }

    private static func normalize(_ value: Int) -> Int {
        let even = value & ~1
        return max(2, even == 0 ? 2 : even)
    }
}

/// Thin wrapper around `SCStream` that captures the main display and
/// (on macOS 13+) system audio as `CMSampleBuffer`s delivered on the
/// capture queues. Consumers — the WebRTC video/audio encoders in
/// Phase 3 — handle their own marshalling.
///
/// Not `@MainActor`: callbacks fire on the capture queue and we don't
/// want a per-frame actor hop at 60 fps.
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
    private var loggedFirstAudioSample = false

    /// Invoked on `videoQueue` for each captured frame.
    var onVideoSample: (@Sendable (CMSampleBuffer) -> Void)?
    /// Invoked on `audioQueue` for each captured audio chunk.
    var onAudioSample: (@Sendable (CMSampleBuffer) -> Void)?
    /// Invoked on an arbitrary queue when the stream ends unexpectedly.
    var onStopped: (@Sendable (Error?) -> Void)?

    enum CaptureError: Error { case noDisplay }

    /// Picks the display containing the menu bar and starts capturing
    /// at up to 60 fps with system audio. Throws if ScreenCaptureKit
    /// can't start (typically: missing TCC approval).
    func start() async throws {
        stopping = false
        loggedFirstAudioSample = false
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }
        let normalizedSize = CaptureSizing.normalized(
            width: display.width,
            height: display.height)

        let config = SCStreamConfiguration()
        config.width = normalizedSize.width
        config.height = normalizedSize.height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 6
        config.showsCursor = true
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: [])

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try s.addStreamOutput(self, type: .audio,  sampleHandlerQueue: audioQueue)

        try await s.startCapture()
        stream = s
        log.info("capture started \(normalizedSize.width, privacy: .public)x\(normalizedSize.height, privacy: .public)")
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

extension ScreenCapture: SCStreamDelegate, SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: onVideoSample?(sampleBuffer)
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
        log.error("stream stopped: \(String(describing: error), privacy: .public)")
        // Don't fire onStopped during an intentional stop() call —
        // the caller already knows and will handle teardown.
        guard !stopping else { return }
        onStopped?(error)
    }
}

private extension ScreenCapture {
    static func isAlreadyStopped(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3808
    }
}
