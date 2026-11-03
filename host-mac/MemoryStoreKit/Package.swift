// swift-tools-version: 5.10
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hostMacDirectory = packageDirectory.deletingLastPathComponent()
let sqlcipherBuild = hostMacDirectory
    .appendingPathComponent("ThirdPartyRuntime/sqlcipher/build/778ab890cfc30c3631212dcceb0295498abdcd3e")
let sqlcipherLibraryDirectory = sqlcipherBuild.appendingPathComponent("lib").path

let package = Package(
    name: "MemoryStoreKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MemoryStoreKit", targets: ["MemoryStoreKit"])],
    targets: [
        .target(
            name: "CSQLCipherBridge",
            path: "Sources/CSQLCipherBridge",
            publicHeadersPath: "include",
            cSettings: [.define("SQLITE_HAS_CODEC")],
            linkerSettings: [
                .unsafeFlags(["-L\(sqlcipherLibraryDirectory)", "-lsqlcipher",
                              "-framework", "Security", "-framework", "CoreFoundation"])
            ]),
        .target(
            name: "MemoryStoreKit",
            dependencies: ["CSQLCipherBridge"],
            path: "Sources/MemoryStoreKit"),
        .target(
            name: "MemoryStoreKitTestSupport",
            path: "Tests/MemoryStoreKitTestSupport",
            publicHeadersPath: "include",
            cSettings: [.define("SQLITE_HAS_CODEC"),
                        .unsafeFlags(["-I\(sqlcipherBuild.appendingPathComponent("include").path)"])],
            linkerSettings: [
                .unsafeFlags(["-L\(sqlcipherLibraryDirectory)", "-lsqlcipher",
                              "-framework", "Security", "-framework", "CoreFoundation"])
            ]),
        .testTarget(
            name: "MemoryStoreKitTests",
            dependencies: ["MemoryStoreKit", "CSQLCipherBridge", "MemoryStoreKitTestSupport"],
            path: "Tests/MemoryStoreKitTests")
    ]
)
