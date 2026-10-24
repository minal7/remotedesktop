import Foundation

enum MemoryFeatureConfiguration {
    static let environmentKey = "REMOTE_DESKTOP_MEMORY_V1_CANDIDATE"

    static func isMemoryV1CandidateEnabled(environment: [String: String]) -> Bool {
#if DEBUG
        environment[environmentKey] == "1"
#elseif MEMORY_V1_SHIPPING_BETA
        true
#else
        false
#endif
    }

    static var memoryV1CandidateEnabled: Bool {
        isMemoryV1CandidateEnabled(environment: ProcessInfo.processInfo.environment)
    }
}
