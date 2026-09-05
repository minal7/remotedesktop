import Foundation

/// Detects app-hosted XCTest runs before the host starts any production-only
/// services. Xcode's test launcher does not consistently provide
/// `XCTestConfigurationFilePath`, so relying on that one environment variable
/// can let a test host advertise, register login items, or read the Keychain.
enum HostRuntimeContext {
    static var isRunningUnitTests: Bool {
        detectsUnitTests(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments,
            loadedBundlePaths: (Bundle.allBundles + Bundle.allFrameworks).map(\.bundlePath),
            xctestRuntimeAvailable: NSClassFromString("XCTestCase") != nil
                || NSClassFromString("XCTest.XCTestCase") != nil)
    }

    /// App-hosted XCTest must remain visually inert. Even an `NSStatusItem`
    /// is a real on-screen surface owned by Control Center, so creating the
    /// normal host chrome would make hidden model acceptance visibly mutate
    /// the user's menu bar.
    static var shouldInstallVisibleChrome: Bool {
        !isRunningUnitTests
    }

    static func detectsUnitTests(
        environment: [String: String],
        arguments: [String],
        loadedBundlePaths: [String],
        xctestRuntimeAvailable: Bool
    ) -> Bool {
        if xctestRuntimeAvailable {
            return true
        }

        let injectionKeys = [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCTestSessionIdentifier",
            "XCInjectBundle",
            "XCInjectBundleInto",
        ]
        if injectionKeys.contains(where: { environment[$0] != nil }) {
            return true
        }

        if environment["DYLD_INSERT_LIBRARIES"]?.localizedCaseInsensitiveContains("XCTest") == true {
            return true
        }

        let hasXCTestLaunchMarker = arguments.contains { argument in
            let marker = argument.lowercased()
            return marker == "-xctest"
                || marker.hasPrefix("-xctest")
                || marker.hasSuffix(".xctest")
                || marker.contains(".xctest/")
        }
        if hasXCTestLaunchMarker {
            return true
        }

        return loadedBundlePaths.contains { path in
            let marker = path.lowercased()
            return marker.hasSuffix(".xctest")
                || marker.contains(".xctest/")
                || marker.hasSuffix("/xctest.framework")
                || marker.contains("/xctest.framework/")
        }
    }
}
