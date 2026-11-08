// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LocalAgentKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalAgentKit", targets: ["LocalAgentKit"]),
        .executable(name: "lacua", targets: ["lacua"]),
    ],
    targets: [
        .target(name: "LocalAgentKit"),
        .executableTarget(name: "lacua", dependencies: ["LocalAgentKit"]),
        .testTarget(name: "LocalAgentKitTests", dependencies: ["LocalAgentKit"]),
    ],
    swiftLanguageVersions: [.v5])
