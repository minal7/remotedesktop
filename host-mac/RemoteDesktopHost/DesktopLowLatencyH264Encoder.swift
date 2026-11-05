#if DEBUG && os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import LiveKitWebRTC
import VideoToolbox
import os

/// Requests are retained until the rate limit permits the next keyframe.
struct DesktopKeyframeGate {
    private var lastForced: Double?
    private var pending = false
    private var requestVersion: UInt64 = 0

    mutating func shouldForce(requested: Bool, now: Double) -> UInt64? {
        if requested { requestVersion &+= 1; pending = true }
        guard pending, now.isFinite else { return nil }
        if let lastForced, now >= lastForced, now - lastForced < 0.3 { return nil }
        lastForced = now
        return requestVersion
    }

    mutating func acknowledge(_ version: UInt64) {
        if version == requestVersion { pending = false }
    }
}

enum DesktopH264AnnexB {
    static func convert(_ avcc: Data, lengthSize: Int, parameterSets: [Data] = []) -> Data? {
        guard (1...4).contains(lengthSize), parameterSets.allSatisfy({ !$0.isEmpty }) else { return nil }
        let bytes = [UInt8](avcc)
        var offset = 0
        var result = Data()
        let prefix: [UInt8] = [0, 0, 0, 1]
        for parameter in parameterSets { result.append(contentsOf: prefix); result.append(parameter) }
        while offset < bytes.count {
            guard bytes.count - offset >= lengthSize else { return nil }
            var length = 0
            for byte in bytes[offset..<(offset + lengthSize)] { length = (length << 8) | Int(byte) }
            offset += lengthSize
            guard length > 0, length <= bytes.count - offset else { return nil }
            result.append(contentsOf: prefix)
            result.append(contentsOf: bytes[offset..<(offset + length)])
            offset += length
        }
        return offset > 0 ? result : nil
    }

    /// SDP advertises constrained-high 5.1; don't emit an incompatible SPS.
    static func isCompatibleSPS(_ sps: Data) -> Bool {
        let b = [UInt8](sps)
        return b.count >= 4 && b[0] & 0x1f == 7 && b[1] == 0x64 &&
            b[2] & 0x0c == 0x0c && b[3] <= 0x33
    }
}

enum DesktopEncoderRate {
    static func apply(kbps: UInt32, fps: UInt32, set: (CFString, CFTypeRef) -> OSStatus) -> Bool {
        guard kbps > 0, fps > 0 else { return false }
        let bitrate = set(kVTCompressionPropertyKey_AverageBitRate, (Int64(kbps) * 1_000) as CFNumber)
        let rate = set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        let interval = set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (Int64(fps) * 2) as CFNumber)
        return bitrate == noErr && rate == noErr && interval == noErr
    }
}

enum DesktopEncoderConfiguration {
    static func specification() -> [CFString: Any] {
        [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
         kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    }

    static func properties(fps: UInt32, bitrateKbps: UInt32) -> [(CFString, CFTypeRef)] {
        [(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
         (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue),
         (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
         (kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber),
         (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel),
         (kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber),
         (kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 2) as CFNumber),
         (kVTCompressionPropertyKey_AverageBitRate, (Int64(bitrateKbps) * 1_000) as CFNumber)]
    }

    /// The experiment is valid only when the encoder advertises the speed
    /// hint and every requested property, including that hint, is accepted.
    static func configure(_ properties: [(CFString, CFTypeRef)], speedHintSupported: Bool,
                          set: (CFString, CFTypeRef) -> OSStatus) -> Bool {
        guard speedHintSupported else { return false }
        return properties.allSatisfy { set($0.0, $0.1) == noErr }
    }

    static func supportsSpeedHint(_ supported: CFDictionary?) -> Bool {
        guard let supported else { return false }
        let key = Unmanaged.passUnretained(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality).toOpaque()
        return CFDictionaryContainsKey(supported, key)
    }
}

@available(macOS 26.0, *)
enum DesktopCBRConfiguration {
    static func specification() -> [CFString: Any] {
        [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    }
    static func properties(fps: UInt32, bitrateKbps: UInt32) -> [(CFString, CFTypeRef)] {
        [(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
         (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
         (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel),
         (kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber),
         (kVTCompressionPropertyKey_MaxKeyFrameInterval, 7200 as CFNumber),
         (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 240 as CFNumber),
         (kVTCompressionPropertyKey_ConstantBitRate, (Int64(bitrateKbps) * 1000) as CFNumber),
         (kVTCompressionPropertyKey_VBVBufferDuration, 0.1 as CFNumber)]
    }
    static func readNumber(_ session: VTCompressionSession, key: CFString) -> NSNumber? {
        // VTSessionCopyProperty returns a retained CF object through a void**.
        var raw: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(session, key: key, allocator: kCFAllocatorDefault, valueOut: &raw)
        let value = raw?.takeRetainedValue()
        return status == noErr ? value as? NSNumber : nil
    }
    // VideoToolbox may quantize a target slightly; reject a difference over
    // 1% or 1 kbit/s, whichever is greater, rather than call it CBR at the requested rate.
    static func rateMatches(requested: Int64, readback: Int64) -> Bool {
        guard requested > 0, readback > 0 else { return false }
        return abs(Double(readback) - Double(requested)) <= max(1000, Double(requested) * 0.01)
    }
    static func update(kbps: UInt32, fps: UInt32, set: (CFString, CFTypeRef) -> OSStatus) -> Bool {
        guard kbps > 0, fps > 0 else { return false }
        return set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber) == noErr &&
            set(kVTCompressionPropertyKey_ConstantBitRate, (Int64(kbps) * 1000) as CFNumber) == noErr
    }
}

/// Opt-in experimental encoder. Setup or unsupported-frame failures use the
/// stock encoder; no experimental object exists in Release builds.
final class DesktopLowLatencyH264Encoder: NSObject, LKRTCVideoEncoder, @unchecked Sendable {
    typealias SessionCreator = (Int32, Int32, CFDictionary, inout VTCompressionSession?) -> OSStatus
    private let fallback: any LKRTCVideoEncoder
    private let cbr: Bool
    private let trace: (([String: Any]) -> Void)?
    private let observeBytes: ((Int) -> Void)?
    private let sessionCreator: SessionCreator
    private let propertySetter: (VTCompressionSession, CFString, CFTypeRef) -> OSStatus
    private let lock = NSRecursiveLock()
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "latency.encoder")
    private var callback: RTCVideoEncoderCallback?
    private var session: VTCompressionSession?
    private var settings: LKRTCVideoEncoderSettings?
    private var cores: Int32 = 1
    private var usingFallback = false
    private var fallbackNeeded = false
    private var generation = 0
    private var keyframeGate = DesktopKeyframeGate()
    private var bitrateKbps: UInt32 = 0
    private var frameRate: UInt32 = UInt32(DesktopVideoQuality.f2FramesPerSecond)

    init(fallback: any LKRTCVideoEncoder, cbr: Bool = false, trace: (([String: Any]) -> Void)? = nil, observeBytes: ((Int) -> Void)? = nil, propertySetter: @escaping (VTCompressionSession, CFString, CFTypeRef) -> OSStatus = { VTSessionSetProperty($0, key: $1, value: $2) }, sessionCreator: @escaping SessionCreator = { width, height, specification, output in
        VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &output)
    }) {
        self.fallback = fallback; self.cbr = cbr; self.trace = trace; self.observeBytes = observeBytes; self.sessionCreator = sessionCreator; self.propertySetter = propertySetter; super.init()
    }

    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        lock.lock(); self.callback = callback; lock.unlock()
        if cbr, let callback, let observeBytes {
            fallback.setCallback { image, info in
                observeBytes(image.buffer.count)
                return callback(image, info)
            }
        } else { fallback.setCallback(callback) }
    }

    func startEncode(with settings: LKRTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        _ = release()
        self.settings = settings; self.cores = numberOfCores
        bitrateKbps = settings.startBitrate
        let captureRate = UInt32(DesktopVideoQuality.f2FramesPerSecond)
        frameRate = settings.maxFramerate > 0 ? (cbr ? settings.maxFramerate : min(settings.maxFramerate, captureRate)) : captureRate
        guard settings.width > 0, settings.height > 0 else { return startFallback() }
        let specification: [CFString: Any]
        if cbr {
            guard #available(macOS 26.0, *) else { return startFallback() }
            specification = DesktopCBRConfiguration.specification()
        } else { specification = DesktopEncoderConfiguration.specification() }
        var created: VTCompressionSession?
        let status = sessionCreator(Int32(settings.width), Int32(settings.height), specification as CFDictionary, &created)
        guard status == noErr, let created else {
            if let created { VTCompressionSessionInvalidate(created) }
            return startFallback()
        }
        let properties: [(CFString, CFTypeRef)]
        if cbr, #available(macOS 26.0, *) { properties = DesktopCBRConfiguration.properties(fps: frameRate, bitrateKbps: bitrateKbps) }
        else { properties = DesktopEncoderConfiguration.properties(fps: frameRate, bitrateKbps: bitrateKbps) }
        var supported: CFDictionary?
        let queried = VTSessionCopySupportedPropertyDictionary(created, supportedPropertyDictionaryOut: &supported) == noErr
        let speedHintSupported = queried && DesktopEncoderConfiguration.supportsSpeedHint(supported)
        guard cbr || speedHintSupported else {
            log.warning("F2 speed-priority hint is not advertised; using stock encoder")
            VTCompressionSessionInvalidate(created)
            return startFallback()
        }
        let configured: Bool
        if cbr {
            configured = properties.allSatisfy { propertySetter(created, $0.0, $0.1) == noErr }
        } else {
            configured = DesktopEncoderConfiguration.configure(properties, speedHintSupported: speedHintSupported,
                set: { VTSessionSetProperty(created, key: $0, value: $1) })
        }
        guard configured, VTCompressionSessionPrepareToEncodeFrames(created) == noErr else {
            VTCompressionSessionInvalidate(created)
            return startFallback()
        }
        if cbr, #available(macOS 26.0, *) {
            guard let seconds = DesktopCBRConfiguration.readNumber(created, key: kVTCompressionPropertyKey_VBVBufferDuration)?.doubleValue,
                  seconds.isFinite, abs(seconds - 0.1) < 0.001,
                  let readBitrate = DesktopCBRConfiguration.readNumber(created, key: kVTCompressionPropertyKey_ConstantBitRate)?.int64Value,
                  DesktopCBRConfiguration.rateMatches(requested: Int64(bitrateKbps) * 1000, readback: readBitrate) else {
                VTCompressionSessionInvalidate(created)
                return startFallback()
            }
            trace?(["type": "encoder_cbr", "event": "configured", "vbvMs": 100, "readbackMs": seconds * 1000, "bitrateBps": Int64(bitrateKbps) * 1000, "readbackBps": readBitrate])
        } else { log.notice("F2 VideoToolbox low-latency encoder active; speed-priority hint accepted") }
        lock.lock(); generation += 1; session = created; usingFallback = false; fallbackNeeded = false
        keyframeGate = DesktopKeyframeGate(); lock.unlock()
        return 0
    }

    private func startFallback() -> Int {
        guard let settings else { return -1 }
        lock.lock(); generation += 1; let old = session; session = nil; usingFallback = true; fallbackNeeded = false; lock.unlock()
        if let old { VTCompressionSessionInvalidate(old) }
        let result = fallback.startEncode(with: settings, numberOfCores: cores)
        if result == 0, bitrateKbps > 0 { _ = fallback.setBitrate(bitrateKbps, framerate: frameRate) }
        if cbr { trace?(["type": "encoder_cbr", "event": "fallback"]) }
        else { log.warning("F2 low-latency encoder unavailable; using stock encoder") }
        return result
    }

    func release() -> Int {
        lock.lock(); generation += 1; let old = session; session = nil
        let wasFallback = usingFallback; usingFallback = false; fallbackNeeded = false; lock.unlock()
        if let old { VTCompressionSessionInvalidate(old) }
        if wasFallback { return fallback.release() }
        return 0
    }

    static func acceptsCBRFrame(_ native: LKRTCCVPixelBuffer, frameWidth: Int32, frameHeight: Int32,
                                settings: LKRTCVideoEncoderSettings) -> Bool {
        // M144 native H.264 passes a larger, uncropped source buffer directly
        // to VideoToolbox when its configured output is smaller.
        native.cropX == 0 && native.cropY == 0 &&
        Int(native.cropWidth) == CVPixelBufferGetWidth(native.pixelBuffer) &&
        Int(native.cropHeight) == CVPixelBufferGetHeight(native.pixelBuffer) &&
        frameWidth == Int32(settings.width) && frameHeight == Int32(settings.height)
    }

    func encode(_ frame: LKRTCVideoFrame, codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?,
                frameTypes: [NSNumber]) -> Int {
        lock.lock(); let needsFallback = fallbackNeeded; let activeFallback = usingFallback; lock.unlock()
        if needsFallback {
            guard startFallback() == 0 else { return -1 }
            return fallback.encode(frame, codecSpecificInfo: info, frameTypes: [NSNumber(value: 3)])
        }
        if activeFallback {
            return fallback.encode(frame, codecSpecificInfo: info, frameTypes: frameTypes)
        }
        guard let native = frame.buffer as? LKRTCCVPixelBuffer, let settings,
              Self.acceptsCBRFrame(native, frameWidth: frame.width, frameHeight: frame.height, settings: settings),
              cbr || (CVPixelBufferGetWidth(native.pixelBuffer) == Int(settings.width) &&
                      CVPixelBufferGetHeight(native.pixelBuffer) == Int(settings.height)) else {
            guard startFallback() == 0 else { return -1 }
            return fallback.encode(frame, codecSpecificInfo: info, frameTypes: [NSNumber(value: 3)])
        }
        lock.lock()
        guard let current = session else { lock.unlock(); return -1 }
        let currentGeneration = generation
        let requestedKeyframe = frameTypes.contains { $0.uintValue == 3 }
        let keyframeTicket = cbr ? nil : keyframeGate.shouldForce(requested: requestedKeyframe,
                                                      now: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        let properties = (cbr ? requestedKeyframe : keyframeTicket != nil) ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let timestamp = frame.timeStamp, timestampNs = frame.timeStampNs, rotation = frame.rotation
        let width = frame.width, height = frame.height
        let status = VTCompressionSessionEncodeFrame(current, imageBuffer: native.pixelBuffer,
            presentationTimeStamp: CMTime(value: timestampNs, timescale: 1_000_000_000), duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil) { [weak self] status, flags, sample in
                self?.deliver(status: status, flags: flags, sample: sample, generation: currentGeneration,
                              timestamp: timestamp, timestampNs: timestampNs, rotation: rotation,
                              width: width, height: height, keyframeTicket: keyframeTicket)
            }
        if status != noErr {
            guard startFallback() == 0 else { return -1 }
            return fallback.encode(frame, codecSpecificInfo: info, frameTypes: [NSNumber(value: 3)])
        }
        return 0
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        lock.lock(); bitrateKbps = bitrateKbit; frameRate = framerate > 0 ? (cbr ? framerate : min(framerate, UInt32(DesktopVideoQuality.f2FramesPerSecond))) : frameRate
        let current = session, activeFallback = usingFallback, rate = frameRate; lock.unlock()
        if activeFallback { return fallback.setBitrate(bitrateKbit, framerate: framerate) }
        guard let current else { return -1 }
        let applied: Bool
        if cbr, #available(macOS 26.0, *) {
            let set = DesktopCBRConfiguration.update(kbps: bitrateKbit, fps: rate) { propertySetter(current, $0, $1) }
            let read = set ? DesktopCBRConfiguration.readNumber(current, key: kVTCompressionPropertyKey_ConstantBitRate)?.int64Value : nil
            let actual = read ?? 0
            applied = read != nil && DesktopCBRConfiguration.rateMatches(requested: Int64(bitrateKbit) * 1000, readback: actual)
            trace?(["type": "encoder_cbr", "event": "rate_update", "bitrateBps": Int64(bitrateKbit) * 1000, "readbackBps": actual, "applied": applied])
        } else {
            applied = DesktopEncoderRate.apply(kbps: bitrateKbit, fps: rate) { VTSessionSetProperty(current, key: $0, value: $1) }
        }
        if !applied {
            guard cbr || bitrateKbit > 0 else { return -1 }
            // Switch on the encoder's next frame so a failed optional VT
            // property update doesn't terminate the stream before fallback.
            lock.lock(); fallbackNeeded = true; lock.unlock()
        }
        return 0
    }

    func implementationName() -> String {
        lock.lock(); let activeFallback = usingFallback; lock.unlock()
        return activeFallback ? fallback.implementationName() : (cbr ? "DesktopCBRH264" : "DesktopLowLatencyH264")
    }
    private var isUsingFallback: Bool { lock.lock(); defer { lock.unlock() }; return usingFallback }
    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? {
        (cbr || isUsingFallback) ? fallback.scalingSettings() : nil
    }
    var resolutionAlignment: Int { isUsingFallback ? fallback.resolutionAlignment : 2 }
    var applyAlignmentToAllSimulcastLayers: Bool {
        isUsingFallback ? fallback.applyAlignmentToAllSimulcastLayers : false
    }
    var supportsNativeHandle: Bool { isUsingFallback ? fallback.supportsNativeHandle : true }

    private func requestFallback(generation: Int) {
        lock.lock(); defer { lock.unlock() }
        if generation == self.generation && !usingFallback { fallbackNeeded = true }
    }

    private func deliver(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?, generation: Int,
                         timestamp: Int32, timestampNs: Int64, rotation: LKRTCVideoRotation,
                         width: Int32, height: Int32, keyframeTicket: UInt64?) {
        lock.lock(); let current = generation == self.generation && !usingFallback; lock.unlock()
        guard current else { return }
        guard status == noErr else { requestFallback(generation: generation); return }
        guard !flags.contains(.frameDropped) else { return }
        guard let sample, CMSampleBufferDataIsReady(sample),
              let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else {
            requestFallback(generation: generation)
            return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        var lengthSize: Int32 = 0, parameterCount = 0
        var parameterSets: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?, length = 0
            let code = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &length,
                parameterSetCountOut: &parameterCount, nalUnitHeaderLengthOut: &lengthSize)
            guard code == noErr, let pointer, length > 0 else { requestFallback(generation: generation); return }
            parameterSets.append(Data(bytes: pointer, count: length))
        }
        guard DesktopH264AnnexB.isCompatibleSPS(parameterSets[0]) else {
            requestFallback(generation: generation); return
        }
        guard CMBlockBufferGetDataLength(block) > 0 else { requestFallback(generation: generation); return }
        var encoded = Data(count: CMBlockBufferGetDataLength(block))
        let copied = encoded.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        guard copied == noErr, let annexB = DesktopH264AnnexB.convert(encoded, lengthSize: Int(lengthSize),
                                                                       parameterSets: keyframe ? parameterSets : []) else {
            requestFallback(generation: generation); return
        }
        let image = LKRTCEncodedImage()
        image.buffer = annexB
        image.encodedWidth = width; image.encodedHeight = height
        image.timeStamp = UInt32(bitPattern: timestamp); image.captureTimeMs = timestampNs / 1_000_000
        image.rotation = rotation
        // No encoder timing timestamps are supplied by this adapter.
        image.flags = UInt8.max
        image.frameType = LKRTCFrameType(rawValue: keyframe ? 3 : 4)!
        image.contentType = LKRTCVideoContentType(rawValue: 1)!
        image.qp = NSNumber(value: -1)
        let info = LKRTCCodecSpecificInfoH264()
        info.packetizationMode = LKRTCH264PacketizationMode(rawValue: 0)!
        // Serialize the final validity check and callback with retirement so an
        // old VideoToolbox callback cannot publish after stock fallback starts.
        lock.lock()
        if generation == self.generation && !usingFallback {
            observeBytes?(annexB.count)
            if callback?(image, info) == true, keyframe, let keyframeTicket,
               generation == self.generation && !usingFallback {
                keyframeGate.acknowledge(keyframeTicket)
            }
        }
        lock.unlock()
    }
}
#endif
