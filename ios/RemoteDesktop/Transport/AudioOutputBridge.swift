import AVFAudio
import Foundation
import os

/// Minimal RTCAudioDeviceModule delegate for the iOS receive-only client.
///
/// The audioEngine ADM creates an AVAudioEngine and calls delegate methods to
/// wire input (recording) and output (playout) graphs.  This bridge only
/// handles the output side: it connects WebRTC's decoded-audio source node
/// straight to the engine's output destination so remote audio plays through
/// the device speaker.
final class AudioOutputBridge: NSObject {
    private let log = Logger(subsystem: "com.threadmark.remotedesktop", category: "audio")
    private weak var engine: AVAudioEngine?

    func attach(to audioDeviceModule: RTCAudioDeviceModule) {
        audioDeviceModule.observer = self
    }

    func detach(from audioDeviceModule: RTCAudioDeviceModule) {
        if audioDeviceModule.observer === self {
            audioDeviceModule.observer = nil
        }
    }
}

extension AudioOutputBridge: RTCAudioDeviceModuleDelegate {
    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                           didReceiveSpeechActivityEvent speechActivityEvent: RTCSpeechActivityEvent) {}

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                           didCreateEngine engine: AVAudioEngine) -> NSInteger {
        self.engine = engine
        log.info("ADM created engine")
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                           willEnableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool,
                           isRecordingEnabled: Bool) -> NSInteger {
        log.info("ADM willEnable playout=\(isPlayoutEnabled) recording=\(isRecordingEnabled)")
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                           willStartEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool,
                           isRecordingEnabled: Bool) -> NSInteger {
        log.info("ADM willStart playout=\(isPlayoutEnabled) recording=\(isRecordingEnabled) running=\(engine.isRunning)")
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                           didStopEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool,
                           isRecordingEnabled: Bool) -> NSInteger {
        log.info("ADM didStop")
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                           didDisableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool,
                           isRecordingEnabled: Bool) -> NSInteger {
        0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                           willReleaseEngine engine: AVAudioEngine) -> NSInteger {
        self.engine = nil
        log.info("ADM willRelease engine")
        return 0
    }

    // MARK: - Input (recording) — not used on the receive-only client

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                           engine: AVAudioEngine,
                           configureInputFromSource source: AVAudioNode?,
                           toDestination destination: AVAudioNode,
                           format: AVAudioFormat,
                           context: [AnyHashable: Any]) -> NSInteger {
        // No mic / recording on the iOS client.
        0
    }

    // MARK: - Output (playout) — wire decoded audio to the speaker

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule,
                           engine: AVAudioEngine,
                           configureOutputFromSource source: AVAudioNode,
                           toDestination destination: AVAudioNode?,
                           format: AVAudioFormat,
                           context: [AnyHashable: Any]) -> NSInteger {
        log.info("configureOutput sr=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public)")
        // Connect the ADM's decoded-audio source node to the output
        // destination (mainMixerNode → outputNode).  If destination is nil
        // the ADM already wired it; just return success.
        if let destination {
            engine.connect(source, to: destination, format: format)
        }
        return 0
    }

    func audioDeviceModuleDidUpdateDevices(_ audioDeviceModule: RTCAudioDeviceModule) {}
}
