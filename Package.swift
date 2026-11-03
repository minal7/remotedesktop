// swift-tools-version: 5.10
import PackageDescription

// Compile the actual Mac computer-use implementation and its existing tests
// without an application host, provisioning profile, or bundled model process.
// Production still builds/signs the app and runtime through host-mac/project.yml.
let package = Package(
    name: "RemoteDesktopComputerUse",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ComputerUseCore", targets: ["RemoteDesktopHost"])],
    dependencies: [
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "144.7559.3"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-system.git", exact: "1.7.4"),
    ],
    targets: [
        .target(
            name: "RemoteDesktopHost",
            dependencies: [
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: ".",
            exclude: [
                ".github", "docs", "ios", "android", "host-windows", "signaling", "script", "scripts",
                "README.md", "TODO.md", "PROGRESS.md", "protocol/PROTOCOL.md",
                "host-mac/README.md", "host-mac/project.yml",
                "host-mac/RemoteDesktopHostTests", "host-mac/AcceptanceFixtures",
                "host-mac/ThirdPartyRuntime", "host-mac/scripts",
                "host-mac/RemoteDesktopHost.xcodeproj",
                "host-mac/RemoteDesktopHost/Assets.xcassets",
                "host-mac/RemoteDesktopHost/ThirdPartyNotices",
                "host-mac/RemoteDesktopHost/Info.plist",
                "host-mac/RemoteDesktopHost/RemoteDesktopHost.entitlements",
                "host-mac/RemoteDesktopHost/App.swift",
                "host-mac/RemoteDesktopHost/AppLogo.swift",
                "host-mac/RemoteDesktopHost/AudioInputEntitlements.swift",
                "host-mac/RemoteDesktopHost/BonjourAdvertiser.swift",
                "host-mac/RemoteDesktopHost/HeadlessHostSettings.swift",
                "host-mac/RemoteDesktopHost/HostCommandLine.swift",
                "host-mac/RemoteDesktopHost/HostSession.swift",
                "host-mac/RemoteDesktopHost/HostSettingsView.swift",
                "host-mac/RemoteDesktopHost/HostSetupView.swift",
                "host-mac/RemoteDesktopHost/MenuContent.swift",
                "host-mac/RemoteDesktopHost/PermissionsProvider.swift",
            ],
            sources: [
                "host-mac/RemoteDesktopHost/ComputerUse",
                "host-mac/RemoteDesktopHost/InputInjector.swift",
                "host-mac/RemoteDesktopHost/HIDUsage.swift",
                "host-mac/RemoteDesktopHost/HostConfig.swift",
                "host-mac/RemoteDesktopHost/HostRuntimeContext.swift",
                "host-mac/RemoteDesktopHost/HostPeerSession.swift",
                "host-mac/RemoteDesktopHost/ScreenCapture.swift",
                "host-mac/RemoteDesktopHost/SystemAudioBridge.swift",
                "host-mac/RemoteDesktopHost/WebRTCAliases.swift",
                "host-mac/RemoteDesktopHost/WireFormat.swift",
                "protocol/Swift",
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(
            name: "ComputerUseCoreTests",
            dependencies: ["RemoteDesktopHost"],
            path: "host-mac/RemoteDesktopHostTests",
            exclude: [
                "HostSessionTests.swift", "ScreenCaptureSizingTests.swift",
                "ComputerUseLicenseComplianceTests.swift", "OSAtlasNativeRealUIAcceptanceTests.swift",
                "ComputerUseClarificationCompositionTests.swift",
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
    ],
    swiftLanguageVersions: [.v5])
