import Foundation

/// Pinned, data-only model package used by the native macOS Computer Use
/// runtime. The signed host contains all executable inference code. Setup
/// downloads only immutable GGUF data files and verifies every byte before the
/// package can become active.
struct ComputerUseArtifactManifest: Codable, Equatable, Sendable {
    enum ModelVariant: String, Codable, CaseIterable, Sendable {
        /// Agentic, single-step GUI action model. This is the production
        /// default because OS-Atlas documents Pro as the action-generation
        /// checkpoint; Base remains available for a future grounding-only
        /// package without allowing both models to be selected together.
        case pro4B = "os-atlas-pro-4b"
        case base4B = "os-atlas-base-4b"
    }

    struct DownloadableArtifact: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case textModelShard
            case visionProjector
        }

        let kind: Kind
        let fileName: String
        let byteCount: Int64
        let sha256: String
        /// Full immutable URL for this exact derived data blob. Keeping the
        /// URL on each artifact avoids silently constructing a mutable latest
        /// URL or mixing files from different releases.
        let downloadURL: URL
    }

    struct BundledArtifact: Codable, Equatable, Sendable {
        let fileName: String
        let byteCount: Int64
        let sha256: String
    }

    let installationVersion: String
    let modelVariant: ModelVariant
    /// Authoritative upstream model provenance. Downloadable artifacts below
    /// are an immutable GGUF conversion of this exact public, ungated commit.
    let modelRepository: String
    let modelRevision: String
    /// Download order is intentional: model shards first, then the projector.
    let modelArtifacts: [DownloadableArtifact]
    let minimumMemoryBytes: UInt64

    static let osAtlasPro4BRevision =
        "06b790b907d82f29bb317ba889e6888805953036"

    static let current = ComputerUseArtifactManifest(
        installationVersion: "os-atlas-pro-4b-q4-k-m-b9992",
        modelVariant: .pro4B,
        modelRepository: "OS-Copilot/OS-Atlas-Pro-4B",
        modelRevision: osAtlasPro4BRevision,
        modelArtifacts: [
            DownloadableArtifact(
                kind: .textModelShard,
                fileName: "os-atlas-pro-4b-q4_k_m-00001-of-00002.gguf",
                byteCount: 1_775_749_760,
                sha256: "c16b6eabf9c1f05856c3750e0619f6e0e111106bde124d394663615d67aba364",
                downloadURL: URL(string:
                    "https://github.com/minal7/remotedesktop/releases/download/os-atlas-pro-4b-q4-k-m-b9992/os-atlas-pro-4b-q4_k_m-00001-of-00002.gguf")!),
            DownloadableArtifact(
                kind: .textModelShard,
                fileName: "os-atlas-pro-4b-q4_k_m-00002-of-00002.gguf",
                byteCount: 620_841_952,
                sha256: "2a671333e62bc51454bdaae5fcd5d1b1f764e23948670c43dd2a4abe7f3a45f0",
                downloadURL: URL(string:
                    "https://github.com/minal7/remotedesktop/releases/download/os-atlas-pro-4b-q4-k-m-b9992/os-atlas-pro-4b-q4_k_m-00002-of-00002.gguf")!),
            DownloadableArtifact(
                kind: .visionProjector,
                fileName: "mmproj-os-atlas-pro-4b-f16.gguf",
                byteCount: 654_988_416,
                sha256: "f147cac4ef583b478b0894995faeb64c1ef72ef51be975889c8390994e8b323b",
                downloadURL: URL(string:
                    "https://github.com/minal7/remotedesktop/releases/download/os-atlas-pro-4b-q4-k-m-b9992/mmproj-os-atlas-pro-4b-f16.gguf")!),
        ],
        minimumMemoryBytes: 16 * 1_024 * 1_024 * 1_024)

    static let osAtlasLicenseRevision =
        "bad08407ab54b5bf6c17a69fe1ced476b9494926"
    static let osAtlasLicenseURL = URL(string:
        "https://github.com/OS-Copilot/OS-Atlas/blob/\(osAtlasLicenseRevision)/LICENSE")!
    static let osAtlasLicense = BundledArtifact(
        fileName: "OS-ATLAS-APACHE-2.0-LICENSE.txt",
        byteCount: 11_357,
        sha256: "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4")

    static let llamaCPPTag = "b9992"
    static let llamaCPPRevision =
        "6eddde06a4f25d55d538b5d15628dcc2b6882147"
    static let llamaCPPLicenseURL = URL(string:
        "https://github.com/ggml-org/llama.cpp/blob/\(llamaCPPRevision)/LICENSE")!
    static let llamaCPPLicense = BundledArtifact(
        fileName: "LLAMA-CPP-MIT-LICENSE.txt",
        byteCount: 1_078,
        sha256: "94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d")

    // Updated alongside ThirdPartyNotices/NOTICE.txt. This notice records both
    // the upstream checkpoint and converter revisions used for the data files.
    static let modelNotice = BundledArtifact(
        fileName: "NOTICE.txt",
        byteCount: 806,
        sha256: "23fc858c612406dbc26d9f6340aa6c49624f0cb4c7c7641d9a3a422a06637748")

    static let modelLegalArtifacts = [
        osAtlasLicense,
        llamaCPPLicense,
        modelNotice,
    ]

    static var displayedOSAtlasLicenseURL: URL {
        bundledLegalDocumentURL(osAtlasLicense) ?? osAtlasLicenseURL
    }

    static func bundledLegalDocumentURL(
        _ artifact: BundledArtifact,
        bundles: [Bundle] = [.main]
    ) -> URL? {
        let name = (artifact.fileName as NSString).deletingPathExtension
        let fileExtension = (artifact.fileName as NSString).pathExtension
        for bundle in bundles {
            if let url = bundle.url(
                forResource: name,
                withExtension: fileExtension.isEmpty ? nil : fileExtension) {
                return url
            }
        }
        return nil
    }
}

struct ComputerUseInstallationReceipt: Codable, Equatable, Sendable {
    let installationVersion: String
    let modelVariant: ComputerUseArtifactManifest.ModelVariant
    let modelDirectory: String
    let installedAt: Date
}
