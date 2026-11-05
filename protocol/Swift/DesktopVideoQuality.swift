import Foundation
import LiveKitWebRTC

/// Shared desktop-video policy for the Apple host and viewer.
///
/// WebRTC owns congestion control. Legacy sessions retain the 30 fps
/// sharpness policy; negotiated adaptive sessions prefer frame rate at 60 fps
/// and allow WebRTC to reduce image quality or resolution when constrained.
enum DesktopVideoQuality {
    static let targetFramesPerSecond = 30
    static let adaptiveFramesPerSecond = 60
    static let adaptiveMaximumMacroblocksPerFrame = 16_384
    static let f2FramesPerSecond = 60
    static let f2MaximumMacroblocksPerFrame = 16_384
    static let maximumBitrateBps = 30_000_000
    static let maximumBitrateKbps = maximumBitrateBps / 1_000
    static let captureQueueDepth = 3

    /// H.264 level 5.1 permits 36,864 macroblocks per frame and 983,040
    /// macroblocks per second. At 30 fps, the rate limit is the tighter one:
    /// 32,768 macroblocks per frame. This keeps a Retina laptop or 4K display
    /// native while retaining enough encode time for a real-time stream.
    /// Level 3.1, which the stock WebRTC factory advertises, permits only 3,600
    /// macroblocks and forced the previous stream down to roughly 768p.
    static let preferredH264LevelIDC = "33"
    static let preferredH264MaximumMacroblocksPerFrame = 32_768
    static let fallbackH264MaximumMacroblocksPerFrame = 3_600
    static let softwareCodecMaximumMacroblocksPerFrame = 8_704
    static let maximumEncodedDimension = 3_840

    struct CapturePolicy: Equatable {
        let framesPerSecond: Int32
        let maximumMacroblocksPerFrame: Int
        let lowLatencyEncoder: Bool
    }

    static func supportsExperimentalEncoder(name: String, profileLevelID: String?, packetizationMode: String?) -> Bool {
        name.caseInsensitiveCompare("H264") == .orderedSame &&
            profileLevelID?.lowercased() == "640c33" && packetizationMode == "1"
    }

    /// F2 uses a level-5.1-safe size at 60 fps; legacy and software peers stay unchanged.
    static func capturePolicy(negotiatedCodecs: [LKRTCRtpCodecParameters], f2Requested: Bool) -> CapturePolicy {
        let current = maximumMacroblocksPerFrame(negotiatedCodecs: negotiatedCodecs)
        let codec = negotiatedCodecs.first(where: {
            ["H264", "VP8", "VP9", "AV1"].contains($0.name.uppercased())
        })
        let mode = codec?.parameters["packetization-mode"]
        return capturePolicy(name: codec?.name, profileLevelID: codec?.parameters["profile-level-id"] as? String,
                             packetizationMode: (mode as? String) ?? (mode as? NSNumber)?.stringValue,
                             currentLimit: current, f2Requested: f2Requested)
    }

    static func capturePolicy(name: String?, profileLevelID: String?, packetizationMode: String?,
                              currentLimit: Int, f2Requested: Bool) -> CapturePolicy {
        #if DEBUG && os(macOS)
        guard f2Requested, let name, supportsExperimentalEncoder(name: name,
              profileLevelID: profileLevelID, packetizationMode: packetizationMode) else {
            return CapturePolicy(framesPerSecond: Int32(targetFramesPerSecond),
                                 maximumMacroblocksPerFrame: currentLimit, lowLatencyEncoder: false)
        }
        return CapturePolicy(framesPerSecond: Int32(f2FramesPerSecond),
                             maximumMacroblocksPerFrame: min(currentLimit, f2MaximumMacroblocksPerFrame),
                             lowLatencyEncoder: true)
        #else
        return CapturePolicy(framesPerSecond: Int32(targetFramesPerSecond),
                             maximumMacroblocksPerFrame: currentLimit, lowLatencyEncoder: false)
        #endif
    }

    static func senderFrameRate(policyRate: Int, captureRate: Int32, isDefault: Bool) -> Int {
        isDefault && captureRate == Int32(f2FramesPerSecond) ? f2FramesPerSecond : policyRate
    }

    struct SenderPolicy: Equatable {
        let maximumFramesPerSecond: Int
        let maximumBitrateBps: Int
        let degradationPreference: LKRTCDegradationPreference
    }

    static let sharpnessPolicy = SenderPolicy(
        maximumFramesPerSecond: targetFramesPerSecond,
        maximumBitrateBps: maximumBitrateBps,
        degradationPreference: .maintainResolution)

    /// The first primary codec must be the validated H.264 profile. Unknown,
    /// older and software codecs retain their existing capture policy.
    static func supportsAdaptive60(name: String?, profileLevelID: String?, packetizationMode: String?) -> Bool {
        name?.uppercased() == "H264" && profileLevelID?.lowercased() == "640c33" && packetizationMode == "1"
    }

    /// The answer's video m-line carries codec preference order. WebRTC's
    /// receiver codec parameter array does not necessarily preserve that order.
    static func supportsAdaptive60(answerSDP: String) -> Bool {
        guard answerSDP.utf8.count <= 1_000_000 else { return false }
        let lines = answerSDP.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let videoSections = lines.indices.filter { lines[$0].hasPrefix("m=video ") }
        guard videoSections.count == 1, let videoStart = videoSections.first else { return false }
        let media = lines[videoStart].split(separator: " ")
        guard media.count > 3, let port = Int(media[1]), port > 0, port <= 65_535,
              Set(media.dropFirst(3)).count == media.count - 3 else { return false }
        let end = lines[(videoStart + 1)...].firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.endIndex
        let section = lines[(videoStart + 1)..<end]
        guard !section.contains("a=inactive"), !section.contains("a=recvonly") else { return false }
        for payload in media.dropFirst(3) {
            let prefix = "a=rtpmap:\(payload) "
            let mappings = section.filter { $0.hasPrefix(prefix) }
            guard mappings.count == 1, let mapping = mappings.first else { return false }
            let name = mapping.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? ""
            if ["RTX", "RED", "ULPFEC", "FLEXFEC-03"].contains(name.uppercased()) { continue }
            let fmtpPrefix = "a=fmtp:\(payload) "
            let formatParameters = section.filter { $0.hasPrefix(fmtpPrefix) }
            guard formatParameters.count == 1, let fmtp = formatParameters.first else { return false }
            let pairs = fmtp.dropFirst(fmtpPrefix.count).split(separator: ";")
            var parameters: [String: String] = [:]
            for pair in pairs {
                let parts = pair.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
                guard parts.count == 2, parameters[parts[0]] == nil else { return false }
                parameters[parts[0]] = parts[1]
            }
            return supportsAdaptive60(name: name, profileLevelID: parameters["profile-level-id"],
                                      packetizationMode: parameters["packetization-mode"])
        }
        return false
    }

    #if DEBUG
    /// Identify the selected primary codec without trusting advertised sender parameters.
    static func labAnswerPrimaryCodec(answerSDP: String) -> String? {
        guard answerSDP.utf8.count <= 1_000_000 else { return nil }
        let lines = answerSDP.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let starts = lines.indices.filter { lines[$0].hasPrefix("m=video ") }
        guard starts.count == 1, let start = starts.first else { return nil }
        let media = lines[start].split(separator: " ")
        guard media.count > 3, let port = Int(media[1]), port > 0, port <= 65_535,
              Set(media.dropFirst(3)).count == media.count - 3 else { return nil }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.endIndex
        let section = lines[(start + 1)..<end]
        guard !section.contains("a=inactive"), !section.contains("a=recvonly") else { return nil }
        for payload in media.dropFirst(3) {
            let prefix = "a=rtpmap:\(payload) "
            let mappings = section.filter { $0.hasPrefix(prefix) }
            guard mappings.count == 1, let mapping = mappings.first,
                  let name = mapping.dropFirst(prefix.count).split(separator: "/").first else { return nil }
            let codec = name.uppercased()
            if ["RTX", "RED", "ULPFEC", "FLEXFEC-03"].contains(codec) { continue }
            return codec
        }
        return nil
    }

    /// Lab-only: accept only the explicitly supported negotiated HEVC profile.
    static func supportsLabHEVC60(answerSDP: String) -> Bool {
        guard answerSDP.utf8.count <= 1_000_000 else { return false }
        let lines = answerSDP.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let videoSections = lines.indices.filter { lines[$0].hasPrefix("m=video ") }
        guard videoSections.count == 1, let videoStart = videoSections.first else { return false }
        let media = lines[videoStart].split(separator: " ")
        guard media.count > 3, let port = Int(media[1]), port > 0, port <= 65_535,
              Set(media.dropFirst(3)).count == media.count - 3 else { return false }
        let end = lines[(videoStart + 1)...].firstIndex(where: { $0.hasPrefix("m=") }) ?? lines.endIndex
        let section = lines[(videoStart + 1)..<end]
        guard !section.contains("a=inactive"), !section.contains("a=recvonly") else { return false }
        for payload in media.dropFirst(3) {
            let prefix = "a=rtpmap:\(payload) "
            let mappings = section.filter { $0.hasPrefix(prefix) }
            guard mappings.count == 1, let mapping = mappings.first else { return false }
            let name = mapping.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? ""
            if ["RTX", "RED", "ULPFEC", "FLEXFEC-03"].contains(name.uppercased()) { continue }
            let fmtpPrefix = "a=fmtp:\(payload) "
            let formatParameters = section.filter { $0.hasPrefix(fmtpPrefix) }
            guard formatParameters.count == 1, let fmtp = formatParameters.first else { return false }
            let pairs = fmtp.dropFirst(fmtpPrefix.count).split(separator: ";")
            var parameters: [String: String] = [:]
            for pair in pairs {
                let parts = pair.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
                guard parts.count == 2, parameters[parts[0]] == nil else { return false }
                parameters[parts[0]] = parts[1]
            }
            return name.uppercased() == "H265" && parameters["profile-id"] == "1" &&
                parameters["tier-flag"] == "0" && parameters["level-id"] == "153" &&
                (parameters["tx-mode"] == nil || parameters["tx-mode"] == "srst")
        }
        return false
    }

    #endif

    static let adaptivePolicy = SenderPolicy(maximumFramesPerSecond: adaptiveFramesPerSecond,
                                             maximumBitrateBps: maximumBitrateBps,
                                             degradationPreference: .maintainFramerate)

    static func senderPolicy(
        targetFramesPerSecond requestedFramesPerSecond: Int,
        maximumBitrateKbps requestedBitrateKbps: Int,
        preference: String,
        maximumFramesPerSecond: Int = targetFramesPerSecond
    ) -> SenderPolicy {
        let framesPerSecond = requestedFramesPerSecond > 0
            ? min(maximumFramesPerSecond, max(10, requestedFramesPerSecond))
            : maximumFramesPerSecond
        let bitrateKbps = requestedBitrateKbps > 0
            ? min(maximumBitrateKbps, max(1_000, requestedBitrateKbps))
            : maximumBitrateKbps
        let degradationPreference: LKRTCDegradationPreference
        switch preference {
        case "sharpness":
            degradationPreference = .maintainResolution
        case "fluency":
            degradationPreference = .maintainFramerate
        default:
            degradationPreference = .balanced
        }
        return SenderPolicy(
            maximumFramesPerSecond: framesPerSecond,
            maximumBitrateBps: bitrateKbps * 1_000,
            degradationPreference: degradationPreference)
    }

    /// Raises only the bundled constrained-high H.264 profile to level 5.1.
    /// The baseline level-3.1 entry remains an exact Windows/legacy fallback.
    /// WebRTC can also negotiate the high profile down with an older Apple peer.
    static func upgradedCodecs(
        _ codecs: [LKRTCVideoCodecInfo]
    ) -> [LKRTCVideoCodecInfo] {
        codecs.map { codec in
            guard codec.name.caseInsensitiveCompare("H264") == .orderedSame,
                  let profileLevelID = codec.parameters["profile-level-id"],
                  profileLevelID.count == 6,
                  profileLevelID.lowercased().hasPrefix("640c") else {
                return codec
            }

            var parameters = codec.parameters
            parameters["profile-level-id"] = String(profileLevelID.prefix(4))
                + preferredH264LevelIDC
            return LKRTCVideoCodecInfo(
                name: codec.name,
                parameters: parameters,
                scalabilityModes: codec.scalabilityModes)
        }
    }

    /// Returns the safe capture ceiling for the first negotiated primary video
    /// codec. An older H.264 peer remains on the conservative level-3.1 limit;
    /// software-codec fallback stays near 1080p to avoid a full-Retina CPU
    /// encode stalling input or accumulating stale frames.
    static func maximumMacroblocksPerFrame(
        negotiatedCodecs: [LKRTCRtpCodecParameters]
    ) -> Int {
        guard let codec = negotiatedCodecs.first(where: {
            ["H264", "VP8", "VP9", "AV1"].contains($0.name.uppercased())
        }) else {
            return fallbackH264MaximumMacroblocksPerFrame
        }
        guard codec.name.caseInsensitiveCompare("H264") == .orderedSame else {
            return softwareCodecMaximumMacroblocksPerFrame
        }
        guard let profileLevelID = codec.parameters["profile-level-id"] as? String,
              profileLevelID.count == 6 else {
            return fallbackH264MaximumMacroblocksPerFrame
        }
        return h264MaximumMacroblocksPerFrame(
            profileLevelID: profileLevelID)
    }

    /// RFC 6184 encodes `profile-level-id` as profile_idc, profile-iop, and
    /// level_idc. Level 1b is the exception to the usual level_idc mapping:
    /// Baseline/Main/Extended signal it with level_idc 11 plus
    /// constraint_set3_flag, while all other profiles use level_idc 9.
    static func h264MaximumMacroblocksPerFrame(
        profileLevelID: String
    ) -> Int {
        guard profileLevelID.count == 6,
              let value = UInt32(profileLevelID, radix: 16) else {
            return fallbackH264MaximumMacroblocksPerFrame
        }
        let profileIDC = UInt8((value >> 16) & 0xFF)
        let profileIOP = UInt8((value >> 8) & 0xFF)
        let levelIDC = UInt8(value & 0xFF)
        let usesConstraintSet3ForLevel1b = [0x42, 0x4D, 0x58]
            .contains(profileIDC)
        let isLevel1b = usesConstraintSet3ForLevel1b
            ? levelIDC == 0x0B && (profileIOP & 0x10) != 0
            : levelIDC == 0x09
        if isLevel1b { return 99 }
        return h264MaximumMacroblocksPerFrame(
            levelIDC: String(format: "%02x", levelIDC))
    }

    static func h264MaximumMacroblocksPerFrame(levelIDC: String) -> Int {
        switch levelIDC.lowercased() {
        case "09", "0a": return 99  // Levels 1b (non-B/M/E) and 1.0
        case "0b", "0c", "0d", "14": return 396  // Levels 1.1 through 2.0
        case "15": return 792  // Level 2.1
        case "16", "1e": return 1_620  // Levels 2.2 and 3.0
        case "1f": return fallbackH264MaximumMacroblocksPerFrame  // Level 3.1
        case "20": return 5_120  // Level 3.2
        case "28", "29": return 8_192  // Levels 4.0 and 4.1
        case "2a": return 8_704  // Level 4.2
        case "32": return 19_660  // Level 5.0, limited by MBPS at 30 fps
        case "33": return preferredH264MaximumMacroblocksPerFrame  // Level 5.1 at 30 fps
        case "34": return 36_864  // Level 5.2
        default: return fallbackH264MaximumMacroblocksPerFrame
        }
    }
}

final class DesktopVideoEncoderFactory: NSObject, LKRTCVideoEncoderFactory {
    private let base = LKRTCDefaultVideoEncoderFactory()
    private let f2Enabled: Bool
    #if DEBUG && os(macOS)
    private let frameByteObserver: ((Int) -> Void)?
    private let keyframeControl: LatencyKeyframeControl?
    private let cbrEnabled: Bool
    private let cbrTrace: (([String: Any]) -> Void)?
    #endif

    init(f2Enabled: Bool = false, frameByteObserver: ((Int) -> Void)? = nil) {
        #if DEBUG && os(macOS)
        self.f2Enabled = f2Enabled
        self.frameByteObserver = frameByteObserver
        self.keyframeControl = nil
        self.cbrEnabled = false
        self.cbrTrace = nil
        #else
        self.f2Enabled = false
        #endif
        super.init()
    }

    #if DEBUG && os(macOS)
    init(f2Enabled: Bool, frameByteObserver: ((Int) -> Void)?, keyframeControl: LatencyKeyframeControl?, cbrEnabled: Bool = false, cbrTrace: (([String: Any]) -> Void)? = nil) {
        self.f2Enabled = f2Enabled
        self.frameByteObserver = frameByteObserver
        self.keyframeControl = keyframeControl
        self.cbrEnabled = cbrEnabled && !f2Enabled
        self.cbrTrace = cbrTrace
        super.init()
    }
    #endif

    func createEncoder(
        _ info: LKRTCVideoCodecInfo
    ) -> (any LKRTCVideoEncoder)? {
        #if DEBUG && os(macOS)
        guard let native = base.createEncoder(info) else { return nil }
        let encoder: any LKRTCVideoEncoder
        if (f2Enabled || cbrEnabled), DesktopVideoQuality.supportsExperimentalEncoder(
            name: info.name, profileLevelID: info.parameters["profile-level-id"],
            packetizationMode: info.parameters["packetization-mode"]) {
            encoder = DesktopLowLatencyH264Encoder(fallback: native, cbr: cbrEnabled, trace: cbrTrace, observeBytes: cbrEnabled ? frameByteObserver : nil)
        } else {
            if cbrEnabled && info.name.uppercased() == "H264" {
                cbrTrace?(["type": "encoder_cbr", "event": "unsupported_profile_fallback"])
            }
            encoder = native
        }
        // WebRTC unwraps native software encoders by concrete class; wrapping
        // one would change its adapter path. Observe only the validated ObjC H.264 encoder.
        if !f2Enabled, info.name.uppercased() == "H264", (frameByteObserver != nil || keyframeControl != nil),
           let object = encoder as? NSObject,
           NSStringFromClass(type(of: object)).hasSuffix("RTCVideoEncoderH264"),
           !object.responds(to: NSSelectorFromString("build:")) {
            return LatencyObservedVideoEncoder(base: encoder, observe: frameByteObserver ?? { _ in }, control: keyframeControl)
        }
        return encoder
        #else
        return base.createEncoder(info)
        #endif
    }

    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        DesktopVideoQuality.upgradedCodecs(base.supportedCodecs())
    }
}

#if DEBUG && os(macOS)
/// A peer-local request latch. The event sink must enqueue only and must not
/// synchronously call this control; it is invoked while generation state is locked.
final class LatencyKeyframeControl: @unchecked Sendable {
    enum RequestResult: String { case accepted, coalesced, unavailable }
    enum Event: String { case delivered, encodeFailed, observed }
    private struct Flight { var accepted = false; var observed = false }
    private let lock = NSLock()
    private let event: @Sendable (Event) -> Void
    private var generation: UInt64 = 0
    private var active = false
    private var closed = false
    private var pending = false
    private var flights: [UInt32: Flight] = [:]
    private var order: [UInt32] = []

    init(event: @escaping @Sendable (Event) -> Void) { self.event = event }

    func requestKeyframe() -> RequestResult {
        lock.lock(); defer { lock.unlock() }
        guard !closed, active else { return .unavailable }
        guard !pending else { return .coalesced }
        pending = true
        return .accepted
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        closed = true; active = false; pending = false; flights.removeAll(); order.removeAll()
    }

    fileprivate func beginEncoder() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        generation &+= 1
        if generation == 0 { generation = 1 }
        active = false; pending = false; flights.removeAll(); order.removeAll()
        return generation
    }
    fileprivate func finishStart(_ token: UInt64?, succeeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let token, !closed, token == generation else { return }
        active = succeeded
    }
    fileprivate func releaseEncoder(_ token: UInt64?) {
        lock.lock(); defer { lock.unlock() }
        guard let token, !closed, token == generation else { return }
        active = false; pending = false; flights.removeAll(); order.removeAll()
    }
    fileprivate func takeRequest(_ token: UInt64?, timestamp: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let token, !closed, active, token == generation, pending,
              flights[timestamp] == nil else { return false }
        pending = false
        order.append(timestamp)
        flights[timestamp] = Flight()
        if order.count > 8 { flights.removeValue(forKey: order.removeFirst()) }
        return true
    }
    fileprivate func finishEncode(_ token: UInt64?, timestamp: UInt32, succeeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let token, !closed, active, token == generation, var flight = flights[timestamp] else { return }
        if succeeded {
            flight.accepted = true
            event(.delivered)
            if flight.observed {
                flights.removeValue(forKey: timestamp); order.removeAll { $0 == timestamp }
                event(.observed)
            } else { flights[timestamp] = flight }
        } else {
            flights.removeValue(forKey: timestamp); order.removeAll { $0 == timestamp }
            pending = true
            event(.encodeFailed)
        }
    }
    fileprivate func observe(_ token: UInt64?, timestamp: UInt32, isKeyframe: Bool) {
        guard isKeyframe else { return }
        lock.lock(); defer { lock.unlock() }
        guard let token, !closed, active, token == generation, var flight = flights[timestamp] else { return }
        if flight.accepted {
            flights.removeValue(forKey: timestamp); order.removeAll { $0 == timestamp }
            event(.observed)
        } else { flight.observed = true; flights[timestamp] = flight }
    }
}

/// Observes encoded byte counts and optionally forwards one peer-local request.
final class LatencyObservedVideoEncoder: NSObject, LKRTCVideoEncoder {
    private let base: any LKRTCVideoEncoder
    private let observe: (Int) -> Void
    private let control: LatencyKeyframeControl?
    private let stateLock = NSLock()
    private var generation: UInt64?
    private var callback: RTCVideoEncoderCallback?
    init(base: any LKRTCVideoEncoder, observe: @escaping (Int) -> Void, control: LatencyKeyframeControl?) {
        self.base = base; self.observe = observe; self.control = control; super.init()
    }
    convenience init(base: any LKRTCVideoEncoder, observe: @escaping (Int) -> Void) {
        self.init(base: base, observe: observe, control: nil)
    }
    private func installCallback(_ callback: RTCVideoEncoderCallback?, generation: UInt64?) {
        guard let callback else { base.setCallback(nil); return }
        let observe = self.observe, control = self.control
        base.setCallback { frame, info in
            observe(frame.buffer.count)
            control?.observe(generation, timestamp: frame.timeStamp, isKeyframe: frame.frameType.rawValue == 3)
            return callback(frame, info)
        }
    }
    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        if control == nil {
            guard let callback else { base.setCallback(nil); return }
            let observe = self.observe
            base.setCallback { frame, info in
                observe(frame.buffer.count)
                return callback(frame, info)
            }
            return
        }
        stateLock.lock(); self.callback = callback; let token = generation; stateLock.unlock()
        installCallback(callback, generation: token)
    }
    func startEncode(with settings: LKRTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        guard let control else { return base.startEncode(with: settings, numberOfCores: numberOfCores) }
        let token = control.beginEncoder()
        stateLock.lock(); generation = token; let callback = self.callback; stateLock.unlock()
        installCallback(callback, generation: token)
        let result = base.startEncode(with: settings, numberOfCores: numberOfCores)
        control.finishStart(token, succeeded: result == 0)
        return result
    }
    func release() -> Int {
        guard let control else { return base.release() }
        stateLock.lock(); let token = generation; generation = nil; stateLock.unlock()
        control.releaseEncoder(token)
        return base.release()
    }
    func encode(_ frame: LKRTCVideoFrame, codecSpecificInfo: (any LKRTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        guard let control else { return base.encode(frame, codecSpecificInfo: codecSpecificInfo, frameTypes: frameTypes) }
        stateLock.lock(); let token = generation; stateLock.unlock()
        let timestamp = UInt32(bitPattern: frame.timeStamp)
        let force = control.takeRequest(token, timestamp: timestamp)
        let requested = force && !frameTypes.contains(where: { $0.uintValue == 3 })
            ? frameTypes + [NSNumber(value: 3)] : frameTypes
        let result = base.encode(frame, codecSpecificInfo: codecSpecificInfo, frameTypes: requested)
        if force { control.finishEncode(token, timestamp: timestamp, succeeded: result == 0) }
        return result
    }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 { base.setBitrate(bitrateKbit, framerate: framerate) }
    func implementationName() -> String { base.implementationName() }
    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? { base.scalingSettings() }
    var resolutionAlignment: Int { base.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool { base.applyAlignmentToAllSimulcastLayers }
    var supportsNativeHandle: Bool { base.supportsNativeHandle }
}
#endif

final class DesktopVideoDecoderFactory: NSObject, LKRTCVideoDecoderFactory {
    private let base = LKRTCDefaultVideoDecoderFactory()
    #if DEBUG
    private let labHEVC: Bool
    init(labHEVC: Bool = false) { self.labHEVC = labHEVC; super.init() }
    #endif

    func createDecoder(
        _ info: LKRTCVideoCodecInfo
    ) -> (any LKRTCVideoDecoder)? {
        base.createDecoder(info)
    }

    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        let codecs = DesktopVideoQuality.upgradedCodecs(base.supportedCodecs())
        #if DEBUG
        guard labHEVC else { return codecs }
        return codecs.map { codec in
            guard codec.name.uppercased() == "H265" else { return codec }
            var parameters = codec.parameters
            parameters["profile-id"] = "1"
            parameters["tier-flag"] = "0"
            parameters["level-id"] = "153"
            return LKRTCVideoCodecInfo(name: codec.name, parameters: parameters, scalabilityModes: codec.scalabilityModes)
        }
        #else
        return codecs
        #endif
    }
}
