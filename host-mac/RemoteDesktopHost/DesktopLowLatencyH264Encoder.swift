#if os(macOS)
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
    static func updateRate(kbps: UInt32, set: (CFString, CFTypeRef) -> OSStatus) -> Bool {
        guard kbps > 0 else { return false }
        return set(kVTCompressionPropertyKey_ConstantBitRate, (Int64(kbps) * 1000) as CFNumber) == noErr
    }
    static func update(kbps: UInt32, fps: UInt32, set: (CFString, CFTypeRef) -> OSStatus) -> Bool {
        guard kbps > 0, fps > 0 else { return false }
        return set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber) == noErr &&
            set(kVTCompressionPropertyKey_ConstantBitRate, (Int64(kbps) * 1000) as CFNumber) == noErr
    }
}

/// Every ConstantBitRate change makes VideoToolbox emit one frame holding about
/// 0.42 s of the new rate (126 KB at 2.4 Mbps), whatever the change or the width.
/// WebRTC sends small updates several times a second, so passing them through
/// floods the pacer. Only meaningful, sustained changes reach the encoder.
struct LabCBRRatePolicy {
    static let minimumDownInterval: TimeInterval = 1, raiseHold: TimeInterval = 2
    private(set) var appliedKbps: UInt32 = 0
    private var lastChange: TimeInterval = -.infinity
    private var raiseStart: TimeInterval?
    private var raiseFloor: UInt32 = 0
    mutating func reset() { self = LabCBRRatePolicy() }
    /// Returns the rate to apply now, or nil to keep the current one.
    mutating func decide(requestKbps: UInt32, now: TimeInterval, framesEncoded: Int) -> UInt32? {
        guard requestKbps > 0 else { return nil }
        // Before the first frame there is nothing to flood.
        if framesEncoded == 0 || appliedKbps == 0 { return commit(requestKbps, now) }
        let ratio = Double(requestKbps) / Double(appliedKbps)
        if ratio < 0.75 {
            raiseStart = nil
            return now - lastChange >= Self.minimumDownInterval ? commit(requestKbps, now) : nil
        }
        guard ratio > 1.3 else { raiseStart = nil; return nil }
        if raiseStart == nil { raiseStart = now; raiseFloor = requestKbps }
        raiseFloor = min(raiseFloor, requestKbps)
        guard now - raiseStart! >= Self.raiseHold, Double(raiseFloor) / Double(appliedKbps) > 1.3 else { return nil }
        return commit(raiseFloor, now)
    }
    private mutating func commit(_ kbps: UInt32, _ now: TimeInterval) -> UInt32 {
        appliedKbps = kbps; lastChange = now; raiseStart = nil; return kbps
    }
}

/// The bitrate minimum keeps a false estimate collapse (Wi-Fi delay spikes, not real
/// congestion) from blurring the stream. If a link really is slower than the minimum,
/// sustained loss or delay shows up here and the session gives the minimum up for good.
struct StreamFloorGuard {
    static let lossFraction = 0.05, lossPolls = 2
    static let roundTripSeconds = 0.5, roundTripPolls = 3
    private var lastSent: Double?, lastLost: Double?
    private var lossyPolls = 0, slowPolls = 0
    private(set) var released = false
    /// Returns true once, on the poll that should remove the minimum.
    mutating func observe(packetsSent: Double?, packetsLost: Double?, roundTrip: Double?) -> Bool {
        guard !released else { return false }
        if let packetsSent, let packetsLost, let lastSent, let lastLost {
            let sent = packetsSent - lastSent, lost = packetsLost - lastLost
            if sent > 0, lost >= 0 { lossyPolls = lost / (sent + lost) >= Self.lossFraction ? lossyPolls + 1 : 0 }
        }
        lastSent = packetsSent ?? lastSent; lastLost = packetsLost ?? lastLost
        if let roundTrip { slowPolls = roundTrip >= Self.roundTripSeconds ? slowPolls + 1 : 0 }
        if lossyPolls >= Self.lossPolls || slowPolls >= Self.roundTripPolls { released = true }
        return released
    }
}

final class LabEncoderCounters: @unchecked Sendable {
    private let lock = NSLock(); private var last = ProcessInfo.processInfo.systemUptime
    var calls = 0, outputs = 0, vtDropped = 0, busy = 0, bytes = 0, rateCalls = 0
    var lastFramerate: UInt32 = 0, lastKbps: UInt32 = 0, appliedKbps: UInt32 = 0, width: Int32 = 0
    func bump(_ body: (LabEncoderCounters) -> Void, emit: ([String: Any]) -> Void) {
        lock.lock(); body(self); let now = ProcessInfo.processInfo.systemUptime
        var row: [String: Any]?
        if now - last >= 1 {
            row = ["type": "encoder_counts", "time": now, "seconds": now - last, "calls": calls, "outputs": outputs, "vtDropped": vtDropped,
                   "busy": busy, "bytes": bytes, "rateCalls": rateCalls, "framerate": lastFramerate, "kbps": lastKbps, "appliedKbps": appliedKbps, "width": width]
            calls = 0; outputs = 0; vtDropped = 0; busy = 0; bytes = 0; rateCalls = 0; last = now
        }
        lock.unlock(); if let row { emit(row) }
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
    // VideoToolbox's remote encoder can block forever if a property call races a
    // frame in flight, so CBR rate changes wait until encode() finds it idle.
    private var cbrInFlight = 0
    private var cbrPendingKbps: UInt32?
    private var cbrPolicy = LabCBRRatePolicy()
    private var cbrFramesEncoded = 0
    private let counters = LabEncoderCounters()
    private func count(_ body: (LabEncoderCounters) -> Void) { if cbr { counters.bump(body) { [trace] in trace?($0) } } }

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
        frameRate = cbr ? captureRate : (settings.maxFramerate > 0 ? min(settings.maxFramerate, captureRate) : captureRate)
        cbrInFlight = 0; cbrPendingKbps = nil; cbrPolicy.reset(); cbrFramesEncoded = 0
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
        count { $0.calls += 1; $0.width = frame.width }
        lock.lock(); let needsFallback = fallbackNeeded; let activeFallback = usingFallback; lock.unlock()
        if needsFallback {
            guard startFallback() == 0 else { return -1 }
            return fallback.encode(frame, codecSpecificInfo: info, frameTypes: [NSNumber(value: 3)])
        }
        if activeFallback {
            return fallback.encode(frame, codecSpecificInfo: info, frameTypes: frameTypes)
        }
        guard let native = frame.buffer as? LKRTCCVPixelBuffer, let settings,
              cbr ? (frame.width >= Int32(settings.width) && frame.height >= Int32(settings.height))
                  : (frame.width == Int32(settings.width) && frame.height == Int32(settings.height)),
              cbr || (Self.acceptsCBRFrame(native, frameWidth: frame.width, frameHeight: frame.height, settings: settings) &&
                      CVPixelBufferGetWidth(native.pixelBuffer) == Int(settings.width) &&
                      CVPixelBufferGetHeight(native.pixelBuffer) == Int(settings.height)) else {
            guard startFallback() == 0 else { return -1 }
            return fallback.encode(frame, codecSpecificInfo: info, frameTypes: [NSNumber(value: 3)])
        }
        var pixelBuffer = native.pixelBuffer
        if cbr, native.requiresCropping() {
            // Odd adapted heights (1644/4 = 411 -> 410) arrive cropped; stock crops them too.
            var output: CVPixelBuffer?
            let created = CVPixelBufferCreate(kCFAllocatorDefault, Int(frame.width), Int(frame.height),
                                              CVPixelBufferGetPixelFormatType(pixelBuffer), nil, &output)
            guard created == kCVReturnSuccess, let output else { return 0 }
            let count = Int(native.bufferSizeForCroppingAndScaling(toWidth: frame.width, height: frame.height))
            var scratch = [UInt8](repeating: 0, count: max(1, count))
            guard scratch.withUnsafeMutableBufferPointer({ native.cropAndScale(to: output, withTempBuffer: $0.baseAddress) }) else { return 0 }
            pixelBuffer = output
        }
        lock.lock()
        guard let current = session else { lock.unlock(); return -1 }
        let currentGeneration = generation
        let requestedKeyframe = frameTypes.contains { $0.uintValue == 3 }
        let keyframeTicket = cbr ? nil : keyframeGate.shouldForce(requested: requestedKeyframe,
                                                      now: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        let properties = (cbr ? requestedKeyframe : keyframeTicket != nil) ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        if cbr { applyPendingCBRRate(current) }
        if cbr { lock.lock(); cbrInFlight += 1; lock.unlock() }
        let timestamp = frame.timeStamp, timestampNs = frame.timeStampNs, rotation = frame.rotation
        // With a scale-down, WebRTC passes the full frame and VideoToolbox scales it to the session size.
        let width = cbr ? Int32(settings.width) : frame.width, height = cbr ? Int32(settings.height) : frame.height
        let status = VTCompressionSessionEncodeFrame(current, imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: timestampNs, timescale: 1_000_000_000), duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil) { [weak self] status, flags, sample in
                self?.deliver(status: status, flags: flags, sample: sample, generation: currentGeneration,
                              timestamp: timestamp, timestampNs: timestampNs, rotation: rotation,
                              width: width, height: height, keyframeTicket: keyframeTicket)
            }
        if status != noErr {
            if cbr { lock.lock(); cbrInFlight = max(0, cbrInFlight - 1); lock.unlock() }
            guard startFallback() == 0 else { return -1 }
            return fallback.encode(frame, codecSpecificInfo: info, frameTypes: [NSNumber(value: 3)])
        }
        return 0
    }

    private func applyPendingCBRRate(_ current: VTCompressionSession) {
        guard #available(macOS 26.0, *) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        cbrFramesEncoded += 1
        guard cbrInFlight == 0, let request = cbrPendingKbps,
              let kbps = cbrPolicy.decide(requestKbps: request, now: now, framesEncoded: cbrFramesEncoded - 1) else { lock.unlock(); return }
        lock.unlock()
        let set = DesktopCBRConfiguration.updateRate(kbps: kbps) { propertySetter(current, $0, $1) }
        let read = set ? DesktopCBRConfiguration.readNumber(current, key: kVTCompressionPropertyKey_ConstantBitRate)?.int64Value : nil
        let actual = read ?? 0
        let applied = read != nil && DesktopCBRConfiguration.rateMatches(requested: Int64(kbps) * 1000, readback: actual)
        trace?(["type": "encoder_cbr", "event": "rate_update", "bitrateBps": Int64(kbps) * 1000, "readbackBps": actual, "applied": applied])
        count { $0.appliedKbps = kbps }
        if !applied { lock.lock(); fallbackNeeded = true; lock.unlock() }
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        count { $0.rateCalls += 1; $0.lastFramerate = framerate; $0.lastKbps = bitrateKbit }
        lock.lock(); bitrateKbps = bitrateKbit
        if !cbr, framerate > 0 { frameRate = min(framerate, UInt32(DesktopVideoQuality.f2FramesPerSecond)) }
        let current = session, activeFallback = usingFallback, rate = frameRate
        if cbr, !activeFallback, current != nil, bitrateKbit > 0 { cbrPendingKbps = bitrateKbit; lock.unlock(); return 0 }
        lock.unlock()
        if activeFallback { return fallback.setBitrate(bitrateKbit, framerate: framerate) }
        guard let current else { return -1 }
        let applied = DesktopEncoderRate.apply(kbps: bitrateKbit, fps: rate) { VTSessionSetProperty(current, key: $0, value: $1) }
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
        if cbr { lock.lock(); if generation == self.generation { cbrInFlight = max(0, cbrInFlight - 1) }; lock.unlock() }
        lock.lock(); let current = generation == self.generation && !usingFallback; lock.unlock()
        guard current else { return }
        guard status == noErr else { requestFallback(generation: generation); return }
        guard !flags.contains(.frameDropped) else { count { $0.vtDropped += 1 }; return }
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
            count { $0.outputs += 1; $0.bytes += annexB.count }
            if callback?(image, info) == true, keyframe, let keyframeTicket,
               generation == self.generation && !usingFallback {
                keyframeGate.acknowledge(keyframeTicket)
            }
        }
        lock.unlock()
    }
}
#if DEBUG
// One in-flight delivery only. Cancellation revokes queued generations without
// waiting for an external WebRTC callback to return.
final class LabHEVCDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "latency.hevc.delivery")
    private var generation: UInt64 = 0
    private var active = false
    private var reservation: UInt64?
    private var reservationGeneration: UInt64 = 0
    private var nextTicket: UInt64 = 0
    private var delivering = false
    func start() { lock.lock(); generation &+= 1; active = true; lock.unlock() }
    func stop() {
        lock.lock(); generation &+= 1; active = false
        if !delivering { reservation = nil }; lock.unlock()
    }
    func reserve() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard active, reservation == nil else { return nil }
        nextTicket &+= 1; reservation = nextTicket; reservationGeneration = generation; return nextTicket
    }
    func complete(_ ticket: UInt64) {
        lock.lock(); if reservation == ticket { reservation = nil; delivering = false }; lock.unlock()
    }
    func deliver(_ ticket: UInt64, callback: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard active, generation == reservationGeneration, reservation == ticket, !delivering else { lock.unlock(); return false }
        delivering = true; let admittedGeneration = generation; lock.unlock()
        queue.async { [self] in
            lock.lock(); let permitted = active && generation == admittedGeneration && reservation == ticket; lock.unlock()
            if permitted { callback() }
            complete(ticket)
        }
        return true
    }
}
struct LabHEVCKeyframeLatch {
    private var requested: UInt64 = 0
    private var acknowledged: UInt64 = 0
    mutating func request() { requested &+= 1 }
    var pending: UInt64? { requested == acknowledged ? nil : requested }
    mutating func acknowledge(_ ticket: UInt64) { if ticket > acknowledged { acknowledged = ticket } }
}

@available(macOS 26.0, *)
final class LabHEVCEncoder: NSObject, LKRTCVideoEncoder, @unchecked Sendable {
    private let native: any LKRTCVideoEncoder
    private let info: any LKRTCCodecSpecificInfo
    private let trace: ([String: Any]) -> Void
    private let observeBytes: ((Int) -> Void)?
    private let gate = LabHEVCDeliveryGate()
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var callback: RTCVideoEncoderCallback?
    private var settings: LKRTCVideoEncoderSettings?
    private var cores: Int32 = 1
    private var fallback = false
    private var fallbackPending = false
    private var spsRejected = false
    private var nativeTicket: UInt64?
    private var nativeSPSAccepted = false
    private var keyframes = LabHEVCKeyframeLatch()
    private var nativeKeyframeTicket: UInt64?
    private var generation: UInt64 = 0
    private var rate: UInt32 = 0
    private var fps: UInt32 = 60
    private var pendingRate: UInt32?
    private var policy = LabCBRRatePolicy()
    private var framesEncoded = 0
    private let counters = LabEncoderCounters()
    private func count(_ body: (LabEncoderCounters) -> Void) { counters.bump(body) { [trace] in trace($0) } }

    static func makeInfo(lookup: (String) -> AnyClass? = { NSClassFromString($0) }) -> (any LKRTCCodecSpecificInfo)? {
        guard let type = lookup("LKRTCCodecSpecificInfoH265") as? NSObject.Type else { return nil }
        return type.init() as? any LKRTCCodecSpecificInfo
    }
    init(native: any LKRTCVideoEncoder, info: any LKRTCCodecSpecificInfo, observeBytes: ((Int) -> Void)? = nil, trace: @escaping ([String: Any]) -> Void) {
        self.native = native; self.info = info; self.observeBytes = observeBytes; self.trace = trace; super.init()
    }
    private static func properties(_ fps: UInt32, _ kbps: UInt32) -> [(CFString, CFTypeRef)] {
        [(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
         (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
         (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel),
         (kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber),
         (kVTCompressionPropertyKey_MaxKeyFrameInterval, 7200 as CFNumber),
         (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 240 as CFNumber),
         (kVTCompressionPropertyKey_ConstantBitRate, (Int64(kbps) * 1000) as CFNumber),
         (kVTCompressionPropertyKey_VBVBufferDuration, 0.1 as CFNumber)]
    }
    private static func makeSession(width: Int32, height: Int32, fps: UInt32, kbps: UInt32) -> VTCompressionSession? {
        guard width > 0, height > 0, fps > 0, kbps > 0 else { return nil }
        var created: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created) == noErr,
            let created else { return nil }
        let configured = properties(fps, kbps).allSatisfy { VTSessionSetProperty(created, key: $0.0, value: $0.1) == noErr }
        let seconds = DesktopCBRConfiguration.readNumber(created, key: kVTCompressionPropertyKey_VBVBufferDuration)?.doubleValue
        let actual = DesktopCBRConfiguration.readNumber(created, key: kVTCompressionPropertyKey_ConstantBitRate)?.int64Value
        guard configured, let seconds, abs(seconds - 0.1) < 0.001, let actual,
              DesktopCBRConfiguration.rateMatches(requested: Int64(kbps) * 1000, readback: actual),
              VTCompressionSessionPrepareToEncodeFrames(created) == noErr else {
            VTCompressionSessionInvalidate(created); return nil
        }
        return created
    }
    static func preflight() -> Bool {
        guard makeInfo() != nil, LKRTCDefaultVideoEncoderFactory().createEncoder(LKRTCVideoCodecInfo(name: "H265")) != nil,
              let session = makeSession(width: 2544, height: 1644, fps: 60, kbps: 3000) else { return false }
        VTCompressionSessionInvalidate(session); return true
    }
    func setCallback(_ cb: RTCVideoEncoderCallback?) {
        lock.lock(); callback = cb; lock.unlock()
        native.setCallback { [weak self] image, metadata in
            guard let self else { return false }
            self.lock.lock(); let ticket = self.nativeTicket; self.nativeTicket = nil; let accepted = self.nativeSPSAccepted; let keyTicket = self.nativeKeyframeTicket; self.nativeKeyframeTicket = nil; let callbackGeneration = self.generation; self.lock.unlock()
            guard let ticket else { return false }
            let key = image.frameType.rawValue == 3
            if key || !accepted {
                guard key, Self.annexBContainsAcceptedSPS(image.buffer) else {
                    self.gate.complete(ticket)
                    self.lock.lock(); self.spsRejected = true; self.lock.unlock()
                    self.trace(["type": "encoder_hevc", "event": "native_sps_rejected", "time": ProcessInfo.processInfo.systemUptime])
                    return false
                }
                self.lock.lock(); self.nativeSPSAccepted = true; self.lock.unlock()
            }
            return self.gate.deliver(ticket) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let cb = self.callback; self.lock.unlock()
                self.observeBytes?(image.buffer.count)
                if cb?(image, metadata) == true, key, let keyTicket {
                    self.lock.lock(); if self.generation == callbackGeneration { self.keyframes.acknowledge(keyTicket) }; self.lock.unlock()
                }
            }
        }
    }
    func startEncode(with settings: LKRTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        _ = release(); self.settings = settings; cores = numberOfCores; rate = settings.startBitrate
        fps = 60; pendingRate = nil; policy.reset(); framesEncoded = 0
        gate.start()
        guard let created = Self.makeSession(width: Int32(settings.width), height: Int32(settings.height), fps: fps, kbps: rate) else {
            return startFallback()
        }
        lock.lock(); generation &+= 1; session = created; fallback = false; fallbackPending = false; spsRejected = false; keyframes = LabHEVCKeyframeLatch(); lock.unlock()
        let actualRate = DesktopCBRConfiguration.readNumber(created, key: kVTCompressionPropertyKey_ConstantBitRate)?.int64Value ?? 0
        let actualVBV = DesktopCBRConfiguration.readNumber(created, key: kVTCompressionPropertyKey_VBVBufferDuration)?.doubleValue ?? 0
        trace(["type": "encoder_hevc", "event": "configured", "time": ProcessInfo.processInfo.systemUptime, "rateBps": Int64(rate)*1000, "readbackBps": actualRate, "readbackVBVMs": actualVBV * 1000])
        return 0
    }
    private func retire(_ old: VTCompressionSession?) {
        if let old { DispatchQueue.global(qos: .userInitiated).async { VTCompressionSessionInvalidate(old) } }
    }
    private func startFallback() -> Int {
        guard let settings else { return -1 }
        lock.lock(); generation &+= 1; let old = session; session = nil; fallback = true; fallbackPending = false; nativeSPSAccepted = false; lock.unlock()
        gate.stop(); gate.start()
        retire(old)
        let result = native.startEncode(with: settings, numberOfCores: cores)
        if result == 0, rate > 0 { _ = native.setBitrate(rate, framerate: fps) }
        trace(["type": "encoder_hevc", "event": "native_hevc_fallback", "time": ProcessInfo.processInfo.systemUptime])
        return result
    }
    func release() -> Int {
        gate.stop()
        lock.lock(); generation &+= 1; let old = session; session = nil; let wasFallback = fallback; fallback = false; fallbackPending = false; nativeTicket = nil; nativeKeyframeTicket = nil; lock.unlock()
        retire(old)
        if wasFallback { return native.release() }
        return 0
    }
    func encode(_ frame: LKRTCVideoFrame, codecSpecificInfo: (any LKRTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        lock.lock()
        if frameTypes.contains(where: { $0.uintValue == 3 }) { keyframes.request() }
        let keyTicket = keyframes.pending
        let useNative = fallback; let needFallback = fallbackPending; let rejected = spsRejected; let current = session; let ticket = generation; lock.unlock()
        if rejected { return -1 }
        if needFallback { guard startFallback() == 0 else { return -1 }; return encode(frame, codecSpecificInfo: codecSpecificInfo, frameTypes: [3]) }
        count { $0.calls += 1; $0.width = frame.width }
        guard let deliveryTicket = gate.reserve() else { count { $0.busy += 1 }; return 0 }
        if useNative {
            lock.lock(); nativeTicket = deliveryTicket; nativeKeyframeTicket = keyTicket; lock.unlock()
            let requestedTypes: [NSNumber] = keyTicket != nil ? [3] : frameTypes
            let result = native.encode(frame, codecSpecificInfo: codecSpecificInfo, frameTypes: requestedTypes)
            if result != 0 { lock.lock(); nativeTicket = nil; lock.unlock(); gate.complete(deliveryTicket) }
            return result
        }
        guard let current, let settings, let source = frame.buffer as? LKRTCCVPixelBuffer,
              frame.width >= Int32(settings.width), frame.height >= Int32(settings.height) else {
            gate.complete(deliveryTicket)
            guard startFallback() == 0 else { return -1 }; return encode(frame, codecSpecificInfo: codecSpecificInfo, frameTypes: [3])
        }
        var pixel = source.pixelBuffer
        if source.requiresCropping() {
            var output: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, Int(frame.width), Int(frame.height),
                CVPixelBufferGetPixelFormatType(pixel), nil, &output)
            guard result == kCVReturnSuccess, let output else { gate.complete(deliveryTicket); lock.lock(); if ticket == generation { fallbackPending = true }; lock.unlock(); return 0 }
            let count = Int(source.bufferSizeForCroppingAndScaling(toWidth: frame.width, height: frame.height))
            var tmp = [UInt8](repeating: 0, count: max(1, count))
            let ok = tmp.withUnsafeMutableBufferPointer { source.cropAndScale(to: output, withTempBuffer: $0.baseAddress) }
            guard ok else { gate.complete(deliveryTicket); lock.lock(); if ticket == generation { fallbackPending = true }; lock.unlock(); return 0 }
            pixel = output
        }
        applyPendingRate(current) // The reserved gate means no frame is in flight here.
        let force = keyTicket != nil ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let ts = frame.timeStamp, ns = frame.timeStampNs, rot = frame.rotation, width = Int32(settings.width), height = Int32(settings.height)
        let status = VTCompressionSessionEncodeFrame(current, imageBuffer: pixel, presentationTimeStamp: CMTime(value: ns, timescale: 1_000_000_000), duration: .invalid, frameProperties: force, infoFlagsOut: nil) { [weak self] status, flags, sample in
            self?.deliver(status: status, flags: flags, sample: sample, ticket: ticket, deliveryTicket: deliveryTicket, keyTicket: keyTicket, ts: ts, ns: ns, rotation: rot, width: width, height: height)
        }
        if status != noErr { gate.complete(deliveryTicket); lock.lock(); if ticket == generation { fallbackPending = true }; lock.unlock() }
        return 0
    }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        // A VideoToolbox property call racing a frame in flight can block the remote
        // encoder forever. encode() applies this while the gate shows nothing in flight.
        count { $0.rateCalls += 1; $0.lastFramerate = framerate; $0.lastKbps = bitrateKbit }
        lock.lock(); rate = bitrateKbit; let current = session; let nativeActive = fallback
        if !nativeActive, current != nil, bitrateKbit > 0 { pendingRate = bitrateKbit }
        lock.unlock()
        if nativeActive { return native.setBitrate(bitrateKbit, framerate: framerate) }
        return current == nil ? -1 : 0
    }
    private func applyPendingRate(_ current: VTCompressionSession) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        framesEncoded += 1
        guard let request = pendingRate,
              let kbps = policy.decide(requestKbps: request, now: now, framesEncoded: framesEncoded - 1) else { lock.unlock(); return }
        lock.unlock()
        let set = DesktopCBRConfiguration.updateRate(kbps: kbps) { VTSessionSetProperty(current, key: $0, value: $1) }
        let actual = set ? DesktopCBRConfiguration.readNumber(current, key: kVTCompressionPropertyKey_ConstantBitRate)?.int64Value : nil
        let applied = actual.map { DesktopCBRConfiguration.rateMatches(requested: Int64(kbps)*1000, readback: $0) } ?? false
        trace(["type": "encoder_hevc", "event": "rate_update", "time": ProcessInfo.processInfo.systemUptime, "requestedBps": Int64(kbps)*1000, "readbackBps": actual ?? 0, "applied": applied])
        count { $0.appliedKbps = kbps }
        if !applied { lock.lock(); fallbackPending = true; lock.unlock() }
    }
    func implementationName() -> String { "LabHEVCEncoder" }
    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? { native.scalingSettings() }
    var resolutionAlignment: Int { native.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool { native.applyAlignmentToAllSimulcastLayers }
    var supportsNativeHandle: Bool { true }
    static func annexBContainsAcceptedSPS(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if i + 4 <= bytes.count, bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 {
                starts.append((i, i+4)); i += 4
            } else if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 1 {
                starts.append((i, i+3)); i += 3
            } else { i += 1 }
        }
        for n in starts.indices {
            let start = starts[n].1, end = n+1 < starts.count ? starts[n+1].0 : bytes.count
            if start < end, (bytes[start] >> 1) & 0x3f == 33 { return acceptsSPS(Data(bytes[start..<end])) }
        }
        return false
    }
    static func acceptsSPS(_ sps: Data) -> Bool {
        guard sps.count >= 2 else { return false }
        var rbsp: [UInt8] = []; var zeroes = 0
        for b in sps.dropFirst(2) {
            if zeroes >= 2 && b == 3 { zeroes = 0; continue }
            rbsp.append(b); zeroes = b == 0 ? zeroes + 1 : 0
        }
        return rbsp.count > 12 && rbsp[1] & 0xc0 == 0 && rbsp[1] & 0x1f == 1 && rbsp[1] & 0x20 == 0 &&
            [UInt8(30), 60, 63, 90, 93, 120, 123, 150, 153].contains(rbsp[12])
    }
    private func deliver(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?, ticket: UInt64, deliveryTicket: UInt64, keyTicket: UInt64?, ts: Int32, ns: Int64, rotation: LKRTCVideoRotation, width: Int32, height: Int32) {
        var handedOff = false
        defer { if !handedOff { gate.complete(deliveryTicket) } }
        lock.lock(); let valid = ticket == generation && !fallback; lock.unlock()
        guard valid else { return }
        if flags.contains(.frameDropped) { count { $0.vtDropped += 1 }; return }
        guard status == noErr, let sample, CMSampleBufferDataIsReady(sample),
              let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else {
            lock.lock(); if ticket == generation { fallbackPending = true }; lock.unlock(); return
        }
        var parameterSets: [Data] = []; var lengthSize: Int32 = 0, count = 0
        for index in 0..<3 {
            var ptr: UnsafePointer<UInt8>?, len = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &ptr, parameterSetSizeOut: &len, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize) == noErr, let ptr, len > 0 else {
                lock.lock(); if ticket == generation { fallbackPending = true }; lock.unlock(); return
            }
            parameterSets.append(Data(bytes: ptr, count: len))
        }
        guard Self.acceptsSPS(parameterSets[1]) else {
            // Never substitute a possibly out-of-profile stream inside negotiated HEVC.
            lock.lock(); let current = ticket == generation; let old = current ? session : nil
            if current { session = nil; spsRejected = true; generation &+= 1 }; lock.unlock()
            guard current else { return }
            retire(old); gate.stop()
            trace(["type": "encoder_hevc", "event": "sps_rejected", "time": ProcessInfo.processInfo.systemUptime])
            return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        let byteCount = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: byteCount)
        guard byteCount > 0, bytes.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!) }) == noErr,
              let annex = DesktopH264AnnexB.convert(bytes, lengthSize: Int(lengthSize), parameterSets: key ? parameterSets : []) else {
            lock.lock(); if ticket == generation { fallbackPending = true }; lock.unlock(); return
        }
        let image = LKRTCEncodedImage(); image.buffer = annex; image.encodedWidth = width; image.encodedHeight = height
        image.timeStamp = UInt32(bitPattern: ts); image.captureTimeMs = ns / 1_000_000; image.rotation = rotation
        image.flags = UInt8.max; image.frameType = LKRTCFrameType(rawValue: key ? 3 : 4)!; image.contentType = LKRTCVideoContentType(rawValue: 1)!; image.qp = NSNumber(value: -1)
        handedOff = gate.deliver(deliveryTicket) { [weak self] in
            guard let self else { return }; self.lock.lock(); let cb = self.callback; self.lock.unlock()
            self.observeBytes?(image.buffer.count)
            self.count { $0.outputs += 1; $0.bytes += image.buffer.count }
            if cb?(image, self.info) == true, key, let keyTicket {
                self.lock.lock(); if self.generation == ticket { self.keyframes.acknowledge(keyTicket) }; self.lock.unlock()
            }
        }
    }
}

@available(macOS 26.0, *)
final class LabHEVCEncoderFactory: NSObject, LKRTCVideoEncoderFactory {
    private let base: DesktopVideoEncoderFactory
    private let trace: ([String: Any]) -> Void
    private let observeBytes: ((Int) -> Void)?
    init(base: DesktopVideoEncoderFactory, observeBytes: ((Int) -> Void)?, trace: @escaping ([String: Any]) -> Void) {
        self.base = base; self.observeBytes = observeBytes; self.trace = trace; super.init()
    }
    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        [LKRTCVideoCodecInfo(name: "H265", parameters: ["profile-id": "1", "tier-flag": "0", "level-id": "153"])] + base.supportedCodecs()
    }
    func createEncoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoEncoder)? {
        guard info.name.uppercased() == "H265" else { return base.createEncoder(info) }
        guard let native = LKRTCDefaultVideoEncoderFactory().createEncoder(info), let metadata = LabHEVCEncoder.makeInfo() else { return nil }
        return LabHEVCEncoder(native: native, info: metadata, observeBytes: observeBytes, trace: trace)
    }
}
#endif
#endif
