import AVFoundation
import CoreMedia
import Foundation
import LiveKitWebRTC
import os

/// Bridges ScreenCaptureKit system-audio buffers into WebRTC's
/// audio-engine recording graph using the public
/// `RTCAudioDeviceModuleDelegate` hooks exposed by LiveKitWebRTC.
///
/// Mirrors LiveKit's `MixerEngineObserver` pattern: a push-driven
/// `AVAudioPlayerNode` feeds a dedicated app mixer, which is mixed
/// into the ADM's input mixer alongside the (silenced) mic path.
/// The pure `AVAudioSourceNode` approach does not work here because
/// the ADM's input tap never pulls it while the engine is only
/// running the recording chain.
final class SystemAudioBridge: NSObject {
    private let queue = DispatchQueue(label: "com.threadmark.remotedesktop.host.audio.bridge")
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "audio")

    private weak var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var appMixerNode: AVAudioMixerNode?
    private var micMixerNode: AVAudioMixerNode?
    private weak var inputMixerNode: AVAudioMixerNode?
    private var playerNodeFormat: AVAudioFormat?
    private var engineFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    private var loggedFirstEnqueue = false
    private var loggedEngineConfiguration = false
    private var loggedFirstPlayerStart = false

    func attach(to audioDeviceModule: RTCAudioDeviceModule) {
        audioDeviceModule.observer = self
    }

    func detach(from audioDeviceModule: RTCAudioDeviceModule) {
        if audioDeviceModule.observer === self {
            audioDeviceModule.observer = nil
        }
        queue.sync {
            detachNodes()
            loggedFirstEnqueue = false
            loggedEngineConfiguration = false
            loggedFirstPlayerStart = false
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self,
                  let playerNode = self.playerNode,
                  let engine = self.engine, engine.isRunning,
                  let playerNodeFormat = self.playerNodeFormat,
                  let sourceBuffer = self.pcmBuffer(from: sampleBuffer),
                  let outputBuffer = self.convert(sourceBuffer, to: playerNodeFormat) else {
                return
            }

            if !self.loggedFirstEnqueue {
                self.loggedFirstEnqueue = true
                self.log.info(
                    "enqueuing first bridged system audio buffer srcSr=\(sourceBuffer.format.sampleRate, privacy: .public) srcCh=\(sourceBuffer.format.channelCount, privacy: .public) dstSr=\(playerNodeFormat.sampleRate, privacy: .public) dstCh=\(playerNodeFormat.channelCount, privacy: .public) frames=\(outputBuffer.frameLength, privacy: .public)")
            }

            playerNode.scheduleBuffer(outputBuffer, completionHandler: nil)
            if !playerNode.isPlaying {
                playerNode.play()
                if !self.loggedFirstPlayerStart {
                    self.loggedFirstPlayerStart = true
                    self.log.info("audio bridge player node started")
                }
            }
        }
    }

    private func attachNodes(to engine: AVAudioEngine) {
        if self.engine !== engine {
            detachNodes()
        }
        self.engine = engine
        guard playerNode == nil else { return }

        let playerNode = AVAudioPlayerNode()
        let appMixer = AVAudioMixerNode()
        let micMixer = AVAudioMixerNode()

        // Match the outputNode's maximumFramesToRender so the engine can
        // allocate buffers large enough for the whole graph. LiveKit's
        // MixerEngineObserver applies the same workaround for
        // kAudioUnitErr_TooManyFramesToProcess (-10874).
        let maxFrames = engine.outputNode.auAudioUnit.maximumFramesToRender
        playerNode.auAudioUnit.maximumFramesToRender = maxFrames
        appMixer.auAudioUnit.maximumFramesToRender = maxFrames
        micMixer.auAudioUnit.maximumFramesToRender = maxFrames

        engine.attach(playerNode)
        engine.attach(appMixer)
        engine.attach(micMixer)

        // We are bridging system audio only; silence the mic contribution
        // outright so the ADM still has a valid input chain but we never
        // ship microphone samples to remote peers.
        micMixer.outputVolume = 0

        self.playerNode = playerNode
        self.appMixerNode = appMixer
        self.micMixerNode = micMixer
    }

    private func detachNodes() {
        let engine = self.engine
        if let engine {
            if let playerNode {
                if playerNode.isPlaying { playerNode.stop() }
                engine.detach(playerNode)
            }
            if let appMixerNode {
                engine.detach(appMixerNode)
            }
            if let micMixerNode {
                engine.detach(micMixerNode)
            }
        }
        playerNode = nil
        appMixerNode = nil
        micMixerNode = nil
        inputMixerNode = nil
        playerNodeFormat = nil
        engineFormat = nil
        converter = nil
        converterSourceFormat = nil
        self.engine = nil
    }

    private func configureConnections(
        on engine: AVAudioEngine,
        source: AVAudioNode?,
        inputMixer: AVAudioMixerNode,
        format: AVAudioFormat
    ) {
        attachNodes(to: engine)
        guard let playerNode, let appMixer = appMixerNode, let micMixer = micMixerNode else {
            return
        }

        // AVAudioPlayerNode only supports Float32; derive a matching format
        // so converted ScreenCaptureKit samples can be scheduled directly.
        guard let playerNodeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: format.channelCount,
            interleaved: format.isInterleaved) else {
            log.error(
                "failed to build player node format sr=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public)")
            return
        }

        self.playerNodeFormat = playerNodeFormat
        self.engineFormat = format
        self.inputMixerNode = inputMixer

        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(appMixer)
        engine.disconnectNodeOutput(micMixer)

        // playerNode (system audio) -> appMixer -> inputMixer
        engine.connect(playerNode, to: appMixer, format: playerNodeFormat)
        engine.connect(appMixer, to: inputMixer, format: format)

        // mic (device) -> micMixer -> inputMixer, muted via micMixer.outputVolume = 0
        if let source {
            engine.disconnectNodeOutput(source)
            engine.connect(source, to: micMixer, format: format)
        }
        engine.connect(micMixer, to: inputMixer, format: format)
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        pcmBuffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList)
        guard status == noErr else {
            log.error("failed to copy system audio samples: \(status, privacy: .public)")
            return nil
        }
        return pcmBuffer
    }

    private func convert(_ sourceBuffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if sourceBuffer.format.isEqual(targetFormat) {
            return sourceBuffer
        }

        if converter == nil || converterSourceFormat != sourceBuffer.format {
            converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat)
            converterSourceFormat = sourceBuffer.format
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / sourceBuffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount((Double(sourceBuffer.frameLength) * ratio).rounded(.up)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        var converted = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if converted {
                outStatus.pointee = .noDataNow
                return nil
            }
            converted = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status != .error, outputBuffer.frameLength > 0 else {
            if let conversionError {
                log.error("failed to convert system audio samples: \(conversionError.localizedDescription, privacy: .public)")
            }
            return nil
        }
        return outputBuffer
    }
}

extension SystemAudioBridge: RTCAudioDeviceModuleDelegate {
    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, didReceiveSpeechActivityEvent speechActivityEvent: RTCSpeechActivityEvent) {}

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> NSInteger {
        queue.sync {
            attachNodes(to: engine)
        }
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> NSInteger {
        0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, willStartEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> NSInteger {
        queue.sync {
            playerNode?.reset()
        }
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, didStopEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> NSInteger {
        queue.sync {
            playerNode?.stop()
            loggedFirstPlayerStart = false
        }
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> NSInteger {
        0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> NSInteger {
        queue.sync {
            detachNodes()
        }
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, engine: AVAudioEngine, configureInputFromSource source: AVAudioNode?, toDestination destination: AVAudioNode, format: AVAudioFormat, context: [AnyHashable: Any]) -> NSInteger {
        queue.sync {
            guard let inputMixer = context[kLKRTCAudioEngineInputMixerNodeKey] as? AVAudioMixerNode else {
                log.error("input mixer missing from configureInputFromSource context")
                return
            }
            if !loggedEngineConfiguration {
                loggedEngineConfiguration = true
                log.info(
                    "configuring host audio bridge engine sr=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public) source=\(String(describing: source), privacy: .public) inputMixer=\(String(describing: inputMixer), privacy: .public) destination=\(String(describing: destination), privacy: .public)")
            }
            configureConnections(
                on: engine,
                source: source,
                inputMixer: inputMixer,
                format: format)
        }
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, engine: AVAudioEngine, configureOutputFromSource source: AVAudioNode, toDestination destination: AVAudioNode?, format: AVAudioFormat, context: [AnyHashable: Any]) -> NSInteger {
        0
    }

    func audioDeviceModuleDidUpdateDevices(_ audioDeviceModule: RTCAudioDeviceModule) {}
}
