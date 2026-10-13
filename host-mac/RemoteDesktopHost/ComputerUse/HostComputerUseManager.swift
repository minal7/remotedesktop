import AppKit
import ApplicationServices
import CoreGraphics
import CoreImage
import CryptoKit
import Dispatch
import Foundation
import OSLog
import Security

/// Flattens host context that is interpolated into a model prompt. Application
/// labels and action history are context, never prompt structure: line/control
/// characters become one ordinary space and output is bounded by UTF-8 bytes.
enum ComputerUsePromptSanitizer {
    static func inline(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> String {
        guard maximumUTF8Bytes > 0 else { return "" }
        var output = ""
        var byteCount = 0
        var pendingSpace = false
        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || CharacterSet.whitespaces.contains(scalar) {
                pendingSpace = !output.isEmpty
                continue
            }
            let fragment = String(scalar)
            let fragmentBytes = fragment.utf8.count
            let spaceBytes = pendingSpace ? 1 : 0
            guard byteCount + spaceBytes + fragmentBytes
                    <= maximumUTF8Bytes else {
                break
            }
            if pendingSpace {
                output.append(" ")
                byteCount += 1
                pendingSpace = false
            }
            output.append(fragment)
            byteCount += fragmentBytes
        }
        return output
    }
}

/// Proof that a bundle path and live PID describe the same valid signed code.
/// Applications launched by computer use carry a pinned Apple/team authority;
/// an already-running unreviewed application may carry only its generic code
/// identity for observation and state invalidation. These value-only fields
/// can cross actor boundaries; Security objects never do.
struct ComputerUseApplicationCodeIdentity:
    Equatable, Hashable, Sendable {
    enum Authority: String, Equatable, Hashable, Sendable {
        case runningCode
        case reviewedPinned
    }

    let authority: Authority
    let bundleIdentifier: String
    let canonicalBundlePath: String
    let canonicalExecutablePath: String
    let designatedRequirement: String
    let teamIdentifier: String?
    let platformIdentifier: UInt32?
}

/// Canonical identity sampled from Launch Services and rebound to signed-code
/// proof. The localized application name is deliberately excluded: an app
/// controls that label and can call itself "Notes" or inject prompt
/// delimiters. PID plus launch generation
/// distinguishes a later process that reused the same bundle identifier for
/// host fingerprints and ledgers, but those process-local values never enter
/// model context.
struct ComputerUseApplicationIdentity: Equatable, Hashable, Sendable {
    struct ReviewedApplication: Equatable, Sendable {
        let canonicalName: String
        let aliases: [String]
        let bundleIdentifiers: Set<String>
    }

    /// One host-owned registry supplies both natural-language app routing and
    /// signed-code verification. Keeping those views together prevents a
    /// planner alias from silently drifting away from the identity that the
    /// executor will actually launch and attest.
    static let reviewedApplications: [ReviewedApplication] = [
        .init(
            canonicalName: "Notes",
            aliases: ["Notes", "Apple Notes"],
            bundleIdentifiers: ["com.apple.Notes"]),
        .init(
            canonicalName: "Mail",
            aliases: ["Mail", "Apple Mail"],
            bundleIdentifiers: ["com.apple.mail"]),
        .init(
            canonicalName: "Calendar",
            aliases: ["Calendar", "Apple Calendar"],
            bundleIdentifiers: ["com.apple.iCal"]),
        .init(
            canonicalName: "Finder",
            aliases: ["Finder"],
            bundleIdentifiers: ["com.apple.finder"]),
        .init(
            canonicalName: "Safari",
            aliases: ["Safari"],
            bundleIdentifiers: ["com.apple.Safari"]),
        .init(
            canonicalName: "Google Chrome",
            aliases: ["Google Chrome", "Chrome"],
            bundleIdentifiers: ["com.google.Chrome"]),
        .init(
            canonicalName: "Reminders",
            aliases: ["Reminders", "Apple Reminders"],
            bundleIdentifiers: ["com.apple.reminders"]),
        .init(
            canonicalName: "Books",
            aliases: ["Books", "Apple Books"],
            bundleIdentifiers: ["com.apple.iBooksX"]),
        .init(
            canonicalName: "TextEdit",
            aliases: ["TextEdit"],
            bundleIdentifiers: ["com.apple.TextEdit"]),
        .init(
            canonicalName: "Freeform",
            aliases: ["Freeform", "Apple Freeform"],
            bundleIdentifiers: ["com.apple.freeform"]),
        .init(
            canonicalName: "Stickies",
            aliases: ["Stickies"],
            bundleIdentifiers: ["com.apple.Stickies"]),
        .init(
            canonicalName: "Preview",
            aliases: ["Preview"],
            bundleIdentifiers: ["com.apple.Preview"]),
        .init(
            canonicalName: "Maps",
            aliases: ["Maps", "Apple Maps"],
            bundleIdentifiers: ["com.apple.Maps"]),
        .init(
            canonicalName: "Music",
            aliases: ["Music", "Apple Music"],
            bundleIdentifiers: ["com.apple.Music"]),
    ]

    static let maximumBundleIdentifierBytes = 255

    let bundleIdentifier: String
    let processIdentifier: pid_t
    let launchGeneration: UInt64?
    let codeIdentity: ComputerUseApplicationCodeIdentity?

    init?(
        bundleIdentifier: String?,
        processIdentifier: pid_t,
        launchGeneration: UInt64? = nil,
        codeIdentity: ComputerUseApplicationCodeIdentity? = nil
    ) {
        guard let bundleIdentifier,
              !bundleIdentifier.isEmpty,
              bundleIdentifier.utf8.count
                <= Self.maximumBundleIdentifierBytes,
              processIdentifier > 0,
              bundleIdentifier.utf8.allSatisfy({ byte in
                  (byte >= 0x41 && byte <= 0x5A)
                    || (byte >= 0x61 && byte <= 0x7A)
                    || (byte >= 0x30 && byte <= 0x39)
                    || byte == 0x2E || byte == 0x2D
              }),
              codeIdentity?.bundleIdentifier == bundleIdentifier
                || codeIdentity == nil else {
            return nil
        }
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.launchGeneration = launchGeneration
        self.codeIdentity = codeIdentity
    }

    init?(
        runningApplication: NSRunningApplication,
        codeIdentity suppliedCodeIdentity:
            ComputerUseApplicationCodeIdentity? = nil
    ) {
        let launchGeneration: UInt64?
        if let date = runningApplication.launchDate {
            let milliseconds = date.timeIntervalSince1970 * 1_000
            launchGeneration = milliseconds.isFinite && milliseconds >= 0
                ? UInt64(milliseconds.rounded(.down))
                : nil
        } else {
            launchGeneration = nil
        }
        let codeIdentity = suppliedCodeIdentity
            ?? ComputerUseReviewedApplicationCodeVerifier
                .proofForRunningApplication(
                    runningApplication: runningApplication)
        self.init(
            bundleIdentifier: runningApplication.bundleIdentifier,
            processIdentifier: runningApplication.processIdentifier,
            launchGeneration: launchGeneration,
            codeIdentity: codeIdentity)
    }

    var stableSortKey: String {
        "\(bundleIdentifier.lowercased())\u{0}\(processIdentifier)\u{0}\(launchGeneration ?? 0)"
    }

    var promptDescription: String {
        guard let codeIdentity else { return "unknown" }
        let displayName = codeIdentity.authority == .reviewedPinned
            ? Self.reviewedApplicationName(
                forBundleIdentifier: bundleIdentifier)
            : nil
        let prefix = displayName.map { "\($0) • " } ?? ""
        return "\(prefix)bundle=\(bundleIdentifier.lowercased())"
    }

    func matchesReviewedApplication(named applicationName: String) -> Bool {
        guard let identifiers = Self.reviewedBundleIdentifiers(
            forApplicationNamed: applicationName),
              identifiers.contains(bundleIdentifier),
              let codeIdentity,
              codeIdentity.authority == .reviewedPinned,
              codeIdentity.bundleIdentifier == bundleIdentifier else {
            return false
        }
        return true
    }

    static func reviewedBundleIdentifiers(
        forApplicationNamed rawName: String
    ) -> Set<String>? {
        let normalized = normalizedApplicationName(rawName)
        return reviewedApplications.first { application in
            application.aliases.contains {
                normalizedApplicationName($0) == normalized
            }
        }?.bundleIdentifiers
    }

    static func reviewedApplicationName(
        forBundleIdentifier bundleIdentifier: String
    ) -> String? {
        reviewedApplications.first { application in
            application.bundleIdentifiers.contains {
                $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
            }
        }?.canonicalName
    }

    static let allReviewedBundleIdentifiers = Set(
        reviewedApplications.flatMap(\.bundleIdentifiers))

    private static func normalizedApplicationName(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar)
                ? Character(String(scalar)) : " "
        }).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Security.framework boundary for reviewed applications. Launch Services is
/// used only to locate a candidate. The candidate bundle is checked against a
/// pinned requirement, then the launched PID is checked against that exact
/// requirement and rebound to the same canonical bundle/executable paths.
enum ComputerUseReviewedApplicationCodeVerifier {
    enum VerificationError: Error {
        case invalidCandidate
        case invalidSignature
        case runningCodeMismatch
    }

    struct StaticIdentity {
        let proof: ComputerUseApplicationCodeIdentity
        let designatedRequirement: SecRequirement
    }

    private final class StaticIdentityCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: StaticIdentity] = [:]

        func value(for key: String) -> StaticIdentity? {
            lock.withLock { values[key] }
        }

        func insert(_ value: StaticIdentity, for key: String) {
            lock.withLock { values[key] = value }
        }
    }

    private final class RunningIdentityCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: ComputerUseApplicationCodeIdentity] = [:]

        func value(for key: String) -> ComputerUseApplicationCodeIdentity? {
            lock.withLock { values[key] }
        }

        func insert(
            _ value: ComputerUseApplicationCodeIdentity,
            for key: String
        ) {
            lock.withLock { values[key] = value }
        }
    }

    private static let staticIdentityCache = StaticIdentityCache()
    private static let runningIdentityCache = RunningIdentityCache()

    static func proofForRunningApplication(
        runningApplication: NSRunningApplication
    ) -> ComputerUseApplicationCodeIdentity? {
        guard let identifier = runningApplication.bundleIdentifier else {
            return nil
        }
        let cacheKey = runningCacheKey(
            runningApplication,
            bundleIdentifier: identifier)
        if let cacheKey,
           let cached = runningIdentityCache.value(for: cacheKey) {
            return cached
        }
        let proof: ComputerUseApplicationCodeIdentity?
        if ComputerUseApplicationIdentity.allReviewedBundleIdentifiers
            .contains(identifier) {
            guard let bundleURL = runningApplication.bundleURL,
                  let staticIdentity = try? cachedStaticIdentity(
                applicationURL: bundleURL,
                bundleIdentifier: identifier),
                  let verifiedProof = try? verifyRunning(
                runningApplication,
                against: staticIdentity) else {
                // A reviewed identifier that fails its pinned proof must not
                // downgrade into the generic code-proven bundle grammar.
                return nil
            }
            proof = verifiedProof
        } else {
            proof = try? verifyUnreviewedRunning(runningApplication)
        }
        if let cacheKey, let proof {
            runningIdentityCache.insert(proof, for: cacheKey)
        }
        return proof
    }

    private static func runningCacheKey(
        _ runningApplication: NSRunningApplication,
        bundleIdentifier: String
    ) -> String? {
        guard runningApplication.processIdentifier > 0,
              let launchDate = runningApplication.launchDate,
              let bundlePath = runningApplication.bundleURL?
                .resolvingSymlinksInPath().standardizedFileURL.path,
              let executablePath = runningApplication.executableURL?
                .resolvingSymlinksInPath().standardizedFileURL.path else {
            return nil
        }
        return [
            bundleIdentifier,
            String(runningApplication.processIdentifier),
            String(launchDate.timeIntervalSince1970.bitPattern),
            bundlePath,
            executablePath,
        ].joined(separator: "\u{0}")
    }

    private static func cachedStaticIdentity(
        applicationURL: URL,
        bundleIdentifier: String
    ) throws -> StaticIdentity {
        let canonicalPath = applicationURL
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let key = "\(bundleIdentifier)\u{0}\(canonicalPath)"
        if let cached = staticIdentityCache.value(for: key) {
            return cached
        }
        let verified = try verifyStatic(
            applicationURL: applicationURL,
            expectedBundleIdentifiers: [bundleIdentifier])
        staticIdentityCache.insert(verified, for: key)
        return verified
    }

    static func verifyStatic(
        applicationURL suppliedURL: URL,
        expectedBundleIdentifiers: Set<String>
    ) throws -> StaticIdentity {
        guard suppliedURL.isFileURL,
              !expectedBundleIdentifiers.isEmpty,
              expectedBundleIdentifiers.isSubset(
                of: ComputerUseApplicationIdentity
                    .allReviewedBundleIdentifiers) else {
            throw VerificationError.invalidCandidate
        }
        let applicationURL = suppliedURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard applicationURL.pathExtension == "app",
              let bundle = Bundle(url: applicationURL),
              let bundleIdentifier = bundle.bundleIdentifier,
              expectedBundleIdentifiers.contains(bundleIdentifier),
              let suppliedExecutableURL = bundle.executableURL else {
            throw VerificationError.invalidCandidate
        }
        let executableURL = suppliedExecutableURL
            .resolvingSymlinksInPath()
            .standardizedFileURL

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            applicationURL as CFURL,
            SecCSFlags(),
            &staticCode) == errSecSuccess,
              let staticCode else {
            throw VerificationError.invalidSignature
        }
        let strictFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(
            staticCode,
            strictFlags,
            nil) == errSecSuccess else {
            throw VerificationError.invalidSignature
        }
        let information = try signingInformation(for: staticCode)
        guard information.identifier == bundleIdentifier,
              let embeddedRequirement = information.designatedRequirement,
              let embeddedRequirementText = requirementText(
                embeddedRequirement) else {
            throw VerificationError.invalidSignature
        }

        let pinnedRequirement: SecRequirement
        if bundleIdentifier.hasPrefix("com.apple.") {
            var requirement: SecRequirement?
            let requirementText =
                "anchor apple and identifier \"\(bundleIdentifier)\""
            guard SecRequirementCreateWithString(
                requirementText as CFString,
                SecCSFlags(),
                &requirement) == errSecSuccess,
                  let requirement,
                  let platformIdentifier = information.platformIdentifier,
                  platformIdentifier > 0 else {
                throw VerificationError.invalidSignature
            }
            pinnedRequirement = requirement
        } else {
            let expectedTeamIdentifier: String
            switch bundleIdentifier {
            case "com.google.Chrome":
                expectedTeamIdentifier = "EQHXZ8M8AV"
            default:
                throw VerificationError.invalidSignature
            }
            guard information.teamIdentifier == expectedTeamIdentifier else {
                throw VerificationError.invalidSignature
            }
            var requirement: SecRequirement?
            let requirementText = "anchor apple generic"
                + " and identifier \"\(bundleIdentifier)\""
                + " and certificate leaf[subject.OU]"
                + " = \"\(expectedTeamIdentifier)\""
            guard SecRequirementCreateWithString(
                requirementText as CFString,
                SecCSFlags(),
                &requirement) == errSecSuccess,
                  let requirement else {
                throw VerificationError.invalidSignature
            }
            pinnedRequirement = requirement
        }
        guard SecStaticCodeCheckValidity(
            staticCode,
            strictFlags,
            pinnedRequirement) == errSecSuccess else {
            throw VerificationError.invalidSignature
        }

        return StaticIdentity(
            proof: ComputerUseApplicationCodeIdentity(
                authority: .reviewedPinned,
                bundleIdentifier: bundleIdentifier,
                canonicalBundlePath: applicationURL.path,
                canonicalExecutablePath: executableURL.path,
                designatedRequirement: embeddedRequirementText,
                teamIdentifier: information.teamIdentifier,
                platformIdentifier: information.platformIdentifier),
            designatedRequirement: pinnedRequirement)
    }

    static func verifyRunning(
        _ runningApplication: NSRunningApplication,
        against staticIdentity: StaticIdentity
    ) throws -> ComputerUseApplicationCodeIdentity {
        let proof = staticIdentity.proof
        guard !runningApplication.isTerminated,
              runningApplication.processIdentifier > 0,
              runningApplication.bundleIdentifier == proof.bundleIdentifier,
              runningApplication.bundleURL?
                .resolvingSymlinksInPath()
                .standardizedFileURL.path == proof.canonicalBundlePath,
              runningApplication.executableURL?
                .resolvingSymlinksInPath()
                .standardizedFileURL.path == proof.canonicalExecutablePath else {
            throw VerificationError.runningCodeMismatch
        }
        let attributes = [
            kSecGuestAttributePid as String:
                NSNumber(value: runningApplication.processIdentifier),
        ] as CFDictionary
        var runningCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &runningCode) == errSecSuccess,
              let runningCode,
              SecCodeCheckValidity(
                runningCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                staticIdentity.designatedRequirement) == errSecSuccess else {
            throw VerificationError.runningCodeMismatch
        }

        var runningStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            runningCode,
            SecCSFlags(),
            &runningStaticCode) == errSecSuccess,
              let runningStaticCode else {
            throw VerificationError.runningCodeMismatch
        }
        let information = try signingInformation(for: runningStaticCode)
        guard information.identifier == proof.bundleIdentifier,
              information.teamIdentifier == proof.teamIdentifier,
              information.platformIdentifier == proof.platformIdentifier,
              let runningRequirement = information.designatedRequirement,
              requirementText(runningRequirement)
                == proof.designatedRequirement else {
            throw VerificationError.runningCodeMismatch
        }
        var runningPath: CFURL?
        guard SecCodeCopyPath(
            runningStaticCode,
            SecCSFlags(),
            &runningPath) == errSecSuccess,
              let runningPath else {
            throw VerificationError.runningCodeMismatch
        }
        let canonicalRunningPath = (runningPath as URL)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard canonicalRunningPath == proof.canonicalExecutablePath
                || canonicalRunningPath == proof.canonicalBundlePath else {
            throw VerificationError.runningCodeMismatch
        }
        return proof
    }

    private static func verifyUnreviewedRunning(
        _ runningApplication: NSRunningApplication
    ) throws -> ComputerUseApplicationCodeIdentity {
        guard !runningApplication.isTerminated,
              runningApplication.processIdentifier > 0,
              let bundleIdentifier = runningApplication.bundleIdentifier,
              !ComputerUseApplicationIdentity.allReviewedBundleIdentifiers
                .contains(bundleIdentifier),
              let suppliedBundleURL = runningApplication.bundleURL,
              let suppliedExecutableURL = runningApplication.executableURL else {
            throw VerificationError.runningCodeMismatch
        }
        let bundleURL = suppliedBundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let executableURL = suppliedExecutableURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let attributes = [
            kSecGuestAttributePid as String:
                NSNumber(value: runningApplication.processIdentifier),
        ] as CFDictionary
        var runningCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &runningCode) == errSecSuccess,
              let runningCode,
              SecCodeCheckValidity(
                runningCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil) == errSecSuccess else {
            throw VerificationError.runningCodeMismatch
        }
        var runningStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            runningCode,
            SecCSFlags(),
            &runningStaticCode) == errSecSuccess,
              let runningStaticCode,
              SecStaticCodeCheckValidity(
                runningStaticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil) == errSecSuccess else {
            throw VerificationError.runningCodeMismatch
        }
        let information = try signingInformation(for: runningStaticCode)
        guard information.identifier == bundleIdentifier,
              let designatedRequirement = information.designatedRequirement,
              let designatedRequirementText = requirementText(
                designatedRequirement) else {
            throw VerificationError.runningCodeMismatch
        }
        var runningPath: CFURL?
        guard SecCodeCopyPath(
            runningStaticCode,
            SecCSFlags(),
            &runningPath) == errSecSuccess,
              let runningPath else {
            throw VerificationError.runningCodeMismatch
        }
        let canonicalRunningPath = (runningPath as URL)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard canonicalRunningPath == executableURL.path
                || canonicalRunningPath == bundleURL.path else {
            throw VerificationError.runningCodeMismatch
        }
        return ComputerUseApplicationCodeIdentity(
            authority: .runningCode,
            bundleIdentifier: bundleIdentifier,
            canonicalBundlePath: bundleURL.path,
            canonicalExecutablePath: executableURL.path,
            designatedRequirement: designatedRequirementText,
            teamIdentifier: information.teamIdentifier,
            platformIdentifier: information.platformIdentifier)
    }

    private struct SigningInformation {
        let identifier: String?
        let designatedRequirement: SecRequirement?
        let teamIdentifier: String?
        let platformIdentifier: UInt32?
    }

    private static func signingInformation(
        for code: SecStaticCode
    ) throws -> SigningInformation {
        var rawInformation: CFDictionary?
        let flags = SecCSFlags(
            rawValue: kSecCSSigningInformation
                | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(
            code,
            flags,
            &rawInformation) == errSecSuccess,
              let information = rawInformation as? [CFString: Any] else {
            throw VerificationError.invalidSignature
        }
        let designatedRequirement: SecRequirement?
        if let rawRequirement = information[
            kSecCodeInfoDesignatedRequirement],
           CFGetTypeID(rawRequirement as CFTypeRef)
                == SecRequirementGetTypeID() {
            designatedRequirement = unsafeBitCast(
                rawRequirement as CFTypeRef,
                to: SecRequirement.self)
        } else {
            designatedRequirement = nil
        }
        return SigningInformation(
            identifier: information[kSecCodeInfoIdentifier] as? String,
            designatedRequirement: designatedRequirement,
            teamIdentifier:
                information[kSecCodeInfoTeamIdentifier] as? String,
            platformIdentifier:
                (information[kSecCodeInfoPlatformIdentifier] as? NSNumber)?
                    .uint32Value)
    }

    private static func requirementText(
        _ requirement: SecRequirement
    ) -> String? {
        var text: CFString?
        guard SecRequirementCopyString(
            requirement,
            SecCSFlags(),
            &text) == errSecSuccess else {
            return nil
        }
        return text as String?
    }
}

struct ComputerUseFrontmostApplicationSnapshot: Equatable, Sendable {
    let localizedName: String?
    let identity: ComputerUseApplicationIdentity?
    let identityIsAuthoritative: Bool

    var policyName: String? {
        if identityIsAuthoritative {
            guard let identity else { return nil }
            return ComputerUseApplicationIdentity.reviewedApplicationName(
                forBundleIdentifier: identity.bundleIdentifier)
                ?? identity.bundleIdentifier
        }
        guard let localizedName else { return nil }
        let sanitized = ComputerUsePromptSanitizer.inline(
            localizedName,
            maximumUTF8Bytes: 256)
        return sanitized.isEmpty ? nil : sanitized
    }
}

struct ComputerUseKeyboardCaretEvidence {
    let applicationIdentity: ComputerUseApplicationIdentity
    let window: ComputerUseFrontmostWindowCaptureIdentity
    let text: ComputerUseTextSnapshot
    let frame: CGRect
    let image: ComputerUseDesktopImage
    // Live keyboard captures preserve the whole field and the existing
    // approval checkpoint. Legacy evidence retains whole-window comparison.
    let comparisonScope: CGRect?
    let checkpointBounds: CGRect?

    init(applicationIdentity: ComputerUseApplicationIdentity, window: ComputerUseFrontmostWindowCaptureIdentity,
         text: ComputerUseTextSnapshot, frame: CGRect, image: ComputerUseDesktopImage,
         comparisonScope: CGRect? = nil, checkpointBounds: CGRect? = nil) {
        self.applicationIdentity = applicationIdentity; self.window = window
        self.text = text; self.frame = frame; self.image = image
        self.comparisonScope = comparisonScope; self.checkpointBounds = checkpointBounds
    }
}

struct ComputerUseApprovalFingerprint: Equatable {
    let action: ComputerUsePredictedAction
    let applicationID: String
    let accessibilityIdentity: String
    let visualDigest: String?
    let keyboardCaretEvidence: ComputerUseKeyboardCaretEvidence?

    init(action: ComputerUsePredictedAction, applicationID: String, accessibilityIdentity: String,
         visualDigest: String?, keyboardCaretEvidence: ComputerUseKeyboardCaretEvidence? = nil) {
        self.action = action
        self.applicationID = applicationID
        self.accessibilityIdentity = accessibilityIdentity
        self.visualDigest = visualDigest
        self.keyboardCaretEvidence = keyboardCaretEvidence
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.action == rhs.action && lhs.applicationID == rhs.applicationID
            && lhs.accessibilityIdentity == rhs.accessibilityIdentity && lhs.visualDigest == rhs.visualDigest
    }

    func matchesForFinalDispatch(_ other: Self) -> Bool {
        guard let evidence = keyboardCaretEvidence,
              let otherEvidence = other.keyboardCaretEvidence else {
            return keyboardCaretEvidence == nil && other.keyboardCaretEvidence == nil && self == other
        }
        guard self.action == other.action,
              self.applicationID == other.applicationID,
              self.accessibilityIdentity == other.accessibilityIdentity,
              case .key = self.action,
              Self.hasEligibleKeyboardEvidence(evidence, applicationID: applicationID),
              Self.hasEligibleKeyboardEvidence(otherEvidence, applicationID: other.applicationID),
              evidence.applicationIdentity == otherEvidence.applicationIdentity,
              evidence.window == otherEvidence.window,
              evidence.text == otherEvidence.text,
              evidence.frame == otherEvidence.frame,
              evidence.comparisonScope == otherEvidence.comparisonScope,
              evidence.checkpointBounds == otherEvidence.checkpointBounds,
              evidence.image.displayBounds == otherEvidence.image.displayBounds,
              evidence.image.pixelWidth == otherEvidence.image.pixelWidth,
              evidence.image.pixelHeight == otherEvidence.image.pixelHeight else { return false }

        // Preserve exact legacy matching once the extra proof has been
        // validated. Otherwise permit only a verified insertion-caret repaint.
        if self == other { return true }
        let comparisonBounds = evidence.comparisonScope ?? evidence.window.bounds
        return (try? evidence.image.matchesInsertionPointPixels(of: otherEvidence.image,
            window: comparisonBounds, field: evidence.frame)) == true
    }

    static func keyboardCaretComparisonScope(
        focusedFrame: CGRect, windowBounds: CGRect, displayBounds: CGRect, checkpoint: CGPoint,
        sourcePixelWidth: Int, sourcePixelHeight: Int
    ) -> CGRect? {
        func finite(_ rect: CGRect) -> Bool {
            !rect.isNull && !rect.isEmpty
                && [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.width, rect.height].allSatisfy(\.isFinite)
        }
        guard finite(focusedFrame), finite(windowBounds), finite(displayBounds),
              displayBounds.contains(windowBounds), windowBounds.contains(focusedFrame),
              checkpoint.x.isFinite, checkpoint.y.isFinite, windowBounds.contains(checkpoint),
              sourcePixelWidth > 0, sourcePixelHeight > 0 else { return nil }
        let scaleX = CGFloat(sourcePixelWidth) / displayBounds.width
        let scaleY = CGFloat(sourcePixelHeight) / displayBounds.height
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return nil }
        let checkpointBounds = CGRect(x: checkpoint.x - 48 / scaleX, y: checkpoint.y - 48 / scaleY,
            width: 96 / scaleX, height: 96 / scaleY).intersection(windowBounds)
        guard finite(checkpointBounds) else { return nil }
        let scope = focusedFrame.union(checkpointBounds).intersection(windowBounds)
        guard finite(scope), scope.contains(focusedFrame), scope.contains(checkpointBounds) else { return nil }
        return scope
    }

    private static func hasEligibleKeyboardEvidence(
        _ evidence: ComputerUseKeyboardCaretEvidence, applicationID: String
    ) -> Bool {
        let app = evidence.applicationIdentity
        let window = evidence.window.bounds
        let display = evidence.image.displayBounds
        let text = evidence.text
        func finite(_ rect: CGRect) -> Bool {
            !rect.isNull && !rect.isEmpty
                && [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.width, rect.height].allSatisfy(\.isFinite)
        }
        let selection = text.selection
        let scopeIsValid: Bool
        if let scope = evidence.comparisonScope, let checkpoint = evidence.checkpointBounds {
            let expected = evidence.frame.union(checkpoint).intersection(window)
            scopeIsValid = finite(scope) && finite(checkpoint)
                && window.contains(checkpoint) && scope == expected
                && scope.contains(evidence.frame) && scope.contains(checkpoint)
        } else {
            scopeIsValid = evidence.comparisonScope == nil && evidence.checkpointBounds == nil
        }
        return scopeIsValid
            && app.codeIdentity != nil
            && app.bundleIdentifier == applicationID
            && app.processIdentifier == evidence.window.applicationProcessIdentifier
            && finite(window) && finite(display) && finite(evidence.frame)
            && window.contains(evidence.frame) && display.contains(window)
            && display.contains(evidence.frame)
            && evidence.image.pixelWidth > 0 && evidence.image.pixelHeight > 0
            && !text.targetID.isEmpty && text.isEditable && !text.isSecure
            && selection.location >= 0 && selection.length == 0
            && selection.location <= (text.value as NSString).length
    }
}

fileprivate struct ComputerUsePreparedApproval {
    let message: String
    let fingerprint: ComputerUseApprovalFingerprint
}

/// Dependency boundary used by deterministic host tests. Production leaves
/// the provider nil and always derives these values from the live frontmost
/// app, Accessibility tree, and bounded screen pixels.
struct ComputerUseApprovalTargetSnapshot: Equatable {
    let context: String
    let applicationID: String
    let accessibilityIdentity: String
    var frame: CGRect? = nil
}

/// Privacy-bounded Accessibility evidence used only to decide whether the
/// person must take over for authentication. Editable field values are never
/// included. Tests inject this seam without touching the live desktop.
struct ComputerUseAuthenticationContextSnapshot: Equatable {
    let focusedElement: String?
    let boundedWindowContext: String
}

/// Identity sampled immediately before and after a display capture. Quote and
/// sign-in OCR may use the focused-window rectangle only when both samples
/// still describe the same Accessibility window at the same location.
struct ComputerUseFrontmostWindowCaptureIdentity: Equatable {
    let applicationProcessIdentifier: pid_t
    let accessibilityWindowHash: CFHashCode
    let bounds: CGRect
}

struct ComputerUseActiveDisplay: Equatable {
    let identifier: CGDirectDisplayID
    let bounds: CGRect
}

/// Selects the one active display that contains the complete focused AX
/// window. Nil is fail-closed for spanning, mirrored, or malformed geometry.
enum ComputerUseFocusedDisplaySelector {
    static func select(windowBounds: CGRect, activeDisplays: [ComputerUseActiveDisplay]) -> ComputerUseActiveDisplay? {
        func valid(_ rect: CGRect) -> Bool {
            !rect.isNull && !rect.isInfinite && !rect.isEmpty
                && [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
        }
        guard valid(windowBounds), !activeDisplays.isEmpty, activeDisplays.count <= 32,
              activeDisplays.allSatisfy({ $0.identifier != 0 && valid($0.bounds) }),
              Set(activeDisplays.map(\.identifier)).count == activeDisplays.count else { return nil }
        let candidates = activeDisplays.filter { $0.bounds.contains(windowBounds) }
        guard candidates.count == 1, let selected = candidates.first else { return nil }
        // Mirrored or otherwise overlapping display geometry cannot identify
        // a unique coordinate-to-panel mapping for this focused window.
        guard !activeDisplays.contains(where: { display in
            guard display.identifier != selected.identifier else { return false }
            let overlap = display.bounds.intersection(windowBounds)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }) else { return nil }
        return selected
    }

    static func isStable(before: ComputerUseActiveDisplay?, after: ComputerUseActiveDisplay?) -> Bool {
        guard let before, let after else { return false }
        return before == after
    }
}

/// One public Window Server entry in top-to-bottom list order. This describes
/// visible composition; it does not replace the app receiving keyboard events.
struct ComputerUseVisibleWindowEntry: Equatable {
    let ownerProcessIdentifier: pid_t
    let layer: Int
    let bounds: CGRect
    let alpha: CGFloat

    init?(windowInfo: [String: Any]) {
        guard let owner = windowInfo[kCGWindowOwnerPID as String] as? Int,
              let ownerPID = pid_t(exactly: owner), ownerPID > 0,
              let layer = windowInfo[kCGWindowLayer as String] as? Int,
              let rawBounds = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let alphaNumber = windowInfo[kCGWindowAlpha as String] as? NSNumber else { return nil }
        var bounds = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(rawBounds as CFDictionary, &bounds),
              !bounds.isNull, !bounds.isInfinite,
              [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite) else { return nil }
        ownerProcessIdentifier = ownerPID; self.layer = layer
        self.bounds = bounds; alpha = CGFloat(alphaNumber.doubleValue)
    }

    init(ownerProcessIdentifier: pid_t, layer: Int, bounds: CGRect, alpha: CGFloat = 1) {
        self.ownerProcessIdentifier = ownerProcessIdentifier; self.layer = layer
        self.bounds = bounds; self.alpha = alpha
    }

    var hasValidGeometryAndAlpha: Bool {
        ownerProcessIdentifier > 0 && alpha.isFinite && (0...1).contains(alpha)
            && !bounds.isNull && !bounds.isInfinite && !bounds.isEmpty
            && [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite)
    }
}

/// Pure occlusion assessment for a retained focused window. Unknown means the
/// stack cannot prove that the visible pixels match the keyboard recipient.
struct ComputerUseVisibleWindowStack {
    enum Assessment: Equatable { case clear, occluded, unknown }
    let entries: [ComputerUseVisibleWindowEntry]
    private let hasInvalidRelevantEntry: Bool

    private static let relevantLayers: Set<Int> = [
        Int(CGWindowLevelForKey(.normalWindow)),
        Int(CGWindowLevelForKey(.floatingWindow)),
        Int(CGWindowLevelForKey(.modalPanelWindow)),
    ]

    init(windowInfo: [[String: Any]]) {
        var parsed: [ComputerUseVisibleWindowEntry] = []
        var invalid = false
        for info in windowInfo {
            guard let layer = info[kCGWindowLayer as String] as? Int else {
                invalid = true; continue
            }
            guard Self.relevantLayers.contains(layer) else { continue }
            guard let entry = ComputerUseVisibleWindowEntry(windowInfo: info),
                  entry.hasValidGeometryAndAlpha else {
                invalid = true; continue
            }
            parsed.append(entry)
        }
        entries = parsed; hasInvalidRelevantEntry = invalid
    }

    init(entries: [ComputerUseVisibleWindowEntry]) {
        self.entries = entries; hasInvalidRelevantEntry = false
    }

    func assessFocusedWindow(ownerProcessIdentifier: pid_t, bounds: CGRect) -> Assessment {
        guard !hasInvalidRelevantEntry, !bounds.isNull, !bounds.isInfinite,
              !bounds.isEmpty,
              [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite) else {
            return .unknown
        }
        let relevant = entries.filter { Self.relevantLayers.contains($0.layer) }
        guard relevant.allSatisfy(\.hasValidGeometryAndAlpha) else { return .unknown }
        guard let candidateIndex = relevant.firstIndex(where: {
            $0.ownerProcessIdentifier == ownerProcessIdentifier && $0.bounds == bounds
                && $0.hasValidGeometryAndAlpha && $0.alpha > 0
        }) else { return .unknown }
        for entry in relevant[..<candidateIndex] {
            guard entry.hasValidGeometryAndAlpha else { return .unknown }
            guard entry.alpha > 0, entry.ownerProcessIdentifier != ownerProcessIdentifier else { continue }
            let intersection = entry.bounds.intersection(bounds)
            if !intersection.isNull && !intersection.isEmpty
                && intersection.width > 0 && intersection.height > 0 {
                return .occluded
            }
        }
        return .clear
    }
}

/// Full text remains local until a current-turn document read is verified.
/// This identity is independent of helper element IDs, which expire with it.
struct ComputerUseMCPFocusedTextSnapshot: Equatable {
    let application: ComputerUseFrontmostApplicationSnapshot
    let window: ComputerUseFrontmostWindowCaptureIdentity
    let text: ComputerUseTextSnapshot
    let frame: CGRect
    let role: String
    let focusedElement: AXUIElement
    let documentIdentity: String?
    /// True only for the current retained AX binding whose parent path
    /// reaches an AXWebArea and the current window. Unknown stays false.
    var isWebContent: Bool = false

    func hasSameDocumentTarget(as other: Self) -> Bool {
        application == other.application && window == other.window
            && CFEqual(focusedElement, other.focusedElement)
            && documentIdentity == other.documentIdentity && frame == other.frame && role == other.role
            && isWebContent == other.isWebContent
            && text.isEditable == other.text.isEditable && text.isSecure == other.text.isSecure
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Text-edit bindings deliberately retire on scope notifications. A
        // read does not inherit mutation authority from that transient UUID.
        // Retain/compare the actual AX reference and exact current document.
        lhs.application == rhs.application && lhs.window == rhs.window
            && CFEqual(lhs.focusedElement, rhs.focusedElement)
            && lhs.documentIdentity == rhs.documentIdentity
            && lhs.isWebContent == rhs.isWebContent
            && lhs.frame == rhs.frame && lhs.role == rhs.role
            && lhs.text.value.utf8.elementsEqual(rhs.text.value.utf8)
            && lhs.text.selection == rhs.text.selection
            && lhs.text.isEditable == rhs.text.isEditable && lhs.text.isSecure == rhs.text.isSecure
    }

    var isReadable: Bool {
        isReadable(allowedRoles: ["AXTextArea"])
    }

    func isReadable(allowedRoles: Set<String>) -> Bool {
        application.identityIsAuthoritative
            && application.identity?.processIdentifier == window.applicationProcessIdentifier
            && allowedRoles.contains(role) && text.isEditable && !text.isSecure
            && !text.targetID.isEmpty
            && frame.width > 0 && frame.height > 0
            && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && window.bounds.intersects(frame)
    }
}

/// Closed host-owned commands used only by the retained default-browser flow.
/// This type is internal and is never decoded from a model proposal.
enum ComputerUseNativeBrowserHostCommand {
    case newWindow
    case focusAddress
    case commitAddress
    case driveOpenNewMenu
    case driveChooseFileUpload

    var usage: Int {
        switch self {
        case .newWindow: return 0x11 // N
        case .focusAddress: return 0x0F // L
        case .commitAddress: return 0x28 // Return
        case .driveOpenNewMenu: return 0x06 // C
        case .driveChooseFileUpload: return 0x18 // U
        }
    }

    var modifiers: UInt16 {
        switch self {
        case .newWindow, .focusAddress: return 1 << 3 // Command
        case .commitAddress: return 0
        case .driveOpenNewMenu: return 1 << 1 // Control
        case .driveChooseFileUpload: return 0
        }
    }

    var action: ComputerUsePredictedAction { .key(usage: usage, modifiers: modifiers) }
}

/// Narrow authority for typing a destination into a verified browser chrome
/// address field. Ordinary native text entry continues to require document,
/// frame, and element identity to remain unchanged.
struct ComputerUseNativeBrowserAddressEntryScope {
    let application: ComputerUseApplicationIdentity
    let window: ComputerUseFrontmostWindowCaptureIdentity
    let retainedWindow: AXUIElement
    let addressField: AXUIElement

    func isBoundToVerifiedSafariAddressField() -> Bool {
        guard application.bundleIdentifier == "com.apple.Safari",
              window.applicationProcessIdentifier == application.processIdentifier,
              CFHash(retainedWindow) == window.accessibilityWindowHash,
              window.bounds.width > 0, window.bounds.height > 0,
              [window.bounds.minX, window.bounds.minY, window.bounds.width, window.bounds.height].allSatisfy(\.isFinite) else { return false }
        var windowPID: pid_t = 0
        var fieldPID: pid_t = 0
        guard AXUIElementGetPid(retainedWindow, &windowPID) == .success,
              windowPID == application.processIdentifier,
              AXUIElementGetPid(addressField, &fieldPID) == .success,
              fieldPID == application.processIdentifier else { return false }
        // The retained Safari session constructs this scope only after its
        // bounded chrome-ancestry and address-field checks, and repeats those
        // checks at the effect boundary. Per-stroke authority is then bound to
        // this exact app, window, and AX field reference below.
        return true
    }

    func matches(_ snapshot: ComputerUseMCPFocusedTextSnapshot) -> Bool {
        let frame = snapshot.frame
        let bounds = window.bounds
        let validFrame = !frame.isNull && !frame.isInfinite && !frame.isEmpty
            && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && bounds.contains(frame)
        return snapshot.application.identityIsAuthoritative
            && snapshot.application.identity == application
            && snapshot.window == window
            && CFEqual(snapshot.focusedElement, addressField)
            && (snapshot.role == "AXTextField" || snapshot.role == "AXComboBox")
            && snapshot.text.isEditable && !snapshot.text.isSecure && !snapshot.isWebContent
            && validFrame
    }
}

/// Value-free identity of the UI state a semantic route was selected from.
/// The executor compares this fingerprint across every asynchronous planning
/// and grounding boundary and immediately before effects. Pixel hashing is
/// focused to the active window when its capture geometry is authoritative so
/// an unrelated menu-bar animation cannot continuously invalidate a task.
struct ComputerUsePlanningStateFingerprint: Equatable {
    let screenDigest: String
    let displayBounds: CGRect
    let frontmostWindowBounds: CGRect?
    let frontmostApplication: String?
    let frontmostApplicationIdentity: ComputerUseApplicationIdentity?
    let focusedAccessibilityIdentity: String?

    /// Revalidates authority for an application-open effect that was derived
    /// only from the trusted task and host-owned application routing. Cursor,
    /// hover, caret, and other harmless pixel animation must not starve that
    /// non-coordinate effect when the signed process, focused window/AX
    /// identity, and display geometry are unchanged.
    ///
    /// If any of those stronger authorities are unavailable, fall back to the
    /// complete visual fingerprint. This keeps synthetic, unsigned, or
    /// geometry-less observations fail-closed instead of treating a mutable
    /// localized application name as identity.
    func matchesNonVisualApplicationOpenAuthority(
        _ candidate: ComputerUsePlanningStateFingerprint
    ) -> Bool {
        matchesStableSignedFocusedAuthority(candidate)
    }

    /// Revalidates a task-bound semantic TYPE/ENTER without binding it to a
    /// blinking caret. The executor separately proves that this same focused
    /// AX target is editable immediately before approval policy and again
    /// immediately before keyboard input.
    func matchesFocusedEditableInputAuthority(
        _ candidate: ComputerUsePlanningStateFingerprint
    ) -> Bool {
        matchesStableSignedFocusedAuthority(candidate)
    }

    /// Revalidates a no-effect answer that the host has independently derived
    /// from the trusted task, its own action ledger, and current OCR. A focused
    /// text field can keep blinking after Return; that caret animation must not
    /// starve an otherwise stable terminal read. The executor recomputes the
    /// exact answer from a fresh capture after this identity check, so changing
    /// page content still fails closed even when the signed app/window/focus
    /// authorities remain the same.
    func matchesVerifiedPostActionAnswerAuthority(
        _ candidate: ComputerUsePlanningStateFingerprint
    ) -> Bool {
        matchesStableSignedFocusedAuthority(candidate)
    }

    /// Revalidates a no-effect pending observation without binding it to
    /// animated pixels. The executor independently reruns bounded OCR on the
    /// fresh capture before accepting WAIT, so this method proves only that
    /// the same signed application, focused window, and display geometry still
    /// own that observation. Missing authority falls back to exact matching.
    func matchesPendingObservationAuthority(
        _ candidate: ComputerUsePlanningStateFingerprint
    ) -> Bool {
        guard let expectedApplicationIdentity = frontmostApplicationIdentity,
              expectedApplicationIdentity.codeIdentity != nil,
              let candidateApplicationIdentity =
                candidate.frontmostApplicationIdentity,
              candidateApplicationIdentity.codeIdentity != nil,
              frontmostWindowBounds != nil,
              candidate.frontmostWindowBounds != nil else {
            return self == candidate
        }
        return displayBounds == candidate.displayBounds
            && frontmostWindowBounds == candidate.frontmostWindowBounds
            && frontmostApplication == candidate.frontmostApplication
            && expectedApplicationIdentity == candidateApplicationIdentity
    }

    func matchesStableSignedFocusedAuthority(
        _ candidate: ComputerUsePlanningStateFingerprint
    ) -> Bool {
        guard let expectedApplicationIdentity = frontmostApplicationIdentity,
              expectedApplicationIdentity.codeIdentity != nil,
              let candidateApplicationIdentity =
                candidate.frontmostApplicationIdentity,
              candidateApplicationIdentity.codeIdentity != nil,
              frontmostWindowBounds != nil,
              candidate.frontmostWindowBounds != nil,
              focusedAccessibilityIdentity != nil,
              candidate.focusedAccessibilityIdentity != nil else {
            return self == candidate
        }
        return displayBounds == candidate.displayBounds
            && frontmostWindowBounds == candidate.frontmostWindowBounds
            && frontmostApplication == candidate.frontmostApplication
            && expectedApplicationIdentity == candidateApplicationIdentity
            && focusedAccessibilityIdentity
                == candidate.focusedAccessibilityIdentity
    }
}

/// Bridges the native opener's callback without making Stop wait for Launch
/// Services. Cancellation/deadline only ends this wait; the OS operation may
/// still finish. The executor must retain that attempted effect as uncertain.
enum ComputerUseApplicationOpenOperation {
    enum Failure: Error, Equatable, LocalizedError {
        case timedOut, busy
        var errorDescription: String? {
            switch self {
            case .timedOut:
                return "Opening the app took too long. It may still open; check its state before continuing."
            case .busy:
                return "An earlier app-open request is still finishing. Wait for it to settle before continuing."
            }
        }
    }

    private static let nativeFlight = NativeFlight()
    static var hasPendingNativeOpen: Bool { nativeFlight.isOccupied }
    static func beginNativeOpen() throws -> UUID { try nativeFlight.begin() }
    static func finishNativeOpen(_ id: UUID) { nativeFlight.finish(id) }

    /// Cancellation of the waiter must not release this lease. An outstanding
    /// OS activation could steal focus from new automation; only its native
    /// callback (or a failure before dispatch) can release the exact lease.
    private final class NativeFlight: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: UUID?
        var isOccupied: Bool { lock.withLock { owner != nil } }
        func begin() throws -> UUID {
            try lock.withLock {
                guard owner == nil else { throw Failure.busy }
                let id = UUID()
                owner = id
                return id
            }
        }
        func finish(_ id: UUID) {
            lock.withLock { if owner == id { owner = nil } }
        }
    }

    @MainActor
    static func run<Value: Sendable>(
        timeout: TimeInterval = 30,
        start: (@escaping @Sendable (Result<Value, Error>) -> Void) throws -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, timeout <= 30 else { throw Failure.timedOut }
        let delivery = Delivery<Value>()
        let deadline = DispatchWorkItem { delivery.finish(.failure(Failure.timedOut)) }
        defer { deadline.cancel() }
        // Return the winning completion without a later cancellation check.
        // The caller must record verified success before honoring Stop.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delivery.install(continuation)
                guard !delivery.isFinished else { return }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + timeout, execute: deadline)
                do {
                    try Task.checkCancellation()
                    guard !delivery.isFinished else { return }
                    try start { delivery.finish($0) }
                } catch {
                    delivery.finish(.failure(error))
                }
            }
        } onCancel: {
            delivery.finish(.failure(CancellationError()))
        }
    }

    private final class Delivery<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, Error>?
        private var continuation: CheckedContinuation<Value, Error>?
        var isFinished: Bool { lock.withLock { result != nil } }

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            let finished = lock.withLock { () -> Result<Value, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let finished { continuation.resume(with: finished) }
        }

        func finish(_ result: Result<Value, Error>) {
            let waiter = lock.withLock { () -> CheckedContinuation<Value, Error>? in
                guard self.result == nil else { return nil }
                self.result = result
                defer { continuation = nil }
                return continuation
            }
            waiter?.resume(with: result)
        }
    }
}

@MainActor
final class ComputerUseHostTools {
    private static let semanticGroundingLog = Logger(
        subsystem: "com.threadmark.remotedesktop.host",
        category: "semantic-grounding")

    enum ToolError: Error, LocalizedError {
        case paused
        case screenshotUnavailable
        case visualSurfaceObscured
        case focusedDisplayUnavailable
        case applicationUnavailable
        case approvalTargetUnavailable
        case approvalTargetChanged
        case approvedActionEffectMayHaveOccurred

        var errorDescription: String? {
            switch self {
            case .paused: return "AI Computer Use is paused."
            case .screenshotUnavailable: return "The Mac screen could not be captured."
            case .visualSurfaceObscured:
                return "Close the covering window or handle the system dialog, then bring the intended window to the front and choose Resume."
            case .focusedDisplayUnavailable:
                return "Move the intended window fully onto one active display, then choose Resume."
            case .applicationUnavailable:
                return "The requested Mac app could not be found or opened."
            case .approvalTargetUnavailable:
                return "The host could not verify the exact control or field, so the action was not offered for approval."
            case .approvalTargetChanged:
                return "The screen or selected field changed while approval was pending."
            case .approvedActionEffectMayHaveOccurred:
                return "Control changed after part of the approved action was posted, so the action may have been performed."
            }
        }
    }

    private let injector: InputInjector
    private let mayAct: () -> Bool
    private let applicationOpener:
        (String) async throws -> ComputerUseApplicationIdentity?
    private let applicationOpenerProvidesCanonicalIdentity: Bool
    private let approvalTargetProvider:
        ((ComputerUsePredictedAction) throws -> ComputerUseApprovalTargetSnapshot)?
    private let actionPerformer: ((ComputerUsePredictedAction) throws -> Void)?
    private let textTarget: any ComputerUseNativeTextTarget
    private let usesDefaultNativeTextTarget: Bool
    private let textEditorOverride: ComputerUseTextEditor?
    private(set) var nativeVisualTypingDiagnostic: [String: String] = [:]
    private(set) var lastScreenCaptureFailureForDiagnostics: String?
    /// Deterministic seam used to exercise a gate close after one low-level
    /// event has posted but before the rest of an approved action is emitted.
    /// Production leaves this nil.
    private let approvedActionStepDidPost: (@MainActor () -> Void)?
    private let screenProvider: (() throws -> ComputerUseScreenObservation)?
    private let conservativeActionAdjustmentProvider:
        ((ComputerUsePredictedAction) -> ComputerUsePredictedAction)?
    private let semanticAccessibilityClickScopeProvider:
        ((ComputerUsePredictedAction, String)
            -> OSAtlasSemanticAccessibilityClickScope?)?
    private let transientSystemOverlayProvider:
        ((ComputerUsePredictedAction) -> Bool)?
    private let accessibilityContextProvider:
        ((ComputerUsePredictedAction) -> String)?
    private let mcpFocusedTextSnapshotProvider: (() throws -> ComputerUseMCPFocusedTextSnapshot?)?
    private let authenticationContextProvider:
        (() -> ComputerUseAuthenticationContextSnapshot?)?
    private let screenCaptureConsentContextProvider:
        (() -> ComputerUseAuthenticationContextSnapshot?)?
    private let planningAccessibilityIdentityProvider: (() -> String?)?
    private let frontmostApplicationProvider: () -> String?
    private let frontmostApplicationIdentityProvider:
        (() -> ComputerUseApplicationIdentity?)?
    private let usesLiveFrontmostApplicationIdentity: Bool

    init(
        injector: InputInjector,
        mayAct: @escaping () -> Bool,
        applicationOpener: ((String) async throws -> Void)? = nil,
        applicationIdentityOpener:
            ((String) async throws -> ComputerUseApplicationIdentity?)? = nil,
        approvalTargetProvider:
            ((ComputerUsePredictedAction) throws -> ComputerUseApprovalTargetSnapshot)? = nil,
        actionPerformer: ((ComputerUsePredictedAction) throws -> Void)? = nil,
        textEditor: ComputerUseTextEditor? = nil,
        nativeTextTarget: (any ComputerUseNativeTextTarget)? = nil,
        nativeTextTargetDiagnosticObserver: (@MainActor (ComputerUseAccessibilityTextTarget.DiagnosticEvent) -> Void)? = nil,
        approvedActionStepDidPost: (@MainActor () -> Void)? = nil,
        screenProvider: (() throws -> ComputerUseScreenObservation)? = nil,
        conservativeActionAdjustmentProvider:
            ((ComputerUsePredictedAction) -> ComputerUsePredictedAction)? = nil,
        semanticAccessibilityClickScopeProvider:
            ((ComputerUsePredictedAction, String)
                -> OSAtlasSemanticAccessibilityClickScope?)? = nil,
        transientSystemOverlayProvider:
            ((ComputerUsePredictedAction) -> Bool)? = nil,
        accessibilityContextProvider:
            ((ComputerUsePredictedAction) -> String)? = nil,
        mcpFocusedTextSnapshotProvider: (() throws -> ComputerUseMCPFocusedTextSnapshot?)? = nil,
        authenticationContextProvider:
            (() -> ComputerUseAuthenticationContextSnapshot?)? = nil,
        screenCaptureConsentContextProvider:
            (() -> ComputerUseAuthenticationContextSnapshot?)? = nil,
        planningAccessibilityIdentityProvider: (() -> String?)? = nil,
        frontmostApplicationIdentityProvider:
            (() -> ComputerUseApplicationIdentity?)? = nil,
        frontmostApplicationProvider: (() -> String?)? = nil
    ) {
        self.injector = injector
        self.mayAct = {
            mayAct() && !ComputerUseApplicationOpenOperation.hasPendingNativeOpen
        }
        if let applicationIdentityOpener {
            self.applicationOpener = applicationIdentityOpener
            self.applicationOpenerProvidesCanonicalIdentity = true
        } else if let applicationOpener {
            self.applicationOpener = { name in
                try await applicationOpener(name)
                return nil
            }
            self.applicationOpenerProvidesCanonicalIdentity = false
        } else {
            self.applicationOpener = {
                try await ComputerUseHostTools.openInstalledApplication(
                    named: $0, mayAct: mayAct)
            }
            self.applicationOpenerProvidesCanonicalIdentity = true
        }
        self.approvalTargetProvider = approvalTargetProvider
        self.actionPerformer = actionPerformer
        self.textEditorOverride = textEditor
        self.textTarget = nativeTextTarget ?? ComputerUseAccessibilityTextTarget(
            diagnosticObserver: nativeTextTargetDiagnosticObserver)
        self.usesDefaultNativeTextTarget = nativeTextTarget == nil
        self.approvedActionStepDidPost = approvedActionStepDidPost
        self.screenProvider = screenProvider
        if let conservativeActionAdjustmentProvider {
            self.conservativeActionAdjustmentProvider =
                conservativeActionAdjustmentProvider
        } else if screenProvider != nil {
            // A virtual screen has no relationship to the person's live AX
            // tree. Keep deterministic tests and hidden evaluation fixtures
            // from reading or snapping to unrelated desktop controls.
            self.conservativeActionAdjustmentProvider = { $0 }
        } else {
            self.conservativeActionAdjustmentProvider = nil
        }
        self.semanticAccessibilityClickScopeProvider =
            semanticAccessibilityClickScopeProvider
        if let transientSystemOverlayProvider {
            self.transientSystemOverlayProvider =
                transientSystemOverlayProvider
        } else if screenProvider != nil {
            // Synthetic screenshots must not be combined with unrelated live
            // Notification Center state from the person's desktop.
            self.transientSystemOverlayProvider = { _ in false }
        } else {
            self.transientSystemOverlayProvider = nil
        }
        self.accessibilityContextProvider = accessibilityContextProvider
        self.mcpFocusedTextSnapshotProvider = mcpFocusedTextSnapshotProvider
        if let authenticationContextProvider {
            self.authenticationContextProvider = authenticationContextProvider
        } else if screenProvider != nil {
            // A synthetic/virtual screen must never be combined with live AX
            // state from the person's unrelated foreground application.
            self.authenticationContextProvider = { nil }
        } else {
            self.authenticationContextProvider = nil
        }
        if let screenCaptureConsentContextProvider {
            self.screenCaptureConsentContextProvider =
                screenCaptureConsentContextProvider
        } else if screenProvider != nil {
            // A synthetic screen must never be paired with Accessibility text
            // from a live system permission prompt. Tests opt in explicitly.
            self.screenCaptureConsentContextProvider = { nil }
        } else {
            self.screenCaptureConsentContextProvider = nil
        }
        self.planningAccessibilityIdentityProvider =
            planningAccessibilityIdentityProvider
        self.frontmostApplicationProvider = frontmostApplicationProvider ?? {
            NSWorkspace.shared.frontmostApplication?.localizedName
        }
        self.frontmostApplicationIdentityProvider =
            frontmostApplicationIdentityProvider
        self.usesLiveFrontmostApplicationIdentity =
            frontmostApplicationIdentityProvider == nil
                && frontmostApplicationProvider == nil
                && screenProvider == nil
    }

    /// Session adapters must not carry permission across asynchronous work.
    func requireActive() throws {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
    }

    /// Closed host-owned browser commands. These cannot be created by a model
    /// proposal and intentionally carry no user-selected key payload.
    func performNativeBrowserHostCommand(
        _ command: ComputerUseNativeBrowserHostCommand,
        expectedApplication: ComputerUseApplicationIdentity,
        willBeginEffect: @escaping () throws -> Void
    ) throws {
        func validateFrontmostSafari() throws {
            guard expectedApplication.bundleIdentifier == "com.apple.Safari",
                  let expectedCode = expectedApplication.codeIdentity,
                  expectedCode.bundleIdentifier == "com.apple.Safari" else {
                throw ToolError.approvalTargetChanged
            }
            let frontmost = frontmostApplicationSnapshot()
            guard frontmost.identityIsAuthoritative,
                  let current = frontmost.identity,
                  current == expectedApplication,
                  current.codeIdentity == expectedCode else {
                throw ToolError.approvalTargetChanged
            }
        }

        try Task.checkCancellation()
        try requireActive()
        try validateFrontmostSafari()

        let beforePosting = {
            try Task.checkCancellation()
            try self.requireActive()
            try validateFrontmostSafari()
            try willBeginEffect()
            // Session checks may perform bounded Accessibility reads. Recheck
            // the signed frontmost app and task gate immediately before input.
            try Task.checkCancellation()
            try self.requireActive()
            try validateFrontmostSafari()
        }
        do {
            if actionPerformer != nil {
                // Deterministic virtual fixtures keep the same checks and latch;
                // production has no actionPerformer and always posts via injector.
                try injector.performHostEffectIfAllowed(
                    ifAllowed: { !Task.isCancelled && self.mayAct() }) {
                    try beforePosting()
                    try self.perform(command.action, reportsPartialApprovedEffect: false)
                }
            } else {
                try injector.applyHostKeyStroke(usage: command.usage, modifiers: command.modifiers,
                    ifAllowed: { !Task.isCancelled && self.mayAct() }, beforePosting: beforePosting)
            }
        } catch InputInjector.AutomationGateError.interrupted {
            try Task.checkCancellation()
            throw ToolError.paused
        }
    }

    func frontmostApplicationName() -> String? {
        frontmostApplicationSnapshot().policyName
    }

    func frontmostApplicationSnapshot()
        -> ComputerUseFrontmostApplicationSnapshot {
        if usesLiveFrontmostApplicationIdentity {
            guard let application = NSWorkspace.shared.frontmostApplication else {
                return ComputerUseFrontmostApplicationSnapshot(
                    localizedName: nil,
                    identity: nil,
                    identityIsAuthoritative: false)
            }
            let identity = ComputerUseApplicationIdentity(
                runningApplication: application)
            return ComputerUseFrontmostApplicationSnapshot(
                localizedName: application.localizedName,
                identity: identity,
                identityIsAuthoritative: identity?.codeIdentity != nil)
        }
        let identity = frontmostApplicationIdentityProvider?()
        return ComputerUseFrontmostApplicationSnapshot(
            localizedName: frontmostApplicationProvider(),
            identity: identity,
            identityIsAuthoritative: identity?.codeIdentity != nil)
    }

    func makeNativeTextExecutor(planner: any ComputerUseTextGoalPlanning,
        journalDirectory: URL = ComputerUseTextStepStore.defaultDirectory) -> ComputerUseNativeTextExecutor {
        ComputerUseNativeTextExecutor(injector: injector, mayAct: mayAct,
            journalDirectory: journalDirectory, planner: planner)
    }

    /// Checks whether a transient macOS notification owns the exact pointer
    /// target. Waiting and re-observing is safer than sending the intended
    /// click through an unrelated overlay or dismissing that overlay without
    /// the person's request.
    func actionIsObstructedByTransientSystemOverlay(
        _ action: ComputerUsePredictedAction
    ) throws -> Bool {
        guard mayAct() else { throw ToolError.paused }
        if let transientSystemOverlayProvider {
            return transientSystemOverlayProvider(action)
        }
        return liveActionIsObstructedByTransientSystemOverlay(action)
    }

    static func isTransientSystemOverlayApplication(
        bundleIdentifier: String?
    ) -> Bool {
        guard let bundleIdentifier else { return false }
        switch bundleIdentifier.lowercased() {
        case "com.apple.usernotificationcenter",
                "com.apple.notificationcenterui":
            return true
        default:
            return false
        }
    }

    private func liveActionIsObstructedByTransientSystemOverlay(
        _ action: ComputerUsePredictedAction
    ) -> Bool {
        let points: [CGPoint]
        switch action {
        case .click(let x, let y, _, _):
            points = [CGPoint(x: x, y: y)]
        case .drag(let fromX, let fromY, let toX, let toY):
            points = [
                CGPoint(x: fromX, y: fromY),
                CGPoint(x: toX, y: toY),
            ]
        case .scroll(let x, let y, _, _):
            points = [CGPoint(x: x, y: y)]
        case .requestApproval(_, let proposedAction):
            return liveActionIsObstructedByTransientSystemOverlay(
                proposedAction)
        case .key, .typeText, .wait, .done:
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()
        for point in points {
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                systemWide,
                Float(point.x),
                Float(point.y),
                &element) == .success,
                  let element else { continue }
            var processIdentifier: pid_t = 0
            guard AXUIElementGetPid(
                element,
                &processIdentifier) == .success else { continue }
            let bundleIdentifier = NSRunningApplication(
                processIdentifier: processIdentifier)?.bundleIdentifier
            if Self.isTransientSystemOverlayApplication(
                bundleIdentifier: bundleIdentifier) {
                return true
            }
        }
        return false
    }

    /// Reads a small, value-redacted Accessibility slice from the frontmost
    /// focused window. This is intentionally separate from action-target
    /// context so the executor can detect an authentication barrier before it
    /// asks a model to choose any action.
    func currentAuthenticationContext()
        throws -> ComputerUseAuthenticationContextSnapshot? {
        guard mayAct() else { throw ToolError.paused }
        if let authenticationContextProvider {
            return authenticationContextProvider()
        }
        return liveAuthenticationContext()
    }

    /// Reads only a bounded, value-redacted Accessibility slice that may own
    /// the macOS screen-and-audio consent sheet. This remains separate from
    /// authentication AX because the secure system sheet can be owned by the
    /// host even while Safari remains the frontmost application.
    func currentScreenCaptureConsentContext()
        throws -> ComputerUseAuthenticationContextSnapshot? {
        guard mayAct() else { throw ToolError.paused }
        if let screenCaptureConsentContextProvider {
            return screenCaptureConsentContextProvider()
        }
        return liveScreenCaptureConsentContext()
    }

    /// Opens exactly one installed application selected by the local visual
    /// model. Native Launch Services is substantially more reliable than
    /// racing synthetic text against Spotlight, while the model still decides
    /// the action from the current screenshot and the user's prompt.
    @discardableResult
    func openApplication(
        named rawName: String
    ) async throws -> ComputerUseApplicationIdentity? {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= 200,
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains("\0"),
              !name.contains("\n"),
              !name.contains("\r"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ToolError.applicationUnavailable
        }
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        let identity = try await applicationOpener(name)
        if applicationOpenerProvidesCanonicalIdentity {
            guard let identity, identity.codeIdentity != nil else {
                throw ToolError.applicationUnavailable
            }
            if ComputerUseApplicationIdentity.reviewedBundleIdentifiers(
                forApplicationNamed: name) != nil,
               !identity.matchesReviewedApplication(named: name) {
                throw ToolError.applicationUnavailable
            }
        }
        return identity
    }

    private static func openInstalledApplication(
        named name: String,
        mayAct: () -> Bool
    ) async throws -> ComputerUseApplicationIdentity {
        // Resolve only through the host-owned alias -> bundle-ID registry.
        // A localized application name is attacker-controlled, and the modern
        // Launch Services API intentionally has no trustworthy name resolver.
        // Unknown names therefore fail closed until their bundle identity and
        // signing authority are explicitly reviewed. Sorting makes selection
        // deterministic if a reviewed application ever has multiple accepted
        // bundle identifiers.
        guard let reviewedIdentifiers = ComputerUseApplicationIdentity
                .reviewedBundleIdentifiers(forApplicationNamed: name),
              let unresolvedURL = reviewedIdentifiers.sorted().lazy
                .compactMap({ identifier in
                    NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: identifier)
                }).first else {
            throw ToolError.applicationUnavailable
        }
        let applicationURL = unresolvedURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let resolvedBundleIdentifier = Bundle(url: applicationURL)?
                .bundleIdentifier else {
            throw ToolError.applicationUnavailable
        }
        guard reviewedIdentifiers.contains(resolvedBundleIdentifier) else {
            throw ToolError.applicationUnavailable
        }
        let reviewedStaticIdentity:
            ComputerUseReviewedApplicationCodeVerifier.StaticIdentity
        do {
            reviewedStaticIdentity = try
                ComputerUseReviewedApplicationCodeVerifier.verifyStatic(
                    applicationURL: applicationURL,
                    expectedBundleIdentifiers: reviewedIdentifiers)
        } catch {
            throw ToolError.applicationUnavailable
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return try await ComputerUseApplicationOpenOperation.run { complete in
            // Static bundle/code validation does not carry permission through
            // to dispatch. Recheck immediately before Launch Services.
            try Task.checkCancellation()
            guard mayAct() else { throw ToolError.paused }
            let flight = try ComputerUseApplicationOpenOperation.beginNativeOpen()
            do {
                try Task.checkCancellation()
                guard mayAct() else { throw ToolError.paused }
            } catch {
                ComputerUseApplicationOpenOperation.finishNativeOpen(flight)
                throw error
            }
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { application, error in
                let result: Result<ComputerUseApplicationIdentity, Error>
                if let error {
                    result = .failure(error)
                } else if let application {
                    do {
                        let proof = try
                            ComputerUseReviewedApplicationCodeVerifier
                                .verifyRunning(
                                    application,
                                    against: reviewedStaticIdentity)
                        guard let identity = ComputerUseApplicationIdentity(
                            runningApplication: application,
                            codeIdentity: proof),
                              identity.bundleIdentifier
                                == resolvedBundleIdentifier,
                              identity.matchesReviewedApplication(
                                named: name) else {
                            throw ToolError.applicationUnavailable
                        }
                        result = .success(identity)
                    } catch {
                        result = .failure(ToolError.applicationUnavailable)
                    }
                } else {
                    result = .failure(ToolError.applicationUnavailable)
                }
                ComputerUseApplicationOpenOperation.finishNativeOpen(flight)
                complete(result)
            }
        }
    }

    func currentScreen() throws -> ComputerUseScreenObservation {
        lastScreenCaptureFailureForDiagnostics = nil
        guard mayAct() else { throw ToolError.paused }
        if let screenProvider {
            return try screenProvider()
        }
        // Read the focused-window geometry next to the display capture. The
        // screenshot remains a full-display input for visual control, while
        // fact extractors can fail closed to this one active window instead
        // of accepting a coherent stale result from another visible app.
        guard let windowBeforeCapture = liveFrontmostWindowSnapshot() else {
            lastScreenCaptureFailureForDiagnostics = "window_before_unavailable"
            throw ToolError.focusedDisplayUnavailable
        }
        guard let activeDisplaysBefore = liveActiveDisplayInventory(),
              let selectedDisplayBefore = ComputerUseFocusedDisplaySelector.select(
                windowBounds: windowBeforeCapture.bounds, activeDisplays: activeDisplaysBefore) else {
            lastScreenCaptureFailureForDiagnostics = "display_before_unavailable"
            throw ToolError.focusedDisplayUnavailable
        }
        guard let stackBeforeCapture = liveVisibleWindowStack(),
              stackBeforeCapture.assessFocusedWindow(
                ownerProcessIdentifier: windowBeforeCapture.applicationProcessIdentifier,
                bounds: windowBeforeCapture.bounds) == .clear else {
            lastScreenCaptureFailureForDiagnostics = "stack_before_obscured"
            throw ToolError.visualSurfaceObscured
        }
        let displayID = selectedDisplayBefore.identifier
        guard let image = CGDisplayCreateImage(displayID) else {
            lastScreenCaptureFailureForDiagnostics = "image_unavailable"
            throw ToolError.screenshotUnavailable
        }
        let windowAfterCapture = liveFrontmostWindowSnapshot()
        guard let windowAfterCapture else {
            lastScreenCaptureFailureForDiagnostics = "window_after_unavailable"
            throw ToolError.visualSurfaceObscured
        }
        guard windowAfterCapture == windowBeforeCapture else {
            lastScreenCaptureFailureForDiagnostics = "window_after_changed"
            throw ToolError.visualSurfaceObscured
        }
        guard let activeDisplaysAfter = liveActiveDisplayInventory(),
              let selectedDisplayAfter = ComputerUseFocusedDisplaySelector.select(
                windowBounds: windowAfterCapture.bounds, activeDisplays: activeDisplaysAfter),
              ComputerUseFocusedDisplaySelector.isStable(before: selectedDisplayBefore, after: selectedDisplayAfter) else {
            lastScreenCaptureFailureForDiagnostics = "display_after_unavailable"
            throw ToolError.focusedDisplayUnavailable
        }
        guard let stackAfterCapture = liveVisibleWindowStack(),
              stackAfterCapture.assessFocusedWindow(
                ownerProcessIdentifier: windowAfterCapture.applicationProcessIdentifier,
                bounds: windowAfterCapture.bounds) == .clear else {
            lastScreenCaptureFailureForDiagnostics = "stack_after_obscured"
            throw ToolError.visualSurfaceObscured
        }
        let frontmostWindowBounds = Self.stableFrontmostWindowBounds(
            before: windowBeforeCapture,
            after: windowAfterCapture)
        let displayBounds = selectedDisplayBefore.bounds
        return ComputerUseScreenObservation(
            image: CIImage(cgImage: image),
            displayBounds: displayBounds,
            frontmostWindowBounds: frontmostWindowBounds)
    }

    private func liveActiveDisplayInventory() -> [ComputerUseActiveDisplay]? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success,
              count > 0, count <= 32 else { return nil }
        var identifiers = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        var actualCount = count
        let status = identifiers.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(count, buffer.baseAddress, &actualCount)
        }
        guard status == .success, actualCount == count else { return nil }
        return identifiers.map { ComputerUseActiveDisplay(identifier: $0, bounds: CGDisplayBounds($0)) }
    }

    private func liveVisibleWindowStack() -> ComputerUseVisibleWindowStack? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
        return ComputerUseVisibleWindowStack(windowInfo: windowInfo)
    }

    func planningStateFingerprint(
        for observation: ComputerUseScreenObservation,
        frontmostApplication: String?,
        frontmostApplicationIdentity: ComputerUseApplicationIdentity? = nil
    ) throws -> ComputerUsePlanningStateFingerprint {
        guard mayAct() else { throw ToolError.paused }
        let focusedIdentity: String?
        if let planningAccessibilityIdentityProvider {
            focusedIdentity = planningAccessibilityIdentityProvider()
        } else if screenProvider != nil {
            // Synthetic pixels must never be mixed with the person's live AX
            // focus. Tests that exercise AX changes inject the explicit seam.
            focusedIdentity = nil
        } else {
            if let textSnapshot = try currentTextSnapshot() {
                focusedIdentity = "text:\(textSnapshot.preconditionDigest)"
            } else {
                focusedIdentity = focusedElementSnapshot()?.identity
            }
        }
        return ComputerUsePlanningStateFingerprint(
            screenDigest: try planningScreenDigest(observation),
            displayBounds: observation.displayBounds,
            frontmostWindowBounds: observation.frontmostWindowBounds,
            frontmostApplication: frontmostApplication,
            frontmostApplicationIdentity: frontmostApplicationIdentity,
            focusedAccessibilityIdentity: focusedIdentity)
    }

    private func planningScreenDigest(
        _ observation: ComputerUseScreenObservation
    ) throws -> String {
        let image = observation.image
        let fullExtent = image.extent.integral
        let extent = planningImageExtent(
            observation: observation,
            fullImageExtent: fullExtent)
        guard !extent.isNull,
              !extent.isEmpty,
              extent.width.isFinite,
              extent.height.isFinite,
              extent.width > 0,
              extent.height > 0,
              let cgImage = CIContext(options: [.cacheIntermediates: false])
                .createCGImage(image, from: extent) else {
            throw ToolError.screenshotUnavailable
        }
        let side = 256
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { throw ToolError.screenshotUnavailable }
        return SHA256.hash(data: Data(pixels))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func planningImageExtent(
        observation: ComputerUseScreenObservation,
        fullImageExtent: CGRect
    ) -> CGRect {
        guard let windowBounds = observation.frontmostWindowBounds,
              !windowBounds.isNull,
              !windowBounds.isEmpty,
              !observation.displayBounds.isNull,
              !observation.displayBounds.isEmpty,
              observation.displayBounds.width > 0,
              observation.displayBounds.height > 0 else {
            return fullImageExtent
        }
        let focusedDisplayBounds = windowBounds.intersection(
            observation.displayBounds)
        guard !focusedDisplayBounds.isNull,
              !focusedDisplayBounds.isEmpty else {
            return fullImageExtent
        }
        let scaleX = fullImageExtent.width / observation.displayBounds.width
        let scaleY = fullImageExtent.height / observation.displayBounds.height
        let pixelBounds = CGRect(
            x: fullImageExtent.minX
                + (focusedDisplayBounds.minX
                    - observation.displayBounds.minX) * scaleX,
            y: fullImageExtent.maxY
                - (focusedDisplayBounds.maxY
                    - observation.displayBounds.minY) * scaleY,
            width: focusedDisplayBounds.width * scaleX,
            height: focusedDisplayBounds.height * scaleY)
            .integral
            .intersection(fullImageExtent)
        guard !pixelBounds.isNull, !pixelBounds.isEmpty else {
            return fullImageExtent
        }
        return pixelBounds
    }

    static func stableFrontmostWindowBounds(
        before: ComputerUseFrontmostWindowCaptureIdentity?,
        after: ComputerUseFrontmostWindowCaptureIdentity?
    ) -> CGRect? {
        guard let before, let after, before == after else { return nil }
        return after.bounds
    }

    private func liveFrontmostWindowSnapshot()
        -> ComputerUseFrontmostWindowCaptureIdentity? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !application.isTerminated else {
            return nil
        }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.5)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            root,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue) == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedWindow = unsafeBitCast(
            focusedWindowValue,
            to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(focusedWindow, 0.5)
        guard let origin = pointAttribute(
                kAXPositionAttribute as CFString,
                from: focusedWindow),
              let size = sizeAttribute(
                kAXSizeAttribute as CFString,
                from: focusedWindow),
              origin.x.isFinite,
              origin.y.isFinite,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return ComputerUseFrontmostWindowCaptureIdentity(
            applicationProcessIdentifier: application.processIdentifier,
            accessibilityWindowHash: CFHash(focusedWindow),
            bounds: CGRect(origin: origin, size: size))
    }

    func currentScreenJPEG(quality: CGFloat = 0.78) throws -> Data {
        let observation = try currentScreen()
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let data = context.jpegRepresentation(
            of: observation.image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: min(1, max(0, quality))]) else {
            throw ToolError.screenshotUnavailable
        }
        return data
    }

    private static func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value) == .success else {
            return nil
        }
        return value as? String
    }

    func approvalReason(for action: ComputerUsePredictedAction) -> String? {
        if case .key(let usage, let modifiers) = action, usage == 0x28, modifiers == 0,
           usesLiveFrontmostApplicationIdentity, screenProvider == nil, accessibilityContextProvider == nil,
           mayAct(), let app = frontmostApplicationSnapshot().identity, app.codeIdentity != nil,
           let snapshot = try? ComputerUseDefaultBrowserSession.captureWindowsForApplication(app),
           !snapshot.hasUnrecognizedSheets, let panel = snapshot.fileOpenPanel,
           panel.isNavigatingPath, panel.pathFieldIsFocused {
            // Return in the native Go To field navigates the local picker.
            // It neither activates the outer Open/Upload button nor submits a
            // website form; the retained-window scope is checked separately.
            return nil
        }
        return ComputerUseActionSafetyPolicy.approvalReason(
            for: action,
            accessibilityContext: accessibilityContext(for: action))
    }

    /// Returns a human-facing label only when the point resolves to an
    /// actionable Accessibility control. Missing labels deliberately remain
    /// inconclusive for canvas and icon-only interfaces.
    func actionablePointerTargetLabel(
        at point: CGPoint,
        providerAction: ComputerUsePredictedAction
    ) -> String? {
        if let accessibilityContextProvider {
            return Self.actionableLabel(
                fromProvidedContext: accessibilityContextProvider(
                    providerAction))
        }

        return actionableElementSnapshot(at: point)?.attestationLabel
    }

    private func actionableElementSnapshot(
        at point: CGPoint,
        requiringLabel: Bool = true,
        excludingStructuralGeometry: Bool = false
    ) -> AccessibilitySnapshot? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &element) == .success,
              var current = element else { return nil }

        var hitPathLabel: String?
        for _ in 0 ..< 8 {
            let snapshot = accessibilitySnapshot(for: current)
            let currentLabel = snapshot.attestationLabel.flatMap { value -> String? in
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return String(value.prefix(256))
            }
            if hitPathLabel == nil {
                hitPathLabel = currentLabel
            }
            let role = Self.stringAttribute(kAXRoleAttribute as CFString, from: current) ?? ""
            var selectedValue: CFTypeRef?
            var selectableCell = false
            if role == "AXCell" {
                selectedValue = Self.attributeValue(kAXSelectedAttribute as CFString, from: current)
                let selectedCapability = Self.selectedAttributeSettableResult(for: current)
                selectableCell = Self.isSelectableAXCell(
                    role: role,
                    selectedValue: selectedValue,
                    selectedSettableResult: selectedCapability.result,
                    selectedIsSettable: selectedCapability.isSettable,
                    enabled: boolAttribute(kAXEnabledAttribute as CFString, from: current))
            }
            if selectableCell {
                let label = currentLabel ?? hitPathLabel
                if !requiringLabel || label != nil {
                    let boundLabel = label
                    let summary = [snapshot.summary, boundLabel]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " • ")
                    return AccessibilitySnapshot(
                        summary: summary,
                        attestationLabel: boundLabel,
                        identity: snapshot.identity
                            + "|AXSelected=\(Self.booleanDescription(selectedValue))"
                            + "|hitPathLabel=\(boundLabel ?? "")",
                        center: snapshot.center,
                        frame: snapshot.frame,
                        isEnabled: true,
                        isActionable: true)
                }
            }
            // AX hit testing identifies the element at the physical point.
            // Browser AX frames can be offset from that point; use the hit
            // for its label, and validate usable geometry separately.
            // Structural containers do not identify a specific clicked control;
            // pointer callers can instead use their scoped point context.
            let structuralGeometryRoles: Set<String> = [
                "AXGroup", "AXWebArea", "AXScrollArea", "AXWindow", "AXApplication"
            ]
            if snapshot.isActionable,
               (!excludingStructuralGeometry || !structuralGeometryRoles.contains(role)),
               (!requiringLabel || snapshot.attestationLabel != nil) {
                return snapshot
            }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        return nil
    }

    static func isSelectableAXCell(
        role: String,
        selectedValue: CFTypeRef?,
        selectedSettableResult: AXError,
        selectedIsSettable: Bool,
        enabled: Bool?
    ) -> Bool {
        guard role == "AXCell",
              let selectedValue,
              CFGetTypeID(selectedValue) == CFBooleanGetTypeID(),
              selectedSettableResult == .success,
              selectedIsSettable,
              enabled != false else { return false }
        return true
    }

    private static func attributeValue(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    private static func selectedAttributeSettableResult(
        for element: AXUIElement
    ) -> (result: AXError, isSettable: Bool) {
        var isSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element, kAXSelectedAttribute as CFString, &isSettable)
        return (result, isSettable.boolValue)
    }

    private static func booleanDescription(_ value: CFTypeRef?) -> String {
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return "unavailable"
        }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self)) ? "true" : "false"
    }

    /// Returns true only when the system focus is a writable, non-secure text
    /// control. A semantic TYPE route carries exact host-owned text, but the
    /// language router cannot prove where keyboard input will land. Keep that
    /// final destination decision in the host and fail closed when
    /// Accessibility cannot identify an editable target.
    func focusedTypingTargetIsEditable(
        providerAction: ComputerUsePredictedAction
    ) throws -> Bool {
        guard mayAct() else { throw ToolError.paused }
        if let accessibilityContextProvider {
            return Self.providedContextDescribesEditableTypingTarget(
                accessibilityContextProvider(providerAction))
        }
        // Use the same retained target and capability rules as verified
        // editing. Native NSTextView may omit AXEnabled and expose writable
        // selected text rather than a writable whole-field value. The shared
        // reader rejects secure/disabled controls and stale AX references.
        return try currentTextSnapshot() != nil
    }

    private static func providedContextDescribesEditableTypingTarget(
        _ context: String
    ) -> Bool {
        let normalized = " " + context.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .map {
                CharacterSet.alphanumerics.contains($0)
                    ? String($0)
                    : " "
            }
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ") + " "
        guard !normalized.contains(" axsecuretextfield "),
              !normalized.contains(" secure text field "),
              !normalized.contains(" disabled "),
              !normalized.contains(" enabled false "),
              !normalized.contains(" editable false ") else { return false }
        return [
            " axtextfield ",
            " axtextarea ",
            " axcombobox ",
            " axsearchfield ",
        ].contains(where: normalized.contains)
    }

    private static func actionableLabel(
        fromProvidedContext context: String
    ) -> String? {
        let tokens = context.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .split(whereSeparator: {
                !CharacterSet.alphanumerics.contains($0)
            })
            .map(String.init)
        let actionableRoles: Set<String> = [
            "axbutton", "axcheckbox", "axradiobutton", "axpopupbutton",
            "axcombobox", "axtextfield", "axtextarea", "axmenuitem",
            "axslider", "axincrementor", "axlink", "axswitch", "axcell",
        ]
        guard !actionableRoles.isDisjoint(with: tokens) else { return nil }

        let structuralValues = actionableRoles.union([
            "role", "subrole", "title", "description", "placeholder",
            "identifier", "enabled", "selected",
        ])
        let labelTokens = tokens.filter { !structuralValues.contains($0) }
        guard !labelTokens.isEmpty else { return nil }
        return labelTokens.joined(separator: " ")
    }

    /// Correct only a primary single-click, and only when the model point lands
    /// on a non-actionable Accessibility container while one unique enabled
    /// control is visible within a tightly bounded neighborhood. This never
    /// chooses between candidates and never changes drags or secondary clicks.
    func conservativelyAdjustedAction(
        _ action: ComputerUsePredictedAction
    ) -> ComputerUsePredictedAction {
        if let conservativeActionAdjustmentProvider {
            return conservativeActionAdjustmentProvider(action)
        }
        guard case .click(let x, let y, let button, let count) = action,
              button == 1,
              count == 1 else { return action }
        let predicted = CGPoint(x: x, y: y)
        let directHit = accessibilityClickCandidate(at: predicted)
        guard let directHit, !directHit.isActionable else { return action }
        let radius = OSAtlasAccessibilityClickCorrection.maximumRadius
        let step: CGFloat = 16
        var nearby: [OSAtlasAccessibilityClickCandidate] = []
        for offsetY in stride(from: -radius, through: radius, by: step) {
            for offsetX in stride(from: -radius, through: radius, by: step) {
                guard offsetX != 0 || offsetY != 0,
                      hypot(offsetX, offsetY) <= radius else { continue }
                let point = CGPoint(
                    x: predicted.x + offsetX,
                    y: predicted.y + offsetY)
                if let candidate = accessibilityClickCandidate(at: point) {
                    nearby.append(candidate)
                }
            }
        }
        let corrected = OSAtlasAccessibilityClickCorrection.correctedPoint(
            predicted: predicted,
            directHit: directHit,
            nearbyCandidates: nearby)
        guard corrected != predicted else { return action }
        return .click(
            x: Int(corrected.x.rounded()),
            y: Int(corrected.y.rounded()),
            button: button,
            count: count)
    }

    /// A typed pointer route may use its task-purpose hint to correct a poor
    /// visual carrier across the focused window. The candidate source is the
    /// focused frontmost window (preferring its first web area) or an explicit
    /// synthetic test seam; it never combines a virtual screenshot with live
    /// Accessibility state. Ambiguous/no semantic matches retain the existing
    /// geometry-only conservative behavior.
    func conservativelyAdjustedAction(
        _ action: ComputerUsePredictedAction,
        semanticTargetHint: String,
        trustedTaskFallbackHint: String?,
        rawVisualPoint: CGPoint
    ) -> ComputerUsePredictedAction {
        guard case .click(_, _, let button, let count) = action,
              button == 1,
              count == 1 else {
            return conservativelyAdjustedAction(action)
        }

        let scope: OSAtlasSemanticAccessibilityClickScope?
        if let semanticAccessibilityClickScopeProvider {
            scope = semanticAccessibilityClickScopeProvider(
                action,
                semanticTargetHint)
        } else if screenProvider != nil {
            // Synthetic pixels and the person's live AX tree have no shared
            // authority. Tests that exercise semantic correction inject the
            // exact candidate scope explicitly.
            scope = nil
        } else {
            scope = focusedSemanticAccessibilityClickScope()
        }

        guard let scope else {
            return conservativelyAdjustedAction(action)
        }
        let primary = OSAtlasSemanticAccessibilityClickCorrection
            .correctedPoint(
                predicted: rawVisualPoint,
                targetHint: semanticTargetHint,
                scope: scope)
        let fallback = trustedTaskFallbackHint.flatMap { hint in
            OSAtlasSemanticAccessibilityClickCorrection.correctedPoint(
                predicted: rawVisualPoint,
                targetHint: hint,
                scope: scope)
        }
        let corrected = primary ?? fallback
        let fallbackMatchCount = trustedTaskFallbackHint.map { hint in
            scope.candidates.filter {
                OSAtlasSemanticAccessibilityClickCorrection.stronglyMatches(
                    targetHint: hint,
                    candidateLabel: $0.label)
            }.count
        } ?? -1
        Self.semanticGroundingLog.info(
            "semantic AX correction rawInside=\(scope.frame.contains(rawVisualPoint), privacy: .public) candidates=\(scope.candidates.count, privacy: .public) primary=\(primary != nil, privacy: .public) fallbackAvailable=\(trustedTaskFallbackHint != nil, privacy: .public) fallbackMatches=\(fallbackMatchCount, privacy: .public) fallbackCorrected=\(fallback != nil, privacy: .public) corrected=\(corrected != nil, privacy: .public)")
        guard let corrected else {
            return conservativelyAdjustedAction(action)
        }
        return .click(
            x: Int(corrected.x.rounded()),
            y: Int(corrected.y.rounded()),
            button: button,
            count: count)
    }

    /// Reports the number of distinct enabled/actionable AX controls that
    /// strongly match one host-bound target. `nil` means no trustworthy AX
    /// scope is available, while `0` deliberately leaves visual grounding as a
    /// fallback. More than one match is an ambiguity and must fail closed.
    func semanticAccessibilityActionableMatchCount(
        for action: ComputerUsePredictedAction,
        targetHint: String
    ) -> Int? {
        guard case .click(_, _, let button, let count) = action,
              button == 1,
              count == 1 else { return nil }

        let scope: OSAtlasSemanticAccessibilityClickScope?
        if let semanticAccessibilityClickScopeProvider {
            scope = semanticAccessibilityClickScopeProvider(action, targetHint)
        } else if screenProvider != nil {
            scope = nil
        } else {
            scope = focusedSemanticAccessibilityClickScope()
        }
        guard let scope,
              scope.frame.origin.x.isFinite,
              scope.frame.origin.y.isFinite,
              scope.frame.width.isFinite,
              scope.frame.height.isFinite,
              scope.frame.width > 0,
              scope.frame.height > 0 else {
            return nil
        }

        var identities: Set<String> = []
        for candidate in scope.candidates where
            candidate.isEnabled && candidate.isActionable
            && candidate.frame.origin.x.isFinite
            && candidate.frame.origin.y.isFinite
            && candidate.frame.width.isFinite
            && candidate.frame.height.isFinite
            && candidate.frame.width > 0 && candidate.frame.height > 0
            && scope.frame.contains(CGPoint(
                x: candidate.frame.midX,
                y: candidate.frame.midY))
            && OSAtlasSemanticAccessibilityClickCorrection.stronglyMatches(
                targetHint: targetHint,
                candidateLabel: candidate.label) {
            identities.insert(candidate.identity)
        }
        return identities.count
    }

    fileprivate func prepareApproval(
        for action: ComputerUsePredictedAction
    ) throws -> ComputerUsePreparedApproval {
        let target = try approvalTarget(for: action)
        var accessibilityIdentity = target.accessibilityIdentity
        var keyboardEvidence: ComputerUseKeyboardCaretEvidence?
        var capturedVisualDigest: String?
        if case .key = action,
           let captured = try liveKeyboardCaretCapture(for: target) {
            keyboardEvidence = captured.evidence
            capturedVisualDigest = captured.visualDigest
            accessibilityIdentity += "|text-state=\(captured.evidence.text.preconditionDigest)"
        }
        if case .typeText = action,
           actionPerformer == nil, approvalTargetProvider == nil {
            guard let textSnapshot = try currentTextSnapshot() else {
                throw ToolError.approvalTargetUnavailable
            }
            accessibilityIdentity += "|text-state=\(textSnapshot.preconditionDigest)"
        }
        let message = ComputerUseActionSafetyPolicy.approvalReason(
            for: action,
            accessibilityContext: target.context,
            forceConfirmation: true)
            ?? "Perform this exact action on the current screen"
        let fingerprint = ComputerUseApprovalFingerprint(
            action: action,
            applicationID: target.applicationID,
            accessibilityIdentity: accessibilityIdentity,
            visualDigest: try capturedVisualDigest ?? visualDigest(around: target.visualCheckpoints),
            keyboardCaretEvidence: keyboardEvidence)
        return ComputerUsePreparedApproval(
            message: message,
            fingerprint: fingerprint)
    }

    private func liveKeyboardCaretCapture(for target: ApprovalTarget) throws ->
        (evidence: ComputerUseKeyboardCaretEvidence, visualDigest: String)? {
        guard usesLiveFrontmostApplicationIdentity,
              usesDefaultNativeTextTarget,
              actionPerformer == nil, approvalTargetProvider == nil, screenProvider == nil,
              textEditorOverride == nil, planningAccessibilityIdentityProvider == nil,
              accessibilityContextProvider == nil, mcpFocusedTextSnapshotProvider == nil,
              authenticationContextProvider == nil, screenCaptureConsentContextProvider == nil,
              frontmostApplicationIdentityProvider == nil else { return nil }
        guard let runningApp = NSWorkspace.shared.frontmostApplication,
              !runningApp.isTerminated,
              let app = ComputerUseApplicationIdentity(runningApplication: runningApp),
              app.codeIdentity != nil else { return nil }
        guard app.bundleIdentifier == target.applicationID,
              let windowBefore = liveFrontmostWindowSnapshot(),
              windowBefore.applicationProcessIdentifier == app.processIdentifier else {
            throw ToolError.approvalTargetChanged
        }
        guard target.accessibilityIdentity != "unavailable" else { return nil }
        guard let focusedBefore = focusedElement() else { throw ToolError.approvalTargetChanged }
        let focusedSnapshotBefore = accessibilitySnapshot(for: focusedBefore)
        guard focusedSnapshotBefore.identity == target.accessibilityIdentity else {
            throw ToolError.approvalTargetChanged
        }
        guard
              let frame = focusedSnapshotBefore.frame,
              let textBefore = try currentTextSnapshot(),
              textBefore.isEditable, !textBefore.isSecure, textBefore.selection.length == 0,
              textBefore.selection.location >= 0,
              textBefore.selection.location <= (textBefore.value as NSString).length,
              !textBefore.targetID.isEmpty,
              !frame.isEmpty,
              windowBefore.bounds.contains(frame),
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else {
            return nil
        }

        // Once an eligible focused editor was observed, any later target or
        // scope change invalidates the capture instead of dropping its proof.
        guard let activeDisplaysBefore = liveActiveDisplayInventory(),
              let selectedDisplayBefore = ComputerUseFocusedDisplaySelector.select(
                windowBounds: windowBefore.bounds, activeDisplays: activeDisplaysBefore) else {
            throw ToolError.approvalTargetUnavailable
        }
        let displayID = selectedDisplayBefore.identifier
        let displayBounds = selectedDisplayBefore.bounds
        guard let image = CGDisplayCreateImage(displayID) else { throw ToolError.screenshotUnavailable }
        guard let runningAppAfter = NSWorkspace.shared.frontmostApplication,
              !runningAppAfter.isTerminated,
              let appAfter = ComputerUseApplicationIdentity(runningApplication: runningAppAfter),
              appAfter == app,
              let windowAfter = liveFrontmostWindowSnapshot(), windowAfter == windowBefore,
              let focusedAfter = focusedElement(), CFEqual(focusedBefore, focusedAfter),
              let textAfter = try currentTextSnapshot(), textAfter == textBefore else {
            throw ToolError.approvalTargetChanged
        }
        guard let activeDisplaysAfter = liveActiveDisplayInventory(),
              let selectedDisplayAfter = ComputerUseFocusedDisplaySelector.select(
                windowBounds: windowAfter.bounds, activeDisplays: activeDisplaysAfter),
              ComputerUseFocusedDisplaySelector.isStable(before: selectedDisplayBefore, after: selectedDisplayAfter) else {
            throw ToolError.approvalTargetChanged
        }
        let focusedSnapshotAfter = accessibilitySnapshot(for: focusedAfter)
        guard focusedSnapshotAfter.identity == focusedSnapshotBefore.identity,
              focusedSnapshotAfter.frame == frame else { throw ToolError.approvalTargetChanged }
        let desktopImage = try ComputerUseDesktopImage(observation: ComputerUseScreenObservation(
            image: CIImage(cgImage: image), displayBounds: displayBounds,
            frontmostWindowBounds: windowBefore.bounds))
        guard target.visualCheckpoints.count == 1,
              let checkpoint = target.visualCheckpoints.first,
              let comparisonScope = ComputerUseApprovalFingerprint.keyboardCaretComparisonScope(
                focusedFrame: frame, windowBounds: windowBefore.bounds, displayBounds: displayBounds,
                checkpoint: checkpoint, sourcePixelWidth: image.width, sourcePixelHeight: image.height),
              let digest = try Self.approvalVisualDigest(around: target.visualCheckpoints, image: image,
                displayBounds: displayBounds, window: windowBefore) else { throw ToolError.approvalTargetUnavailable }
        let checkpointScaleX = CGFloat(image.width) / displayBounds.width
        let checkpointScaleY = CGFloat(image.height) / displayBounds.height
        let checkpointBounds = CGRect(x: checkpoint.x - 48 / checkpointScaleX,
            y: checkpoint.y - 48 / checkpointScaleY, width: 96 / checkpointScaleX,
            height: 96 / checkpointScaleY).intersection(windowBefore.bounds)
        return (ComputerUseKeyboardCaretEvidence(applicationIdentity: app, window: windowBefore,
            text: textBefore, frame: frame, image: desktopImage, comparisonScope: comparisonScope,
            checkpointBounds: checkpointBounds), digest)
    }

    fileprivate func performApproved(
        _ action: ComputerUsePredictedAction,
        fingerprint: ComputerUseApprovalFingerprint,
        nativeVisualKeyboard: Bool = false,
        nativeBrowserAddressEntryScope: ComputerUseNativeBrowserAddressEntryScope? = nil,
        nativeBrowserAddressValueWrite: (() throws -> Void)? = nil,
        willBeginEffect: () throws -> Void
    ) async throws {
        if nativeVisualKeyboard, case .typeText(let payload) = action {
            guard !payload.isEmpty else { throw ComputerUseTextEditError.selectionUnsupported }
            guard payload.utf8.count <= ComputerUseTextEditor.maximumPayloadBytes else {
                throw ComputerUseTextEditError.payloadTooLarge
            }
            if payload.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                throw ComputerUseTextEditError.valueNotRepresentable
            }
        }
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        let current = try prepareApproval(for: action).fingerprint
        guard current.matchesForFinalDispatch(fingerprint) else {
            throw ToolError.approvalTargetChanged
        }
        try willBeginEffect()
        if case .typeText = action {
            if let nativeBrowserAddressValueWrite {
                try nativeBrowserAddressValueWrite()
            } else if nativeVisualKeyboard, case .typeText(let payload) = action {
                if actionPerformer != nil, textEditorOverride == nil {
                    // Preserve the explicitly injected virtual performer path.
                    try perform(action)
                } else {
                    try await performNativeVisualKeyboardTyping(
                        payload, browserAddressEntryScope: nativeBrowserAddressEntryScope)
                }
            } else {
                try await performVerified(action)
            }
        } else {
            try perform(action, reportsPartialApprovedEffect: true)
        }
    }

    /// Native model adapters retain the same approval fingerprint boundary as
    /// approved host input. Text dispatch uses its scoped visual-keyboard path;
    /// the adapter still owns policy and journals in willBeginEffect.
    func prepareNativeActionFingerprint(for action: ComputerUsePredictedAction) throws -> ComputerUseApprovalFingerprint {
        try prepareApproval(for: action).fingerprint
    }

    func nativePointerTargetFrame(for action: ComputerUsePredictedAction) throws -> CGRect? {
        guard mayAct() else { throw ToolError.paused }
        guard case .click(let x, let y, _, _) = action else { return nil }
        if let approvalTargetProvider { return try approvalTargetProvider(action).frame }
        guard screenProvider == nil else { return nil }
        // Geometry is useful even when an editor or icon has no semantic
        // label. Label attestation keeps its stricter, separate requirement;
        // the executor still validates target authority and current pixels.
        let point = CGPoint(x: x, y: y)
        guard let frame = actionableElementSnapshot(
            at: point,
            requiringLabel: false,
            excludingStructuralGeometry: true)?.frame,
              !frame.isEmpty, [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.contains(point) else { return nil }
        return frame
    }

    func nativeFocusedTextFrame() throws -> CGRect? {
        guard mayAct() else { throw ToolError.paused }
        guard screenProvider == nil, let snapshot = try currentTextSnapshot(), snapshot.selection.length == 0,
              let frame = focusedElementSnapshot()?.frame, !frame.isEmpty,
              try currentTextSnapshot() == snapshot else { return nil }
        return frame
    }

    func mcpFocusedTextSnapshot() throws -> ComputerUseMCPFocusedTextSnapshot? {
        try focusedTextSnapshot(allowedRoles: ["AXTextArea"], validateProvidedSnapshot: false)
    }

    func nativeVisualKeyboardTextSnapshot() throws -> ComputerUseMCPFocusedTextSnapshot? {
        try focusedTextSnapshot(allowedRoles: ["AXTextArea", "AXTextField", "AXComboBox"],
                                validateProvidedSnapshot: true)
    }

    /// AX can briefly return no focused text snapshot during a browser's
    /// inline-completion update. Retry only absence; a readable changed state
    /// is returned immediately for the caller's exact baseline comparison.
    private func nativeVisualKeyboardTextSnapshotRetryingNil(
        deadline: TimeInterval
    ) async throws -> ComputerUseMCPFocusedTextSnapshot? {
        let clock = ContinuousClock()
        let retryDeadline = clock.now.advanced(by: .milliseconds(500))
        while true {
            try Task.checkCancellation()
            guard mayAct() else { throw ComputerUseTextEditError.interrupted }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            if let snapshot = try nativeVisualKeyboardTextSnapshot() { return snapshot }
            let remaining = retryDeadline - clock.now
            guard remaining > .zero,
                  ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            try Task.checkCancellation()
            guard mayAct() else { throw ComputerUseTextEditError.interrupted }
            try await Task.sleep(for: min(.milliseconds(25), remaining))
        }
    }

    private func allowsInlineCompletionRefresh(
        _ candidate: ComputerUseMCPFocusedTextSnapshot,
        relativeTo baseline: ComputerUseMCPFocusedTextSnapshot,
        browserAddressEntryScope: ComputerUseNativeBrowserAddressEntryScope? = nil
    ) -> Bool {
        let candidateRange = candidate.text.selection
        let baselineRange = baseline.text.selection
        let candidateUTF16 = candidate.text.value.utf16
        let baselineUTF16 = baseline.text.value.utf16
        guard Self.hasSameNativeTypingTarget(candidate, as: baseline,
                  browserAddressEntryScope: browserAddressEntryScope),
              candidateRange.location == baselineRange.location,
              candidateRange.location >= 0, baselineRange.location >= 0,
              candidateRange.length >= 0, baselineRange.length >= 0,
              candidateRange.location <= candidateUTF16.count,
              baselineRange.location <= baselineUTF16.count,
              ((candidateRange.length == 0 && baselineRange.length == 0)
                || (candidateRange.length == candidateUTF16.count - candidateRange.location
                    && baselineRange.length == baselineUTF16.count - baselineRange.location)),
              candidate.text.value.utf8.count <= ComputerUseTextEditor.maximumObservedValueBytes,
              baseline.text.value.utf8.count <= ComputerUseTextEditor.maximumObservedValueBytes else {
            return false
        }
        // Inline completion may expose a ghost suffix after a collapsed caret.
        // Only the unchanged prefix through that caret is typing authority.
        return Array(candidateUTF16.prefix(candidateRange.location))
            == Array(baselineUTF16.prefix(baselineRange.location))
    }

    private static func hasSameNativeTypingTarget(
        _ candidate: ComputerUseMCPFocusedTextSnapshot,
        as baseline: ComputerUseMCPFocusedTextSnapshot,
        browserAddressEntryScope: ComputerUseNativeBrowserAddressEntryScope?
    ) -> Bool {
        guard let browserAddressEntryScope else {
            return candidate.hasSameDocumentTarget(as: baseline)
        }
        return browserAddressEntryScope.matches(candidate)
            && browserAddressEntryScope.matches(baseline)
            && candidate.documentIdentity == baseline.documentIdentity
            && candidate.role == baseline.role
            && candidate.isWebContent == baseline.isWebContent
            && candidate.text.isEditable == baseline.text.isEditable
            && candidate.text.isSecure == baseline.text.isSecure
    }

    private func focusedTextSnapshot(allowedRoles: Set<String>,
                                     validateProvidedSnapshot: Bool) throws -> ComputerUseMCPFocusedTextSnapshot? {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        if let mcpFocusedTextSnapshotProvider {
            guard let snapshot = try mcpFocusedTextSnapshotProvider() else { return nil }
            guard !validateProvidedSnapshot || snapshot.isReadable(allowedRoles: allowedRoles) else { return nil }
            return snapshot
        }
        // Synthetic screens or app identities cannot authorize live AX reads.
        guard usesLiveFrontmostApplicationIdentity, screenProvider == nil,
              accessibilityContextProvider == nil else { return nil }
        let application = frontmostApplicationSnapshot()
        guard let window = liveFrontmostWindowSnapshot(),
              let text = try currentTextSnapshot(), let element = focusedTextElement(),
              let role = Self.stringAttribute(kAXRoleAttribute as CFString, from: element),
              let frame = accessibilitySnapshot(for: element).frame else { return nil }
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success,
              elementPID == window.applicationProcessIdentifier else { return nil }
        var windowValue: CFTypeRef?
        let windowAttributeResult = AXUIElementCopyAttributeValue(
            element, kAXWindowAttribute as CFString, &windowValue)
        let windowElement: AXUIElement
        if windowAttributeResult == .success {
            guard let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
            windowElement = unsafeBitCast(windowValue, to: AXUIElement.self)
            guard CFHash(windowElement) == window.accessibilityWindowHash else { return nil }
        } else {
            // Some native sheet fields omit AXWindow. Accept only an exact,
            // bounded parent path to the same currently focused app window.
            guard windowAttributeResult == .noValue else { return nil }
            let root = AXUIElementCreateApplication(elementPID)
            var focusedWindowValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString,
                                                 &focusedWindowValue) == .success,
                  let focusedWindowValue, CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else { return nil }
            let focusedWindow = unsafeBitCast(focusedWindowValue, to: AXUIElement.self)
            guard CFHash(focusedWindow) == window.accessibilityWindowHash,
                  ComputerUseAccessibilityTextTarget.parentPathReachesWindow(
                    from: element, window: focusedWindow, access: .live, mayAct: mayAct) else { return nil }
            windowElement = focusedWindow
        }
        let snapshot = ComputerUseMCPFocusedTextSnapshot(
            application: application, window: window, text: text, frame: frame, role: role,
            focusedElement: element,
            documentIdentity: Self.stringAttribute(kAXDocumentAttribute as CFString, from: windowElement),
            isWebContent: (textTarget as? ComputerUseAccessibilityTextTarget)?.isWebContent(
                targetID: text.targetID, matching: element) ?? false)
        guard snapshot.isReadable(allowedRoles: allowedRoles), try currentTextSnapshot() == text,
              liveFrontmostWindowSnapshot() == window,
              focusedTextElement().map({ CFEqual($0, element) }) == true,
              frontmostApplicationSnapshot() == application else { return nil }
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        return snapshot
    }

    func nativeFocusedEditorDescription() throws -> String? {
        try nativeFocusedEditorObservation()?.description
    }

    func nativeControlObservation(displayBounds: CGRect, windowBounds: CGRect) throws -> ComputerUseNativeControls? {
        guard mayAct() else { throw ToolError.paused }
        // Synthetic screenshots/context have no relationship to live AX.
        guard screenProvider == nil, accessibilityContextProvider == nil else { return nil }
        return try ComputerUseNativeControlReader.observe(displayBounds: displayBounds, windowBounds: windowBounds,
            access: .live, mayAct: mayAct)
    }

    func nativeFocusedEditorObservation() throws -> (description: String, textState: ComputerUseNativeTextState?, stabilityToken: String?)? {
        guard mayAct() else { throw ToolError.paused }
        let description: String
        let observed: ComputerUseTextSnapshot?
        if let accessibilityContextProvider {
            let context = accessibilityContextProvider(.typeText(""))
            guard Self.providedContextDescribesEditableTypingTarget(context) else { return nil }
            description = context
            // Synthetic context must never acquire the person's live AX text.
            observed = textEditorOverride != nil ? try currentTextSnapshot() : nil
            if textEditorOverride != nil, observed == nil { return nil }
        } else {
            guard screenProvider == nil, let before = try currentTextSnapshot() else { return nil }
            observed = before
            if let target = textTarget as? ComputerUseAccessibilityTextTarget {
                // The focused AX child can be a suggestion inside an editor.
                // Describe the same retained binding that supplied this text.
                guard let retainedDescription = target.editorDescription(targetID: before.targetID) else { return nil }
                description = retainedDescription
            } else {
                guard let focused = focusedElementSnapshot() else { return nil }
                description = focused.summary
            }
        }
        let state: ComputerUseNativeTextState?
        if let observed {
            guard let projected = ComputerUseNativeTextState(snapshot: observed),
                  try currentTextSnapshot() == observed else { return nil }
            state = projected
        } else { state = nil }
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        // Snapshot summaries contain role/label/identifier attributes, never
        // AXValue or selected text. Preserve whole characters within the cap.
        var result = ""
        for character in description {
            let next = String(character)
            guard result.utf8.count + next.utf8.count <= 1_024 else { break }
            result += next
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : (result, state, observed?.preconditionDigest)
    }

    func performNativeAction(_ action: ComputerUsePredictedAction, fingerprint: ComputerUseApprovalFingerprint,
                            willBeginEffect: () throws -> Void) async throws {
        try await performApproved(action, fingerprint: fingerprint, nativeVisualKeyboard: true,
                                  willBeginEffect: willBeginEffect)
    }

    func performNativeBrowserAddressEntry(_ payload: String,
                                          scope: ComputerUseNativeBrowserAddressEntryScope,
                                          fingerprint: ComputerUseApprovalFingerprint,
                                          willBeginEffect: () throws -> Void) async throws {
        // An injected virtual performer has no live Safari AX tree to prove;
        // the retained session still supplies its full effect-boundary checks.
        // Keep native PID/window binding mandatory for the real keyboard path.
        if actionPerformer == nil || textEditorOverride != nil {
            guard scope.isBoundToVerifiedSafariAddressField() else {
                throw ComputerUseTextEditError.preconditionChanged
            }
        }
        try await performApproved(.typeText(payload), fingerprint: fingerprint,
                                  nativeVisualKeyboard: true,
                                  nativeBrowserAddressEntryScope: scope,
                                  willBeginEffect: willBeginEffect)
    }

    func performNativeBrowserAddressValueWrite(_ payload: String,
                                               scope: ComputerUseNativeBrowserAddressEntryScope,
                                               fingerprint: ComputerUseApprovalFingerprint,
                                               willBeginEffect: () throws -> Void,
                                               writeValue: @escaping () throws -> Void) async throws {
        guard !payload.isEmpty, payload.utf8.count <= ComputerUseTextEditor.maximumPayloadBytes,
              !payload.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ComputerUseTextEditError.valueNotRepresentable
        }
        if actionPerformer == nil || textEditorOverride != nil {
            guard scope.isBoundToVerifiedSafariAddressField() else {
                throw ComputerUseTextEditError.preconditionChanged
            }
        }
        try await performApproved(.typeText(payload), fingerprint: fingerprint,
            nativeVisualKeyboard: true, nativeBrowserAddressEntryScope: scope,
            nativeBrowserAddressValueWrite: {
                try self.injector.performHostEffectIfAllowed(
                    ifAllowed: { !Task.isCancelled && self.mayAct() }) {
                    try Task.checkCancellation()
                    guard self.mayAct() else { throw ToolError.paused }
                    if self.actionPerformer == nil || self.textEditorOverride != nil {
                        guard scope.isBoundToVerifiedSafariAddressField() else {
                            throw ComputerUseTextEditError.preconditionChanged
                        }
                    }
                    try writeValue()
                }
            }, willBeginEffect: willBeginEffect)
    }

    /// Native visual text proposals use keyboard events only. The semantic
    /// AX editing route remains unchanged for MCP and other approved actions.
    private func performNativeVisualKeyboardTyping(
        _ payload: String,
        browserAddressEntryScope: ComputerUseNativeBrowserAddressEntryScope? = nil
    ) async throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var stage = "initial-read"
        var failureType = "none"
        var attemptedStrokes = 0
        var completedStrokes = 0
        var provisionalSpaceTransitions = 0
        var restoredSpaceTransitions = 0
        var pendingSpaceUTF16Index: Int?
        var lastSnapshot: ComputerUseMCPFocusedTextSnapshot?
        var referenceSnapshot: ComputerUseMCPFocusedTextSnapshot?
        var expectedLocation: Int?
        var lastMayAct = false
        var deadline: TimeInterval = .greatestFiniteMagnitude
        nativeVisualTypingDiagnostic = [:]
        defer {
            let snapshot = lastSnapshot
            nativeVisualTypingDiagnostic = [
                "stage": stage,
                "failureType": failureType,
                "attemptedStrokes": String(attemptedStrokes),
                "completedStrokes": String(completedStrokes),
                "snapshotAvailable": String(snapshot != nil),
                "samePhysicalTarget": String(snapshot.map { value in
                    referenceSnapshot.map {
                        Self.hasSameNativeTypingTarget(value, as: $0, browserAddressEntryScope: browserAddressEntryScope)
                    } ?? false
                } ?? false),
                "sameApplication": snapshot.flatMap { value in referenceSnapshot.map { String(value.application == $0.application) } } ?? "unknown",
                "sameWindow": snapshot.flatMap { value in referenceSnapshot.map { String(value.window == $0.window) } } ?? "unknown",
                "sameElement": snapshot.flatMap { value in referenceSnapshot.map { String(CFEqual(value.focusedElement, $0.focusedElement)) } } ?? "unknown",
                "sameDocument": snapshot.flatMap { value in referenceSnapshot.map { String(value.documentIdentity == $0.documentIdentity) } } ?? "unknown",
                "sameFrame": snapshot.flatMap { value in referenceSnapshot.map { String(value.frame == $0.frame) } } ?? "unknown",
                "sameRole": snapshot.flatMap { value in referenceSnapshot.map { String(value.role == $0.role) } } ?? "unknown",
                "sameWebClassification": snapshot.flatMap { value in referenceSnapshot.map { String(value.isWebContent == $0.isWebContent) } } ?? "unknown",
                "selectionLocation": snapshot.map { String($0.text.selection.location) } ?? "unknown",
                "selectionLength": snapshot.map { String($0.text.selection.length) } ?? "unknown",
                "expectedLocation": expectedLocation.map(String.init) ?? "unknown",
                "editable": snapshot.map { String($0.text.isEditable) } ?? "unknown",
                "secure": snapshot.map { String($0.text.isSecure) } ?? "unknown",
                "provisionalSpaceTransitions": String(provisionalSpaceTransitions),
                "restoredSpaceTransitions": String(restoredSpaceTransitions),
                "pendingSpace": String(pendingSpaceUTF16Index != nil),
                "isWebContent": snapshot.map { String($0.isWebContent) } ?? "unknown",
                "cancelled": String(Task.isCancelled),
                "mayActAtLastSuccessfulCheck": String(lastMayAct),
                "deadlineExceeded": String(ProcessInfo.processInfo.systemUptime >= deadline),
                "elapsedMilliseconds": String(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))
            ]
        }
        let initial: ComputerUseMCPFocusedTextSnapshot?
        do { initial = try nativeVisualKeyboardTextSnapshot() }
        catch { failureType = "initialSnapshotError"; throw error }
        guard let initial else {
            failureType = "unavailableTarget"
            throw ComputerUseTextEditError.unavailableTarget
        }
        if let browserAddressEntryScope, !browserAddressEntryScope.matches(initial) {
            failureType = "browserAddressScopeRejected"
            throw ComputerUseTextEditError.preconditionChanged
        }
        lastSnapshot = initial
        referenceSnapshot = initial
        do {
            guard try currentTextSnapshot() == initial.text else {
                failureType = "initialSnapshotMismatch"
                throw ComputerUseTextEditError.preconditionChanged
            }
        } catch {
            if failureType == "none" { failureType = "initialReadError" }
            throw error
        }
        deadline = ProcessInfo.processInfo.systemUptime + ComputerUseTextEditor.defaultMaximumDuration
        var baseline = initial
        var postedAnyStroke = false

        let graphemes = Array(payload)
        for (graphemeIndex, character) in graphemes.enumerated() {
            let grapheme = String(character)
            if pendingSpaceUTF16Index != nil && character.isWhitespace {
                failureType = "pendingSpaceFollowedByWhitespace"
                throw ComputerUseTextEditError.deliveryUncertain
            }
            stage = "pre-key-read"
            expectedLocation = baseline.text.selection.location + grapheme.utf16.count
            let entryAllowed = !Task.isCancelled && mayAct()
            lastMayAct = entryAllowed
            guard grapheme.utf8.count <= ComputerUseTextEditor.maximumPayloadBytes,
                  entryAllowed else {
                failureType = Task.isCancelled ? "interrupted" : "pausedOrPayloadRejected"
                throw ComputerUseTextEditError.interrupted
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                failureType = "deadlineExceeded"
                throw ComputerUseTextEditError.deadlineExceeded
            }
            do { try textEditorOverride?.validateContext() }
            catch {
                failureType = "preKeyContextChanged"
                if postedAnyStroke, error as? ComputerUseTextEditError == .preconditionChanged {
                    throw ComputerUseTextEditError.deliveryUncertain
                }
                throw error
            }
            let current: ComputerUseMCPFocusedTextSnapshot?
            do { current = try await nativeVisualKeyboardTextSnapshotRetryingNil(deadline: deadline) }
            catch {
                failureType = "preKeySnapshotError"
                if Task.isCancelled || error is CancellationError
                    || (error as? ComputerUseTextEditError) == .interrupted {
                    throw ComputerUseTextEditError.interrupted
                }
                if postedAnyStroke { throw ComputerUseTextEditError.deliveryUncertain }
                throw error
            }
            lastSnapshot = current
            guard let current,
                  Self.hasSameNativeTypingTarget(current, as: baseline, browserAddressEntryScope: browserAddressEntryScope),
                  current == baseline || (pendingSpaceUTF16Index == nil && postedAnyStroke
                    && allowsInlineCompletionRefresh(current, relativeTo: baseline,
                        browserAddressEntryScope: browserAddressEntryScope)) else {
                failureType = current == nil ? "preKeySnapshotUnavailable" : "preKeySnapshotChanged"
                throw postedAnyStroke ? ComputerUseTextEditError.deliveryUncertain : .preconditionChanged
            }
            baseline = current
            referenceSnapshot = current
            // The final check runs from InputInjector immediately before keydown.
            // Calling it twice also keeps injected editor context checks at the
            // same boundary as production ownership checks.
            do { try textEditorOverride?.validateContext() }
            catch {
                failureType = "prePostContextChanged"
                if postedAnyStroke, error as? ComputerUseTextEditError == .preconditionChanged {
                    throw ComputerUseTextEditError.deliveryUncertain
                }
                throw error
            }
            var failedFinalStateCheck = false
            var passedFinalStateCheck = false
            var readFailure: Error?
            let delivered: Bool
            stage = "final-pre-post"
            if let textEditorOverride {
                var final = try nativeVisualKeyboardTextSnapshot()
                if final == nil {
                    let retryDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.5)
                    do {
                        try await Task.sleep(for: .milliseconds(25))
                        final = try await nativeVisualKeyboardTextSnapshotRetryingNil(deadline: retryDeadline)
                    } catch {
                        failureType = "finalPrePostSnapshotRetryError"
                        if Task.isCancelled || error is CancellationError
                            || (error as? ComputerUseTextEditError) == .interrupted {
                            throw ComputerUseTextEditError.interrupted
                        }
                        if postedAnyStroke { throw ComputerUseTextEditError.deliveryUncertain }
                        throw error
                    }
                }
                lastSnapshot = final
                guard let final,
                      final == baseline || (pendingSpaceUTF16Index == nil && postedAnyStroke
                        && allowsInlineCompletionRefresh(final, relativeTo: baseline,
                            browserAddressEntryScope: browserAddressEntryScope)) else {
                    failureType = "finalPrePostSnapshotChanged"
                    throw postedAnyStroke ? ComputerUseTextEditError.deliveryUncertain : .preconditionChanged
                }
                baseline = final
                referenceSnapshot = final
                let postAllowed = !Task.isCancelled && mayAct()
                lastMayAct = postAllowed
                guard postAllowed else {
                    failureType = "prePostGateClosed"
                    throw ComputerUseTextEditError.interrupted
                }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    failureType = "deadlineExceeded"
                    throw ComputerUseTextEditError.deadlineExceeded
                }
                passedFinalStateCheck = true
                attemptedStrokes += 1
                do {
                    try await textEditorOverride.postUnicode(grapheme, baseline.text)
                    delivered = true
                } catch {
                    failureType = Task.isCancelled ? "cancelledDuringInput" : "inputError"
                    readFailure = Task.isCancelled ? ComputerUseTextEditError.interrupted : .deliveryUncertain
                    delivered = false
                }
            } else {
                var finalRetryDeadline: TimeInterval?
                var strokeDelivered = false
                while true {
                    failedFinalStateCheck = false
                    passedFinalStateCheck = false
                    readFailure = nil
                    attemptedStrokes += 1
                    strokeDelivered = await injector.applyTextStroke(grapheme, ifAllowed: {
                        !Task.isCancelled && mayAct()
                            && ProcessInfo.processInfo.systemUptime < deadline
                    }, beforePosting: {
                        guard !Task.isCancelled, mayAct(), ProcessInfo.processInfo.systemUptime < deadline else {
                            return false
                        }
                        if let finalRetryDeadline,
                           ProcessInfo.processInfo.systemUptime >= finalRetryDeadline {
                            failedFinalStateCheck = true
                            return false
                        }
                        do {
                            let final = try nativeVisualKeyboardTextSnapshot()
                            lastSnapshot = final
                            guard let final,
                                  final == baseline || (pendingSpaceUTF16Index == nil && postedAnyStroke
                                  && allowsInlineCompletionRefresh(final, relativeTo: baseline,
                                      browserAddressEntryScope: browserAddressEntryScope)) else {
                                failedFinalStateCheck = true
                                return false
                            }
                            baseline = final
                            referenceSnapshot = final
                            guard !Task.isCancelled, mayAct(),
                                  ProcessInfo.processInfo.systemUptime < deadline else { return false }
                            if let finalRetryDeadline,
                               ProcessInfo.processInfo.systemUptime >= finalRetryDeadline {
                                failedFinalStateCheck = true
                                return false
                            }
                            passedFinalStateCheck = true
                            return true
                        } catch {
                            readFailure = error
                            failedFinalStateCheck = true
                            return false
                        }
                    })
                    // InputInjector invokes beforePosting before posting key-down;
                    // a nil-only rejection here proves this grapheme was not sent.
                    guard !strokeDelivered, failedFinalStateCheck, !passedFinalStateCheck,
                          readFailure == nil, lastSnapshot == nil,
                          !Task.isCancelled, mayAct(),
                          ProcessInfo.processInfo.systemUptime < deadline else { break }
                    if finalRetryDeadline == nil {
                        finalRetryDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.5)
                    }
                    guard let finalRetryDeadline,
                          ProcessInfo.processInfo.systemUptime < finalRetryDeadline else { break }
                    do {
                        try await Task.sleep(for: .milliseconds(25))
                        guard !Task.isCancelled, mayAct(),
                              ProcessInfo.processInfo.systemUptime < deadline else {
                            throw ComputerUseTextEditError.interrupted
                        }
                        guard let recovered = try await nativeVisualKeyboardTextSnapshotRetryingNil(deadline: finalRetryDeadline) else {
                            break
                        }
                        guard recovered == baseline
                            || (pendingSpaceUTF16Index == nil && postedAnyStroke
                                && allowsInlineCompletionRefresh(recovered, relativeTo: baseline,
                                    browserAddressEntryScope: browserAddressEntryScope)) else {
                            lastSnapshot = recovered
                            failedFinalStateCheck = true
                            break
                        }
                        lastSnapshot = recovered
                        baseline = recovered
                        referenceSnapshot = recovered
                    } catch {
                        failureType = "finalPrePostSnapshotRetryError"
                        if Task.isCancelled || error is CancellationError
                            || (error as? ComputerUseTextEditError) == .interrupted {
                            throw ComputerUseTextEditError.interrupted
                        }
                        if postedAnyStroke { throw ComputerUseTextEditError.deliveryUncertain }
                        throw error
                    }
                }
                delivered = strokeDelivered
            }
            stage = "input-return"
            guard delivered else {
                if let readFailure {
                    failureType = "inputGuardReadError"
                    if postedAnyStroke { throw ComputerUseTextEditError.deliveryUncertain }
                    throw readFailure
                }
                if failedFinalStateCheck && !passedFinalStateCheck {
                    failureType = "finalPrePostStateRejected"
                    throw postedAnyStroke ? ComputerUseTextEditError.deliveryUncertain : .preconditionChanged
                }
                failureType = "inputNotDeliveredOrUncertain"
                throw Task.isCancelled ? ComputerUseTextEditError.interrupted : .deliveryUncertain
            }
            postedAnyStroke = true
            completedStrokes += 1

            stage = "post-stroke-read"
            let strokeBaseline = baseline
            let expectedLocation = strokeBaseline.text.selection.location + grapheme.utf16.count
            let expectedPrefix: String
            if let range = Range(strokeBaseline.text.selection, in: strokeBaseline.text.value) {
                expectedPrefix = String(strokeBaseline.text.value[..<range.lowerBound]) + grapheme
            } else {
                failureType = "postStrokeInvalidBaselineSelection"
                throw ComputerUseTextEditError.deliveryUncertain
            }
            let settleDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.5)
            var after: ComputerUseMCPFocusedTextSnapshot?
            lastSnapshot = nil
            do {
                after = try await nativeVisualKeyboardTextSnapshotRetryingNil(deadline: settleDeadline)
                // A readable snapshot equal to the exact pre-stroke baseline may
                // be an AX read that has not caught up with the posted key. Wait
                // briefly only in that state; any other readable change is
                // validated immediately and can never cause this key to repeat.
                while let candidate = after, candidate == strokeBaseline,
                      ProcessInfo.processInfo.systemUptime < settleDeadline {
                    try Task.checkCancellation()
                    guard mayAct() else { throw ComputerUseTextEditError.interrupted }
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw ComputerUseTextEditError.deadlineExceeded
                    }
                    try await Task.sleep(for: .milliseconds(25))
                    try Task.checkCancellation()
                    guard mayAct() else { throw ComputerUseTextEditError.interrupted }
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw ComputerUseTextEditError.deadlineExceeded
                    }
                    after = try await nativeVisualKeyboardTextSnapshotRetryingNil(deadline: settleDeadline)
                }
            } catch {
                failureType = "postStrokeSnapshotError"
                if Task.isCancelled || error is CancellationError
                    || (error as? ComputerUseTextEditError) == .interrupted {
                    throw ComputerUseTextEditError.interrupted
                }
                if (error as? ComputerUseTextEditError) == .deadlineExceeded {
                    failureType = "deadlineExceeded"
                    throw ComputerUseTextEditError.deliveryUncertain
                }
                throw ComputerUseTextEditError.deliveryUncertain
            }
            lastSnapshot = after
            stage = "post-stroke-validation"
            let afterAllowed = !Task.isCancelled && mayAct()
            lastMayAct = afterAllowed
            let expectedUnits = Array(expectedPrefix.utf16)
            let observedUnits = after.map { Array($0.text.value.utf16) } ?? []
            let suffixLength = max(0, observedUnits.count - expectedLocation)
            var exactExpectedUnits = expectedUnits
            if let pendingSpaceUTF16Index {
                guard pendingSpaceUTF16Index < exactExpectedUnits.count else {
                    failureType = "pendingSpaceIndexOutOfBounds"
                    throw ComputerUseTextEditError.deliveryUncertain
                }
                // The next grapheme must cause the browser to restore this one
                // known compatibility NBSP. No other Unicode differences are accepted.
                exactExpectedUnits[pendingSpaceUTF16Index] = 0x20
            }
            let hasExactTypedPrefix = observedUnits.count >= exactExpectedUnits.count
                && Array(observedUnits.prefix(exactExpectedUnits.count)) == exactExpectedUnits
            let hasPermittedInlineSuffix = after.map {
                $0.text.selection.length == 0 || $0.text.selection.length == suffixLength
            } ?? false
            let nextGrapheme = graphemeIndex + 1 < graphemes.count ? graphemes[graphemeIndex + 1] : nil
            let previousGraphemeIsNonWhitespace = strokeBaseline.text.value.last.map { !$0.isWhitespace } ?? false
            let canProvisionallyAcceptSpace = pendingSpaceUTF16Index == nil
                && grapheme == " "
                && nextGrapheme.map { !$0.isWhitespace } == true
                && strokeBaseline.isWebContent
                && strokeBaseline.role == "AXTextArea"
                && after?.isWebContent == true
                && after?.role == "AXTextArea"
                && strokeBaseline.text.selection.length == 0
                && strokeBaseline.text.selection.location == strokeBaseline.text.value.utf16.count
                && after?.text.selection.length == 0
                && previousGraphemeIsNonWhitespace
                && strokeBaseline.hasSameDocumentTarget(as: initial)
                && expectedUnits.count == observedUnits.count
                && observedUnits.indices.allSatisfy { index in
                    observedUnits[index] == (index == expectedLocation - 1 ? 0x00A0 : expectedUnits[index])
                }
            let exactWholeValue = observedUnits == exactExpectedUnits
                && after?.text.selection.length == 0
            guard afterAllowed, ProcessInfo.processInfo.systemUptime < deadline,
                  let after,
                  Self.hasSameNativeTypingTarget(after, as: strokeBaseline,
                      browserAddressEntryScope: browserAddressEntryScope),
                  after.text.isEditable, !after.text.isSecure,
                  after.text.selection.location == expectedLocation,
                  after.text.value.utf8.count <= ComputerUseTextEditor.maximumObservedValueBytes,
                  (canProvisionallyAcceptSpace || (hasExactTypedPrefix && hasPermittedInlineSuffix)),
                  pendingSpaceUTF16Index == nil || exactWholeValue else {
                failureType = Task.isCancelled ? "interrupted"
                    : (!afterAllowed ? "paused" : (ProcessInfo.processInfo.systemUptime >= deadline
                        ? "deadlineExceeded" : (after == nil ? "postStrokeSnapshotUnavailable" : "postStrokeStateRejected")))
                throw Task.isCancelled ? ComputerUseTextEditError.interrupted : .deliveryUncertain
            }
            if canProvisionallyAcceptSpace {
                pendingSpaceUTF16Index = expectedLocation - 1
                provisionalSpaceTransitions += 1
            } else if pendingSpaceUTF16Index != nil {
                pendingSpaceUTF16Index = nil
                restoredSpaceTransitions += 1
            }
            // Inline completions may select a suffix after the inserted text.
            // Keep validating its bounded snapshot and insertion point without requiring a collapsed range.
            baseline = after
            referenceSnapshot = after
        }
        guard pendingSpaceUTF16Index == nil else {
            failureType = "unresolvedPendingSpace"
            throw ComputerUseTextEditError.deliveryUncertain
        }
        stage = "completed"
    }

    private struct ApprovalTarget {
        let context: String
        let accessibilityIdentity: String
        let applicationID: String
        let visualCheckpoints: [CGPoint]
    }

    private struct AccessibilitySnapshot {
        let summary: String
        let attestationLabel: String?
        let identity: String
        let center: CGPoint?
        let frame: CGRect?
        let isEnabled: Bool
        let isActionable: Bool
    }

    private func approvalTarget(
        for action: ComputerUsePredictedAction
    ) throws -> ApprovalTarget {
        if let approvalTargetProvider {
            let snapshot = try approvalTargetProvider(action)
            return ApprovalTarget(
                context: snapshot.context,
                accessibilityIdentity: snapshot.accessibilityIdentity,
                applicationID: snapshot.applicationID,
                visualCheckpoints: [])
        }
        let applicationID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            ?? "pid:\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)"
        let snapshots: [AccessibilitySnapshot]
        let checkpoints: [CGPoint]

        switch action {
        case .click(let x, let y, _, _):
            let point = CGPoint(x: x, y: y)
            snapshots = actionableElementSnapshot(at: point).map { [$0] } ?? []
            checkpoints = [point]

        case .drag(let fromX, let fromY, let toX, let toY):
            let from = CGPoint(x: fromX, y: fromY)
            let to = CGPoint(x: toX, y: toY)
            snapshots = [elementSnapshot(at: from), elementSnapshot(at: to)]
                .compactMap { $0 }
            checkpoints = [from, to]

        case .key:
            let focused = focusedElementSnapshot()
            snapshots = focused.map { [$0] } ?? []
            guard screenProvider == nil,
                  let focusedWindow = liveFrontmostWindowSnapshot(),
                  let activeDisplays = liveActiveDisplayInventory(),
                  let selectedDisplay = ComputerUseFocusedDisplaySelector.select(
                    windowBounds: focusedWindow.bounds, activeDisplays: activeDisplays) else {
                throw ToolError.approvalTargetUnavailable
            }
            checkpoints = [Self.nativeKeyboardCheckpoint(focusedFrame: focused?.frame,
                windowBounds: focusedWindow.bounds, displayBounds: selectedDisplay.bounds)]

        case .typeText:
            guard let focused = focusedElementSnapshot() else {
                throw ToolError.approvalTargetUnavailable
            }
            snapshots = [focused]
            // Accessibility identity includes the field's role, label, app,
            // position, and size. Avoid a pixel check here because a blinking
            // insertion caret would otherwise invalidate every approval.
            checkpoints = []

        case .scroll(let x, let y, _, _):
            let point = CGPoint(x: x, y: y)
            snapshots = elementSnapshot(at: point).map { [$0] } ?? []
            checkpoints = [point]

        case .requestApproval(_, let proposedAction):
            return try approvalTarget(for: proposedAction)

        case .wait, .done:
            throw ToolError.approvalTargetUnavailable
        }

        return ApprovalTarget(
            context: snapshots.map(\.summary).filter { !$0.isEmpty }.joined(separator: " → "),
            accessibilityIdentity: snapshots.isEmpty
                ? "unavailable"
                : snapshots.map(\.identity).joined(separator: " -> "),
            applicationID: applicationID,
            visualCheckpoints: checkpoints)
    }

    static func nativeKeyboardCheckpoint(focusedFrame: CGRect?, windowBounds: CGRect?, displayBounds: CGRect) -> CGPoint {
        func visible(_ frame: CGRect?, in bounds: CGRect) -> CGRect? {
            guard let frame, !frame.isEmpty,
                  [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return nil }
            let intersection = frame.intersection(bounds)
            return intersection.isEmpty || intersection.isNull ? nil : intersection
        }
        let window = visible(windowBounds, in: displayBounds) ?? displayBounds
        // AX outlines can describe all scrollable rows, with their center far
        // offscreen. Bind keyboard pixels to the visible part of that control.
        // This point is only observed; keyboard input still targets AX focus.
        let target = visible(focusedFrame, in: window) ?? window
        return CGPoint(x: target.midX, y: target.midY)
    }

    private func accessibilityContext(for action: ComputerUsePredictedAction) -> String {
        if let accessibilityContextProvider {
            let context = accessibilityContextProvider(action)
            if case .click = action,
               Self.actionableLabel(fromProvidedContext: context) == nil { return "" }
            return context
        }
        switch action {
        case .click(let x, let y, _, _):
            // A containing application/window/web area does not identify the
            // clicked control. Resolve an actionable ancestor (for nested
            // text/images), or require approval for the unidentified point.
            return actionableElementSnapshot(at: CGPoint(x: x, y: y))?.summary ?? ""
        case .drag(let fromX, let fromY, let toX, let toY):
            return [
                elementSnapshot(at: CGPoint(x: fromX, y: fromY))?.summary,
                elementSnapshot(at: CGPoint(x: toX, y: toY))?.summary,
            ].compactMap { $0 }.joined(separator: " → ")
        case .key, .typeText:
            return focusedElementSnapshot()?.summary ?? ""
        case .scroll(let x, let y, _, _):
            return elementSnapshot(at: CGPoint(x: x, y: y))?.summary ?? ""
        case .requestApproval(_, let proposedAction):
            return accessibilityContext(for: proposedAction)
        case .wait, .done:
            return ""
        }
    }

    private func elementSnapshot(at point: CGPoint) -> AccessibilitySnapshot? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &element) == .success,
              let element else { return nil }
        return accessibilitySnapshot(for: element)
    }

    private func accessibilityClickCandidate(
        at point: CGPoint
    ) -> OSAtlasAccessibilityClickCandidate? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &element) == .success,
              var current = element else { return nil }

        var fallback: AccessibilitySnapshot?
        for _ in 0 ..< 8 {
            let snapshot = accessibilitySnapshot(for: current)
            if fallback == nil { fallback = snapshot }
            if snapshot.isActionable, snapshot.frame != nil {
                return clickCandidate(from: snapshot)
            }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        guard let fallback else { return nil }
        return clickCandidate(from: fallback)
    }

    /// Traverses only the current frontmost application's focused window and
    /// at most one focused document root. Labels remain transient in memory;
    /// no caller receives the scanned tree or writes it to diagnostics.
    private func focusedSemanticAccessibilityClickScope()
        -> OSAtlasSemanticAccessibilityClickScope? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let applicationRoot = AXUIElementCreateApplication(
            application.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationRoot,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue) == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedWindow = unsafeBitCast(
            focusedWindowValue,
            to: AXUIElement.self)
        let scopeRoot = firstWebContentRoot(in: focusedWindow)
            ?? focusedWindow
        guard let scopeFrame = accessibilitySnapshot(for: scopeRoot).frame,
              scopeFrame.origin.x.isFinite,
              scopeFrame.origin.y.isFinite,
              scopeFrame.width.isFinite,
              scopeFrame.height.isFinite,
              scopeFrame.width > 0,
              scopeFrame.height > 0 else {
            return nil
        }

        let maximumElements = 256
        let maximumDepth = 12
        let maximumChildrenPerElement = 48
        var queue: [(AXUIElement, Int)] = [(scopeRoot, 0)]
        var index = 0
        var candidates: [OSAtlasSemanticAccessibilityClickCandidate] = []
        while index < queue.count, index < maximumElements {
            let (element, depth) = queue[index]
            index += 1
            guard depth <= maximumDepth else { continue }

            let snapshot = accessibilitySnapshot(for: element)
            if snapshot.isEnabled,
               snapshot.isActionable,
               let frame = snapshot.frame,
               frame.origin.x.isFinite,
               frame.origin.y.isFinite,
               frame.width.isFinite,
               frame.height.isFinite,
               frame.width > 0,
               frame.height > 0,
               let label = snapshot.attestationLabel,
               !label.isEmpty {
                candidates.append(OSAtlasSemanticAccessibilityClickCandidate(
                    identity: snapshot.identity,
                    frame: frame,
                    isEnabled: true,
                    isActionable: true,
                    label: label))
            }

            guard queue.count < maximumElements else { continue }
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else {
                continue
            }
            let remaining = maximumElements - queue.count
            queue.append(contentsOf: children
                .prefix(min(maximumChildrenPerElement, remaining))
                .map { ($0, depth + 1) })
        }
        return OSAtlasSemanticAccessibilityClickScope(
            frame: scopeFrame,
            candidates: candidates)
    }

    private func clickCandidate(
        from snapshot: AccessibilitySnapshot
    ) -> OSAtlasAccessibilityClickCandidate? {
        guard let frame = snapshot.frame else { return nil }
        return OSAtlasAccessibilityClickCandidate(
            identity: snapshot.identity,
            frame: frame,
            isEnabled: snapshot.isEnabled,
            isActionable: snapshot.isActionable)
    }

    private func parentElement(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// Text snapshots may resolve an active suggestion row to its owning
    /// expanded combo box. Generic button/menu focus continues to use the raw
    /// system-wide focused element above.
    private func focusedTextElement() -> AXUIElement? {
        guard let focused = focusedElement(),
              let runningApplication = NSWorkspace.shared.frontmostApplication,
              !runningApplication.isTerminated,
              let role = Self.stringAttribute(kAXRoleAttribute as CFString, from: focused) else { return nil }
        if [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role) {
            return focused
        }
        let root = AXUIElementCreateApplication(runningApplication.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString,
                                            &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        let launchTime = runningApplication.launchDate?.timeIntervalSince1970 ?? 0
        let bundlePath = runningApplication.bundleURL?.path ?? ""
        let application = ComputerUseAccessibilityTextTarget.Application(
            identity: "\(runningApplication.processIdentifier):\(launchTime):\(bundlePath)",
            root: root)
        return ComputerUseAccessibilityTextTarget.focusedComboBox(
            from: focused, application: application, window: window,
            access: ComputerUseAccessibilityTextTarget.Access.live)
    }

    private func focusedElementSnapshot() -> AccessibilitySnapshot? {
        guard let focused = focusedElement() else { return nil }
        return accessibilitySnapshot(for: focused)
    }

    private func liveScreenCaptureConsentContext()
        -> ComputerUseAuthenticationContextSnapshot? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let systemFocused: AXUIElement?
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue) == .success,
           let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            systemFocused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        } else {
            systemFocused = nil
        }

        var roots: [AXUIElement] = []
        if let systemFocused {
            var contextRoot = systemFocused
            var current = systemFocused
            for _ in 0 ..< 10 {
                let role = Self.stringAttribute(
                    kAXRoleAttribute as CFString,
                    from: current) ?? ""
                contextRoot = current
                if ["AXWindow", "AXSheet", "AXDialog"].contains(role) {
                    break
                }
                guard let parent = parentElement(of: current) else { break }
                current = parent
            }
            roots.append(contextRoot)
        }

        // The screen-capture consent sheet can remain owned by this process
        // while another app is reported as frontmost. Include only the host's
        // bounded windows, then rely on local OCR if AX does not expose them.
        let ownRoot = AXUIElementCreateApplication(
            ProcessInfo.processInfo.processIdentifier)
        var ownWindowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            ownRoot,
            kAXWindowsAttribute as CFString,
            &ownWindowsValue) == .success,
           let ownWindows = ownWindowsValue as? [AXUIElement] {
            roots.append(contentsOf: ownWindows.prefix(8))
        }

        let focusedSummary = systemFocused
            .map(authenticationContextSummary)
            .flatMap { $0.isEmpty ? nil : $0 }
        var queue = roots.map { ($0, 0) }
        var index = 0
        var summaries: [String] = []
        var seen = Set<String>()
        while index < queue.count, index < 128 {
            let (element, depth) = queue[index]
            index += 1
            guard depth <= 8 else { continue }
            let summary = authenticationContextSummary(for: element)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty, seen.insert(summary).inserted {
                summaries.append(summary)
            }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(48).map {
                    ($0, depth + 1)
                })
            }
        }
        let bounded = String(
            summaries.joined(separator: "\n").prefix(4_000))
        guard focusedSummary != nil || !bounded.isEmpty else { return nil }
        return ComputerUseAuthenticationContextSnapshot(
            focusedElement: focusedSummary,
            boundedWindowContext: bounded)
    }

    private func liveAuthenticationContext()
        -> ComputerUseAuthenticationContextSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !application.isTerminated else {
            return nil
        }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedElement: AXUIElement?
        if AXUIElementCopyAttributeValue(
            root,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue) == .success,
           let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        } else {
            focusedElement = nil
        }
        let focusedSummary = focusedElement.map(authenticationContextSummary)
            .flatMap { $0.isEmpty ? nil : $0 }

        var windowValue: CFTypeRef?
        let focusedWindow: AXUIElement?
        if AXUIElementCopyAttributeValue(
            root,
            kAXFocusedWindowAttribute as CFString,
            &windowValue) == .success,
           let windowValue,
           CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            focusedWindow = unsafeBitCast(windowValue, to: AXUIElement.self)
        } else {
            focusedWindow = nil
        }

        // Browser chrome (toolbars, extensions, and large tab strips) can
        // otherwise consume the retained-text bound before the selected
        // document's login controls are reached. Prefer the focused window's
        // first exposed web area; native windows and sheets keep their full
        // focused-window traversal. Editable field values are never read.
        let authenticationRoot = focusedWindow.flatMap {
            firstWebContentRoot(in: $0)
        } ?? focusedWindow
        var queue: [(AXUIElement, Int)] =
            authenticationRoot.map { [($0, 0)] } ?? []
        var index = 0
        var summaries: [String] = []
        var seen = Set<String>()
        while index < queue.count, index < 96 {
            let (element, depth) = queue[index]
            index += 1
            guard depth <= 8 else { continue }
            let summary = authenticationContextSummary(for: element)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty, seen.insert(summary).inserted {
                summaries.append(summary)
            }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(48).map {
                    ($0, depth + 1)
                })
            }
        }
        let bounded = String(
            summaries.joined(separator: "\n").prefix(4_000))
        guard focusedSummary != nil || !bounded.isEmpty else { return nil }
        return ComputerUseAuthenticationContextSnapshot(
            focusedElement: focusedSummary,
            boundedWindowContext: bounded)
    }

    private func firstWebContentRoot(
        in window: AXUIElement
    ) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        while index < queue.count, index < 128 {
            let (element, depth) = queue[index]
            index += 1
            guard depth <= 8 else { continue }
            if Self.stringAttribute(
                kAXRoleAttribute as CFString,
                from: element) == "AXWebArea" {
                return element
            }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(48).map {
                    ($0, depth + 1)
                })
            }
        }
        return nil
    }

    /// Attribute names, labels, and placeholders reveal field purpose without
    /// exposing what the person typed. Static labels/buttons may contribute a
    /// short value so provider-based sign-in sheets remain detectable.
    private func authenticationContextSummary(
        for element: AXUIElement
    ) -> String {
        var summary = accessibilitySnapshot(for: element).summary
        let role = Self.stringAttribute(
            kAXRoleAttribute as CFString,
            from: element) ?? ""
        let safeValueRoles: Set<String> = [
            "AXStaticText", "AXButton", "AXLink", "AXHeading",
            "AXRadioButton", "AXCheckBox",
        ]
        if safeValueRoles.contains(role),
           let value = Self.stringAttribute(
               kAXValueAttribute as CFString,
               from: element)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            let boundedValue = String(value.prefix(200))
            if !summary.localizedCaseInsensitiveContains(boundedValue) {
                summary += summary.isEmpty ? boundedValue : " • \(boundedValue)"
            }
        }
        return summary
    }

    private func accessibilitySnapshot(
        for element: AXUIElement
    ) -> AccessibilitySnapshot {
        let attributes: [(String, CFString)] = [
            ("role", kAXRoleAttribute as CFString),
            ("subrole", kAXSubroleAttribute as CFString),
            ("title", kAXTitleAttribute as CFString),
            ("description", kAXDescriptionAttribute as CFString),
            ("help", kAXHelpAttribute as CFString),
            ("identifier", kAXIdentifierAttribute as CFString),
            ("placeholder", kAXPlaceholderValueAttribute as CFString),
        ]
        let values: [(String, String)] = attributes.compactMap { name, attribute in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                attribute,
                &value) == .success,
                  let string = value as? String,
                  !string.isEmpty else { return nil }
            return (name, string)
        }
        let position = pointAttribute(
            kAXPositionAttribute as CFString,
            from: element)
        let size = sizeAttribute(
            kAXSizeAttribute as CFString,
            from: element)
        let enabled = boolAttribute(
            kAXEnabledAttribute as CFString,
            from: element) ?? false
        var actionNames: CFArray?
        let copyActionsResult = AXUIElementCopyActionNames(element, &actionNames)
        let actions = copyActionsResult == .success
            ? (actionNames as? [String] ?? [])
            : []
        let role = values.first(where: { $0.0 == "role" })?.1 ?? ""
        let actionableRoles: Set<String> = [
            kAXButtonRole as String,
            "AXLink",
            kAXCheckBoxRole as String,
            kAXRadioButtonRole as String,
            kAXPopUpButtonRole as String,
            kAXComboBoxRole as String,
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXMenuItemRole as String,
            kAXSliderRole as String,
            kAXIncrementorRole as String,
        ]
        let isActionable = actions.contains(kAXPressAction as String)
            || actionableRoles.contains(role)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        var identity = values.map { "\($0.0)=\($0.1)" }.joined(separator: "|")
        identity += "|pid=\(pid)"
        if let position {
            identity += "|position=\(Int(position.x.rounded())),\(Int(position.y.rounded()))"
        }
        if let size {
            identity += "|size=\(Int(size.width.rounded())),\(Int(size.height.rounded()))"
        }
        let center: CGPoint?
        let frame: CGRect?
        if let position, let size {
            center = CGPoint(
                x: position.x + size.width / 2,
                y: position.y + size.height / 2)
            frame = CGRect(origin: position, size: size)
        } else {
            center = nil
            frame = nil
        }
        return AccessibilitySnapshot(
            summary: values.map(\.1).joined(separator: " • "),
            attestationLabel: {
                for attribute in [
                    "title", "description", "placeholder", "help",
                ] {
                    if let value = values.first(where: {
                        $0.0 == attribute
                    })?.1 {
                        return String(value.prefix(256))
                    }
                }
                return nil
            }(),
            identity: identity,
            center: center,
            frame: frame,
            isEnabled: enabled,
            isActionable: isActionable)
    }

    private func boolAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    private func pointAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func visualDigest(around points: [CGPoint]) throws -> String? {
        lastScreenCaptureFailureForDiagnostics = nil
        guard !points.isEmpty else { return nil }
        // A synthetic observation must never be mixed with the live display.
        guard screenProvider == nil else { return nil }
        let windowBefore = liveFrontmostWindowSnapshot()
        guard let windowBefore else {
            lastScreenCaptureFailureForDiagnostics = "digest_window_before_unavailable"
            throw ToolError.focusedDisplayUnavailable
        }
        guard let activeDisplaysBefore = liveActiveDisplayInventory(),
              let selectedDisplayBefore = ComputerUseFocusedDisplaySelector.select(
                windowBounds: windowBefore.bounds, activeDisplays: activeDisplaysBefore) else {
            lastScreenCaptureFailureForDiagnostics = "digest_display_before_unavailable"
            throw ToolError.focusedDisplayUnavailable
        }
        let displayID = selectedDisplayBefore.identifier
        let bounds = selectedDisplayBefore.bounds
        guard bounds.width > 0, bounds.height > 0,
              let image = CGDisplayCreateImage(displayID) else {
            throw ToolError.screenshotUnavailable
        }
        let windowAfter = liveFrontmostWindowSnapshot()
        guard let windowAfter else {
            lastScreenCaptureFailureForDiagnostics = "digest_window_after_unavailable"
            throw ToolError.approvalTargetChanged
        }
        guard windowBefore == windowAfter else {
            lastScreenCaptureFailureForDiagnostics = "digest_window_after_changed"
            throw ToolError.approvalTargetChanged
        }
        guard let activeDisplaysAfter = liveActiveDisplayInventory(),
              let selectedDisplayAfter = ComputerUseFocusedDisplaySelector.select(
                windowBounds: windowAfter.bounds, activeDisplays: activeDisplaysAfter) else {
            lastScreenCaptureFailureForDiagnostics = "digest_display_after_unavailable"
            throw ToolError.approvalTargetChanged
        }
        guard ComputerUseFocusedDisplaySelector.isStable(before: selectedDisplayBefore, after: selectedDisplayAfter) else {
            lastScreenCaptureFailureForDiagnostics = "digest_display_after_changed"
            throw ToolError.approvalTargetChanged
        }
        return try Self.approvalVisualDigest(around: points, image: image, displayBounds: bounds, window: windowAfter)
    }

    static func approvalVisualDigest(around points: [CGPoint], image: CGImage, displayBounds bounds: CGRect,
                                     window: ComputerUseFrontmostWindowCaptureIdentity?) throws -> String? {
        guard !points.isEmpty else { return nil }
        func valid(_ rect: CGRect) -> Bool {
            !rect.isEmpty && [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.width, rect.height].allSatisfy(\.isFinite)
        }
        guard valid(bounds), points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && bounds.contains($0) }),
              window.map({ valid($0.bounds) }) ?? true else { throw ToolError.approvalTargetUnavailable }
        let scaleX = CGFloat(image.width) / bounds.width
        let scaleY = CGFloat(image.height) / bounds.height
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var scope = imageBounds
        func geometry(_ rect: CGRect) -> [String] {
            [rect.minX, rect.minY, rect.width, rect.height].map { String(Double($0)) }
        }
        var identity = ["approval-pixels-v2", String(image.width), String(image.height)] + geometry(bounds)
        if let window {
            identity += ["window", String(window.applicationProcessIdentifier), String(window.accessibilityWindowHash)] + geometry(window.bounds)
            // A cross-window drag or a target outside the focused window
            // still needs display pixels at every checkpoint.
            if points.allSatisfy({ window.bounds.contains($0) }) {
                scope = CGRect(x: (window.bounds.minX - bounds.minX) * scaleX,
                    y: (window.bounds.minY - bounds.minY) * scaleY,
                    width: window.bounds.width * scaleX, height: window.bounds.height * scaleY).intersection(imageBounds)
            }
        } else { identity.append("unknown-window") }
        var digestInput = Data(ComputerUseTaskContract.digest(identity).utf8)
        for point in points {
            let pixelPoint = CGPoint(
                x: (point.x - bounds.minX) * scaleX,
                y: (point.y - bounds.minY) * scaleY)
            let radius: CGFloat = 48
            let requested = CGRect(
                x: pixelPoint.x - radius,
                y: pixelPoint.y - radius,
                width: radius * 2,
                height: radius * 2)
                .intersection(scope)
            // Whole image pixels only: outward rounding at a fractional
            // window edge can import pixels from the adjacent application.
            let cropRect = CGRect(x: ceil(requested.minX), y: ceil(requested.minY),
                width: floor(requested.maxX) - ceil(requested.minX), height: floor(requested.maxY) - ceil(requested.minY))
            guard cropRect.width > 0, cropRect.height > 0,
                  let crop = image.cropping(to: cropRect) else {
                throw ToolError.approvalTargetUnavailable
            }

            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: 32,
                    height: 32,
                    bitsPerComponent: 8,
                    bytesPerRow: 32 * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    return false
                }
                context.interpolationQuality = .low
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 32, height: 32))
                return true
            }
            guard rendered else { throw ToolError.screenshotUnavailable }
            digestInput.append(contentsOf: ComputerUseTaskContract.digest(geometry(cropRect)).utf8)
            digestInput.append(contentsOf: pixels)
        }
        return SHA256.hash(data: digestInput)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func perform(_ action: ComputerUsePredictedAction) throws {
        try perform(action, reportsPartialApprovedEffect: false)
    }

    private func currentTextSnapshot() throws -> ComputerUseTextSnapshot? {
        if let textEditorOverride { return try textEditorOverride.read() }
        return textTarget.snapshot()
    }

    func performVerified(_ action: ComputerUsePredictedAction) async throws {
        guard case .typeText(let payload) = action else {
            try perform(action)
            return
        }
        // A virtual action performer owns its simulated effects. Production
        // has no performer override and must confirm the real field value.
        if actionPerformer != nil, textEditorOverride == nil {
            try perform(action)
            return
        }
        try await editFocusedText(payload, mode: .insert)
    }

    func editFocusedText(
        _ payload: String,
        mode: ComputerUseTextEditMode
    ) async throws {
        guard let snapshot = try currentTextSnapshot() else {
            throw ComputerUseTextEditError.unavailableTarget
        }
        let deadline = ProcessInfo.processInfo.systemUptime + ComputerUseTextEditor.defaultMaximumDuration
        var editor = textEditorOverride ?? ComputerUseTextEditor(
            read: { [textTarget] in textTarget.snapshot() },
            select: { [textTarget, injector, mayAct] range, expected in
                try injector.performHostEffectIfAllowed(ifAllowed: mayAct) {
                    try textTarget.select(range, expected: expected)
                }
            },
            replaceSelectedText: { [textTarget, injector, mayAct] text, expected in
                try injector.performHostEffectIfAllowed(ifAllowed: mayAct) {
                    try textTarget.replaceSelectedText(text, expected: expected)
                }
            },
            postUnicode: { [textTarget, injector, mayAct] text, expected in
                var targetChanged = false, expired = false
                guard await injector.applyTextStroke(text, ifAllowed: {
                    guard mayAct(), !Task.isCancelled else { return false }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { expired = true; return false }
                    guard textTarget.snapshot()?.targetID == expected.targetID else { targetChanged = true; return false }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { expired = true; return false }
                    return mayAct() && !Task.isCancelled
                }, beforePosting: {
                    guard textTarget.snapshot() == expected else { targetChanged = true; return false }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { expired = true; return false }
                    return mayAct() && !Task.isCancelled
                }) else {
                    if expired { throw ComputerUseTextEditError.deadlineExceeded }
                    throw targetChanged ? ComputerUseTextEditError.deliveryUncertain : .interrupted
                }
            },
            mayAct: mayAct)
        if textEditorOverride == nil {
            editor.readEditedTarget = { [textTarget] targetID in textTarget.snapshot(targetID: targetID) }
            editor.replaceValue = { [textTarget, injector, mayAct] value, expected in
                try injector.performHostEffectIfAllowed(ifAllowed: mayAct) {
                    try textTarget.replaceWebValue(value, expected: expected)
                }
            }
        }
        try await editor.edit(payload, mode: mode, expected: snapshot)
    }

    private func perform(
        _ action: ComputerUsePredictedAction,
        reportsPartialApprovedEffect: Bool
    ) throws {
        var approvedStepWasPosted = false

        func inject(_ message: ControlMessage) throws {
            guard injector.apply(message, ifAllowed: mayAct) else {
                if reportsPartialApprovedEffect, approvedStepWasPosted {
                    throw ToolError.approvedActionEffectMayHaveOccurred
                }
                throw ToolError.paused
            }
            if reportsPartialApprovedEffect {
                approvedStepWasPosted = true
                approvedActionStepDidPost?()
            }
        }

        guard mayAct() else { throw ToolError.paused }
        if let actionPerformer {
            try actionPerformer(action)
            return
        }
        switch action {
        case .click(let x, let y, let button, let count):
            for index in 0 ..< max(1, count) {
                try inject(.pointer(x: x, y: y, buttons: button))
                try inject(.pointer(x: x, y: y, buttons: 0))
                if index + 1 < count { Thread.sleep(forTimeInterval: 0.08) }
            }
        case .drag(let fromX, let fromY, let toX, let toY):
            try inject(.pointer(x: fromX, y: fromY, buttons: 0))
            try inject(.pointer(x: fromX, y: fromY, buttons: 1))
            // Real AppKit drag destinations commonly require several moved
            // events while the button is held. Interpolate a short, bounded
            // path instead of teleporting directly from source to destination.
            let distance = hypot(Double(toX - fromX), Double(toY - fromY))
            let steps = max(4, min(24, Int((distance / 24).rounded(.up))))
            for step in 1 ... steps {
                let fraction = Double(step) / Double(steps)
                let x = Int((Double(fromX) + Double(toX - fromX) * fraction).rounded())
                let y = Int((Double(fromY) + Double(toY - fromY) * fraction).rounded())
                try inject(.pointer(x: x, y: y, buttons: 1))
            }
            try inject(.pointer(x: toX, y: toY, buttons: 0))
        case .scroll(let x, let y, let dx, let dy):
            try inject(.pointer(x: x, y: y, buttons: 0))
            try inject(.scroll(x: x, y: y, dx: 0, dy: 0, phase: .begin))
            try inject(.scroll(x: x, y: y, dx: dx, dy: dy, phase: .changed))
            try inject(.scroll(x: x, y: y, dx: 0, dy: 0, phase: .end))
        case .key(let usage, let modifiers):
            try inject(.key(usage: usage, down: true, modifiers: modifiers))
            try inject(.key(usage: usage, down: false, modifiers: modifiers))
        case .typeText(let text):
            try inject(.text(text))
        case .requestApproval, .wait, .done:
            break
        }
    }
}

final class ComputerUseActionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    private var pendingAutomationID: UUID?
    private var pendingAutomationAdopted = false
    private var automationActive = false
    private var approvalPending = false
    struct InputIntervention: Equatable, Sendable {
        fileprivate let id: UUID
    }
    private var pendingInputIntervention: InputIntervention?
    struct PausedInputSnapshot: Equatable, Sendable {
        let scopeID: UUID
        let generation: UInt64
    }
    private var pausedInputScopeID: UUID?
    private var pausedInputGeneration: UInt64 = 0
    private var pausedInputUnacknowledged = false

    func trackPausedInput(scopeID: UUID?) {
        lock.withLock {
            guard pausedInputScopeID != scopeID else { return }
            pausedInputScopeID = scopeID
            pausedInputGeneration = 0
            pausedInputUnacknowledged = false
        }
    }
    func pausedInputSnapshot(scopeID: UUID) -> PausedInputSnapshot? {
        lock.withLock {
            guard pausedInputScopeID == scopeID else { return nil }
            return .init(scopeID: scopeID, generation: pausedInputGeneration)
        }
    }
    func hasUnacknowledgedInput(_ snapshot: PausedInputSnapshot) -> Bool {
        lock.withLock {
            pausedInputScopeID == snapshot.scopeID && pausedInputUnacknowledged
        }
    }
    func acknowledgePausedInput(_ snapshot: PausedInputSnapshot) {
        lock.withLock {
            guard pausedInputScopeID == snapshot.scopeID, pausedInputGeneration == snapshot.generation,
                  pausedInputGeneration < UInt64.max else { return }
            pausedInputUnacknowledged = false
        }
    }

    var allowsActions: Bool {
        lock.withLock { value }
    }

    func setAllowsActions(_ allowed: Bool) {
        lock.withLock { value = allowed }
    }

    /// Claims one automation while it waits for a cancelled predecessor to
    /// join. Actions stay closed, but direct input still owns an intervention
    /// race and can invalidate this pending claim synchronously off-main.
    func reservePendingAutomation() -> UUID {
        lock.withLock { reservePendingAutomationLocked() }
    }
    func reservePendingAutomation(after snapshot: PausedInputSnapshot) -> UUID? {
        lock.withLock {
            guard pausedInputScopeID == snapshot.scopeID, pausedInputGeneration == snapshot.generation,
                  !pausedInputUnacknowledged else { return nil }
            return reservePendingAutomationLocked()
        }
    }
    private func reservePendingAutomationLocked() -> UUID {
        let id = UUID()
        pendingInputIntervention = nil
        value = false
        pendingAutomationID = id
        pendingAutomationAdopted = false
        automationActive = false
        approvalPending = false
        return id
    }

    /// Resume reserves before readiness/claim work. Adoption cannot recreate
    /// a reservation invalidated by direct input during that synchronous work.
    func adoptPendingAutomation(_ id: UUID) -> Bool {
        lock.withLock {
            guard pendingAutomationID == id, !pendingAutomationAdopted else { return false }
            pendingAutomationAdopted = true
            return true
        }
    }

    func abandonReservedAutomation(_ id: UUID) {
        lock.withLock {
            guard pendingAutomationID == id, !pendingAutomationAdopted else { return }
            value = false
            pendingAutomationID = nil
        }
    }

    /// Opens the pending claim only if no intervention, stop, or newer state
    /// transition took ownership while the predecessor was unwinding.
    func activatePendingAutomation(_ id: UUID) -> Bool {
        lock.withLock {
            guard pendingAutomationID == id, pendingAutomationAdopted else { return false }
            value = true
            pendingAutomationID = nil
            pendingAutomationAdopted = false
            automationActive = true
            approvalPending = false
            return true
        }
    }

    /// Moves directly from the held approval state into the one approved
    /// operation. A synchronous user-intervention close clears
    /// `approvalPending`, so a delayed approval response cannot reopen the
    /// gate after the person has already taken control.
    func beginApprovedAutomation() -> Bool {
        lock.withLock {
            guard approvalPending else { return false }
            value = true
            pendingAutomationID = nil
            pendingAutomationAdopted = false
            automationActive = true
            approvalPending = false
            return true
        }
    }

    /// Finishing normal work may reopen the idle gate only while this caller
    /// still owns an active automation or approval transition. Intervention
    /// clears both ownership flags synchronously and therefore wins over a
    /// later completion callback.
    @discardableResult
    func endAutomation(allowsActions: Bool) -> Bool {
        lock.withLock {
            let ownsTransition = pendingAutomationID != nil
                || automationActive
                || approvalPending
            if !allowsActions {
                value = false
            } else if ownsTransition {
                value = true
            }
            pendingAutomationID = nil
            pendingAutomationAdopted = false
            automationActive = false
            approvalPending = false
            pendingInputIntervention = nil
            return value
        }
    }

    func beginApprovalWait() -> Bool {
        lock.withLock {
            // A result arriving after synchronous input cannot recreate held
            // approval authority while the input's actor callback is queued.
            guard automationActive, value else { return false }
            value = false
            pendingAutomationID = nil
            pendingAutomationAdopted = false
            automationActive = false
            approvalPending = true
            return true
        }
    }

    /// Record occurrence only. A paused burst schedules no actor callback or
    /// disk write; an arriving control reconciles its newest generation.
    func recordUserInput() -> InputIntervention? {
        lock.withLock {
            if pausedInputScopeID != nil {
                if pausedInputGeneration < UInt64.max { pausedInputGeneration += 1 }
                pausedInputUnacknowledged = true
            }
            guard blockForInterventionLocked() else { return nil }
            let intervention = InputIntervention(id: UUID())
            pendingInputIntervention = intervention
            return intervention
        }
    }

    /// The actor may apply this interruption once, only while the gate still
    /// retains it. Pause, completion, Stop and a new admission retire it.
    func consumeInputIntervention(_ intervention: InputIntervention) -> Bool {
        lock.withLock {
            guard pendingInputIntervention == intervention else { return false }
            pendingInputIntervention = nil
            return true
        }
    }
    func blockForIntervention() -> Bool {
        lock.withLock { blockForInterventionLocked() }
    }
    private func blockForInterventionLocked() -> Bool {
        guard pendingAutomationID != nil || automationActive || approvalPending else { return false }
        value = false
        pendingAutomationID = nil
        pendingAutomationAdopted = false
        automationActive = false
        approvalPending = false
        return true
    }
}

private final class ComputerUsePeerAuthorizationEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.withLock {
            value &+= 1
            return value
        }
    }
}

/// Lock-protected ownership consulted by the WebRTC disconnect callback before
/// it crosses to MainActor. A rejected second peer must never close the active
/// LAN owner's native-action gate.
final class ComputerUseWebRTCAuthorizationFence: @unchecked Sendable {
    private struct Owner: Equatable {
        let senderID: String
        let generation: UInt64
    }

    private let lock = NSLock()
    private var owner: Owner?

    func set(senderID: String, generation: UInt64) {
        lock.withLock {
            owner = Owner(senderID: senderID, generation: generation)
        }
    }

    func clear(senderID: String? = nil, generation: UInt64? = nil) {
        lock.withLock {
            if let senderID, owner?.senderID != senderID { return }
            if let generation, owner?.generation != generation { return }
            owner = nil
        }
    }

    /// Keeps the owner check and its synchronous effect in one transition.
    /// The effect must not re-enter this fence or wait on MainActor.
    func performIfOwned(senderID: String, generation: UInt64, _ effect: () -> Bool) -> Bool {
        lock.withLock {
            guard owner == Owner(senderID: senderID, generation: generation) else { return false }
            return effect()
        }
    }
}

/// Cancellation alone cannot bound an arbitrary transport await: a legacy or
/// test channel may ignore it. This lock-backed one-shot lets teardown race
/// that await against a wall-clock deadline without requiring either racer to
/// re-enter MainActor (or another contended cooperative executor).
private final class ComputerUseTransportDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func finish(completed: Bool) {
        let pending = lock.withLock {
            guard result == nil else {
                return [CheckedContinuation<Bool, Never>]()
            }
            result = completed
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        pending.forEach { $0.resume(returning: completed) }
    }

    func wait() async -> Bool {
        return await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Bool? in
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let completed {
                continuation.resume(returning: completed)
            }
        }
    }
}

@MainActor
enum ComputerUseExecutionResult: Equatable {
    case completed(String)
    /// The executor reached a terminal, evidence-backed explanation that the
    /// requested end state cannot be achieved on this host.
    case unableToComplete(String)
    /// The task cannot proceed until the user supplies missing information.
    /// Unlike live-screen intervention, this terminalizes the stable task ID;
    /// A retained native form issues a scoped reference for the answer task;
    /// other capabilities may use recent conversation as planning context.
    case clarificationRequired(String)
    /// The requested task is still active, but the next step must be performed
    /// by the person (for example, entering account credentials). The manager
    /// preserves the task context and pauses all automation until Resume.
    case userInterventionRequired(String)
    case approvalRequired(
        message: String,
        action: ComputerUsePredictedAction,
        continuation: ComputerUseVisualApprovalContinuation)
    case agentApprovalRequired(AgentApprovalRequest)
}

protocol HostComputerUseChannel: Sendable {
    @discardableResult
    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope

    func poll() async throws -> [ComputerUseEnvelope]
    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws
    func stopPolling() async
}

extension HostComputerUseChannel {
    @discardableResult
    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?
    ) async throws -> ComputerUseEnvelope {
        try await send(
            kind: kind,
            body: body,
            to: explicitTargetID,
            sessionID: explicitSessionID,
            messageID: nil)
    }

    func stopPolling() async {}
}

/// Restricts the private-CloudKit Computer Use record stream to bootstrap
/// setup only. Discovery, signaling, and encrypted LAN credential enrollment
/// use their own CloudKit record types and remain unchanged; prompts, approval
/// decisions, lifecycle controls, and task results must cross the
/// authenticated local broker after enrollment.
actor SetupOnlyHostComputerUseChannel: HostComputerUseChannel {
    static let rejectedSendMessage =
        "CloudKit is available only for AI setup. Task traffic requires the authenticated local connection."

    private let wrapped: any HostComputerUseChannel

    init(wrapping wrapped: any HostComputerUseChannel) {
        self.wrapped = wrapped
    }

    @discardableResult
    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        guard kind == .setupProgress else {
            throw SignalingError.transport(Self.rejectedSendMessage)
        }
        return try await wrapped.send(
            kind: kind,
            body: body,
            to: explicitTargetID,
            sessionID: explicitSessionID,
            messageID: explicitMessageID)
    }

    func poll() async throws -> [ComputerUseEnvelope] {
        let envelopes = try await wrapped.poll()
        let rejected = envelopes.filter { $0.kind != .setupRequest }
        // Delete rejected task records before exposing any setup request from
        // the same batch. If cleanup fails, fail the whole poll closed so the
        // manager cannot accidentally process a partially filtered batch.
        if !rejected.isEmpty {
            try await wrapped.acknowledge(rejected)
        }
        return envelopes.filter { $0.kind == .setupRequest }
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {
        let setupRequests = envelopes.filter { $0.kind == .setupRequest }
        guard !setupRequests.isEmpty else { return }
        try await wrapped.acknowledge(setupRequests)
    }

    func stopPolling() async {
        await wrapped.stopPolling()
    }
}

extension CloudKitComputerUseChannel: HostComputerUseChannel {}

/// Read-only status checks are intentionally separate from installation so
/// constructing the manager or opening the Mac UI can never start a download.
/// The production actor performs signature and receipt validation for status;
/// tests inject an in-memory implementation and never touch the network.
protocol ComputerUseModelProvisioning: Sendable {
    func currentInstallation() async -> ComputerUseInstallationReceipt?
    func interruptedInstallationExists() async -> Bool
    func clearInterruptedInstallationMarker() async
    func recordRuntimeActivationSuccess(
        for receipt: ComputerUseInstallationReceipt
    ) async throws
    func restorePreviousInstallation(
        afterFailedActivationOf receipt: ComputerUseInstallationReceipt
    ) async throws
    func install(
        progress: @MainActor @Sendable @escaping (ComputerUseInstaller.Update) -> Void
    ) async throws -> ComputerUseInstallationReceipt
}

extension ComputerUseInstaller: ComputerUseModelProvisioning {}

@MainActor
protocol ComputerUseExecuting: AnyObject {
    var isReady: Bool { get }
    var runtimeName: String { get }
    var hasAdditionalSetup: Bool { get }
    var supportsNativeTextTasks: Bool { get }
    var readyDetail: String { get }
    func execute(
        prompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult

    /// Runs a task while keeping model conversation context structurally
    /// separate from the current user-authored request. Implementations may
    /// show `prompt` to a planner, but host policy, evidence, and completion
    /// gates must use only `trustedUserPrompt`.
    func execute(
        taskID: String,
        prompt: String,
        trustedUserPrompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult

    /// Structured production entrypoint. Keeping prior turns typed through
    /// the executor boundary prevents assistant prose from being recovered by
    /// parsing a display-oriented labeled prompt and accidentally promoted to
    /// current-user authority.
    func execute(
        taskID: String,
        modelPrompt: String,
        currentUserPrompt: String,
        conversation: [ComputerUseConversationTurn],
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult
}

/// Typed continuation boundary for a visual action that was held for user
/// approval. The manager posts the approved action exactly once, then returns
/// the opaque token to the same executor instead of reconstructing model state
/// from host-authored prose.
@MainActor
protocol ComputerUseVisualApprovalContinuing: AnyObject {
    func performApprovedVisualAction(
        _ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction,
        fingerprint: ComputerUseApprovalFingerprint,
        tools: ComputerUseHostTools,
        willBeginEffect: () -> Void
    ) async throws

    func continueAfterApprovedVisualAction(
        _ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult

    func cancelVisualApprovalContinuation(
        _ continuation: ComputerUseVisualApprovalContinuation)
}

extension ComputerUseVisualApprovalContinuing {
    func performApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction, fingerprint: ComputerUseApprovalFingerprint,
        tools: ComputerUseHostTools, willBeginEffect: () -> Void) async throws {
        try await tools.performApproved(action, fingerprint: fingerprint,
            willBeginEffect: willBeginEffect)
    }
}

extension ComputerUseExecuting {
    var hasAdditionalSetup: Bool { false }
    var supportsNativeTextTasks: Bool { false }
    var readyDetail: String { "AI Computer Use is ready" }

    func execute(
        taskID: String,
        modelPrompt: String,
        currentUserPrompt: String,
        conversation: [ComputerUseConversationTurn],
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        return try await execute(
            taskID: taskID,
            prompt: modelPrompt,
            trustedUserPrompt: currentUserPrompt,
            tools: tools,
            progress: progress)
    }

    func execute(
        taskID: String,
        prompt: String,
        trustedUserPrompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        try await execute(
            // An executor that has not explicitly adopted the separated API
            // gets the narrower user request by default. This is fail-safe:
            // it may lose conversational convenience, but it can never
            // accidentally treat prior assistant prose as host authority.
            prompt: trustedUserPrompt,
            tools: tools,
            progress: progress)
    }
}

typealias ComputerUseNativeTextLoader = @MainActor @Sendable (
    ComputerUseInstallationReceipt, ComputerUseHostTools, @escaping (String) -> Void
) async throws -> ComputerUseCapabilityExecutor

/// Bounded monitor set for one setup generation. iOS refreshes its idempotent
/// setup request while monitoring, so an active recipient renews its lease.
/// Silent clients expire, and a same-sender refresh replaces its abandoned
/// session instead of retaining another fanout destination.
struct ComputerUseSetupRecipientRegistry {
    struct Recipient: Hashable, Sendable {
        let senderID: String
        let sessionID: String
        let requestID: String
        let idempotencyKey: String
    }

    enum Admission: Equatable {
        case accepted
        case invalidIdentifier
        case capacityExceeded
    }

    static let productionMaximumRecipients = 8
    static let productionRetentionInterval: TimeInterval = 5 * 60

    init(
        maximumRecipients: Int = productionMaximumRecipients,
        retentionInterval: TimeInterval = productionRetentionInterval
    ) {
        precondition(maximumRecipients > 0)
        precondition(retentionInterval > 0)
        self.maximumRecipients = maximumRecipients
        self.retentionInterval = retentionInterval
    }

    mutating func admit(
        senderID: String,
        sessionID: String,
        requestID: String,
        idempotencyKey: String,
        replacingGeneration: Bool = false,
        observedAt: Date = Date()
    ) -> Admission {
        pruneExpired(at: observedAt)
        guard ComputerUseSetupIdentifierPolicy.isValidRoute(
                senderID: senderID,
                sessionID: sessionID,
                requestID: requestID),
              ComputerUseSetupIdentifierPolicy.isValidIdempotencyKey(
                idempotencyKey) else {
            return .invalidIdentifier
        }

        let recipient = Recipient(
            senderID: senderID,
            sessionID: sessionID,
            requestID: requestID,
            idempotencyKey: idempotencyKey)
        let key = Key(
            senderID: senderID,
            idempotencyKey: idempotencyKey)
        let entry = Entry(
            recipient: recipient,
            expiresAt: observedAt.addingTimeInterval(retentionInterval))

        if replacingGeneration {
            entries = [key: entry]
            return .accepted
        }
        guard entries[key] != nil || entries.count < maximumRecipients else {
            return .capacityExceeded
        }
        entries[key] = entry
        return .accepted
    }

    mutating func activeRecipients(
        observedAt: Date = Date()
    ) -> [Recipient] {
        pruneExpired(at: observedAt)
        return entries.values.map(\.recipient).sorted {
            if $0.senderID != $1.senderID {
                return $0.senderID < $1.senderID
            }
            if $0.sessionID != $1.sessionID {
                return $0.sessionID < $1.sessionID
            }
            return $0.requestID < $1.requestID
        }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }

    private struct Key: Hashable {
        let senderID: String
        let idempotencyKey: String
    }

    private struct Entry {
        let recipient: Recipient
        let expiresAt: Date
    }

    private mutating func pruneExpired(at observedAt: Date) {
        entries = entries.filter { $0.value.expiresAt > observedAt }
    }

    private let maximumRecipients: Int
    private let retentionInterval: TimeInterval
    private var entries: [Key: Entry] = [:]
}

@MainActor
final class HostComputerUseManager: ObservableObject {
    static let orderedControlsRequiredResponse =
        "AI Computer Use requires an updated iPhone app with ordered task controls. Update Remote Desktop before trying again. No action was taken."
    static let userInterventionGuidance =
        "AI paused because control of the Mac changed. Check the screen, then tap Let AI continue."
    static let connectionEndedResponse =
        "The connection ended before this task finished. It will not resume automatically."
    static let terminalPersistenceFailureResponse =
        "The host could not safely save the final result, so the task was not reported as complete."
    static let activeTaskConflictResponse =
        "Another AI Computer Use task is still active. Finish it or stop it, then send this request again. This request was not run."

    enum ModelState: Equatable {
        case downloadRequired
        case packageFound(fileName: String)
        case installing(detail: String, fraction: Double?)
        case ready(runtimeName: String)
        case error(String)
    }

    enum Activity: Equatable {
        case idle
        case working(String)
        case paused
        case awaitingApproval(String)
    }

    /// Host-owned classification for a signaling sender correlated with the
    /// account-enrolled LAN control owner. The shared LAN credential
    /// authenticates account enrollment, while this host-held sender-ID
    /// correlation prevents a client-provided flag from opting a peer into the
    /// sidecar path.
    enum WebRTCPeerClassification: Equatable, Sendable {
        case primaryRemoteControl
        case localComputerUseSidecar
    }

    @Published private(set) var modelState: ModelState = .downloadRequired
    @Published private(set) var activity: Activity = .idle {
        didSet { refreshLocalTaskControls() }
    }
    private struct TaskControlIdentity: Equatable {
        let taskID: String
        let senderID: String
        let sessionID: String
        var executionToken: UUID?
        let authorizationGeneration: UInt64
        let transportGeneration: UInt64
        let remoteRevision: UInt64?
        let hostControlEpoch: UInt64
        let phase: ComputerUseTaskControls.Phase
        let canResume: Bool

        func sameOwner(as other: Self) -> Bool {
            taskID == other.taskID && senderID == other.senderID && sessionID == other.sessionID
                && authorizationGeneration == other.authorizationGeneration
                && transportGeneration == other.transportGeneration
        }
    }
    private var taskControlIdentity: TaskControlIdentity?
    @Published private(set) var localTaskControls: ComputerUseTaskControls?
    private struct PausedInputOwner: Equatable {
        let taskID: String
        let senderID: String
        let sessionID: String
        init(_ context: ExecutionContext) {
            taskID = context.envelope.id; senderID = context.envelope.senderID; sessionID = context.envelope.sessionID
        }
    }
    private var pausedInputOwner: PausedInputOwner?
    private var pausedInputScopeID: UUID?

    private var executorIsReady: Bool {
        executor?.isReady == true
    }

    var needsAdditionalSetup: Bool {
        executor?.hasAdditionalSetup == true
            || (nativeTextInstaller != nil && executor?.supportsNativeTextTasks != true)
    }

    var capability: ComputerUseCapability {
        if setupTask != nil, case .installing(let detail, _) = modelState {
            // Setup owns the executor/model transition. New tasks are held
            // at admission even if a previously loaded capability still exists.
            return ComputerUseCapability(state: .installing, detail: detail)
        }
        if executorIsReady {
            switch activity {
            case .idle:
                return ComputerUseCapability(state: .ready, detail: executor?.readyDetail ?? "AI Computer Use is ready")
            case .working:
                return ComputerUseCapability(
                    state: .busy,
                    detail: "AI Computer Use is working")
            case .paused:
                return ComputerUseCapability(
                    state: .paused,
                    detail: "AI Computer Use is paused")
            case .awaitingApproval:
                return ComputerUseCapability(
                    state: .paused,
                    detail: "AI Computer Use is waiting for your approval")
            }
        }

        switch modelState {
        case .installing(let detail, _):
            return ComputerUseCapability(state: .installing, detail: detail)
        case .downloadRequired, .packageFound, .error:
            return ComputerUseCapability(
                state: .setupRequired,
                detail: modelStateDetail)
        case .ready:
            guard executorIsReady else {
                return ComputerUseCapability(
                    state: .setupRequired,
                    detail: "Set up AI Computer Use")
            }
            return ComputerUseCapability(state: .ready, detail: executor?.readyDetail ?? "AI Computer Use is ready")
        }
    }

    nonisolated static var modelDirectoryURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Remote Desktop Host", isDirectory: true)
            .appendingPathComponent("Computer Use Model", isDirectory: true)
    }

    private struct SetupProgressDelivery: Sendable {
        let progress: ComputerUseSetupProgress
        let targetID: String
        let sessionID: String
    }

    private struct TextClarificationContinuation {
        let originatingTaskID: String
        let goal: ComputerUseUnresolvedTextGoal
        let selectedChoice: ComputerUseClarificationChoice?
    }

    private struct ExecutionContext {
        let envelope: ComputerUseEnvelope
        let channel: any HostComputerUseChannel
        /// Current user-authored request, retained separately from the model
        /// prompt so assistant conversation can never become host evidence.
        let trustedUserPrompt: String
        /// Typed prior chat supplied by the signed prompt payload. Host-authored
        /// resume/replan prose is deliberately not inserted into these turns.
        let conversation: [ComputerUseConversationTurn]
        let textClarification: TextClarificationContinuation?
        /// False only when a versioned Pause reached the durable ledger before
        /// its Prompt. Resume can then claim and start that Prompt exactly once
        /// instead of treating it as work that needs a continuation replan.
        let hasStarted: Bool

        init(
            envelope: ComputerUseEnvelope,
            channel: any HostComputerUseChannel,
            trustedUserPrompt: String? = nil,
            conversation: [ComputerUseConversationTurn]? = nil,
            textClarification: TextClarificationContinuation? = nil,
            hasStarted: Bool = true
        ) {
            self.envelope = envelope
            self.channel = channel
            self.trustedUserPrompt = trustedUserPrompt
                ?? ComputerUsePromptRequest.decodeCompatibleBody(
                    envelope.body).prompt
            self.conversation = conversation
                ?? ComputerUsePromptRequest.decodeCompatibleBody(
                    envelope.body).conversation
            self.hasStarted = hasStarted
            self.textClarification = textClarification
        }

        func belongs(to control: ComputerUseEnvelope) -> Bool {
            envelope.senderID == control.senderID
                && envelope.sessionID == control.sessionID
        }
    }

    private enum PendingOperation {
        case visual(
            continuation: ComputerUseVisualApprovalContinuation,
            action: ComputerUsePredictedAction,
            fingerprint: ComputerUseApprovalFingerprint)
        case agent(AgentApprovalRequest)
    }

    private enum VisualApprovalContinuationError: Error, LocalizedError {
        case invalidContinuation
        case interruptedAfterApprovedAction

        var errorDescription: String? {
            switch self {
            case .invalidContinuation:
                return "The visual approval no longer matches the active task."
            case .interruptedAfterApprovedAction:
                return "Control changed after the approved action was performed."
            }
        }
    }

    private struct PendingApproval {
        let request: ComputerUseApprovalRequest
        let context: ExecutionContext
        let operation: PendingOperation
    }

    private var executor: (any ComputerUseExecuting)?
    private let generalAgentFactory: ((ComputerUseInstallationReceipt) throws -> ComputerUseCapabilityExecutor)?
    private var agentLifecycleTask: Task<Void, Never>?
    var hasRetainedAgentTask: Bool { generalAgent?.hasRetainedTask == true }
    private var generalAgent: AgentCapabilityAdapter? {
        (executor as? ComputerUseCapabilityExecutor)?.agentAdapter ?? executor as? AgentCapabilityAdapter
    }
#if DEBUG
    func debugPendingAgentApproval(taskID: String, requestID: String) -> AgentLoop.PendingStep? {
        guard case .awaitingApproval = activity,
              let pendingApproval,
              pendingApproval.context.envelope.id == taskID,
              pendingApproval.request.taskID == taskID,
              pendingApproval.request.requestID == requestID,
              case .agent(let request) = pendingApproval.operation,
              let id = UUID(uuidString: requestID), request.id == id else { return nil }
        return generalAgent?.debugPendingApproval(taskID: taskID, requestID: id)
    }
#endif
    private let injector: InputInjector
    private let tools: ComputerUseHostTools
    var nativeVisualTypingDiagnosticForTests: [String: String] {
        tools.nativeVisualTypingDiagnostic
    }
    private let actionGate: ComputerUseActionGate
    private let installer: any ComputerUseModelProvisioning
    private let nativeTextInstaller: (any ComputerUseModelProvisioning)?
    private let nativeTextLoader: ComputerUseNativeTextLoader
    private let nativeTextPreparer: ComputerUseNativeTextLoader
    private let visualExecutorLoader: any ComputerUseVisualExecutorLoading
    private let taskLedger: ComputerUseTaskLedger
    private let textClarifications: ComputerUseTextClarificationStore
    private let transportTeardownTimeout: Duration
    /// False only for app-hosted test sessions. Direct manager constructions
    /// keep the production default so their installer lifecycle tests retain
    /// the behavior they are explicitly exercising.
    let allowsExternalServices: Bool
    private let allowsAutomaticSetup: Bool
    private let experimentalEnabled: @MainActor () -> Bool
    private let peerAuthorizationEpoch = ComputerUsePeerAuthorizationEpoch()
    private let webRTCAuthorizationFence =
        ComputerUseWebRTCAuthorizationFence()
    private let channelFactory: @MainActor (String) -> any HostComputerUseChannel
    private var channel: (any HostComputerUseChannel)?
    private var pollingTask: Task<Void, Never>?
    /// Serializes host-to-phone delivery. In particular, transport teardown
    /// must enqueue the durable typed terminal result before the trailing ready
    /// status and must not stop polling underneath either send.
    private var outboundDeliveryTask: Task<Void, Never>?
    /// Retains the complete transport teardown even for synchronous UI stops.
    /// Application/session shutdown can await this exact barrier before the
    /// LAN listener or peer transport is closed.
    private var transportTeardownTask: Task<Void, Never>?
    /// Invalidates a poll result that arrives after its transport was stopped.
    /// Some channel implementations cannot promptly cancel an in-flight
    /// network request, so Task cancellation alone is not a sufficient fence.
    private var transportGeneration: UInt64 = 0
    private var peerAuthorizationGeneration: UInt64 = 0
    private var executionTask: Task<Void, Never>?
    private var currentExecution: ExecutionContext?
    private var pausedExecution: ExecutionContext?
    /// One host task can be resumably paused at a time. Retaining its exact
    /// bounded instruction lets a duplicate accepted Prompt replay the same
    /// typed handoff instead of replacing useful sign-in guidance with a
    /// generic pause explanation.
    private var lastUserIntervention: (taskID: String, guidance: String, report: ComputerUseResearchProgress?)?
    private var currentExecutionToken: UUID?
    private var pendingApproval: PendingApproval?
    private var activeVisualApprovalContinuation:
        ComputerUseVisualApprovalContinuation?
    /// Non-nil only after the fingerprinted action crossed the host posting
    /// boundary and until its typed continuation returns. A lifecycle pause in
    /// this phase must terminalize: rebuilding the original prompt could post
    /// the already-completed action a second time.
    private var postedApprovedVisualTaskID: String?
    private var approvalDeliveryTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var setupProgressDeliveryTask: Task<Void, Never>?
    private var modelCheckTask: Task<Void, Never>?
    private var setupRecipients = ComputerUseSetupRecipientRegistry()
    private var currentSetupProgress: ComputerUseSetupProgress?
    private var authorizedPeerID: String? {
        didSet { refreshLocalTaskControls() }
    }
    private var authorizedPeerSupportsOrderedComputerUseControls = false {
        didSet { refreshLocalTaskControls() }
    }
    /// Authorization sources are tracked independently so expiry of the LAN
    /// lease cannot revoke an authenticated WebRTC connection (or vice versa).
    /// Both sources may coexist only for the same stable device identity.
    private var localAuthorizedPeerID: String?
    private var webRTCAuthorizedPeerID: String?
    private var webRTCAuthorizedPeerGeneration: UInt64?
    private var webRTCSupportsOrderedComputerUseControls = false
    private var activeWebRTCPeer:
        (senderID: String,
         generation: UInt64,
         classification: WebRTCPeerClassification)?
    private var appliedPeerAuthorizationEpoch: UInt64 = 0
    private var localInputMonitors: [Any] = []
    private var lastInstallerProgressPhase: ComputerUseSetupProgress.Phase?
    private var lastInstallerProgressFraction: Double?
    private var lastInstallerProgressDate = Date.distantPast
    private var isShuttingDown = false

    init(
        experimentalEnabled: @escaping @MainActor () -> Bool = { ComputerUseFeatureFlags.experimental },
        injector: InputInjector,
        executor: (any ComputerUseExecuting)? = nil,
        installer: (any ComputerUseModelProvisioning)? = nil,
        nativeTextInstaller: (any ComputerUseModelProvisioning)? = nil,
        nativeTextLoader: ComputerUseNativeTextLoader? = nil,
        nativeTextPreparer: ComputerUseNativeTextLoader? = nil,
        visualExecutorLoader: (any ComputerUseVisualExecutorLoading)? = nil,
        taskLedger: ComputerUseTaskLedger = ComputerUseTaskLedger(),
        textClarifications: ComputerUseTextClarificationStore? = nil,
        transportTeardownTimeout: Duration = .seconds(5),
        allowsExternalServices: Bool = true,
        allowsAutomaticSetup: Bool = true,
        agentConfiguration: AgentHostFactory.Configuration = .init(),
        approvalTargetProvider:
            ((ComputerUsePredictedAction) throws -> ComputerUseApprovalTargetSnapshot)? = nil,
        actionPerformer: ((ComputerUsePredictedAction) throws -> Void)? = nil,
        approvedActionStepDidPost: (@MainActor () -> Void)? = nil,
        screenProvider: (() throws -> ComputerUseScreenObservation)? = nil,
        nativeTextTarget: (any ComputerUseNativeTextTarget)? = nil,
        nativeTextTargetDiagnosticObserver: (@MainActor (ComputerUseAccessibilityTextTarget.DiagnosticEvent) -> Void)? = nil,
        accessibilityContextProvider:
            ((ComputerUsePredictedAction) -> String)? = nil,
        channelFactory: @escaping @MainActor (String) -> any HostComputerUseChannel = {
            SetupOnlyHostComputerUseChannel(
                wrapping: CloudKitComputerUseChannel(
                    containerIdentifier:
                        HostConfig.cloudKitContainerIdentifier,
                    pairingCode: $0))
        }
    ) {
        let gate = ComputerUseActionGate()
        self.experimentalEnabled = experimentalEnabled
        let mayAct = { [weak gate] in gate?.allowsActions == true }
        self.executor = executor
        self.injector = injector
        self.actionGate = gate
        self.tools = ComputerUseHostTools(
            injector: injector,
            mayAct: mayAct,
            approvalTargetProvider: approvalTargetProvider,
            actionPerformer: actionPerformer,
            nativeTextTarget: nativeTextTarget,
            nativeTextTargetDiagnosticObserver: nativeTextTargetDiagnosticObserver,
            approvedActionStepDidPost: approvedActionStepDidPost,
            screenProvider: screenProvider,
            accessibilityContextProvider: accessibilityContextProvider)
        let modelInstaller = installer ?? ComputerUseInstaller()
        self.installer = modelInstaller
        self.nativeTextInstaller = nativeTextInstaller
        if executor == nil, visualExecutorLoader == nil,
           nativeTextLoader == nil, nativeTextPreparer == nil {
            generalAgentFactory = { receipt in
                try AgentHostFactory.make(receipt: receipt, injector: injector, mayAct: mayAct,
                    configuration: agentConfiguration)
            }
        } else { generalAgentFactory = nil }
        self.nativeTextLoader = nativeTextLoader ?? { receipt, tools, progress in
            try await ComputerUseNativeTextExecutorLoader.load(receipt: receipt, tools: tools, progress: progress)
        }
        self.nativeTextPreparer = nativeTextPreparer ?? nativeTextLoader ?? { receipt, tools, progress in
            try await ComputerUseNativeTextExecutorLoader.prepare(receipt: receipt, tools: tools, progress: progress)
        }
        let modelLoader = visualExecutorLoader ?? OSAtlasVisualExecutorLoader()
        self.visualExecutorLoader = modelLoader
        self.taskLedger = taskLedger
        self.textClarifications = textClarifications ?? ComputerUseTextClarificationStore()
        self.transportTeardownTimeout = transportTeardownTimeout
        self.allowsExternalServices = allowsExternalServices
        self.allowsAutomaticSetup = allowsAutomaticSetup
        self.channelFactory = channelFactory
        if allowsExternalServices {
            refreshModelState()
            installLocalInterventionMonitors()
        }
        refreshLocalTaskControls()
    }

    func refreshModelState() {
        guard allowsExternalServices, !isShuttingDown else { return }
        if executorIsReady, let executor {
            modelState = .ready(runtimeName: executor.runtimeName)
            return
        }
        guard setupTask == nil, modelCheckTask == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { modelCheckTask = nil }
            if let generalAgentFactory {
                if let receipt = await installer.currentInstallation() {
                    guard !Task.isCancelled, !isShuttingDown else { return }
                    do {
                        executor = try generalAgentFactory(receipt)
                        modelState = .ready(runtimeName: executor!.runtimeName)
                    } catch { modelState = .error(error.localizedDescription) }
                } else if allowsAutomaticSetup, await installer.interruptedInstallationExists() {
                    guard !Task.isCancelled, !isShuttingDown else { return }
                    startSetupPipeline()
                } else { modelState = .downloadRequired }
                return
            }
            if let nativeTextInstaller {
                let receipt = await nativeTextInstaller.currentInstallation()
                guard !Task.isCancelled, !isShuttingDown else { return }
                if let receipt {
                    beginNativeTextPreparation(of: receipt)
                    return
                }
                let interrupted = await nativeTextInstaller.interruptedInstallationExists()
                guard !Task.isCancelled, !isShuttingDown else { return }
                if interrupted { startSetupPipeline(); return }
            }
            if let modelReceipt = await installer.currentInstallation() {
                guard !Task.isCancelled, !isShuttingDown else { return }
                modelState = .packageFound(fileName: "Verified model installation")
                beginActivation(of: modelReceipt)
            } else if allowsAutomaticSetup, await installer.interruptedInstallationExists() {
                guard !Task.isCancelled, !isShuttingDown else { return }
                modelState = .installing(detail: "Resuming AI setup…", fraction: nil)
                startSetupPipeline()
            } else {
                modelState = .downloadRequired
            }
        }
        modelCheckTask = task
    }

    func revealModelFolder() {
        try? FileManager.default.createDirectory(
            at: Self.modelDirectoryURL,
            withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Self.modelDirectoryURL])
    }

    func start(
        pairingCode: String,
        additionalChannels: [any HostComputerUseChannel] = [],
        includeDefaultChannel: Bool = true,
        forceMultiplex: Bool = false
    ) {
        guard allowsExternalServices,
              includeDefaultChannel || !additionalChannels.isEmpty else {
            return
        }
        stopTransport()
        actionGate.setAllowsActions(true)
        refreshModelState()
        var channels = additionalChannels
        if includeDefaultChannel {
            channels.append(channelFactory(pairingCode))
        }
        let channel: any HostComputerUseChannel
        if channels.count == 1, let only = channels.first, !forceMultiplex {
            channel = only
        } else {
            channel = MultiplexHostComputerUseChannel(
                channels: channels)
        }
        let generation = transportGeneration
        self.channel = channel
        pollingTask = Task { [weak self] in
            await self?.pollLoop(
                channel: channel,
                generation: generation)
        }
    }

    func addDefaultChannel(pairingCode: String) {
        guard let multiplex = channel as? MultiplexHostComputerUseChannel else {
            return
        }
        let addedChannel = channelFactory(pairingCode)
        Task { await multiplex.add(addedChannel) }
    }

    /// Classifies only from host-held authorization state. Once an
    /// account-enrolled TLS-PSK LAN request claims Computer Use, a signaling
    /// offer carrying that same stable sender ID may add screen/control media as
    /// a sidecar; another claimed sender is rejected before capture starts.
    func classifyWebRTCPeer(
        senderID: String
    ) -> WebRTCPeerClassification? {
        guard !senderID.isEmpty else { return nil }
        if let activeWebRTCPeer {
            return activeWebRTCPeer.senderID == senderID
                ? activeWebRTCPeer.classification
                : nil
        }
        if let localAuthorizedPeerID {
            return localAuthorizedPeerID == senderID
                ? .localComputerUseSidecar
                : nil
        }
        guard authorizedPeerID == nil || authorizedPeerID == senderID else {
            return nil
        }
        return .primaryRemoteControl
    }

    /// Revalidates the classification at the exact capture boundary and binds
    /// callbacks to one host generation. An older peer may finish closing after
    /// its replacement was accepted, but it can no longer close the new peer's
    /// automation gate or authorization.
    @discardableResult
    func activateWebRTCPeer(
        senderID: String,
        generation: UInt64,
        classification: WebRTCPeerClassification
    ) -> Bool {
        guard generation > 0,
              activeWebRTCPeer == nil,
              classifyWebRTCPeer(senderID: senderID) == classification else {
            return false
        }
        activeWebRTCPeer = (
            senderID: senderID,
            generation: generation,
            classification: classification)
        webRTCAuthorizationFence.set(
            senderID: senderID,
            generation: generation)
        return true
    }

    /// Ends only the matching WebRTC generation. A local visual sidecar is not
    /// the task transport: its loss releases native input and creates a
    /// resumable intervention boundary while leaving the TLS channel, task ID,
    /// local authorization, and private routing binding intact.
    @discardableResult
    func endWebRTCPeer(
        senderID: String,
        generation: UInt64,
        classification: WebRTCPeerClassification
    ) -> Bool {
        guard let activeWebRTCPeer,
              activeWebRTCPeer.senderID == senderID,
              activeWebRTCPeer.generation == generation,
              activeWebRTCPeer.classification == classification else {
            return false
        }
        self.activeWebRTCPeer = nil
        webRTCAuthorizationFence.clear(
            senderID: senderID,
            generation: generation)
        if webRTCAuthorizedPeerID == senderID,
           webRTCAuthorizedPeerGeneration == generation {
            webRTCAuthorizedPeerID = nil
            webRTCAuthorizedPeerGeneration = nil
            webRTCSupportsOrderedComputerUseControls = false
        }

        guard classification == .localComputerUseSidecar else {
            return true
        }
        injector.releaseHeldInput()
        guard localAuthorizedPeerID == senderID else {
            revokePeerAuthorization()
            return true
        }
        authorizedPeerID = senderID
        authorizedPeerSupportsOrderedComputerUseControls = true
        _ = blockActionsForUserIntervention()
        switch activity {
        case .working, .awaitingApproval:
            userIntervened()
        case .idle, .paused:
            actionGate.setAllowsActions(false)
        }
        return true
    }

    func authorizePeer(
        senderID: String,
        supportsOrderedComputerUseControls: Bool = true
    ) {
        guard !senderID.isEmpty else { return }
        if authorizedPeerID != senderID {
            invalidateTextClarification()
            peerAuthorizationGeneration &+= 1
        }
        authorizedPeerID = senderID
        authorizedPeerSupportsOrderedComputerUseControls =
            supportsOrderedComputerUseControls

        guard !supportsOrderedComputerUseControls else { return }
        _ = blockActionsForUserIntervention()
        switch activity {
        case .working, .awaitingApproval:
            userIntervened()
        case .idle, .paused:
            actionGate.setAllowsActions(false)
        }
    }

    /// Claims or renews the TLS-PSK LAN authorization without replacing a
    /// different active WebRTC peer. The broker maps `false` to a bounded busy
    /// response before any prompt enters the host queue.
    @discardableResult
    func authorizeLocalPeer(senderID: String) -> Bool {
        guard !senderID.isEmpty,
              authorizedPeerID == nil || authorizedPeerID == senderID else {
            return false
        }
        localAuthorizedPeerID = senderID
        authorizePeer(senderID: senderID)
        return true
    }

    func revokeLocalPeerAuthorization(senderID: String) {
        guard localAuthorizedPeerID == senderID else { return }
        localAuthorizedPeerID = nil
        if webRTCAuthorizedPeerID == senderID {
            authorizedPeerID = senderID
            authorizedPeerSupportsOrderedComputerUseControls =
                webRTCSupportsOrderedComputerUseControls
        } else {
            revokePeerAuthorization()
        }
    }

    func revokePeerAuthorization() {
        invalidateTextClarification()
        peerAuthorizationGeneration &+= 1
        authorizedPeerID = nil
        authorizedPeerSupportsOrderedComputerUseControls = false
        _ = blockActionsForUserIntervention()
        switch activity {
        case .working, .awaitingApproval:
            userIntervened()
        case .idle, .paused:
            actionGate.setAllowsActions(false)
        }
    }

    nonisolated func nextPeerAuthorizationEpoch() -> UInt64 {
        peerAuthorizationEpoch.next()
    }

    func applyPeerAuthorization(
        senderID: String,
        authorized: Bool,
        supportsOrderedComputerUseControls: Bool,
        peerGeneration: UInt64,
        epoch: UInt64
    ) {
        guard let activeWebRTCPeer,
              activeWebRTCPeer.senderID == senderID,
              activeWebRTCPeer.generation == peerGeneration else {
            return
        }
        guard epoch > appliedPeerAuthorizationEpoch else { return }
        appliedPeerAuthorizationEpoch = epoch
        if authorized {
            guard authorizedPeerID == nil || authorizedPeerID == senderID else {
                // Remote control may remain connected, but a second device can
                // never replace the peer that owns the active AI control plane.
                return
            }
            // A disconnect closes the gate synchronously off-main. Even if a
            // newer reconnect callback reaches MainActor first, preserve that
            // intervention as a paused task requiring an explicit Resume.
            if !actionGate.allowsActions {
                switch activity {
                case .working, .awaitingApproval:
                    userIntervened()
                case .idle, .paused:
                    break
                }
            }
            webRTCAuthorizedPeerID = senderID
            webRTCAuthorizedPeerGeneration = peerGeneration
            webRTCSupportsOrderedComputerUseControls =
                supportsOrderedComputerUseControls
            webRTCAuthorizationFence.set(
                senderID: senderID,
                generation: peerGeneration)
            authorizePeer(
                senderID: senderID,
                supportsOrderedComputerUseControls:
                    supportsOrderedComputerUseControls)
        } else {
            guard webRTCAuthorizedPeerID == senderID,
                  webRTCAuthorizedPeerGeneration == peerGeneration else {
                return
            }
            webRTCAuthorizedPeerID = nil
            webRTCAuthorizedPeerGeneration = nil
            webRTCSupportsOrderedComputerUseControls = false
            // Keep the active-generation fence until the peer ends so a
            // repeated disconnect callback still closes the action gate.
            if localAuthorizedPeerID == senderID {
                // The off-main disconnect fence already blocked actions. Keep
                // the same device authenticated on LAN, but surface the control
                // boundary to any live task before it may explicitly resume.
                _ = blockActionsForUserIntervention()
                switch activity {
                case .working, .awaitingApproval:
                    userIntervened()
                case .idle, .paused:
                    break
                }
                authorizedPeerID = senderID
                authorizedPeerSupportsOrderedComputerUseControls = true
            } else {
                revokePeerAuthorization()
            }
        }
    }

    func isPeerAuthorized(senderID: String) -> Bool {
        authorizedPeerID == senderID
    }

    func isPeerAuthorizedForComputerUse(senderID: String) -> Bool {
        authorizedPeerID == senderID
            && authorizedPeerSupportsOrderedComputerUseControls
    }

    @discardableResult
    func stop() -> Task<Void, Never> {
        let teardown = stopTransport()
        actionGate.setAllowsActions(false)
        activity = .idle
        return teardown
    }

    /// Application termination is stronger than disconnecting a remote peer:
    /// every in-flight setup task must finish unwinding and the local visual
    /// runtime must be gone before AppKit is allowed to exit. A plain
    /// `stop()` intentionally keeps the verified model warm for reconnects.
    func shutdown() async {
        isShuttingDown = true

        // Keep strong handles before stopTransport clears the manager slots.
        // Application shutdown is a teardown barrier: a cancelled executor
        // must finish unwinding before the visual runtime can be deactivated,
        // otherwise stale model work could outlive that deactivation boundary.
        let pendingExecution = executionTask
        let pendingSetup = setupTask
        let pendingModelCheck = modelCheckTask
        let pendingTransportTeardown = stopTransport()
        actionGate.setAllowsActions(false)
        activity = .idle
        removeLocalInterventionMonitors()

        pendingExecution?.cancel()
        setupTask?.cancel()
        modelCheckTask?.cancel()
        await pendingExecution?.value
        await agentLifecycleTask?.value
        await pendingSetup?.value
        await pendingModelCheck?.value

        // A status check from an older build/test double may ignore task
        // cancellation and enqueue setup while it is unwinding. Re-read after
        // awaiting it so even that late task is cancelled before deactivation.
        if let lateSetup = setupTask {
            lateSetup.cancel()
            await lateSetup.value
        }

        // `stopTransport()` is intentionally synchronous for the menu-bar UI,
        // but process shutdown is a hard delivery barrier. Do not let AppKit
        // tear down the LAN listener/peer while the typed terminal result,
        // trailing ready status, or channel poll shutdown is still pending.
        await pendingTransportTeardown.value

        await visualExecutorLoader.deactivate()
        executor = nil
    }

    /// Immediate MainActor lifecycle interruption. Off-main physical/direct
    /// input must use its captured receipt through applyUserInputIntervention.
    func userIntervened() {
        switch activity {
        case .working, .awaitingApproval:
            blockActionsForUserIntervention()
            if let context = currentExecution ?? pendingApproval?.context {
                pauseForLocalIntervention(context)
            }
        case .idle, .paused:
            return
        }
    }

    func applyUserInputIntervention(_ intervention: ComputerUseActionGate.InputIntervention) {
        guard actionGate.consumeInputIntervention(intervention) else { return }
        userIntervened()
    }

    nonisolated func recordPhysicalInputForIntervention(_ event: NSEvent) -> ComputerUseActionGate.InputIntervention? {
        guard InputInjector.isPhysicalIntervention(event) else { return nil }
        return recordUserInputForIntervention()
    }

    /// Physical input closes the gate under the injection lock before its
    /// lifecycle update follows on MainActor. Direct phone input instead uses
    /// recordUserInputInInjectionTransaction under its packet transaction. The
    /// callback carries no key, text, pointer coordinate or authentication data.
    @discardableResult
    nonisolated func recordUserInputForIntervention() -> ComputerUseActionGate.InputIntervention? {
        var intervention: ComputerUseActionGate.InputIntervention?
        injector.interruptAutomation { [actionGate] in
            intervention = actionGate.recordUserInput()
            return intervention != nil
        }
        return intervention
    }

    /// Direct phone input uses InputInjector.applyDirectInput, which already
    /// holds the injection lock and owns release/dispatch. Do not reacquire it.
    nonisolated func recordUserInputInInjectionTransaction() -> ComputerUseActionGate.InputIntervention? {
        actionGate.recordUserInput()
    }

    @discardableResult
    nonisolated func blockActionsForUserIntervention() -> Bool {
        injector.interruptAutomation { [actionGate] in
            actionGate.blockForIntervention()
        }
    }

    /// Source-aware disconnect fence used by HostPeerSession. Every
    /// current-peer loss releases direct-input state even when automation was
    /// already paused: a person can press a button (which pauses AI) and lose
    /// the data channel before sending the matching release. The generation
    /// check and cleanup share one ownership transition so replacement cannot
    /// slip between the check and release or action-gate interruption.
    @discardableResult
    nonisolated func blockActionsForWebRTCDeauthorization(
        senderID: String,
        generation: UInt64
    ) -> Bool {
        webRTCAuthorizationFence.performIfOwned(
            senderID: senderID,
            generation: generation) {
            injector.releaseHeldInput()
            return blockActionsForUserIntervention()
        }
    }

    @discardableResult
    private func stopTransport() -> Task<Void, Never> {
        invalidateTextClarification()
        // Fence an in-flight poll before doing anything that can yield. A
        // cancellation-ignoring channel may still return, but its generation
        // can no longer enter `handle` or acknowledge stale envelopes.
        transportGeneration &+= 1

        // Close native injection first, then durably terminalize the one live
        // task while its original envelope and channel are still available.
        // This applies equally to executing, user-paused, and approval-pending
        // work. A reconnect must never silently resume any of those states.
        actionGate.endAutomation(allowsActions: false)
        let invalidatedApproval = pendingApproval
        let terminalContext = currentExecution
            ?? pausedExecution
            ?? invalidatedApproval?.context
        if let terminalContext {
            sendDurableTerminal(
                Self.connectionEndedResponse,
                outcome: .unableToComplete,
                replyingTo: terminalContext.envelope,
                channel: terminalContext.channel)
            sendStatus(
                "ready",
                replyingTo: terminalContext.envelope,
                channel: terminalContext.channel)
        }

        cancelApprovalIfNeeded(invalidatedApproval)
        cancelActiveVisualApprovalContinuation()
        postedApprovedVisualTaskID = nil
        if invalidatedApproval == nil {
            cancelActiveTaskWork()
        }
        pollingTask?.cancel()
        pollingTask = nil
        executionTask?.cancel()
        currentExecution = nil
        pausedExecution = nil
        pendingApproval = nil
        approvalDeliveryTask?.cancel()
        approvalDeliveryTask = nil
        setupProgressDeliveryTask?.cancel()
        setupProgressDeliveryTask = nil
        currentExecutionToken = nil
        let stoppedChannel = channel
        let finalDelivery = outboundDeliveryTask
        outboundDeliveryTask = nil
        let previousTeardown = transportTeardownTask
        let timeout = transportTeardownTimeout
        let teardown = Task {
            // Prior generations already own the same bounded contract. Send
            // the current terminal first so a stale CloudKit generation can
            // never starve a healthy LAN result.
            if let finalDelivery {
                _ = await Self.wait(
                    for: finalDelivery,
                    timeout: timeout)
            }
            if let stoppedChannel {
                let stopPolling = Task {
                    await stoppedChannel.stopPolling()
                }
                _ = await Self.wait(
                    for: stopPolling,
                    timeout: timeout)
            }
            if let previousTeardown {
                _ = await Self.wait(
                    for: previousTeardown,
                    timeout: timeout)
            }
        }
        transportTeardownTask = teardown
        channel = nil
        authorizedPeerID = nil
        authorizedPeerSupportsOrderedComputerUseControls = false
        localAuthorizedPeerID = nil
        webRTCAuthorizedPeerID = nil
        webRTCAuthorizedPeerGeneration = nil
        webRTCSupportsOrderedComputerUseControls = false
        activeWebRTCPeer = nil
        webRTCAuthorizationFence.clear()
        setupRecipients.removeAll()
        return teardown
    }

    /// Returns `true` when `task` completed and `false` when the deadline won.
    /// The timed-out task is canceled as a best-effort cleanup, but this method
    /// itself never waits on cancellation cooperation.
    private nonisolated static func wait(
        for task: Task<Void, Never>,
        timeout: Duration
    ) async -> Bool {
        let deadline = ComputerUseTransportDeadline()
        // This helper is called from HostComputerUseManager's MainActor, but
        // neither side of a wall-clock deadline may inherit that executor.
        // During application termination the main actor can be busy draining
        // lifecycle callbacks, so Dispatch owns the deadline while the
        // completion racer owns only Sendable task/deadline handles.
        let completion = Task.detached(priority: .high) {
            await task.value
            deadline.finish(completed: true)
        }
        let components = timeout.components
        let delay = max(
            0,
            Double(components.seconds)
                + Double(components.attoseconds)
                    / 1_000_000_000_000_000_000)
        let timer = DispatchWorkItem {
            deadline.finish(completed: false)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + delay,
            execute: timer)
        let completed = await deadline.wait()
        if completed {
            timer.cancel()
        } else {
            task.cancel()
            completion.cancel()
        }
        return completed
    }

    private func pollLoop(
        channel: any HostComputerUseChannel,
        generation: UInt64
    ) async {
        while !Task.isCancelled, generation == transportGeneration {
            do {
                let envelopes = try await channel.poll()
                guard !Task.isCancelled,
                      generation == transportGeneration else { return }
                var acknowledged: [ComputerUseEnvelope] = []
                for envelope in envelopes {
                    guard !Task.isCancelled,
                          generation == transportGeneration else { return }
                    if handle(envelope, channel: channel) {
                        acknowledged.append(envelope)
                    }
                }
                guard !Task.isCancelled,
                      generation == transportGeneration else { return }
                try await channel.acknowledge(acknowledged)
            } catch is CancellationError {
                return
            } catch {
                // WebRTC and an in-flight local installation stay usable during
                // a transient CloudKit problem. The short poll retries.
            }

            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    @discardableResult
    func handle(
        _ envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) -> Bool {
        switch envelope.kind {
        case .setupRequest:
            handleSetupRequest(envelope, channel: channel)
            return true
        case .setupProgress:
            return true
        case .approvalRequest:
            return true
        case .approvalResponse:
            guard let authorizedPeerID else { return false }
            guard authorizedPeerID == envelope.senderID else { return true }
            guard authorizedPeerSupportsOrderedComputerUseControls else {
                return true
            }
            handleApprovalResponse(envelope)
            return true
        case .prompt:
            guard let authorizedPeerID else { return false }
            guard authorizedPeerID == envelope.senderID else { return true }
            guard authorizedPeerSupportsOrderedComputerUseControls else {
                send(
                    kind: .assistant,
                    body: "Update Remote Desktop on this iPhone or iPad before using AI Computer Use. Ordinary remote control is still available.",
                    replyingTo: envelope,
                    channel: channel,
                    outcome: .userInterventionRequired)
                sendStatus("ready", replyingTo: envelope, channel: channel)
                return true
            }
            startExecution(for: envelope, channel: channel)
            return true
        case .pause, .resume, .cancel:
            guard let authorizedPeerID else { return false }
            guard authorizedPeerID == envelope.senderID else { return true }
            guard authorizedPeerSupportsOrderedComputerUseControls else {
                return true
            }
            return handleControl(envelope, channel: channel)
        case .status:
            guard let probe = try? ComputerUseClarificationProbe.decodeBody(envelope.body) else { return true }
            guard let authorizedPeerID else { return false }
            guard authorizedPeerID == envelope.senderID, authorizedPeerSupportsOrderedComputerUseControls else { return true }
            sendClarificationProbeResult(probe, replyingTo: envelope, channel: channel)
            return true
        case .assistant:
            return true
        }
    }

    private func refreshLocalTaskControls() {
        // A reconnect of this same retained task keeps unacknowledged input.
        // Leaving paused ownership or replacing the task retires that scope.
        let inputOwner: PausedInputOwner?
        if !isShuttingDown, case .paused = activity, let pausedExecution { inputOwner = .init(pausedExecution) }
        else { inputOwner = nil }
        if inputOwner != pausedInputOwner {
            pausedInputOwner = inputOwner
            pausedInputScopeID = inputOwner == nil ? nil : UUID()
            actionGate.trackPausedInput(scopeID: pausedInputScopeID)
        }
        let context: ExecutionContext?
        let phase: ComputerUseTaskControls.Phase
        switch activity {
        case .working: context = currentExecution; phase = .working
        case .paused: context = pausedExecution; phase = .paused
        case .awaitingApproval: context = pendingApproval?.context; phase = .awaitingApproval
        case .idle: context = nil; phase = .paused
        }
        guard !isShuttingDown, let context else {
            taskControlIdentity = nil
            localTaskControls = nil
            return
        }
        var identity = TaskControlIdentity(taskID: context.envelope.id,
            senderID: context.envelope.senderID, sessionID: context.envelope.sessionID,
            executionToken: currentExecutionToken,
            authorizationGeneration: peerAuthorizationGeneration,
            transportGeneration: transportGeneration,
            remoteRevision: taskLedger.appliedControlRevision(taskID: context.envelope.id),
            hostControlEpoch: taskLedger.hostControlEpoch(taskID: context.envelope.id),
            phase: phase, canResume: phase == .paused
                && isPeerAuthorizedForComputerUse(senderID: context.envelope.senderID)
                && taskLedger.canResumeLocally(taskID: context.envelope.id,
                    senderID: context.envelope.senderID, sessionID: context.envelope.sessionID))
        if identity.executionToken == nil, let previous = taskControlIdentity,
           identity.sameOwner(as: previous) {
            identity.executionToken = previous.executionToken
        }
        guard identity != taskControlIdentity else { return }
        let sameRun = taskControlIdentity.map {
            identity.sameOwner(as: $0) && identity.executionToken == $0.executionToken
        } ?? false
        let snapshot = ComputerUseTaskControls(taskID: identity.taskID,
            scopeID: sameRun ? (localTaskControls?.scopeID ?? UUID()) : UUID(),
            presentationID: UUID(), phase: phase, canResume: identity.canResume,
            ownerID: taskControlIdentity.map { identity.sameOwner(as: $0) } == true
                ? (localTaskControls?.ownerID ?? UUID()) : UUID())
        taskControlIdentity = identity
        localTaskControls = snapshot
    }

    func requestLocalTaskControl(_ action: ComputerUseTaskControls.Action,
                                 displayed: ComputerUseTaskControls) {
        refreshLocalTaskControls()
        guard let current = localTaskControls,
              current.taskID == displayed.taskID, current.scopeID == displayed.scopeID,
              let context = currentExecution ?? pausedExecution ?? pendingApproval?.context,
              context.envelope.id == current.taskID else { return }
        switch action {
        case .takeControl:
            guard current.phase != .paused else { return }
            pauseForLocalIntervention(context)
        case .resume:
            guard displayed == current, current.phase == .paused, current.canResume,
                  isPeerAuthorizedForComputerUse(senderID: context.envelope.senderID) else { return }
            let input = pausedInputSnapshot(for: context)
            guard persistLocalControl(.resume, context: context, acknowledgingInput: input) else {
                pauseExecution(context, guidance: Self.localControlPersistenceFailureGuidance)
                return
            }
            resumeExecution(context, afterInput: input)
        case .stop:
            actionGate.endAutomation(allowsActions: false)
            do {
                let resolution = try taskLedger.cancelLocally(taskID: context.envelope.id,
                    senderID: context.envelope.senderID, sessionID: context.envelope.sessionID)
                guard resolution.disposition != .identityMismatch, resolution.state == .cancelled else {
                    throw ComputerUseTaskLedger.LedgerError.invalidIdentity
                }
                sendDurableTerminal(ComputerUseTaskLedger.stoppedResponse, outcome: .unableToComplete,
                                    replyingTo: context.envelope, channel: context.channel)
            } catch {
                send(kind: .assistant, body: Self.terminalPersistenceFailureResponse,
                     replyingTo: context.envelope, channel: context.channel, outcome: .unableToComplete)
            }
            stopExecution(context)
            sendStatus("ready", replyingTo: context.envelope, channel: context.channel)
        }
    }

    private func handleControl(
        _ envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) -> Bool {
        refreshLocalTaskControls()
        defer { refreshLocalTaskControls() }
        guard let control = ledgerControl(for: envelope.kind) else { return true }

        if envelope.body.isEmpty {
            return handleLegacyControl(
                control,
                envelope: envelope,
                channel: channel)
        }

        guard let request = try? ComputerUseControlRequest.decodeBody(
            envelope.body),
              request.isValid else {
            // A nonempty malformed body is not treated as legacy. That would
            // let a corrupted task ID accidentally control whichever task is
            // currently active.
            return true
        }

        let context = executionContext(
            taskID: request.taskID,
            matching: envelope)

        var inputChanged = false
        var resumeInput: ComputerUseActionGate.PausedInputSnapshot?
        if control != .cancel, let context {
            guard let reconciled = reconcilePausedInputBeforeRemoteControl(context) else { return false }
            inputChanged = reconciled.changed; resumeInput = reconciled.snapshot
        }
        let resolution: ComputerUseTaskLedger.ControlResolution
        let rejectedQuestion = taskLedger.rejectedAnswerReference(taskID: request.taskID)
        do {
            resolution = try taskLedger.applyControl(
                control,
                taskID: request.taskID,
                revision: request.revision,
                senderID: envelope.senderID,
                sessionID: envelope.sessionID,
                observedHostControlEpoch: request.observedHostControlEpoch)
        } catch {
            // Control is fail-closed unless its causal state was durably
            // recorded. Pause and Cancel also stop the live executor before
            // returning the envelope for retry; otherwise a disk failure
            // could be acknowledged while automation kept acting.
            if control == .pause || control == .cancel,
               let context {
                pauseExecution(context)
            }
            return false
        }
        guard resolution.disposition != .identityMismatch else { return true }

        let replyEnvelope = context?.envelope
            ?? controlReplyEnvelope(
                taskID: request.taskID,
                basedOn: envelope)
        let replyChannel = context?.channel ?? channel

        if resolution.state == .cancelled {
            if let rejectedQuestion {
                if taskLedger.terminalClarification(taskID: rejectedQuestion.taskID) == rejectedQuestion {
                    do { _ = try taskLedger.cancelLocally(taskID: rejectedQuestion.taskID,
                        senderID: envelope.senderID, sessionID: envelope.sessionID) }
                    catch { return false }
                }
            }
            textClarifications.invalidate(for: replyEnvelope)
            (executor as? any ComputerUseTextClarificationContinuing)?.invalidateClarification(taskID: request.taskID)
        }

        if let terminalResponse = resolution.terminalResponse {
            if resolution.state == .cancelled, let context {
                stopExecution(context)
            }
            // Pause/Resume received after a task already terminalized are
            // durable revision acknowledgements, not terminal replay requests.
            // Re-emitting here would produce a second terminal update in the
            // same live session. Cancel still owns a terminal reply, while a
            // retried Prompt remains the explicit durable replay path.
            if context != nil || resolution.state == .cancelled {
                send(
                    kind: .assistant,
                    body: terminalResponse,
                    replyingTo: replyEnvelope,
                    channel: replyChannel,
                    outcome: taskLedger.terminalOutcome(taskID: request.taskID))
            }
            sendStatus(
                "ready",
                replyingTo: replyEnvelope,
                channel: replyChannel)
            return true
        }

        switch resolution.state {
        case .paused:
            if let context {
                pauseExecution(context, guidance: inputChanged ? Self.pausedInputChangedGuidance : nil)
            } else {
                // The Prompt may still be in flight. Its stable ID is used for
                // correlation even though no execution context exists yet.
                sendUserInterventionStatus(
                    Self.userInterventionGuidance,
                    replyingTo: replyEnvelope,
                    channel: replyChannel)
            }

        case .running:
            if resolution.disposition == .advanced,
               let context {
                if pendingApproval?.context.envelope.id
                    == context.envelope.id {
                    // A newer Resume revision supersedes the causal state
                    // stamped onto the outstanding approval. Tear down its
                    // delivery loop and held Agent lifecycle work, then replan from
                    // the current screen so only a revision-current approval
                    // can be presented or accepted.
                    pauseExecution(context)
                    resumeExecution(context, controlEnvelope: envelope, afterInput: resumeInput)
                } else if pausedExecution?.envelope.id
                    == context.envelope.id {
                    resumeExecution(context, controlEnvelope: envelope, afterInput: resumeInput)
                } else {
                    sendCurrentStatus(
                        for: context,
                        fallback: "ready",
                        replyingTo: replyEnvelope,
                        channel: replyChannel)
                }
            } else {
                sendCurrentStatus(
                    for: context,
                    fallback: "ready",
                    replyingTo: replyEnvelope,
                    channel: replyChannel)
            }

        case .cancelled:
            // Cancel always creates a terminal response in the ledger.
            assertionFailure("Cancelled control missing terminal response")
        case nil:
            break
        }
        return true
    }

    private func handleLegacyControl(
        _ control: ComputerUseTaskLedger.Control,
        envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) -> Bool {
        // Empty bodies are the compatibility path for shipped clients. With no
        // task ID or revision, they may only touch the one live context owned
        // by the same sender and session. In particular, nil-context Pause is
        // a no-op instead of placing the whole host in a phantom paused state.
        guard let context = legacyExecutionContext(matching: envelope) else {
            return true
        }
        var resumeInput: ComputerUseActionGate.PausedInputSnapshot?
        if control != .cancel {
            guard let reconciled = reconcilePausedInputBeforeRemoteControl(context) else { return false }
            resumeInput = reconciled.snapshot
        }
        // An empty legacy control cannot have observed a local handoff. Stop
        // remains available; Pause/Resume need a versioned, current command.
        if control != .cancel, taskLedger.hostControlEpoch(taskID: context.envelope.id) > 0 {
            sendCurrentStatus(for: context, fallback: "paused", replyingTo: context.envelope, channel: context.channel)
            return true
        }

        switch control {
        case .pause:
            pauseExecution(context)
        case .resume:
            guard pausedExecution?.envelope.id == context.envelope.id else {
                return true
            }
            resumeExecution(context, controlEnvelope: envelope, afterInput: resumeInput)
        case .cancel:
            sendDurableTerminal(
                ComputerUseTaskLedger.stoppedResponse,
                outcome: .unableToComplete,
                replyingTo: context.envelope,
                channel: context.channel)
            stopExecution(context)
            sendStatus(
                "ready",
                replyingTo: context.envelope,
                channel: context.channel)
        }
        return true
    }

    private func ledgerControl(
        for kind: ComputerUseEnvelope.Kind
    ) -> ComputerUseTaskLedger.Control? {
        switch kind {
        case .pause: return .pause
        case .resume: return .resume
        case .cancel: return .cancel
        default: return nil
        }
    }

    private func legacyExecutionContext(
        matching envelope: ComputerUseEnvelope
    ) -> ExecutionContext? {
        let context = currentExecution
            ?? pausedExecution
            ?? pendingApproval?.context
        guard let context, context.belongs(to: envelope) else { return nil }
        return context
    }

    private func executionContext(
        taskID: String,
        matching envelope: ComputerUseEnvelope
    ) -> ExecutionContext? {
        let candidates = [
            currentExecution,
            pausedExecution,
            pendingApproval?.context,
        ]
        return candidates.compactMap { $0 }.first {
            $0.envelope.id == taskID && $0.belongs(to: envelope)
        }
    }

    private static let localControlPersistenceFailureGuidance =
        "AI is paused, but the Mac couldn't safely save this handoff. Keep control of the Mac until its task storage is available."

    private static let pausedInputChangedGuidance =
        "You used the Mac while AI was paused. Choose Resume again when you are ready."

    private static let heldInputGuidance =
        "Finish the current input and release any held keys or mouse buttons, then choose Resume."

    private static func admissionGuidance(_ admission: InputInjector.AutomationAdmission) -> String? {
        switch admission {
        case .inputHeld: return heldInputGuidance
        case .inputStateUnavailable:
            return "I couldn't check keyboard and mouse input. Check Accessibility access for RemoteDesktopHost, then choose Resume."
        case .admitted, .interrupted: return nil
        }
    }

    private func admitAutomation(_ admission: () -> Bool) -> InputInjector.AutomationAdmission {
        if allowsExternalServices, !HostRuntimeContext.isRunningUnitTests {
            if localInputMonitors.count != 2 { installLocalInterventionMonitors() }
            guard localInputMonitors.count == 2 else { return .inputStateUnavailable }
        }
        return injector.admitAutomation(admission)
    }

    private func pausedInputSnapshot(for context: ExecutionContext) -> ComputerUseActionGate.PausedInputSnapshot? {
        guard case .paused = activity, pausedInputOwner == PausedInputOwner(context), let scope = pausedInputScopeID else { return nil }
        return actionGate.pausedInputSnapshot(scopeID: scope)
    }
    private func reconcilePausedInputBeforeRemoteControl(_ context: ExecutionContext)
        -> (snapshot: ComputerUseActionGate.PausedInputSnapshot?, changed: Bool)? {
        guard let input = pausedInputSnapshot(for: context) else { return (nil, false) }
        guard actionGate.hasUnacknowledgedInput(input) else { return (input, false) }
        guard persistLocalControl(.pause, context: context, acknowledgingInput: input) else {
            pauseExecution(context, guidance: Self.localControlPersistenceFailureGuidance)
            return nil
        }
        return (pausedInputSnapshot(for: context), true)
    }

    private func persistLocalControl(_ control: ComputerUseTaskLedger.Control, context: ExecutionContext,
        acknowledgingInput: ComputerUseActionGate.PausedInputSnapshot? = nil) -> Bool {
        let input = acknowledgingInput ?? pausedInputSnapshot(for: context)
        defer { refreshLocalTaskControls() }
        do {
            try taskLedger.applyLocalControl(control, taskID: context.envelope.id,
                senderID: context.envelope.senderID, sessionID: context.envelope.sessionID)
            if let input { actionGate.acknowledgePausedInput(input) }
            return true
        } catch {
            actionGate.endAutomation(allowsActions: false)
            return false
        }
    }

    private func pauseForLocalIntervention(_ context: ExecutionContext, guidance: String? = nil,
                                            report: ComputerUseResearchProgress? = nil) {
        actionGate.endAutomation(allowsActions: false)
        let persisted = persistLocalControl(.pause, context: context)
        pauseExecution(context, guidance: persisted ? guidance : Self.localControlPersistenceFailureGuidance,
            report: persisted ? report : nil)
    }

    private func pauseExecution(_ context: ExecutionContext, guidance: String? = nil,
                                report: ComputerUseResearchProgress? = nil) {
        let guidance = guidance ?? Self.userInterventionGuidance
        if postedApprovedVisualTaskID == context.envelope.id {
            terminalizePostedVisualActionForIntervention(context: context)
            return
        }
        if pausedExecution?.envelope.id == context.envelope.id {
            if guidance == Self.userInterventionGuidance {
                sendStatus("paused", replyingTo: context.envelope, channel: context.channel)
            } else {
                sendUserInterventionStatus(guidance, replyingTo: context.envelope, channel: context.channel, report: report)
            }
            return
        }

        // Close injection before cancellation. Executors are untrusted to
        // observe Task cancellation promptly and may still unwind through a
        // final tool call.
        actionGate.endAutomation(allowsActions: false)
        let invalidatedApproval = pendingApproval
        pausedExecution = context
        currentExecution = nil
        pendingApproval = nil
        cancelApprovalIfNeeded(invalidatedApproval, preservingTaskProgress: true)
        approvalDeliveryTask?.cancel()
        approvalDeliveryTask = nil
        currentExecutionToken = nil
        cancelActiveVisualApprovalContinuation()
        cancelActiveTaskWork(preservingTaskProgress: true)
        if generalAgent == nil { executionTask?.cancel() }
        activity = .paused
        sendUserInterventionStatus(
            guidance,
            replyingTo: context.envelope,
            channel: context.channel,
            report: report)
    }

    private func resumeExecution(
        _ context: ExecutionContext,
        controlEnvelope: ComputerUseEnvelope,
        afterInput: ComputerUseActionGate.PausedInputSnapshot? = nil
    ) {
        guard context.belongs(to: controlEnvelope) else { return }
        resumeExecution(context, afterInput: afterInput)
    }

    private func resumeExecution(_ context: ExecutionContext, afterInput: ComputerUseActionGate.PausedInputSnapshot? = nil) {
        guard case .paused = activity,
              let pausedExecution,
              pausedExecution.envelope.id == context.envelope.id,
              pausedExecution.belongs(to: context.envelope) else {
            sendCurrentStatus(
                for: context,
                fallback: "ready",
                replyingTo: context.envelope,
                channel: context.channel)
            return
        }

        // Own a closed admission before readiness checks or durable prompt
        // claiming. Direct input can revoke it even while activity is idle.
        let pendingAutomationID: UUID
        if let input = afterInput ?? pausedInputSnapshot(for: context) {
            guard let reservation = actionGate.reservePendingAutomation(after: input) else {
                pauseForLocalIntervention(context, guidance: Self.pausedInputChangedGuidance)
                return
            }
            pendingAutomationID = reservation
        } else { pendingAutomationID = actionGate.reservePendingAutomation() }
        defer { actionGate.abandonReservedAutomation(pendingAutomationID) }
        if !pausedExecution.hasStarted {
            // An unstarted prompt owns no live browser handoff. The ordinary
            // claim path may terminalize without adopting this reservation.
            self.pausedExecution = nil
            lastUserIntervention = nil
            activity = .idle
            // This Prompt was durably claimed while a pre-delivered Pause was
            // in force. Re-enter the normal claim path: the ledger atomically
            // marks executionStarted and returns `.new` exactly once.
            startExecution(
                for: pausedExecution.envelope,
                channel: pausedExecution.channel, pendingAutomationID: pendingAutomationID)
            return
        }

        // Preserve the paused owner and its provider window through readiness.
        // Publishing idle here would clear browser controls and close sign-in.
        guard let executor, executor.isReady else {
            self.pausedExecution = pausedExecution
            activity = .paused
            pauseForLocalIntervention(pausedExecution)
            return
        }

        let original = pausedExecution.envelope
        let resumed = ComputerUseEnvelope(
            id: original.id,
            senderID: original.senderID,
            targetID: original.targetID,
            pairingCode: original.pairingCode,
            sessionID: original.sessionID,
            kind: .prompt,
            body: original.body
                + "\n\nContinue from the current screen after the user intervened. Some actions may already be complete; observe carefully and do not repeat them.",
            createdAt: original.createdAt)
        beginExecution(
            executor,
            for: resumed,
            trustedUserPrompt: pausedExecution.trustedUserPrompt,
            conversation: pausedExecution.conversation,
            textClarification: pausedExecution.textClarification,
            channel: pausedExecution.channel,
            isResuming: true, pendingAutomationID: pendingAutomationID)
    }

    private func stopExecution(_ context: ExecutionContext) {
        let activeTaskID = currentExecution?.envelope.id
            ?? pausedExecution?.envelope.id
            ?? pendingApproval?.context.envelope.id
        guard activeTaskID == context.envelope.id else { return }
        textClarifications.invalidate(for: context.envelope)
        (executor as? any ComputerUseTextClarificationContinuing)?.invalidateClarification(taskID: context.envelope.id)
        // Cancel is terminal for this execution. Keep the automation gate
        // closed until a later, separately claimed Prompt explicitly begins;
        // never let cancellation-ignoring work inject during unwind.
        actionGate.endAutomation(allowsActions: false)
        let invalidatedApproval = pendingApproval
        postedApprovedVisualTaskID = nil
        cancelActiveVisualApprovalContinuation()
        cancelActiveTaskWork()
        executionTask?.cancel()
        currentExecution = nil
        pausedExecution = nil
        pendingApproval = nil
        cancelApprovalIfNeeded(invalidatedApproval)
        approvalDeliveryTask?.cancel()
        approvalDeliveryTask = nil
        currentExecutionToken = nil
        activity = .idle
    }

    private func sendCurrentStatus(
        for context: ExecutionContext?,
        fallback: String,
        replyingTo envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) {
        let status: String
        if context != nil {
            switch activity {
            case .working: status = "working"
            case .paused: status = "paused"
            case .awaitingApproval:
                status = "Waiting for your approval before continuing…"
            case .idle: status = fallback
            }
        } else {
            status = fallback
        }
        sendStatus(status, replyingTo: envelope, channel: channel)
    }

    private func controlReplyEnvelope(
        taskID: String,
        basedOn control: ComputerUseEnvelope
    ) -> ComputerUseEnvelope {
        ComputerUseEnvelope(
            id: taskID,
            senderID: control.senderID,
            targetID: control.targetID,
            pairingCode: control.pairingCode,
            sessionID: control.sessionID,
            kind: .prompt,
            body: "",
            createdAt: control.createdAt)
    }

    private func handleApprovalResponse(_ envelope: ComputerUseEnvelope) {
        guard let pendingApproval,
              pendingApproval.context.belongs(to: envelope),
              let response = try? ComputerUseApprovalResponse.decodeBody(envelope.body),
              response.requestID == pendingApproval.request.requestID,
              approvalResponse(response, matches: pendingApproval) else {
            return
        }
        self.pendingApproval = nil
        approvalDeliveryTask?.cancel()
        approvalDeliveryTask = nil

        if case let .agent(request) = pendingApproval.operation {
            guard let agent = generalAgent,
                  agent.ownsApproval(request, hostTaskID: pendingApproval.context.envelope.id) else { return }
            let admission = admitAutomation { actionGate.beginApprovedAutomation() }
            guard admission == .admitted else {
                cancelApprovalIfNeeded(pendingApproval, preservingTaskProgress: true)
                pauseForLocalIntervention(pendingApproval.context, guidance: Self.admissionGuidance(admission))
                return
            }
            continueApprovedAgent(request, approved: response.approved, agent: agent, context: pendingApproval.context)
            return
        }

        guard response.approved,
              let executor,
              executor.isReady else {
            cancelApprovalIfNeeded(pendingApproval)
            actionGate.endAutomation(allowsActions: true)
            activity = .idle
            sendDurableTerminal(
                "Canceled. No action was taken.",
                outcome: .unableToComplete,
                replyingTo: pendingApproval.context.envelope,
                channel: pendingApproval.context.channel)
            sendStatus(
                "ready",
                replyingTo: pendingApproval.context.envelope,
                channel: pendingApproval.context.channel)
            return
        }

        let admission = admitAutomation { actionGate.beginApprovedAutomation() }
        guard admission == .admitted else {
            // Direct input can close the gate synchronously before its
            // MainActor lifecycle callback arrives. That close owns the race:
            // keep the held task resumable and never execute the approval.
            cancelApprovalIfNeeded(pendingApproval, preservingTaskProgress: true)
            pauseForLocalIntervention(pendingApproval.context,
                guidance: Self.admissionGuidance(admission))
            return
        }

        switch pendingApproval.operation {
        case .agent: return
        case .visual(let continuation, let action, let fingerprint):
            continueApprovedVisualAction(
                continuation,
                action: action,
                fingerprint: fingerprint,
                executor: executor,
                context: pendingApproval.context)
        }
    }

    private func pauseAfterApprovedOperationWasBlocked(
        context: ExecutionContext
    ) {
        pauseForLocalIntervention(context)
    }

    private func continueApprovedAgent(_ request: AgentApprovalRequest, approved: Bool,
                                       agent: AgentCapabilityAdapter, context: ExecutionContext) {
        let token = UUID()
        currentExecution = context; currentExecutionToken = token
        activity = .working("Continuing the approved agent task…")
        let lifecycle = agentLifecycleTask
        executionTask = Task { [weak self] in
            guard let self else { return }
            await lifecycle?.value
            guard !Task.isCancelled, currentExecutionToken == token else { return }
            let result = await agent.resumeApproval(request: request, approved: approved)
            guard !Task.isCancelled, currentExecutionToken == token, let executor else { return }
            do { try await acceptExecutionResult(result, executor: executor, context: context, token: token) }
            catch {
                guard currentExecutionToken == token else { return }
                currentExecution = nil; currentExecutionToken = nil; executionTask = nil
                finishApprovedActionFailure(error, context: context)
            }
        }
    }

    private func approvalResponse(
        _ response: ComputerUseApprovalResponse,
        matches approval: PendingApproval
    ) -> Bool {
        let taskID = approval.context.envelope.id
        let expectedRevision = approval.request.appliedControlRevision
        guard approval.request.taskID == taskID,
              (response.hostControlEpoch ?? 0) == (approval.request.hostControlEpoch ?? 0),
              (approval.request.hostControlEpoch ?? 0) == taskLedger.hostControlEpoch(taskID: taskID),
              taskLedger.appliedControlRevision(taskID: taskID)
                == expectedRevision else {
            // A lifecycle control advanced after the card was created. The
            // approved fingerprint and its decision are no longer causal for
            // the current task state.
            return false
        }

        if response.taskID == nil,
           response.appliedControlRevision == nil {
            // Pre-revision clients did not echo task metadata. They remain
            // compatible only while the task itself has never received a
            // versioned lifecycle control.
            return expectedRevision == nil && (approval.request.hostControlEpoch ?? 0) == 0
        }

        return response.taskID == taskID
            && response.appliedControlRevision == expectedRevision
    }

    private func cancelApprovalIfNeeded(_ approval: PendingApproval?, preservingTaskProgress: Bool = false) {
        guard let approval else { return }
        switch approval.operation {
        case .agent:
            cancelActiveTaskWork(preservingTaskProgress: preservingTaskProgress)
        case .visual(let token, _, _):
            cancelVisualApprovalContinuation(token)
        }
    }

    private func cancelVisualApprovalContinuation(
        _ token: ComputerUseVisualApprovalContinuation
    ) {
        guard let continuation =
                executor as? any ComputerUseVisualApprovalContinuing else {
            return
        }
        continuation.cancelVisualApprovalContinuation(token)
    }

    private func cancelActiveVisualApprovalContinuation() {
        guard let token = activeVisualApprovalContinuation else { return }
        activeVisualApprovalContinuation = nil
        cancelVisualApprovalContinuation(token)
    }

    private func terminalizePostedVisualActionForIntervention(
        context: ExecutionContext
    ) {
        actionGate.endAutomation(allowsActions: false)
        cancelActiveVisualApprovalContinuation()
        cancelActiveTaskWork()
        executionTask?.cancel()
        postedApprovedVisualTaskID = nil
        currentExecution = nil
        currentExecutionToken = nil
        executionTask = nil
        pausedExecution = nil
        pendingApproval = nil
        approvalDeliveryTask?.cancel()
        approvalDeliveryTask = nil
        finishApprovedVisualContinuationFailure(
            VisualApprovalContinuationError.interruptedAfterApprovedAction,
            context: context,
            allowsActions: false)
    }

    /// Serialize AgentLoop pause/cancel requests behind prior lifecycle work so
    /// an immediate Resume cannot be overtaken by stale cleanup.
    private func cancelActiveTaskWork(preservingTaskProgress: Bool = false) {
        if let agent = generalAgent {
            if preservingTaskProgress { agent.requestPause() }
            else { agent.requestCancellation() }
            let previous = agentLifecycleTask
            agentLifecycleTask = Task {
                await previous?.value
                if preservingTaskProgress { await agent.pauseAgent() }
                else { await agent.cancelAgent() }
            }
            return
        }
    }

    private func finishApprovedActionFailure(
        _ error: Error,
        context: ExecutionContext
    ) {
        actionGate.endAutomation(allowsActions: true)
        activity = .idle
        let response = "I couldn't confirm the approved action's result. It will not be retried automatically: \(error.localizedDescription)"
        sendDurableTerminal(
            response,
            outcome: .unableToComplete,
            replyingTo: context.envelope,
            channel: context.channel)
        sendStatus("ready", replyingTo: context.envelope, channel: context.channel)
    }

    /// This path begins only after the fingerprinted visual effect was posted.
    /// Never describe it as unperformed or invite an automatic retry: either
    /// statement could duplicate a consequential action whose verification or
    /// remaining plan failed after the effect crossed the host boundary.
    private func finishApprovedVisualContinuationFailure(
        _ error: Error,
        context: ExecutionContext,
        allowsActions: Bool = true
    ) {
        actionGate.endAutomation(allowsActions: allowsActions)
        postedApprovedVisualTaskID = nil
        currentExecution = nil
        currentExecutionToken = nil
        executionTask = nil
        pausedExecution = nil
        activity = .idle
        let detail = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let response = "The approved action was performed once, but I couldn't verify that the rest of the task completed: \(detail) I will not retry the approved action automatically."
        sendDurableTerminal(
            response,
            outcome: .unableToComplete,
            replyingTo: context.envelope,
            channel: context.channel)
        sendStatus("ready", replyingTo: context.envelope, channel: context.channel)
    }

    private func handleSetupRequest(
        _ envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) {
        // Reject unsafe response routes before decoding or reflecting any part
        // of the request. The outer poll loop still acknowledges the record.
        guard ComputerUseSetupIdentifierPolicy.isValidSenderID(
                envelope.senderID),
              ComputerUseSetupIdentifierPolicy.isValidSessionID(
                envelope.sessionID) else {
            return
        }

        let request: ComputerUseSetupRequest
        do {
            request = try ComputerUseSetupRequest.decodeBody(envelope.body)
        } catch {
            sendSetupProgress(
                ComputerUseSetupProgress(
                    requestID: "invalid",
                    phase: .failed,
                    detail: "The setup request was invalid.",
                    errorMessage: "Update the iOS app and try again."),
                replyingTo: envelope,
                channel: channel)
            return
        }

        // Invalid routes are acknowledged by the poll loop but never become a
        // response target. In particular, do not reflect an attacker-sized or
        // display-spoofing identifier into setup progress.
        guard ComputerUseSetupIdentifierPolicy.isValidRoute(
                senderID: envelope.senderID,
                sessionID: envelope.sessionID,
                requestID: request.requestID) else {
            return
        }

        guard request.idempotencyKey == ComputerUseSetupRequest.currentIdempotencyKey else {
            sendSetupProgress(
                ComputerUseSetupProgress(
                    requestID: request.requestID,
                    idempotencyKey: request.idempotencyKey,
                    phase: .failed,
                    detail: "This host needs an update.",
                    errorMessage: "Update Remote Desktop Host, then try again."),
                replyingTo: envelope,
                channel: channel)
            return
        }

        // Setup may replace the coordinator and switch the shared model owner.
        // It cannot discard a running/paused task or an approval continuation.
        guard activity == .idle else {
            sendSetupProgress(ComputerUseSetupProgress(requestID: request.requestID,
                idempotencyKey: request.idempotencyKey, phase: .failed,
                detail: "Finish or stop the current AI task before changing setup.",
                errorMessage: "Finish or stop the current AI task, then retry setup."),
                replyingTo: envelope, channel: channel)
            return
        }

        let replacesFailedGeneration =
            currentSetupProgress?.phase == .failed && setupTask == nil
        let admission = setupRecipients.admit(
            senderID: envelope.senderID,
            sessionID: envelope.sessionID,
            requestID: request.requestID,
            idempotencyKey: request.idempotencyKey,
            replacingGeneration: replacesFailedGeneration)
        // `handle` returns true for every setup request, so both malformed and
        // over-capacity records are acknowledged and deleted without being
        // retained or producing an attacker-amplified progress fanout.
        guard admission == .accepted else { return }

        // A fresh tap after a terminal failure is an explicit retry. Do not
        // replay the old failure before the new pipeline has a chance to start.
        if replacesFailedGeneration {
            currentSetupProgress = nil
            startSetupPipeline()
            return
        }

        if executorIsReady, !needsAdditionalSetup {
            publishSetupProgress(
                phase: .ready,
                fraction: 1,
                detail: executor?.readyDetail ?? "AI Computer Use is ready")
            return
        }
        if let currentSetupProgress, currentSetupProgress.phase != .ready {
            sendSetupProgress(currentSetupProgress, replyingTo: envelope, channel: channel)
        }
        if setupTask == nil { startSetupPipeline() }
    }

    private func startSetupPipeline() {
        guard allowsExternalServices,
              !isShuttingDown,
              setupTask == nil else { return }
        if let generalAgentFactory {
            startGeneralAgentSetup(factory: generalAgentFactory)
            return
        }
        modelCheckTask?.cancel()
        modelCheckTask = nil
        lastInstallerProgressPhase = nil
        lastInstallerProgressFraction = nil
        lastInstallerProgressDate = .distantPast
        publishSetupProgress(phase: .queued, fraction: 0, detail: "Checking this Mac…")
        modelState = .installing(detail: "Checking this Mac…", fraction: 0)
        setupTask = Task { [weak self] in
            guard let self else { return }
            defer { setupTask = nil }
            let previouslyAvailableExecutor = executor
            var activationReceipt: ComputerUseInstallationReceipt?
            var nativeExecutor: ComputerUseCapabilityExecutor?
            do {
                if let nativeTextInstaller {
                    let receipt = try await nativeTextInstaller.install { [weak self] update in
                        self?.consumeInstallerUpdate(update, nativeText: true)
                    }
                    try Task.checkCancellation()
                    nativeExecutor = try await nativeTextLoader(receipt, tools) { [weak self] detail in
                        self?.consumeProvisioningProgress(phase: .installingPackages,
                            candidateFraction: 0.45, detail: detail, minimumPublishDelta: 0.005, forcePublish: false)
                    }
                    try Task.checkCancellation()
                    try await nativeTextInstaller.recordRuntimeActivationSuccess(for: receipt)
                    try Task.checkCancellation()
                    executor = nativeExecutor
                }
                let receipt = try await installer.install { [weak self] update in
                    self?.consumeInstallerUpdate(update)
                }
                activationReceipt = receipt
                try Task.checkCancellation()
                modelState = .installing(detail: "Loading the on-device AI…", fraction: 0.98)
                publishSetupProgress(phase: .installingPackages, fraction: 0.98,
                    detail: "Loading the on-device AI…")
                if nativeExecutor == nil { executor = nil }
                let loaded = try await visualExecutorLoader.load(receipt: receipt) { [weak self] detail in
                    self?.consumeRuntimeActivationUpdate(detail)
                }
                try Task.checkCancellation()
                publishSetupProgress(phase: .installingPackages, fraction: 0.99,
                    detail: "Starting the on-device AI…")
                try await installer.recordRuntimeActivationSuccess(for: receipt)
                try Task.checkCancellation()
                if let nativeExecutor {
                    configureVisualFactory(nativeExecutor, receipt: receipt)
                    executor = nativeExecutor
                } else {
                    executor = loaded
                }
                modelState = .ready(runtimeName: executor?.runtimeName ?? loaded.runtimeName)
                publishSetupProgress(phase: .ready, fraction: 1,
                    detail: executor?.readyDetail ?? "AI Computer Use is ready")
            } catch is CancellationError {
                await visualExecutorLoader.deactivate()
                executor = nativeExecutor ?? previouslyAvailableExecutor
                if let activationReceipt {
                    try? await installer.restorePreviousInstallation(afterFailedActivationOf: activationReceipt)
                }
                modelState = executor.map { .ready(runtimeName: $0.runtimeName) } ?? .downloadRequired
                publishSetupProgress(phase: .failed, fraction: nil, detail: "Setup stopped",
                    errorMessage: executor == nil
                        ? "Setup stopped before AI Computer Use was activated. Tap Retry to continue."
                        : "Available AI tools are ready. Additional setup stopped; tap Retry to finish it.")
            } catch {
                await visualExecutorLoader.deactivate()
                executor = nativeExecutor ?? previouslyAvailableExecutor
                if let activationReceipt {
                    try? await installer.restorePreviousInstallation(afterFailedActivationOf: activationReceipt)
                }
                await installer.clearInterruptedInstallationMarker()
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                modelState = executor.map { .ready(runtimeName: $0.runtimeName) } ?? .error(message)
                publishSetupProgress(phase: .failed, fraction: nil, detail: "Setup needs attention",
                    errorMessage: message)
            }
        }
    }

    private func startGeneralAgentSetup(factory: @escaping (ComputerUseInstallationReceipt) throws -> ComputerUseCapabilityExecutor) {
        modelCheckTask?.cancel(); modelCheckTask = nil
        publishSetupProgress(phase: .queued, fraction: 0, detail: "Checking the local model package…")
        modelState = .installing(detail: "Checking the local model package…", fraction: 0)
        setupTask = Task { [weak self] in
            guard let self else { return }
            defer { setupTask = nil }
            do {
                try Task.checkCancellation()
                let receipt = try await installer.install { [weak self] update in self?.consumeInstallerUpdate(update) }
                try Task.checkCancellation()
                executor = try factory(receipt)
                modelState = .ready(runtimeName: executor!.runtimeName)
                publishSetupProgress(phase: .ready, fraction: 1, detail: executor!.readyDetail)
            } catch is CancellationError {
                modelState = executor.map { .ready(runtimeName: $0.runtimeName) } ?? .downloadRequired
                publishSetupProgress(phase: .failed, fraction: nil, detail: "Setup stopped", errorMessage: "Setup stopped before the local agent was ready.")
            } catch {
                await installer.clearInterruptedInstallationMarker()
                modelState = .error(error.localizedDescription)
                publishSetupProgress(phase: .failed, fraction: nil, detail: "Setup needs attention", errorMessage: error.localizedDescription)
            }
        }
    }

    private func configureVisualFactory(_ native: ComputerUseCapabilityExecutor,
        receipt: ComputerUseInstallationReceipt?) {
        native.setDesktopFactory(includesVisualControl: receipt != nil) { [weak self] _ in
            guard let self else { throw CancellationError() }
            return deferredVisualExecutor(receipt: receipt)
        }
    }

    private func deferredVisualExecutor(receipt: ComputerUseInstallationReceipt?) -> ComputerUseDeferredVisualExecutor {
        guard let receipt else { return ComputerUseDeferredVisualExecutor() }
        return ComputerUseDeferredVisualExecutor(loader: { [visualExecutorLoader, installer] progress in
            do {
                let prepared = try await visualExecutorLoader.prepare(receipt: receipt, progress: progress)
                try Task.checkCancellation()
                if prepared.runtimeWasActivated {
                    try await installer.recordRuntimeActivationSuccess(for: receipt)
                }
                try Task.checkCancellation()
                return prepared.executor
            } catch {
                await visualExecutorLoader.deactivate()
                throw error
            }
        }, abandon: { [visualExecutorLoader] _ in await visualExecutorLoader.deactivate() })
    }

    private func publishRequestedActivationFailure(_ error: Error) {
        guard !setupRecipients.activeRecipients().isEmpty else { return }
        publishSetupProgress(phase: .failed, fraction: nil, detail: "Setup needs attention",
            errorMessage: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private func beginNativeTextPreparation(of receipt: ComputerUseInstallationReceipt) {
        guard allowsExternalServices, !isShuttingDown, setupTask == nil else { return }
        modelState = .installing(detail: "Preparing local form editing…", fraction: nil)
        setupTask = Task { [weak self] in
            guard let self else { return }
            var finishRequestedSetup = false
            defer {
                setupTask = nil
                if finishRequestedSetup, !Task.isCancelled, !isShuttingDown { startSetupPipeline() }
            }
            do {
                let native = try await nativeTextPreparer(receipt, tools) { [weak self] detail in
                    self?.consumeRuntimeActivationUpdate(detail)
                }
                try Task.checkCancellation()
                let visualReceipt = await installer.currentInstallation()
                try Task.checkCancellation()
                configureVisualFactory(native, receipt: visualReceipt)
                if native.hasAdditionalSetup {
                    let interrupted = await installer.interruptedInstallationExists()
                    try Task.checkCancellation()
                    finishRequestedSetup = interrupted || !setupRecipients.activeRecipients().isEmpty
                }
                executor = native
                modelState = .ready(runtimeName: native.runtimeName)
                if !native.hasAdditionalSetup {
                    publishSetupProgress(phase: .ready, fraction: 1, detail: native.readyDetail)
                }
                if finishRequestedSetup, currentSetupProgress?.phase == .ready { currentSetupProgress = nil }
            } catch is CancellationError {
                await visualExecutorLoader.deactivate()
                executor = nil
                modelState = .downloadRequired
                publishRequestedActivationFailure(CancellationError())
            } catch {
                await visualExecutorLoader.deactivate()
                executor = nil
                modelState = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                publishRequestedActivationFailure(error)
            }
        }
    }

    private func beginActivation(of receipt: ComputerUseInstallationReceipt) {
        guard allowsExternalServices, !isShuttingDown, setupTask == nil,
              executor?.isReady != true else { return }
        modelState = .installing(detail: "Loading the on-device AI…", fraction: 0.98)
        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                executor = nil
                let loaded = try await visualExecutorLoader.load(receipt: receipt) { [weak self] detail in
                    self?.consumeRuntimeActivationUpdate(detail)
                }
                try Task.checkCancellation()
                try await installer.recordRuntimeActivationSuccess(for: receipt)
                try Task.checkCancellation()
                executor = loaded
                modelState = .ready(runtimeName: loaded.runtimeName)
                publishSetupProgress(phase: .ready, fraction: 1, detail: "AI Computer Use is ready")
            } catch is CancellationError {
                await visualExecutorLoader.deactivate()
                executor = nil
                try? await installer.restorePreviousInstallation(afterFailedActivationOf: receipt)
                modelState = .downloadRequired
            } catch {
                await visualExecutorLoader.deactivate()
                executor = nil
                try? await installer.restorePreviousInstallation(afterFailedActivationOf: receipt)
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                modelState = .error(message)
            }
            setupTask = nil
        }
    }

    private func consumeInstallerUpdate(_ update: ComputerUseInstaller.Update, nativeText: Bool = false) {
        let base = Self.visibleModelInstallerFraction(update)
        let visibleFraction = base.map { value in
            nativeText ? value * 0.45
                : (nativeTextInstaller == nil ? value : 0.45 + value * 0.5)
        }
        let phase: ComputerUseSetupProgress.Phase
        switch update.phase {
        case .preparing:
            phase = .installingPackages
        case .downloadingModel:
            phase = .downloadingModel
        case .verifying:
            phase = .verifying
        case .ready:
            phase = .installingPackages
        }
        consumeProvisioningProgress(
            phase: phase,
            candidateFraction: visibleFraction,
            detail: update.detail,
            minimumPublishDelta: 0.02,
            forcePublish: update.phase == .ready)
    }

    /// Runtime activation is part of setup too. Forward its changing detail to
    /// CloudKit so the iOS row does not appear frozen after the downloads and
    /// checksum verification have completed.
    private func consumeRuntimeActivationUpdate(_ detail: String) {
        consumeProvisioningProgress(
            phase: .installingPackages,
            candidateFraction: 0.99,
            detail: detail,
            minimumPublishDelta: 0.005,
            forcePublish: false)
    }

    private func consumeProvisioningProgress(
        phase: ComputerUseSetupProgress.Phase,
        candidateFraction: Double?,
        detail: String,
        minimumPublishDelta: Double,
        forcePublish: Bool
    ) {
        let visibleFraction = candidateFraction.map {
            max(lastInstallerProgressFraction ?? 0, min(0.99, max(0, $0)))
        } ?? lastInstallerProgressFraction
        modelState = .installing(
            detail: detail,
            fraction: visibleFraction)
        let now = Date()
        let fractionDelta = abs(
            (visibleFraction ?? lastInstallerProgressFraction ?? 0)
                - (lastInstallerProgressFraction ?? 0))
        let shouldPublish = phase != lastInstallerProgressPhase
            || fractionDelta >= minimumPublishDelta
            || now.timeIntervalSince(lastInstallerProgressDate) >= 2
            || forcePublish
        guard shouldPublish else { return }
        lastInstallerProgressPhase = phase
        lastInstallerProgressFraction = visibleFraction
        lastInstallerProgressDate = now
        publishSetupProgress(
            phase: phase,
            fraction: visibleFraction,
            detail: detail)
    }

    nonisolated static func visibleModelInstallerFraction(
        _ update: ComputerUseInstaller.Update
    ) -> Double? {
        visibleInstallerFraction(update)
    }

    /// The installer owns the first 97% of user-visible setup. Native model
    /// activation then advances through 98-99% before readiness reaches 100%.
    /// This prevents the installer's internal `.ready == 1` event from making
    /// the device-row progress bar jump backward while OS-Atlas starts.
    nonisolated static func visibleInstallerFraction(
        _ update: ComputerUseInstaller.Update
    ) -> Double? {
        guard let fraction = update.fraction, fraction.isFinite else { return nil }
        return min(0.97, max(0, fraction))
    }

    private func publishSetupProgress(
        phase: ComputerUseSetupProgress.Phase,
        fraction: Double?,
        detail: String,
        errorMessage: String? = nil
    ) {
        let recipients = setupRecipients.activeRecipients()
        let template = ComputerUseSetupProgress(
            requestID: recipients.first?.requestID ?? "host",
            phase: phase,
            fractionCompleted: fraction,
            detail: detail,
            errorMessage: errorMessage)
        currentSetupProgress = template
        if phase == .ready || phase == .failed {
            setupRecipients.removeAll()
        }
        guard let channel else { return }
        let deliveries = recipients.map { recipient in
            let progress = ComputerUseSetupProgress(
                requestID: recipient.requestID,
                idempotencyKey: recipient.idempotencyKey,
                phase: phase,
                fractionCompleted: fraction,
                detail: detail,
                errorMessage: errorMessage)
            return SetupProgressDelivery(
                progress: progress,
                targetID: recipient.senderID,
                sessionID: recipient.sessionID)
        }
        enqueueSetupProgress(deliveries, on: channel)
    }

    private func sendSetupProgress(
        _ progress: ComputerUseSetupProgress,
        replyingTo envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel
    ) {
        enqueueSetupProgress([
            SetupProgressDelivery(
                progress: progress,
                targetID: envelope.senderID,
                sessionID: envelope.sessionID),
        ], on: channel)
    }

    /// CloudKit sends are asynchronous. Chaining every setup update prevents
    /// a slower 99% write from arriving after the terminal 100% update and
    /// making the phone's progress bar appear to move backward or stall.
    private func enqueueSetupProgress(
        _ deliveries: [SetupProgressDelivery],
        on channel: any HostComputerUseChannel
    ) {
        guard !deliveries.isEmpty else { return }
        let previous = setupProgressDeliveryTask
        setupProgressDeliveryTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            for delivery in deliveries {
                guard !Task.isCancelled,
                      let body = try? delivery.progress.encodedBody() else {
                    continue
                }
                _ = try? await channel.send(
                    kind: .setupProgress,
                    body: body,
                    to: delivery.targetID,
                    sessionID: delivery.sessionID)
            }
        }
    }

    private func startExecution(
        for envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel,
        pendingAutomationID: UUID? = nil
    ) {
        let activeTaskID = currentExecution?.envelope.id
            ?? pausedExecution?.envelope.id
            ?? pendingApproval?.context.envelope.id
        let hasDifferentActiveTask: Bool
        switch activity {
        case .idle:
            hasDifferentActiveTask = false
        case .working, .paused, .awaitingApproval:
            // A non-idle state without this task's matching context is also
            // treated as a conflict. It is safer to terminalize the new ID
            // than to let a transient invariant failure strand it forever.
            hasDifferentActiveTask = activeTaskID != envelope.id
        }
        do {
            switch try taskLedger.claim(
                taskID: envelope.id,
                senderID: envelope.senderID,
                sessionID: envelope.sessionID,
                promptBody: envelope.body) {
            case .new:
                if hasDifferentActiveTask {
                    sendDurableTerminal(
                        Self.activeTaskConflictResponse,
                        outcome: .userInterventionRequired,
                        replyingTo: envelope,
                        channel: channel)
                    return
                }
                break
            case .paused:
                if hasDifferentActiveTask {
                    sendDurableTerminal(
                        Self.activeTaskConflictResponse,
                        outcome: .userInterventionRequired,
                        replyingTo: envelope,
                        channel: channel)
                    return
                }
                let context = ExecutionContext(
                    envelope: envelope,
                    channel: channel,
                    hasStarted: false)
                pausedExecution = context
                currentExecution = nil
                pendingApproval = nil
                currentExecutionToken = nil
                actionGate.setAllowsActions(false)
                actionGate.endAutomation(allowsActions: false)
                activity = .paused
                sendUserInterventionStatus(
                    Self.userInterventionGuidance,
                    replyingTo: envelope,
                    channel: channel)
                return
            case .completed(let response):
                if taskLedger.isCancelled(taskID: envelope.id),
                   let reference = (try? ComputerUseExecutionPromptDecoder.decode(envelope.body))?.clarification {
                    if taskLedger.terminalClarification(taskID: reference.taskID) == reference {
                        _ = try taskLedger.cancelLocally(taskID: reference.taskID,
                            senderID: envelope.senderID, sessionID: envelope.sessionID)
                    }
                }
                send(
                    kind: .assistant,
                    body: response,
                    replyingTo: envelope,
                    channel: channel,
                    outcome: taskLedger.terminalOutcome(taskID: envelope.id),
                    clarification: taskLedger.terminalClarification(taskID: envelope.id))
                sendStatus("ready", replyingTo: envelope, channel: channel)
                return
            case .accepted:
                let activeID = currentExecution?.envelope.id
                    ?? pausedExecution?.envelope.id
                    ?? pendingApproval?.context.envelope.id
                if activeID == envelope.id {
                    switch activity {
                    case .working:
                        sendStatus(
                            "working",
                            replyingTo: envelope,
                            channel: channel)
                    case .paused:
                        let guidance: String
                        if let lastUserIntervention,
                           lastUserIntervention.taskID == envelope.id {
                            guidance = lastUserIntervention.guidance
                        } else {
                            guidance = Self.userInterventionGuidance
                        }
                        sendUserInterventionStatus(
                            guidance,
                            replyingTo: envelope,
                            channel: channel,
                            report: lastUserIntervention?.taskID == envelope.id ? lastUserIntervention?.report : nil)
                    case .awaitingApproval:
                        sendStatus(
                            "Waiting for your approval before continuing…",
                            replyingTo: envelope,
                            channel: channel)
                    case .idle:
                        sendStatus(
                            "ready",
                            replyingTo: envelope,
                            channel: channel)
                    }
                } else {
                    let response = "That request was received before the host restarted, so it was not run again. Send it as a new request if it is still needed."
                    sendDurableTerminal(response, outcome: .unableToComplete,
                        replyingTo: envelope, channel: channel)
                    sendStatus("ready", replyingTo: envelope, channel: channel)
                }
                return
            case .identityMismatch:
                // A conflicting delivery cannot replace the live request or
                // terminalize its phone state while the original may act.
                return
            case .promptIdentityUnavailable:
                send(kind: .assistant, body: Self.promptIdentityRecoveryResponse,
                    replyingTo: envelope, channel: channel, outcome: .unableToComplete)
                sendStatus("ready", replyingTo: envelope, channel: channel)
                return
            }
        } catch {
            send(
                kind: .assistant,
                body: "The host could not safely record or verify this request. It will not start another attempt. Check the Mac before sending a new request.",
                replyingTo: envelope,
                channel: channel,
                outcome: .unableToComplete)
            return
        }
        let request: ComputerUsePromptRequest
        do {
            request = try ComputerUseExecutionPromptDecoder.decode(envelope.body)
        } catch {
            sendDurableTerminal("I couldn't validate this request or its clarification. Start a new request with the complete instruction.",
                outcome: .unableToComplete, replyingTo: envelope, channel: channel)
            sendStatus("ready", replyingTo: envelope, channel: channel)
            return
        }
        // A newly claimed ordinary request retires the old question even if
        // setup/readiness prevents the new request from executing.
        if request.clarification == nil { invalidateTextClarification() }
        guard setupTask == nil else {
            sendDurableTerminal("AI setup is still running. Wait for setup to finish, then send this as a new request.",
                outcome: .userInterventionRequired, replyingTo: envelope, channel: channel)
            return
        }
        guard let executor, executor.isReady else {
            let response = "AI Computer Use still needs setup. Return to Devices and tap Set up AI."
            sendDurableTerminal(
                response,
                outcome: .userInterventionRequired,
                replyingTo: envelope,
                channel: channel)
            return
        }

        let continuation: TextClarificationContinuation?
        do {
            if let reference = request.clarification {
                guard let continuing = executor as? any ComputerUseTextClarificationContinuing,
                      let pending = try continuing.clarification(taskID: reference.taskID) else {
                    throw ComputerUseTextClarificationStore.Failure.invalidReference
                }
                let originalQuestion = controlReplyEnvelope(taskID: reference.taskID, basedOn: envelope)
                guard textClarifications.retains(reference, native: pending, for: originalQuestion) else {
                    throw ComputerUseTextClarificationStore.Failure.invalidReference
                }
                let resolution = try textClarifications.consumeSelection(reference, answer: request.prompt,
                    choiceID: request.clarificationChoiceID, scope: pending.scope, for: envelope)
                continuation = TextClarificationContinuation(originatingTaskID: reference.taskID,
                    goal: resolution.goal, selectedChoice: resolution.selectedChoice)
            } else {
                continuation = nil
            }
        } catch {
            sendDurableTerminal("I couldn't validate this request or its clarification. Start a new request with the complete instruction.",
                outcome: .unableToComplete, replyingTo: envelope, channel: channel)
            sendStatus("ready", replyingTo: envelope, channel: channel)
            return
        }
        let clarification: String?
        if continuation != nil {
            clarification = nil
        } else if request.prompt.isEmpty {
            clarification = "What would you like me to do on your Mac?"
        } else {
            clarification = nil
        }
        if let clarification {
            // This is a terminal response for this stable task ID. The user's
            // answer is a new prompt carrying this question in recent chat
            // context, which keeps retries at-most-once and multi-turn chat
            // unambiguous across host or app restarts.
            sendDurableTerminal(
                clarification,
                outcome: .userInterventionRequired,
                replyingTo: envelope,
                channel: channel)
            sendStatus("ready", replyingTo: envelope, channel: channel)
            return
        }

        // From here onward the existing pause/approval/replan lifecycle works
        // with plain model input. The original IDs and routing fields remain
        // unchanged, so ledger replay and CloudKit correlation stay intact.
        let executionEnvelope = ComputerUseEnvelope(
            id: envelope.id,
            senderID: envelope.senderID,
            targetID: envelope.targetID,
            pairingCode: envelope.pairingCode,
            sessionID: envelope.sessionID,
            kind: envelope.kind,
            body: request.modelPrompt,
            createdAt: envelope.createdAt)
        beginExecution(
            executor,
            for: executionEnvelope,
            trustedUserPrompt: request.prompt,
            conversation: request.conversation,
            textClarification: continuation,
            channel: channel, pendingAutomationID: pendingAutomationID)
    }

    private func beginExecution(
        _ executor: any ComputerUseExecuting,
        for envelope: ComputerUseEnvelope,
        trustedUserPrompt: String,
        conversation: [ComputerUseConversationTurn],
        textClarification: TextClarificationContinuation? = nil,
        channel: any HostComputerUseChannel,
        isResuming: Bool = false,
        pendingAutomationID: UUID? = nil
    ) {
        let context = ExecutionContext(
            envelope: envelope,
            channel: channel,
            trustedUserPrompt: trustedUserPrompt,
            conversation: conversation,
            textClarification: textClarification)
        let admissionID = pendingAutomationID ?? actionGate.reservePendingAutomation()
        guard actionGate.adoptPendingAutomation(admissionID) else {
            pauseForLocalIntervention(context)
            return
        }
        let precedingExecution = executionTask
        precedingExecution?.cancel()
        // Keep this exact reservation through predecessor joining. An input
        // event may revoke it before or after adoption, and a later run cannot
        // substitute a new reservation for this continuation.
        let token = UUID()
        currentExecution = context
        currentExecutionToken = token
        pausedExecution = nil
        lastUserIntervention = nil
        activity = .working(isResuming ? "Continuing…" : "Starting…")
        sendStatus("working", replyingTo: envelope, channel: channel)
        let capturedContext = context
        executionTask = Task { [weak self] in
            guard let self else { return }
            var context = capturedContext
            // Cancellation is a lifecycle barrier, not merely a signal. The
            // previous executor joins its runtime-cancel child before this
            // separately claimed prompt is allowed to activate/reuse a model.
            await precedingExecution?.value
            guard !Task.isCancelled,
                  currentExecutionToken == token else { return }
            let admission = admitAutomation { self.actionGate.activatePendingAutomation(admissionID) }
            guard admission == .admitted else {
                pauseAfterPendingAutomationWasBlocked(context: context, token: token,
                    guidance: Self.admissionGuidance(admission))
                return
            }
            do {
                let progress: (String) -> Void = { [weak self] value in
                    guard self?.currentExecutionToken == token else { return }
                    self?.activity = .working(value)
                    self?.sendStatus(value, replyingTo: envelope, channel: channel)
                }
                try Task.checkCancellation()
                guard currentExecutionToken == token else { throw CancellationError() }
                let result: ComputerUseExecutionResult
                if let textClarification {
                    guard let continuing = executor as? any ComputerUseTextClarificationContinuing else {
                        throw ComputerUseTextClarificationStore.Failure.invalidReference
                    }
                    result = try await continuing.continueClarification(taskID: envelope.id,
                        originatingTaskID: textClarification.originatingTaskID, goal: textClarification.goal,
                        selectedChoice: textClarification.selectedChoice, progress: progress)
                } else {
                    await agentLifecycleTask?.value
                    try Task.checkCancellation()
                    guard currentExecutionToken == token else { throw CancellationError() }
                    result = try await executor.execute(
                        taskID: envelope.id,
                        modelPrompt: envelope.body,
                        currentUserPrompt: trustedUserPrompt,
                        conversation: conversation,
                        tools: tools,
                        progress: progress)
                }
                guard !Task.isCancelled,
                      currentExecutionToken == token else { return }
                try await acceptExecutionResult(
                    result,
                    executor: executor,
                    context: context,
                    token: token)
            } catch is CancellationError {
                // Lifecycle-driven cancellation clears/replaces the token
                // before this task observes it. A cancellation originating
                // inside a model/runtime must not leave the UI permanently in
                // "working" with an accepted, nonterminal ledger record.
                finishUnexpectedCancellationIfCurrent(
                    context: context,
                    token: token)
                return
            } catch ComputerUseHostTools.ToolError.paused, ComputerUseTextEditError.interrupted {
                // The injection gate can close synchronously on local input or
                // WebRTC disconnect before its MainActor lifecycle callback.
                // Preserve the task for explicit Resume instead of recording
                // a pause as a terminal failure.
                guard currentExecutionToken == token else { return }
                pauseForLocalIntervention(context)
            } catch {
                guard currentExecutionToken == token else { return }
                if currentExecution?.envelope.id == envelope.id {
                    currentExecution = nil
                }
                currentExecutionToken = nil
                actionGate.endAutomation(allowsActions: true)
                activity = .idle
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                let response = "I couldn't complete that task: \(message)"
                sendDurableTerminal(
                    response,
                    outcome: .unableToComplete,
                    replyingTo: envelope,
                    channel: channel)
                sendStatus("ready", replyingTo: envelope, channel: channel)
            }
        }
    }

    private func pauseAfterPendingAutomationWasBlocked(
        context: ExecutionContext,
        token: UUID,
        guidance: String? = nil
    ) {
        guard currentExecutionToken == token else { return }
        pauseForLocalIntervention(context, guidance: guidance)
    }

    private func continueApprovedVisualAction(
        _ continuationToken: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction,
        fingerprint: ComputerUseApprovalFingerprint,
        executor: any ComputerUseExecuting,
        context: ExecutionContext
    ) {
        guard let continuationExecutor =
                executor as? any ComputerUseVisualApprovalContinuing else {
            cancelVisualApprovalContinuation(continuationToken)
            finishApprovedActionFailure(
                VisualApprovalContinuationError.invalidContinuation,
                context: context)
            return
        }

        let precedingExecution = executionTask
        precedingExecution?.cancel()
        let executionToken = UUID()
        activeVisualApprovalContinuation = continuationToken
        currentExecution = context
        currentExecutionToken = executionToken
        activity = .working("Executing the one approved action…")
        sendStatus(
            "Executing the one approved action…",
            replyingTo: context.envelope,
            channel: context.channel)

        executionTask = Task { [weak self] in
            guard let self else { return }
            await precedingExecution?.value
            guard !Task.isCancelled,
                  currentExecutionToken == executionToken else { return }
            guard actionGate.allowsActions else {
                cancelActiveVisualApprovalContinuation()
                pauseAfterApprovedOperationWasBlocked(context: context)
                return
            }

            do {
                try await continuationExecutor.performApprovedVisualAction(continuationToken,
                    action: action, fingerprint: fingerprint, tools: tools,
                    willBeginEffect: { [weak self] in
                        // Browser validation can suspend without posting any
                        // input. Only cross into may-have-occurred tracking
                        // after those checks and immediately before dispatch.
                        self?.postedApprovedVisualTaskID = context.envelope.id
                    })
            } catch ComputerUseHostTools.ToolError.approvalTargetChanged {
                postedApprovedVisualTaskID = nil
                guard currentExecutionToken == executionToken else { return }
                cancelActiveVisualApprovalContinuation()
                replanAfterChangedVisualApprovalTarget(
                    executor: executor,
                    context: context)
                return
            } catch ComputerUseHostTools.ToolError
                    .approvedActionEffectMayHaveOccurred {
                postedApprovedVisualTaskID = nil
                guard currentExecutionToken == executionToken else { return }
                cancelActiveVisualApprovalContinuation()
                currentExecution = nil
                currentExecutionToken = nil
                executionTask = nil
                finishApprovedVisualEffectMayHaveOccurred(context: context)
                return
            } catch ComputerUseHostTools.ToolError.paused {
                postedApprovedVisualTaskID = nil
                guard currentExecutionToken == executionToken else { return }
                cancelActiveVisualApprovalContinuation()
                pauseAfterApprovedOperationWasBlocked(context: context)
                return
            } catch {
                postedApprovedVisualTaskID = nil
                guard currentExecutionToken == executionToken else { return }
                cancelActiveVisualApprovalContinuation()
                currentExecution = nil
                currentExecutionToken = nil
                executionTask = nil
                finishApprovedActionFailure(error, context: context)
                return
            }

            // Consume the exact continuation only after the host action has
            // completed its required verification. Cancellation while checking
            // text is handled as a possibly performed effect above.
            guard currentExecutionToken == executionToken,
                  !Task.isCancelled else { return }
            do {
                let result = try await continuationExecutor
                    .continueAfterApprovedVisualAction(
                        continuationToken,
                        action: action,
                        tools: tools,
                        progress: { [weak self] value in
                            guard self?.currentExecutionToken
                                    == executionToken else { return }
                            self?.activity = .working(value)
                            self?.sendStatus(
                                value,
                                replyingTo: context.envelope,
                                channel: context.channel)
                        })
                guard !Task.isCancelled,
                      currentExecutionToken == executionToken else { return }
                postedApprovedVisualTaskID = nil
                if activeVisualApprovalContinuation == continuationToken {
                    activeVisualApprovalContinuation = nil
                }
                try await acceptExecutionResult(
                    result,
                    executor: executor,
                    context: context,
                    token: executionToken)
            } catch is CancellationError {
                guard currentExecutionToken == executionToken else { return }
                postedApprovedVisualTaskID = nil
                if activeVisualApprovalContinuation == continuationToken {
                    activeVisualApprovalContinuation = nil
                }
                currentExecution = nil
                currentExecutionToken = nil
                executionTask = nil
                finishApprovedVisualContinuationFailure(
                    CancellationError(),
                    context: context)
                return
            } catch {
                guard currentExecutionToken == executionToken else { return }
                postedApprovedVisualTaskID = nil
                if activeVisualApprovalContinuation == continuationToken {
                    activeVisualApprovalContinuation = nil
                }
                currentExecution = nil
                currentExecutionToken = nil
                executionTask = nil
                finishApprovedVisualContinuationFailure(
                    error,
                    context: context)
            }
        }
    }

    /// At least one event crossed the host posting boundary, but an
    /// intervention prevented the approved action from returning normally.
    /// Its visible effect is therefore indeterminate and must never be replayed.
    private func finishApprovedVisualEffectMayHaveOccurred(
        context: ExecutionContext
    ) {
        actionGate.endAutomation(allowsActions: true)
        postedApprovedVisualTaskID = nil
        currentExecution = nil
        currentExecutionToken = nil
        executionTask = nil
        pausedExecution = nil
        activity = .idle
        let response = "The approved action may have been performed once before control changed. I couldn't safely verify the result, so I will not retry the approved action automatically."
        sendDurableTerminal(
            response,
            outcome: .unableToComplete,
            replyingTo: context.envelope,
            channel: context.channel)
        sendStatus(
            "ready",
            replyingTo: context.envelope,
            channel: context.channel)
    }

    private func replanAfterChangedVisualApprovalTarget(
        executor: any ComputerUseExecuting,
        context: ExecutionContext
    ) {
        guard actionGate.endAutomation(allowsActions: true) else {
            pauseAfterApprovedOperationWasBlocked(context: context)
            return
        }
        currentExecution = nil
        currentExecutionToken = nil
        executionTask = nil
        activity = .idle
        let original = context.envelope
        let replanned = ComputerUseEnvelope(
            id: original.id,
            senderID: original.senderID,
            targetID: original.targetID,
            pairingCode: original.pairingCode,
            sessionID: original.sessionID,
            kind: .prompt,
            body: original.body
                + "\n\nThe screen or focused field changed while the user was approving the prior action. Nothing was executed. Observe the current screen again and request a fresh approval for any consequential action.",
            createdAt: original.createdAt)
        sendStatus(
            "The screen changed — checking again before acting…",
            replyingTo: original,
            channel: context.channel)
        beginExecution(
            executor,
            for: replanned,
            trustedUserPrompt: context.trustedUserPrompt,
            conversation: context.conversation,
            textClarification: context.textClarification,
            channel: context.channel,
            isResuming: true)
    }

    private func acceptExecutionResult(
        _ result: ComputerUseExecutionResult,
        executor: any ComputerUseExecuting,
        context: ExecutionContext,
        token: UUID
    ) async throws {
        guard currentExecutionToken == token else { throw CancellationError() }
        let envelope = context.envelope

        switch result {
        case .agentApprovalRequired(let request):
            guard let agent = generalAgent, agent.ownsApproval(request, hostTaskID: envelope.id) else {
                throw AgentLoopError.noMatchingApproval
            }
            let action = String(decoding: try JSONEncoder().encode(request.action), as: UTF8.self)
            let presentation = ComputerUseApprovalRequest(requestID: request.id.uuidString, taskID: envelope.id,
                message: request.reason,
                details: [.init(label: "Action", value: action), .init(label: "Fingerprint", value: request.fingerprint)]
                    + request.reviewFields.map { .init(label: $0.label, value: $0.value) })
            enterApproval(.init(request: presentation, context: context, operation: .agent(request)))
        case .completed(let response):
            sendDurableTerminal(
                response,
                outcome: .taskCompleted,
                replyingTo: envelope,
                channel: context.channel)
            currentExecution = nil
            currentExecutionToken = nil
            executionTask = nil
            actionGate.endAutomation(allowsActions: true)
            activity = .idle
            sendStatus("ready", replyingTo: envelope, channel: context.channel)

        case .unableToComplete(let response):
            sendDurableTerminal(
                response,
                outcome: .unableToComplete,
                replyingTo: envelope,
                channel: context.channel)
            currentExecution = nil
            currentExecutionToken = nil
            executionTask = nil
            actionGate.endAutomation(allowsActions: true)
            activity = .idle
            sendStatus("ready", replyingTo: envelope, channel: context.channel)

        case .clarificationRequired(let response):
            let reference: ComputerUseClarificationReference?
            let choices: [ComputerUseClarificationChoice]?
            if let pending = try (executor as? any ComputerUseTextClarificationContinuing)?.clarification(taskID: envelope.id) {
                let goal = try context.textClarification?.goal
                    ?? ComputerUseUnresolvedTextGoal(userRequest: context.trustedUserPrompt)
                guard pending.taskID == envelope.id, pending.goal == goal,
                      pending.question.utf8.elementsEqual(response.utf8) else {
                    throw ComputerUseTextClarificationStore.Failure.invalidReference
                }
                reference = try textClarifications.issue(goal: goal, question: response, scope: pending.scope,
                    choices: pending.choices, expiresAt: pending.expiresAt, for: envelope)
                choices = pending.choices
            } else {
                guard context.textClarification == nil else { throw ComputerUseTextClarificationStore.Failure.invalidReference }
                reference = nil
                choices = nil
            }
            sendDurableTerminal(
                response,
                outcome: .userInterventionRequired,
                replyingTo: envelope,
                channel: context.channel,
                clarification: reference,
                clarificationChoices: choices)
            currentExecution = nil
            currentExecutionToken = nil
            executionTask = nil
            actionGate.endAutomation(allowsActions: true)
            activity = .idle
            sendStatus("ready", replyingTo: envelope, channel: context.channel)

        case .userInterventionRequired(let message):
            // This is not a terminal assistant response and must not complete
            // the idempotency ledger. Preserve the exact prompt so the user
            // can sign in through the live screen and resume from the changed
            // UI without starting a second task.
            pauseForLocalIntervention(context, guidance: message)

        case .approvalRequired(
            _,
            let proposedAction,
            let continuationToken):
            guard let continuationExecutor =
                    executor as? any ComputerUseVisualApprovalContinuing else {
                throw VisualApprovalContinuationError.invalidContinuation
            }
            guard continuationToken.taskID == envelope.id else {
                continuationExecutor.cancelVisualApprovalContinuation(
                    continuationToken)
                throw VisualApprovalContinuationError.invalidContinuation
            }
            // Build the user-facing description and TOCTOU fingerprint from the
            // exact action and host-observed Accessibility target.
            let prepared: ComputerUsePreparedApproval
            do {
                try Task.checkCancellation()
                guard currentExecutionToken == token else { throw CancellationError() }
                prepared = try tools.prepareApproval(for: proposedAction)
            } catch {
                continuationExecutor.cancelVisualApprovalContinuation(
                    continuationToken)
                throw error
            }
            let request = ComputerUseApprovalRequest(
                taskID: envelope.id,
                message: prepared.message,
                details: nil,
                confirmLabel: nil)
            enterApproval(
                PendingApproval(
                    request: request,
                    context: context,
                    operation: .visual(
                        continuation: continuationToken,
                        action: proposedAction,
                        fingerprint: prepared.fingerprint)))


        }
    }

    private func finishUnexpectedCancellationIfCurrent(
        context: ExecutionContext,
        token: UUID
    ) {
        guard currentExecutionToken == token else { return }
        currentExecution = nil
        currentExecutionToken = nil
        executionTask = nil
        actionGate.endAutomation(allowsActions: true)
        activity = .idle
        let response = "The task stopped before it finished. It will not be retried automatically."
        sendDurableTerminal(
            response,
            outcome: .unableToComplete,
            replyingTo: context.envelope,
            channel: context.channel)
        sendStatus("ready", replyingTo: context.envelope, channel: context.channel)
    }

    private func enterApproval(_ approval: PendingApproval) {
        let request = ComputerUseApprovalRequest(
            requestID: approval.request.requestID,
            taskID: approval.context.envelope.id,
            message: approval.request.message,
            details: approval.request.details,
            confirmLabel: approval.request.confirmLabel,
            appliedControlRevision: taskLedger.appliedControlRevision(
                taskID: approval.context.envelope.id),
            hostControlEpoch: taskLedger.hostControlEpoch(taskID: approval.context.envelope.id))
        let stampedApproval = PendingApproval(
            request: request,
            context: approval.context,
            operation: approval.operation)
        guard actionGate.beginApprovalWait() else {
            cancelApprovalIfNeeded(approval, preservingTaskProgress: true)
            pauseForLocalIntervention(approval.context)
            return
        }
        pendingApproval = stampedApproval
        currentExecution = nil
        currentExecutionToken = nil
        executionTask = nil
        activity = .awaitingApproval(request.message)
        startApprovalDelivery(stampedApproval)
        sendStatus(
            "Waiting for your approval before continuing…",
            replyingTo: stampedApproval.context.envelope,
            channel: stampedApproval.context.channel)
    }

    private func sendStatus(
        _ status: String,
        replyingTo envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel,
        outcome: ComputerUseTerminalOutcome? = nil
    ) {
        send(
            kind: .status,
            body: status,
            replyingTo: envelope,
            channel: channel,
            outcome: outcome)
    }

    /// Every resumable handoff carries both the legacy-safe text prefix and the
    /// host-authoritative typed outcome. The prefix keeps older clients safely
    /// paused; the outcome lets current clients and evaluators distinguish a
    /// person-only step from generic progress without parsing prose.
    private func sendUserInterventionStatus(
        _ guidance: String,
        replyingTo envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel,
        report: ComputerUseResearchProgress? = nil
    ) {
        let signal = ComputerUseStatusSignal.userIntervention(guidance)
        if let boundedGuidance = ComputerUseStatusSignal
            .userInterventionMessage(from: signal) {
            lastUserIntervention = (
                taskID: envelope.id,
                guidance: boundedGuidance,
                report: report)
        }
        send(
            kind: .status,
            body: signal,
            replyingTo: envelope,
            channel: channel,
            outcome: .userInterventionRequired,
            researchProgress: report,
            authorizationDeliveryGeneration: report == nil ? nil :
                (transport: transportGeneration, authorization: peerAuthorizationGeneration))
    }

    /// A terminal reply is authoritative only after its first-result-wins
    /// ledger record reaches durable storage. If that write fails, never emit
    /// the requested result (especially success); report the storage failure
    /// directly and leave the poisoned ledger to reject future retries.
    private func sendDurableTerminal(
        _ response: String,
        outcome: ComputerUseTerminalOutcome,
        replyingTo envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel,
        clarification: ComputerUseClarificationReference? = nil,
        clarificationChoices: [ComputerUseClarificationChoice]? = nil
    ) {
        let identifiesTextQuestion = clarification.map { textClarifications.matches($0) } ?? false
        do {
            let terminal = try taskLedger.complete(
                taskID: envelope.id,
                response: response,
                outcome: outcome,
                clarification: clarification,
                clarificationOwner: identifiesTextQuestion ? .text : nil)
            if terminal.clarification == nil || (clarification != nil && terminal.clarification != clarification) {
                textClarifications.invalidate(for: envelope)
                (executor as? any ComputerUseTextClarificationContinuing)?.invalidateClarification(taskID: envelope.id)
            }
            send(
                kind: .assistant,
                body: terminal.response,
                replyingTo: envelope,
                channel: channel,
                outcome: terminal.outcome,
                clarification: terminal.clarification,
                clarificationChoices: terminal.clarification == clarification
                    && terminal.outcome == .userInterventionRequired ? clarificationChoices : nil)
        } catch {
            textClarifications.invalidate(for: envelope)
            (executor as? any ComputerUseTextClarificationContinuing)?.invalidateClarification(taskID: envelope.id)
            send(
                kind: .assistant,
                body: Self.terminalPersistenceFailureResponse,
                replyingTo: envelope,
                channel: channel,
                outcome: .unableToComplete)
        }
    }

    private func invalidateTextClarification() {
        textClarifications.invalidate()
        (executor as? any ComputerUseTextClarificationContinuing)?.invalidateClarification(taskID: nil)
    }

    private func startApprovalDelivery(_ approval: PendingApproval) {
        approvalDeliveryTask?.cancel()
        approvalDeliveryTask = Task { [weak self] in
            guard let body = try? approval.request.encodedBody() else { return }
            while !Task.isCancelled {
                guard self?.pendingApproval?.request.requestID
                        == approval.request.requestID else { return }
                _ = try? await approval.context.channel.send(
                    kind: .approvalRequest,
                    body: body,
                    to: approval.context.envelope.senderID,
                    sessionID: approval.context.envelope.sessionID,
                    messageID: approval.request.requestID)
                do {
                    try await Task.sleep(for: .seconds(8))
                } catch {
                    return
                }
            }
        }
    }

    static let promptIdentityRecoveryResponse = "The Mac has an older record for this request but cannot verify its original instruction. It will not run it again or use the old result as confirmation. Check the Mac before starting a new request."

    private func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        replyingTo envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel,
        outcome: ComputerUseTerminalOutcome? = nil,
        clarification: ComputerUseClarificationReference? = nil,
        clarificationChoices requestedClarificationChoices: [ComputerUseClarificationChoice]? = nil,
        researchProgress: ComputerUseResearchProgress? = nil,
        authorizationDeliveryGeneration: (transport: UInt64, authorization: UInt64)? = nil
    ) {
        // Gate every projection of an older unbound result, including Cancel
        // replies with no prompt body. Preserve the durable result for future
        // reconciliation; do not attach its clarification.
        let needsIdentityRecovery = taskLedger.requiresPromptIdentityRecovery(taskID: envelope.id)
        let liveQuestion = clarification.map { reference in
            !needsIdentityRecovery
                && taskLedger.terminalClarification(taskID: envelope.id) == reference
                && retainsNativeQuestion(reference, for: envelope)
        } ?? false
        let liveTextQuestion = clarification.map { reference in
            liveQuestion && taskLedger.clarificationOwner(taskID: envelope.id) != .browser
        } ?? false
        let availableClarificationChoices: [ComputerUseClarificationChoice]? = clarification.flatMap { reference in
            guard liveTextQuestion else { return nil }
            let originalQuestion = controlReplyEnvelope(taskID: reference.taskID, basedOn: envelope)
            return textClarifications.retainedChoices(for: reference, request: originalQuestion)
        }
        let canPublishClarificationChoices = requestedClarificationChoices == nil
            || requestedClarificationChoices == availableClarificationChoices
        let clarificationChoices = canPublishClarificationChoices ? availableClarificationChoices : nil
        let unavailableQuestion = clarification != nil && (!liveQuestion || !canPublishClarificationChoices)
        let responseBody = needsIdentityRecovery && kind == .assistant ? Self.promptIdentityRecoveryResponse
            : unavailableQuestion ? "The original question is no longer active. Start a new request with the complete instruction." : body
        let wireBody: String
        switch kind {
        case .assistant, .status:
            wireBody = (try? ComputerUseTaskUpdate(
                taskID: envelope.id,
                text: responseBody,
                appliedControlRevision: taskLedger.appliedControlRevision(taskID: envelope.id),
                hostControlEpoch: taskLedger.hostControlEpoch(taskID: envelope.id),
                outcome: (needsIdentityRecovery && kind == .assistant) || unavailableQuestion ? .unableToComplete : outcome,
                clarification: needsIdentityRecovery || unavailableQuestion ? nil : clarification,
                clarificationAnswerPolicy: nil,
                clarificationRetry: nil,
                clarificationChoices: needsIdentityRecovery || unavailableQuestion ? nil : clarificationChoices,
                supportsClarificationRecovery: !needsIdentityRecovery && !unavailableQuestion && clarification != nil,
                researchProgress: needsIdentityRecovery ? nil : researchProgress).encodedBody()) ?? responseBody
        default:
            wireBody = body
        }
        let previousDelivery = outboundDeliveryTask
        let guardedGeneration = clarification != nil
            ? (transport: transportGeneration, authorization: peerAuthorizationGeneration) : authorizationDeliveryGeneration
        let delivery = Task { [weak self] in
            if let previousDelivery { await previousDelivery.value }
            if let guardedGeneration {
                guard let self, self.transportGeneration == guardedGeneration.transport,
                      self.peerAuthorizationGeneration == guardedGeneration.authorization,
                      self.authorizedPeerID == envelope.senderID else { return }
            }
            var deliveredBody = wireBody
            if clarification != nil && !unavailableQuestion {
                guard let self, let freshBody = self.revalidateClarificationDelivery(wireBody, replyingTo: envelope,
                    question: clarification) else { return }
                deliveredBody = freshBody
            }
            _ = try? await channel.send(
                kind: kind,
                body: deliveredBody,
                to: envelope.senderID,
                sessionID: envelope.sessionID,
                messageID: nil)
        }
        outboundDeliveryTask = delivery
    }

    /// Recheck after preceding deliveries finish, immediately before handing
    /// this reply to the channel. A historical question is not a live owner.
    private func revalidateClarificationDelivery(_ body: String, replyingTo envelope: ComputerUseEnvelope,
                                                question: ComputerUseClarificationReference?) -> String? {
        guard let original = try? ComputerUseTaskUpdate.decodeBody(body), original.taskID == envelope.id,
              original.clarification == question else { return nil }
        let liveQuestion = question.map {
            taskLedger.terminalClarification(taskID: envelope.id) == $0
                && retainsNativeQuestion($0, for: envelope)
        } ?? true
        let liveChoices: [ComputerUseClarificationChoice]? = question.flatMap { reference in
            guard liveQuestion else { return nil }
            let originalRequest = controlReplyEnvelope(taskID: reference.taskID, basedOn: envelope)
            return textClarifications.retainedChoices(for: reference, request: originalRequest)
        }
        guard !liveQuestion else {
            guard original.clarificationChoices == liveChoices else { return nil }
            return body
        }
        return try? ComputerUseTaskUpdate(taskID: original.taskID,
            text: "The original question is no longer active. Start a new request with the complete instruction.",
            appliedControlRevision: original.appliedControlRevision, hostControlEpoch: original.hostControlEpoch,
            outcome: .unableToComplete).encodedBody()
    }

    private func retainsNativeQuestion(_ reference: ComputerUseClarificationReference, for envelope: ComputerUseEnvelope) -> Bool {
        guard taskLedger.clarificationOwner(taskID: envelope.id) != .browser,
              textClarifications.matches(reference),
              let native = try? (executor as? any ComputerUseTextClarificationContinuing)?.clarification(taskID: envelope.id) else { return false }
        return textClarifications.retains(reference, native: native, for: envelope)
    }

    private func sendClarificationProbeResult(_ probe: ComputerUseClarificationProbe, replyingTo envelope: ComputerUseEnvelope,
                                              channel: any HostComputerUseChannel) {
        let previousDelivery = outboundDeliveryTask
        let generation = (transport: transportGeneration, authorization: peerAuthorizationGeneration)
        let delivery = Task { [weak self] in
            if let previousDelivery { await previousDelivery.value }
            guard let self, self.transportGeneration == generation.transport,
                  self.peerAuthorizationGeneration == generation.authorization,
                  self.authorizedPeerID == envelope.senderID else { return }
            // This is a read-only lookup. Never claim a new prompt, change
            // controls, interpret a goal or reconstruct a missing owner.
            let original = self.controlReplyEnvelope(taskID: probe.reference.taskID, basedOn: envelope)
            let available = !self.taskLedger.requiresPromptIdentityRecovery(taskID: probe.reference.taskID)
                && self.taskLedger.terminalClarification(taskID: probe.reference.taskID) == probe.reference
                && self.retainsNativeQuestion(probe.reference, for: original)
            let choices = available ? self.textClarifications.retainedChoices(for: probe.reference, request: original) : nil
            guard let result = try? ComputerUseClarificationProbeResult(probeID: probe.probeID, reference: probe.reference,
                question: available ? self.taskLedger.terminalClarificationText(taskID: probe.reference.taskID) : nil,
                answerPolicy: nil,
                clarificationChoices: choices),
                let body = try? result.encodedBody() else { return }
            _ = try? await channel.send(kind: .status, body: body, to: envelope.senderID, sessionID: envelope.sessionID, messageID: nil)
        }
        outboundDeliveryTask = delivery
    }

    private var modelStateDetail: String {
        switch modelState {
        case .downloadRequired:
            return "Set up AI Computer Use"
        case .packageFound:
            return "Loading the installed AI model"
        case .installing(let detail, _):
            return detail
        case .ready:
            return "AI Computer Use is ready"
        case .error(let message):
            return message
        }
    }

    private func removeLocalInterventionMonitors() {
        for monitor in localInputMonitors { NSEvent.removeMonitor(monitor) }
        localInputMonitors.removeAll()
    }

    private func installLocalInterventionMonitors() {
        guard !HostRuntimeContext.isRunningUnitTests else {
            return
        }
        guard !isShuttingDown, localInputMonitors.count != 2 else { return }
        removeLocalInterventionMonitors()
        let mask = InputInjector.physicalInterventionEventMask
        let interrupt: @Sendable (NSEvent) -> Void = { [weak self] event in
            guard let intervention = self?.recordPhysicalInputForIntervention(event) else { return }
            Task { @MainActor [weak self] in self?.applyUserInputIntervention(intervention) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: mask,
            handler: interrupt) {
            localInputMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: mask,
            handler: { event in
                interrupt(event)
                return event
            }) {
            localInputMonitors.append(local)
        }
    }
}
