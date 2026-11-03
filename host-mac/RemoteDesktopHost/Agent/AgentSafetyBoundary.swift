import Foundation

enum AgentSafetyBoundary {
    private static let blockedBundleIDs: Set<String> = [
        "com.apple.keychainaccess", "com.apple.terminal", "com.googlecode.iterm2",
        "com.1password.1password", "com.bitwarden.desktop", "com.dashlane.dashlane",
        "com.lastpass.lastpass", "org.keepassxc.keepassxc"
    ]

    static func blocksAutomation(bundleID: String?, appName: String?) -> Bool {
        let bundle = bundleID?.lowercased() ?? ""
        let name = appName?.lowercased() ?? ""
        if blockedBundleIDs.contains(bundle) { return true }
        if name.contains("system settings") || bundle == "com.apple.systempreferences" { return false }
        let financeTerms = ["bank", "credit union", "online banking", "investment account"]
        return financeTerms.contains { name.contains($0) }
    }

    static func readOnly(bundleID: String?, appName: String?) -> Bool {
        (bundleID?.lowercased() == "com.apple.systempreferences") ||
        (appName?.localizedCaseInsensitiveContains("System Settings") == true)
    }
}
