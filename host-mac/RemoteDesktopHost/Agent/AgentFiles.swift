import Foundation

/// Host-owned file search shared by the Pixel environment and host backends.
typealias AgentWebFileFinder = @MainActor (String, String?, String?) async throws -> [AgentFileCandidate]

/// A file selected by a host-owned catalog. Model-visible records contain only
/// candidate IDs and display metadata; local paths never enter AgentObservation.
struct AgentFileCandidate: Equatable, Sendable {
    let id: String
    let name: String
    let kind: String?
    let modifiedAt: Date?
}

/// Validated bytes returned by the host only after resolving a candidate ID.
struct AgentWebFile: Equatable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let lastModified: Date
    let bytes: Data
}
