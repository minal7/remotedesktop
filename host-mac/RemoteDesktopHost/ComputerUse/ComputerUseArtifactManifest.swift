import Foundation

/// Pinned, data-only model package used by the native macOS Computer Use
/// runtime. The signed host contains all executable inference code. Setup
/// downloads only immutable GGUF data files and verifies every byte before the
/// package can become active.
struct ComputerUseArtifactManifest: Codable, Equatable, Sendable {
    enum ModelVariant: String, Codable, CaseIterable, Sendable {
        /// Retained receipt identities for legacy packages and rollback.
        case pro4B = "os-atlas-pro-4b"
        case base4B = "os-atlas-base-4b"
        case nativeText4B = "qwen35-native-text-4b"
        case fara15_4B = "fara15-4b"
        case uiTars15_7B = "ui-tars15-7b"
        case guiOwl15_4B = "gui-owl15-4b"
        case holo31_4B = "holo31-4b"
    }

    struct DownloadableArtifact: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case textModelShard
            case visionProjector
            case semanticRouterModel
            case nativeTextPlannerModel
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
    /// Pinned source repository for this package: upstream checkpoint for the
    /// OS-Atlas conversion, conversion repository for the native text GGUF.
    let modelRepository: String
    let modelRevision: String
    /// Download order is intentional: model shards first, then the projector.
    let modelArtifacts: [DownloadableArtifact]
    let minimumMemoryBytes: UInt64

    /// Browser-trained replacement, already exercised with this exact GGUF pair.
    static let fara15 = ComputerUseArtifactManifest(
        installationVersion: "fara15-4b-q4-k-m-b9992",
        modelVariant: .fara15_4B,
        modelRepository: "bartowski/Fara1.5-4B-GGUF",
        modelRevision: "b97f335231e01efbbad37bb89b5310340fc10735",
        modelArtifacts: [
            .init(kind: .textModelShard, fileName: "Fara1.5-4B-Q4_K_M.gguf", byteCount: 2_884_850_784,
                sha256: "aedd3e6ed7071eb0941a9d86de0f35c16f76eedb9e15dbefa2b4a4e5e7838e51",
                downloadURL: URL(string: "https://huggingface.co/bartowski/Fara1.5-4B-GGUF/resolve/b97f335231e01efbbad37bb89b5310340fc10735/Fara1.5-4B-Q4_K_M.gguf")!),
            .init(kind: .visionProjector, fileName: "mmproj-Fara1.5-4B-f16.gguf", byteCount: 672_423_584,
                sha256: "373320845fb5539dd55a66d3faafcd8f123e83a7318334d557a04d604f5ef84d",
                downloadURL: URL(string: "https://huggingface.co/bartowski/Fara1.5-4B-GGUF/resolve/b97f335231e01efbbad37bb89b5310340fc10735/mmproj-Fara1.5-4B-f16.gguf")!)],
        minimumMemoryBytes: 16 * 1_024 * 1_024 * 1_024)
    static let current = fara15

    static let qwen35License = BundledArtifact(
        fileName: "QWEN35-APACHE-2.0-LICENSE.txt", byteCount: 11_544,
        sha256: "bbedc3fda3305820b977265f01b8619d87570a6739de3a5582c3464840f1e57a")
    static let qwen35LicenseURL = URL(string: "https://huggingface.co/Qwen/Qwen3.5-4B/blob/851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a/LICENSE")!
    static let qwen35Notice = BundledArtifact(
        fileName: "QWEN35-NOTICE.txt", byteCount: 1_030,
        sha256: "b560a5da0265ef822c3b3f4ab1c29e562fe2db4a9ca5ff10e98907a5a6aca253")

    var legalArtifacts: [BundledArtifact] {
        switch modelVariant {
        case .fara15_4B: return [Self.faraLicense, Self.qwen35License, Self.llamaCPPLicense, Self.faraNotice]
        case .holo31_4B: return [Self.qwen35License, Self.llamaCPPLicense, Self.holoNotice]
        case .nativeText4B: return [Self.qwen35License, Self.llamaCPPLicense, Self.qwen35Notice]
        case .guiOwl15_4B: return [Self.guiOwlLicense, Self.qwen35License, Self.llamaCPPLicense, Self.guiOwlNotice]
        default: return Self.modelLegalArtifacts
        }
    }

    static let holoNotice = BundledArtifact(fileName: "HOLO-NOTICE.txt", byteCount: 1144,
        sha256: "81aa0042cc34c7b841e26f5b88a3f83610a3a7a1abddf13a5407d030c72e5821")
    static let guiOwlLicense = BundledArtifact(fileName: "GUI-OWL-DESKTOP-MIT-LICENSE.txt", byteCount: 1062,
        sha256: "961819a89dacd1f4f161e1d2ebf616b538bf095a2eecfa3ef40b7ccec633fac4")
    static let guiOwlNotice = BundledArtifact(fileName: "GUI-OWL-NOTICE.txt", byteCount: 1_010,
        sha256: "1a0f2fb053c4b3ef807dde28a132fc58946f5e7d38b87b1d7446314a9bb1a7f0")

    static let faraLicense = BundledArtifact(fileName: "FARA-MIT-LICENSE.txt", byteCount: 1066,
        sha256: "98a96c38494df4963951e32b81ec4effebe4c8a812ab8d9e7d185d59e86fe2fc")
    static let faraNotice = BundledArtifact(fileName: "FARA-NOTICE.txt", byteCount: 1284,
        sha256: "21dc5548710abe9fcb7b2bac5afaf2e1702cbeeb92eb32c5fdf5d43c6a175dfb")
    static let faraLicenseURL = URL(string: "https://github.com/microsoft/fara/blob/a675d6d61c41c47ae87bacefeab22caad18e3e84/LICENSE")!
    static var displayedFaraLicenseURL: URL { bundledLegalDocumentURL(faraLicense) ?? faraLicenseURL }

    static let osAtlasLicenseRevision =
        "bad08407ab54b5bf6c17a69fe1ced476b9494926"
    static let osAtlasLicenseURL = URL(string:
        "https://github.com/OS-Copilot/OS-Atlas/blob/\(osAtlasLicenseRevision)/LICENSE")!
    static let osAtlasLicense = BundledArtifact(
        fileName: "OS-ATLAS-APACHE-2.0-LICENSE.txt",
        byteCount: 11_357,
        sha256: "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4")

    static let granite4OneBRevision =
        "6a7381ba1f54d684ff508d991aeb7dc580157103"
    static let graniteLicenseRevision =
        "1c66d6a87aaa251ef88a3154393d3dddba497bfa"
    static let graniteLicenseURL = URL(string:
        "https://github.com/ibm-granite/granite-4.0-nano-language-models/blob/\(graniteLicenseRevision)/LICENSE")!
    static let graniteLicense = BundledArtifact(
        fileName: "GRANITE-APACHE-2.0-LICENSE.txt",
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
        byteCount: 657,
        sha256: "2d5f3e0e8342a7f00fc5c53eb80ca1ebef5d2c267a5e6b55bf41d654840fe997")

    static let modelLegalArtifacts = [
        osAtlasLicense,
        graniteLicense,
        llamaCPPLicense,
        modelNotice,
    ]

    static var displayedOSAtlasLicenseURL: URL {
        bundledLegalDocumentURL(osAtlasLicense) ?? osAtlasLicenseURL
    }

    static var displayedGraniteLicenseURL: URL {
        bundledLegalDocumentURL(graniteLicense) ?? graniteLicenseURL
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
