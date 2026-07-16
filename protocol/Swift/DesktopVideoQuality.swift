import Foundation
import LiveKitWebRTC

/// Shared desktop-video policy for the Apple host and viewer.
///
/// WebRTC still owns congestion control. These values raise the quality ceiling
/// and tell its quality scaler to shed frame rate before desktop resolution, so
/// a constrained link stays responsive instead of building a stale-frame queue.
enum DesktopVideoQuality {
    static let targetFramesPerSecond = 30
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

    struct SenderPolicy: Equatable {
        let maximumFramesPerSecond: Int
        let maximumBitrateBps: Int
        let degradationPreference: LKRTCDegradationPreference
    }

    static let sharpnessPolicy = SenderPolicy(
        maximumFramesPerSecond: targetFramesPerSecond,
        maximumBitrateBps: maximumBitrateBps,
        degradationPreference: .maintainResolution)

    static func senderPolicy(
        targetFramesPerSecond requestedFramesPerSecond: Int,
        maximumBitrateKbps requestedBitrateKbps: Int,
        preference: String
    ) -> SenderPolicy {
        let framesPerSecond = requestedFramesPerSecond > 0
            ? min(targetFramesPerSecond, max(10, requestedFramesPerSecond))
            : targetFramesPerSecond
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

    func createEncoder(
        _ info: LKRTCVideoCodecInfo
    ) -> (any LKRTCVideoEncoder)? {
        base.createEncoder(info)
    }

    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        DesktopVideoQuality.upgradedCodecs(base.supportedCodecs())
    }
}

final class DesktopVideoDecoderFactory: NSObject, LKRTCVideoDecoderFactory {
    private let base = LKRTCDefaultVideoDecoderFactory()

    func createDecoder(
        _ info: LKRTCVideoCodecInfo
    ) -> (any LKRTCVideoDecoder)? {
        base.createDecoder(info)
    }

    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        DesktopVideoQuality.upgradedCodecs(base.supportedCodecs())
    }
}
