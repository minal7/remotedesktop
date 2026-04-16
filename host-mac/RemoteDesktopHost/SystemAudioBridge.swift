import AVFoundation
import CoreMedia
import Foundation
import os

final class SystemAudioBridge: NSObject {
    private struct PendingBuffer {
        let buffer: AVAudioPCMBuffer
        var frameOffset: Int = 0
    }

    private let queue = DispatchQueue(label: "com.threadmark.remotedesktop.host.audio.bridge")
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "audio")
    private let pendingBuffersLock = NSLock()

    private weak var engine: AVAudioEngine?
    private weak var sourceNode: AVAudioNode?
    private weak var destinationNode: AVAudioNode?
    private var bridgeNode: AVAudioSourceNode?
    private var targetFormat: AVAudioFormat?
    private var pendingBuffers: [PendingBuffer] = []
    private var pendingBufferHead = 0
    private var activePendingBuffer: PendingBuffer?
    private var loggedFirstEnqueue = false
    private var loggedEngineConfiguration = false
    private var loggedBridgeReconnect = false
    private var loggedFirstRenderPull = false
    private var loggedFirstNonZeroRender = false

    func attach(to audioDeviceModule: RTCAudioDeviceModule) {
        audioDeviceModule.observer = self
    }

    func detach(from audioDeviceModule: RTCAudioDeviceModule) {
        if audioDeviceModule.observer === self {
            audioDeviceModule.observer = nil
        }
        queue.sync {
            teardownBridgeNode()
            loggedFirstEnqueue = false
            loggedEngineConfiguration = false
            loggedBridgeReconnect = false
            loggedFirstRenderPull = false
            loggedFirstNonZeroRender = false
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self,
                  let targetFormat = self.targetFormat,
                  let sourceBuffer = self.pcmBuffer(from: sampleBuffer),
                  let outputBuffer = self.convert(sourceBuffer, to: targetFormat) else {
                return
            }
            if !self.loggedFirstEnqueue {
                self.loggedFirstEnqueue = true
                self.log.info(
                    "enqueuing first bridged system audio buffer srcSr=\(sourceBuffer.format.sampleRate, privacy: .public) srcCh=\(sourceBuffer.format.channelCount, privacy: .public) dstSr=\(targetFormat.sampleRate, privacy: .public) dstCh=\(targetFormat.channelCount, privacy: .public) frames=\(outputBuffer.frameLength, privacy: .public)")
            }
            self.appendPendingBuffer(outputBuffer)
        }
    }

    private func installBridgeNode(
        on engine: AVAudioEngine,
        source: AVAudioNode?,
        destination: AVAudioNode,
        format: AVAudioFormat
    ) {
        if self.engine !== engine {
            teardownBridgeNode()
            self.engine = engine
        }
        sourceNode = source
        destinationNode = destination

        if let source {
            engine.disconnectNodeOutput(source)
        }

        let bridgeNode: AVAudioSourceNode
        if let existing = self.bridgeNode, existing.engine === engine {
            bridgeNode = existing
        } else {
            let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
                guard let self else {
                    Self.zeroAudioBuffers(UnsafeMutableAudioBufferListPointer(audioBufferList))
                    return noErr
                }
                return self.renderAudio(into: audioBufferList, frameCount: frameCount)
            }
            engine.attach(node)
            self.bridgeNode = node
            bridgeNode = node
        }

        engine.disconnectNodeOutput(bridgeNode)
        engine.connect(bridgeNode, to: destination, format: format)
        targetFormat = format
        resetPendingBuffers()
        loggedBridgeReconnect = false
    }

    private func teardownBridgeNode() {
        resetPendingBuffers()
        guard let bridgeNode else {
            sourceNode = nil
            destinationNode = nil
            targetFormat = nil
            return
        }
        if let engine {
            engine.disconnectNodeOutput(bridgeNode)
            engine.detach(bridgeNode)
        }
        self.bridgeNode = nil
        sourceNode = nil
        destinationNode = nil
        targetFormat = nil
    }

    private func appendPendingBuffer(_ buffer: AVAudioPCMBuffer) {
        pendingBuffersLock.lock()
        pendingBuffers.append(PendingBuffer(buffer: buffer))
        pendingBuffersLock.unlock()
    }

    private func resetPendingBuffers() {
        pendingBuffersLock.lock()
        pendingBuffers.removeAll(keepingCapacity: false)
        pendingBufferHead = 0
        activePendingBuffer = nil
        pendingBuffersLock.unlock()
    }

    private func dequeuePendingBufferLocked() -> PendingBuffer? {
        guard pendingBufferHead < pendingBuffers.count else {
            pendingBuffers.removeAll(keepingCapacity: false)
            pendingBufferHead = 0
            return nil
        }

        let buffer = pendingBuffers[pendingBufferHead]
        pendingBufferHead += 1

        if pendingBufferHead >= pendingBuffers.count {
            pendingBuffers.removeAll(keepingCapacity: true)
            pendingBufferHead = 0
        } else if pendingBufferHead > 32 && pendingBufferHead * 2 > pendingBuffers.count {
            pendingBuffers.removeFirst(pendingBufferHead)
            pendingBufferHead = 0
        }

        return buffer
    }

    private func renderAudio(
        into audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount
    ) -> OSStatus {
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        Self.zeroAudioBuffers(destinationBuffers)

        if !loggedFirstRenderPull {
            loggedFirstRenderPull = true
            log.info("audio bridge render pulled for first time frames=\(frameCount, privacy: .public)")
        }

        pendingBuffersLock.lock()
        defer { pendingBuffersLock.unlock() }

        var framesWritten = 0
        let requestedFrames = Int(frameCount)

        while framesWritten < requestedFrames {
            if activePendingBuffer == nil {
                activePendingBuffer = dequeuePendingBufferLocked()
            }
            guard var activePendingBuffer else { break }

            let copiedFrames = copyFrames(
                from: activePendingBuffer.buffer,
                sourceFrameOffset: activePendingBuffer.frameOffset,
                to: destinationBuffers,
                destinationFrameOffset: framesWritten,
                requestedFrames: requestedFrames - framesWritten)

            guard copiedFrames > 0 else {
                self.activePendingBuffer = nil
                continue
            }

            activePendingBuffer.frameOffset += copiedFrames
            framesWritten += copiedFrames

            if !loggedFirstNonZeroRender && copiedFrames > 0 {
                loggedFirstNonZeroRender = true
                log.info("audio bridge first non-zero render copied=\(copiedFrames, privacy: .public)")
            }

            if activePendingBuffer.frameOffset >= Int(activePendingBuffer.buffer.frameLength) {
                self.activePendingBuffer = nil
            } else {
                self.activePendingBuffer = activePendingBuffer
            }
        }

        return noErr
    }

    private func copyFrames(
        from sourceBuffer: AVAudioPCMBuffer,
        sourceFrameOffset: Int,
        to destinationBuffers: UnsafeMutableAudioBufferListPointer,
        destinationFrameOffset: Int,
        requestedFrames: Int
    ) -> Int {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(sourceBuffer.mutableAudioBufferList)
        let bytesPerFrame = Int(sourceBuffer.format.streamDescription.pointee.mBytesPerFrame)
        let availableFrames = Int(sourceBuffer.frameLength) - sourceFrameOffset
        let framesToCopy = min(requestedFrames, availableFrames)

        guard framesToCopy > 0, bytesPerFrame > 0 else {
            return 0
        }
        guard sourceBuffers.count == destinationBuffers.count else {
            return 0
        }

        let byteCount = framesToCopy * bytesPerFrame
        let sourceByteOffset = sourceFrameOffset * bytesPerFrame
        let destinationByteOffset = destinationFrameOffset * bytesPerFrame

        for bufferIndex in 0..<sourceBuffers.count {
            guard let sourceData = sourceBuffers[bufferIndex].mData,
                  let destinationData = destinationBuffers[bufferIndex].mData else {
                continue
            }
            memcpy(
                destinationData.advanced(by: destinationByteOffset),
                sourceData.advanced(by: sourceByteOffset),
                byteCount)
        }

        return framesToCopy
    }

    private static func zeroAudioBuffers(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }

    private func reconnectBridgeNode(
        on engine: AVAudioEngine,
        destination: AVAudioNode,
        format: AVAudioFormat
    ) {
        guard let bridgeNode = self.bridgeNode else { return }
        if !loggedBridgeReconnect {
            loggedBridgeReconnect = true
            log.warning("audio bridge source node disconnected; reconnecting to engine graph")
        }
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
        }
        engine.disconnectNodeOutput(bridgeNode)
        engine.connect(bridgeNode, to: destination, format: format)
    }

    private func bridgeNodeIsConnected(_ bridgeNode: AVAudioSourceNode, on engine: AVAudioEngine) -> Bool {
        guard bridgeNode.engine === engine else { return false }
        return !engine.outputConnectionPoints(for: bridgeNode, outputBus: 0).isEmpty
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
        if sourceBuffer.format == targetFormat || sourceBuffer.format.isEqual(targetFormat) {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
            return nil
        }

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
        queue.async { [weak self] in
            self?.engine = engine
        }
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> NSInteger {
        0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, willStartEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> NSInteger {
        queue.async { [weak self] in
            guard let self,
                  let bridgeNode = self.bridgeNode,
                  let destinationNode = self.destinationNode,
                  let targetFormat = self.targetFormat else { return }
            guard !self.bridgeNodeIsConnected(bridgeNode, on: engine) else {
                self.loggedBridgeReconnect = false
                return
            }
            self.reconnectBridgeNode(on: engine, destination: destinationNode, format: targetFormat)
        }
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, didStopEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> NSInteger {
        queue.async { [weak self] in
            self?.resetPendingBuffers()
        }
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> NSInteger {
        0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> NSInteger {
        queue.async { [weak self] in
            self?.teardownBridgeNode()
            self?.engine = nil
        }
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, engine: AVAudioEngine, configureInputFromSource source: AVAudioNode?, toDestination destination: AVAudioNode, format: AVAudioFormat, context: [AnyHashable: Any]) -> NSInteger {
        queue.sync {
            if !loggedEngineConfiguration {
                loggedEngineConfiguration = true
                log.info(
                    "configuring host audio bridge engine sr=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public) source=\(String(describing: source), privacy: .public)")
            }
            installBridgeNode(on: engine, source: source, destination: destination, format: format)
        }
        return 0
    }

    func audioDeviceModule(_ audioDeviceModule: RTCAudioDeviceModule, engine: AVAudioEngine, configureOutputFromSource source: AVAudioNode, toDestination destination: AVAudioNode?, format: AVAudioFormat, context: [AnyHashable: Any]) -> NSInteger {
        0
    }

    func audioDeviceModuleDidUpdateDevices(_ audioDeviceModule: RTCAudioDeviceModule) {}
}
