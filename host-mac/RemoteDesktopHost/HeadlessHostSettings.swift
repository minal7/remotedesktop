import Darwin
import Foundation

enum HeadlessHostSettings {
    static let startAtLoginKey = "StartAtLogin"
    static let startListeningOnLaunchKey = "StartListeningOnLaunch"
    private static let legacyPairingCodeFileKey = "PairingCodeFile"
    private static let legacyPairingCodeFileName = "pairing-code.txt"

    static var startAtLogin: Bool {
        bool(forKey: startAtLoginKey, defaultValue: true)
    }

    static var startListeningOnLaunch: Bool {
        startListeningOnLaunch(
            defaults: .standard,
            arguments: CommandLine.arguments)
    }

    static func startAtLogin(defaults: UserDefaults) -> Bool {
        bool(forKey: startAtLoginKey, defaultValue: true, defaults: defaults)
    }

    static func startListeningOnLaunch(
        defaults: UserDefaults,
        arguments: [String]
    ) -> Bool {
        arguments.contains("--start-listening")
            || bool(
                forKey: startListeningOnLaunchKey,
                defaultValue: true,
                defaults: defaults)
    }

    /// Removes artifacts written by pre-automatic-pairing releases. Current
    /// releases never serialize the internal CloudKit session binding.
    static func removeLegacyManualPairingArtifacts(
        defaults: UserDefaults = .standard
    ) {
        let legacyDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/RemoteDesktopHost",
                isDirectory: true)
        removeLegacyManualPairingArtifacts(
            defaults: defaults,
            legacyDirectoryURL: legacyDirectoryURL)
    }

    /// The explicit directory keeps the filesystem boundary testable without
    /// reading or mutating the real user defaults or Application Support tree.
    /// Production callers use the overload above, whose directory is fixed.
    static func removeLegacyManualPairingArtifacts(
        defaults: UserDefaults,
        legacyDirectoryURL: URL
    ) {
        // The retired preference is untrusted legacy input. Clear it without
        // parsing or using its value as a filesystem path.
        defaults.removeObject(forKey: legacyPairingCodeFileKey)
        removeFixedLegacyPairingCodeFile(in: legacyDirectoryURL)
    }

    private static func removeFixedLegacyPairingCodeFile(
        in directoryURL: URL
    ) {
        let directory = directoryURL.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directory >= 0 else { return }
        defer { Darwin.close(directory) }

        var directoryStatus = stat()
        guard Darwin.fstat(directory, &directoryStatus) == 0,
              legacyPairingCodeDirectoryCanBeUsed(directoryStatus) else {
            return
        }

        var namedStatus = stat()
        let statusResult = legacyPairingCodeFileName.withCString {
            Darwin.fstatat(
                directory,
                $0,
                &namedStatus,
                AT_SYMLINK_NOFOLLOW)
        }
        guard statusResult == 0,
              legacyPairingCodeFileCanBeRemoved(namedStatus) else {
            return
        }

        let file = legacyPairingCodeFileName.withCString {
            Darwin.openat(
                directory,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard file >= 0 else { return }
        defer { Darwin.close(file) }

        var openedStatus = stat()
        guard Darwin.fstat(file, &openedStatus) == 0,
              legacyPairingCodeFileCanBeRemoved(openedStatus),
              openedStatus.st_dev == namedStatus.st_dev,
              openedStatus.st_ino == namedStatus.st_ino else {
            return
        }

        // Revalidate the directory entry immediately before unlinking it. The
        // descriptor pins the parent and O_NOFOLLOW prevents either check from
        // following a substituted final-component symlink.
        var finalStatus = stat()
        let finalStatusResult = legacyPairingCodeFileName.withCString {
            Darwin.fstatat(
                directory,
                $0,
                &finalStatus,
                AT_SYMLINK_NOFOLLOW)
        }
        guard finalStatusResult == 0,
              legacyPairingCodeFileCanBeRemoved(finalStatus),
              finalStatus.st_dev == openedStatus.st_dev,
              finalStatus.st_ino == openedStatus.st_ino else {
            return
        }

        _ = legacyPairingCodeFileName.withCString {
            Darwin.unlinkat(directory, $0, 0)
        }
    }

    static func legacyPairingCodeFileCanBeRemoved(
        _ status: stat,
        expectedOwnerID: uid_t = Darwin.geteuid()
    ) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == expectedOwnerID
            && status.st_nlink == 1
    }

    static func legacyPairingCodeDirectoryCanBeUsed(
        _ status: stat,
        expectedOwnerID: uid_t = Darwin.geteuid()
    ) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR
            && status.st_uid == expectedOwnerID
    }

    private static func bool(
        forKey key: String,
        defaultValue: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let value = defaults.object(forKey: key) as? Bool else {
            return defaultValue
        }
        return value
    }
}
