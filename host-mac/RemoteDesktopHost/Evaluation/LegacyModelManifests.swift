#if DEBUG
import Foundation

extension ComputerUseArtifactManifest {
    static let osAtlasPro4BRevision =
        "06b790b907d82f29bb317ba889e6888805953036"

    /// Exact package shipped before the semantic router was added. This
    /// snapshot is intentionally independent from `current`: it is the sole
    /// package whose verified visual artifacts may be reused during the
    /// one-time multi-model migration.
    static let legacyVisualOnly = ComputerUseArtifactManifest(
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
        minimumMemoryBytes: 8 * 1_024 * 1_024 * 1_024)

    /// Community GGUF conversion of the official UI-TARS 1.5-7B checkpoint.
    /// The immutable conversion revision and blob hashes pin the data files;
    /// execution remains in the signed bundled llama.cpp runtime.
    static let uiTars15 = ComputerUseArtifactManifest(
        installationVersion: "ui-tars15-7b-q4-k-m-b9992",
        modelVariant: .uiTars15_7B,
        modelRepository: "mradermacher/UI-TARS-1.5-7B-GGUF",
        modelRevision: "bd33135be0c6a564eeac241c7cd985b9f779e057",
        modelArtifacts: [
            .init(kind: .textModelShard, fileName: "UI-TARS-1.5-7B.Q4_K_M.gguf",
                byteCount: 4_683_073_856,
                sha256: "3233f143243135ef458a3e18894c4d6883d384abcef23367a538a3a78003009b",
                downloadURL: URL(string: "https://huggingface.co/mradermacher/UI-TARS-1.5-7B-GGUF/resolve/bd33135be0c6a564eeac241c7cd985b9f779e057/UI-TARS-1.5-7B.Q4_K_M.gguf")!),
            .init(kind: .visionProjector, fileName: "UI-TARS-1.5-7B.mmproj-f16.gguf",
                byteCount: 1_354_162_880,
                sha256: "45fff9aa4ee4dcab82ad668e681b5ce0e061eb52a7dca26ddb8922435c567a8f",
                downloadURL: URL(string: "https://huggingface.co/mradermacher/UI-TARS-1.5-7B-GGUF/resolve/bd33135be0c6a564eeac241c7cd985b9f779e057/UI-TARS-1.5-7B.mmproj-f16.gguf")!)
        ],
        minimumMemoryBytes: 16 * 1_024 * 1_024 * 1_024)

    /// Native desktop candidate. Selection remains explicit until whole-task
    /// and whole-app resource qualification is complete.
    static let holo31 = ComputerUseArtifactManifest(
        installationVersion: "holo31-4b-q4-k-m-b9992", modelVariant: .holo31_4B,
        modelRepository: "mradermacher/Holo-3.1-4B-GGUF", modelRevision: "6d76eab0233f62783ddec95a7a2e2b057c6d7e66",
        modelArtifacts: [
            .init(kind: .textModelShard, fileName: "Holo-3.1-4B.Q4_K_M.gguf", byteCount: 3_066_386_464,
                sha256: "cfdd26e8e9ee34de0c052ea68fb5c61dd8f34986fa3e1b631e2bab6ab1b44ac9",
                downloadURL: URL(string: "https://huggingface.co/mradermacher/Holo-3.1-4B-GGUF/resolve/6d76eab0233f62783ddec95a7a2e2b057c6d7e66/Holo-3.1-4B.Q4_K_M.gguf")!),
            .init(kind: .visionProjector, fileName: "Holo-3.1-4B.mmproj-f16.gguf", byteCount: 672_424_256,
                sha256: "4eca6e6633c5384c4f6e220e1076fd6b96c53bc75baf421c553a8d8ba9649f5f",
                downloadURL: URL(string: "https://huggingface.co/mradermacher/Holo-3.1-4B-GGUF/resolve/6d76eab0233f62783ddec95a7a2e2b057c6d7e66/Holo-3.1-4B.mmproj-f16.gguf")!)],
        minimumMemoryBytes: 16 * 1_024 * 1_024 * 1_024)

    /// Opt-in Q4_K_M conversion of GUI-Owl 1.5 4B. The source checkpoint and
    /// GGUF conversion have separate immutable revisions and are recorded in
    /// the corresponding download URLs and notice.
    static let guiOwl15 = ComputerUseArtifactManifest(
        installationVersion: "gui-owl15-4b-q4-k-m-b9992", modelVariant: .guiOwl15_4B,
        modelRepository: "mradermacher/GUI-Owl-1.5-4B-Instruct-GGUF",
        modelRevision: "f77e8a457158e773d9f3135ff0cac5811878d3b7",
        modelArtifacts: [
            .init(kind: .textModelShard, fileName: "GUI-Owl-1.5-4B-Instruct.Q4_K_M.gguf",
                byteCount: 2_497_282_208,
                sha256: "8e1793b69bb4064671ab6529b43f5b943850f73a9244ad139c16e93a44709232",
                downloadURL: URL(string: "https://huggingface.co/mradermacher/GUI-Owl-1.5-4B-Instruct-GGUF/resolve/f77e8a457158e773d9f3135ff0cac5811878d3b7/GUI-Owl-1.5-4B-Instruct.Q4_K_M.gguf")!),
            .init(kind: .visionProjector, fileName: "GUI-Owl-1.5-4B-Instruct.mmproj-Q8_0.gguf",
                byteCount: 453_974_336,
                sha256: "b705d940e9b7f212235a16c9c4b8cc9dd9053a1ccf549b99fc069a0ae694b073",
                downloadURL: URL(string: "https://huggingface.co/mradermacher/GUI-Owl-1.5-4B-Instruct-GGUF/resolve/f77e8a457158e773d9f3135ff0cac5811878d3b7/GUI-Owl-1.5-4B-Instruct.mmproj-Q8_0.gguf")!)],
        minimumMemoryBytes: 16 * 1_024 * 1_024 * 1_024)

    /// Separate installation/receipt from the visual package. The native form
    /// planner does not require its projector, helper or Apple Intelligence.
    static let nativeTextV2 = ComputerUseArtifactManifest(
        installationVersion: "qwen35-4b-q4-k-m-native-text-v2-b9992",
        modelVariant: .nativeText4B,
        modelRepository: "unsloth/Qwen3.5-4B-GGUF",
        modelRevision: "e87f176479d0855a907a41277aca2f8ee7a09523",
        modelArtifacts: [DownloadableArtifact(
            kind: .nativeTextPlannerModel,
            fileName: "Qwen3.5-4B-Q4_K_M.gguf",
            byteCount: 2_740_937_888,
            sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf")!)],
        minimumMemoryBytes: 8 * 1_024 * 1_024 * 1_024)

}

extension ComputerUseInstaller {
    nonisolated static var nativeTextRootDirectory: URL {
        HostComputerUseManager.modelDirectoryURL.deletingLastPathComponent()
            .appendingPathComponent("Native Text Model", isDirectory: true)
    }

    static func nativeText() -> ComputerUseInstaller {
        ComputerUseInstaller(manifest: .nativeTextV2,
                             rootDirectory: nativeTextRootDirectory,
                             legacyManifest: nil)
    }
}
#endif
