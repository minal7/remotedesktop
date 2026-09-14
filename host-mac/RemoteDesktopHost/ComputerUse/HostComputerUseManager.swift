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
            canonicalName: "Calculator",
            aliases: ["Calculator"],
            bundleIdentifiers: ["com.apple.calculator"]),
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

struct ComputerUseApprovalFingerprint: Equatable {
    let action: ComputerUsePredictedAction
    let applicationID: String
    let accessibilityIdentity: String
    let visualDigest: String?
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

struct ComputerUseCalculatorSnapshot: Equatable {
    let inputValue: String?
    let expressionValue: String?
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

    func hasSameDocumentTarget(as other: Self) -> Bool {
        application == other.application && window == other.window
            && CFEqual(focusedElement, other.focusedElement)
            && documentIdentity == other.documentIdentity && frame == other.frame && role == other.role
            && text.isEditable == other.text.isEditable && text.isSecure == other.text.isSecure
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Text-edit bindings deliberately retire on scope notifications. A
        // read does not inherit mutation authority from that transient UUID.
        // Retain/compare the actual AX reference and exact current document.
        lhs.application == rhs.application && lhs.window == rhs.window
            && CFEqual(lhs.focusedElement, rhs.focusedElement)
            && lhs.documentIdentity == rhs.documentIdentity
            && lhs.frame == rhs.frame && lhs.role == rhs.role
            && lhs.text.value.utf8.elementsEqual(rhs.text.value.utf8)
            && lhs.text.selection == rhs.text.selection
            && lhs.text.isEditable == rhs.text.isEditable && lhs.text.isSecure == rhs.text.isSecure
    }

    var isReadable: Bool {
        application.identityIsAuthoritative
            && application.identity?.processIdentifier == window.applicationProcessIdentifier
            && role == "AXTextArea" && text.isEditable && !text.isSecure
            && !text.targetID.isEmpty
            && frame.width > 0 && frame.height > 0
            && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && window.bounds.intersects(frame)
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

    private func matchesStableSignedFocusedAuthority(
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
        case applicationUnavailable
        case approvalTargetUnavailable
        case approvalTargetChanged
        case approvedActionEffectMayHaveOccurred

        var errorDescription: String? {
            switch self {
            case .paused: return "AI Computer Use is paused."
            case .screenshotUnavailable: return "The Mac screen could not be captured."
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
    private let textEditorOverride: ComputerUseTextEditor?
    private var browserNavigationTask: ComputerUseBrowserNavigationTask?
    private var browserToolProposals: (id: UUID, taskID: String, propose: ComputerUseFaraBrowserExecutor.ProposeUsingTools)?
    private var browserResearchAdmissionObserver: (@MainActor (ComputerUseBrowserResearchTask) throws -> Void)?
    private var browserTaskControls: ComputerUseBrowserTaskControls?
    private var browserTaskControlHandler: ((ComputerUseBrowserTaskControls, ComputerUseBrowserTaskControls.Action) -> Void)?
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
    private let calculatorSnapshotProvider: (() -> ComputerUseCalculatorSnapshot?)?
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
        browserNavigationTask: ComputerUseBrowserNavigationTask? = nil,
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
        calculatorSnapshotProvider: (() -> ComputerUseCalculatorSnapshot?)? = nil,
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
        self.textTarget = nativeTextTarget ?? ComputerUseAccessibilityTextTarget()
        self.browserNavigationTask = browserNavigationTask
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
        self.calculatorSnapshotProvider = calculatorSnapshotProvider
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
            journalDirectory: journalDirectory, planner: planner,
            browserTargetProvider: { [weak self] taskID in
                try await self?.browserNavigationTask?.textTargetIfFrontmost(taskID: taskID)
            })
    }

    func shouldRouteToOwnedBrowserAgent() throws -> Bool {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        return browserNavigationTask?.hasFrontmostOwnedWindow == true
    }

    func executeOwnedBrowserTaskIfSupported(taskID: String, prompt: String,
        progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult? {
        let workflow = try ComputerUseBrowserWorkflowRequest.compile(prompt)
        guard workflow != nil || ComputerUseBrowserNavigationRequest.urls(in: prompt) != nil else { return nil }
        if browserNavigationTask == nil {
            // App-hosted tests opt into an isolated loopback fixture explicitly;
            // unrelated routing tests must not open websites on the user's Mac.
            guard !HostRuntimeContext.isRunningUnitTests else { return nil }
            browserNavigationTask = ComputerUseBrowserNavigationTask(
                browser: ComputerUseOwnedBrowser(mayAct: mayAct),
                journalDirectory: ComputerUseBrowserNavigationTask.journalDirectory)
            publishOwnedBrowserTaskControls()
        }
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        if let workflow {
            guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
            return try await browserNavigationTask.executeWorkflow(taskID: taskID, request: workflow,
                injector: injector, progress: progress)
        }
        return try await browserNavigationTask?.execute(taskID: taskID, prompt: prompt, progress: progress)
    }

    func closeOwnedBrowser() {
        browserNavigationTask?.close()
        browserNavigationTask = nil
    }

    var hasOwnedBrowserToolProposals: Bool { browserToolProposals != nil }

    func withOwnedBrowserToolProposals(taskID: String, propose: @escaping ComputerUseFaraBrowserExecutor.ProposeUsingTools,
        operation: () async throws -> ComputerUseExecutionResult) async throws -> ComputerUseExecutionResult {
        guard browserToolProposals == nil else { throw ComputerUseTaskExecutionError.alreadyExecuting }
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        let id = UUID()
        browserToolProposals = (id, taskID, propose)
        defer { if browserToolProposals?.id == id { browserToolProposals = nil } }
        return try await operation()
    }

    func proposeUsingOwnedBrowserTools(_ input: ComputerUseFaraModel.Input,
        observation: ComputerUseFaraBrowserExecutor.ToolObservation) async throws -> ComputerUseFaraModel.Proposal? {
        guard let scope = browserToolProposals else { return nil }
        func check() throws {
            try Task.checkCancellation()
            guard mayAct() else { throw ToolError.paused }
            guard browserToolProposals?.id == scope.id, observation.taskID == scope.taskID else {
                throw ComputerUseBrowserError.ownershipLost
            }
        }
        try check()
        let result = try await scope.propose(input, observation)
        try check()
        return result
    }

    /// Read-only admission gate before text-only research planning.
    func validateBrowserResearchAdmission() throws {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
    }

    /// Capture the exact prepared owner before either scoped callback can
    /// fail or suspend its caller. This does not navigate or invoke a planner.
    func prepareOwnedBrowserResearch(taskID: String, prompt: String,
        goalPlanner: any ComputerUseBrowserGoalPlanning, resultPlanner: any ComputerUseBrowserResultPlanning,
        referenceDate: Date = Date(), timeZoneIdentifier: String = TimeZone.current.identifier,
        planningWorker: ComputerUsePlanningWorker = .shared, planningTimeout: TimeInterval = 30,
        workBudget: ComputerUseBrowserWorkBudget? = nil,
        didPrepare: (@MainActor (ComputerUseBrowserResearchTask) throws -> Void)? = nil) throws -> ComputerUseBrowserResearchTask {
        try validateBrowserResearchAdmission()
        if browserNavigationTask == nil {
            guard !HostRuntimeContext.isRunningUnitTests else { throw ComputerUseBrowserResearchTask.Failure.browserRequired }
            browserNavigationTask = .init(browser: ComputerUseOwnedBrowser(mayAct: mayAct),
                journalDirectory: ComputerUseBrowserNavigationTask.journalDirectory)
            publishOwnedBrowserTaskControls()
        }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        let owner = try browserNavigationTask.prepareResearchTask(taskID: taskID, prompt: prompt, goalPlanner: goalPlanner,
            resultPlanner: resultPlanner, mayAct: mayAct, referenceDate: referenceDate, timeZoneIdentifier: timeZoneIdentifier,
            planningWorker: planningWorker, planningTimeout: planningTimeout, workBudget: workBudget)
        // Capture admission synchronously. The owner may be closed/replaced
        // while the driver awaits, so a later lookup cannot prove no admission.
        try didPrepare?(owner)
        try browserResearchAdmissionObserver?(owner)
        return owner
    }

    func withOwnedBrowserResearchAdmission(didPrepare: @escaping @MainActor (ComputerUseBrowserResearchTask) throws -> Void,
        operation: @MainActor () async throws -> ComputerUseExecutionResult?) async throws -> ComputerUseExecutionResult? {
        guard browserResearchAdmissionObserver == nil else { throw ComputerUseBrowserResearchTask.Failure.busy }
        browserResearchAdmissionObserver = didPrepare
        defer { browserResearchAdmissionObserver = nil }
        return try await operation()
    }

    func pauseOwnedBrowserForUserControl(taskID: String) { browserNavigationTask?.pauseForUserControl(taskID: taskID) }
    func resumeOwnedBrowserResearch(taskID: String) async throws { try await browserNavigationTask?.resumeResearchTask(taskID: taskID) }
    func retireOwnedBrowserResearch(taskID: String) { browserNavigationTask?.retireResearchTask(taskID: taskID) }
    func ownedBrowserResearch(taskID: String) -> ComputerUseBrowserResearchTask? { browserNavigationTask?.researchTask(taskID: taskID) }
    func ownedBrowserTaskID(forExecution taskID: String) -> String { browserNavigationTask?.browserTaskID(forExecution: taskID) ?? taskID }

    func matchesOwnedBrowserAgentSession(taskID: String, identity: String) -> Bool {
        browserNavigationTask?.matchesAgentSession(taskID: taskID, identity: identity) == true
    }

    func bindOwnedBrowserAgentContinuation(rootTaskID: String, executionTaskID: String, previousExecutionTaskID: String, sessionIdentity: String) throws {
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        try browserNavigationTask.bindAgentContinuation(rootTaskID: rootTaskID, executionTaskID: executionTaskID,
            previousExecutionTaskID: previousExecutionTaskID, sessionIdentity: sessionIdentity)
    }

    /// Read-only evidence for browser capabilities. It does not open a window,
    /// claim that a search finished, or feed raw destinations into a model.
    func observeOwnedBrowserPage(taskID: String) async throws -> ComputerUseBrowserPageEvidence? {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        return try await browserNavigationTask?.pageEvidenceIfFrontmost(taskID: taskID)
    }

    func validateOwnedBrowserPageEvidence(_ evidence: ComputerUseBrowserPageEvidence) async throws {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        try await browserNavigationTask.validatePageEvidence(evidence)
    }

    func captureOwnedBrowserAgentObservation(taskID: String, preserving session: ComputerUseOwnedBrowser.AgentObservation? = nil) async throws -> ComputerUseOwnedBrowser.AgentObservation {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        return try await browserNavigationTask.captureAgentObservation(taskID: taskID, preserving: session)
    }

    func captureOwnedBrowserInitialAgentObservation(taskID: String, expectedSessionIdentity: String?) async throws -> ComputerUseOwnedBrowser.InitialAgentObservation? {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        if browserNavigationTask == nil {
            guard expectedSessionIdentity == nil, !HostRuntimeContext.isRunningUnitTests else { throw ComputerUseBrowserError.closed }
            browserNavigationTask = .init(browser: ComputerUseOwnedBrowser(mayAct: mayAct), journalDirectory: ComputerUseBrowserNavigationTask.journalDirectory)
            publishOwnedBrowserTaskControls()
        }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        return try await browserNavigationTask.captureInitialAgentObservation(taskID: taskID, expectedSessionIdentity: expectedSessionIdentity)
    }

    func validateOwnedBrowserInitialAgentObservation(_ observation: ComputerUseOwnedBrowser.InitialAgentObservation) throws {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        try browserNavigationTask.validateInitialAgentObservation(observation)
    }

    func performOwnedBrowserInitialAgentNavigation(_ url: URL, observation: ComputerUseOwnedBrowser.InitialAgentObservation,
        operationID: String, willBeginEffect: () throws -> Void) async throws {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        try await browserNavigationTask.performInitialAgentNavigation(url, observation: observation, operationID: operationID, willBeginEffect: willBeginEffect)
    }

    func validateOwnedBrowserAgentObservation(_ observation: ComputerUseOwnedBrowser.AgentObservation, allowingIdenticalScreenshot: Bool = false) async throws {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        try await browserNavigationTask.validateAgentObservation(observation, allowingIdenticalScreenshot: allowingIdenticalScreenshot)
    }

    func validateOwnedBrowserAgentMemoryObservation(_ observation: ComputerUseOwnedBrowser.AgentObservation) throws {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        try browserNavigationTask.validateAgentMemoryObservation(observation)
    }

    func predictedOwnedBrowserAgentAction(_ action: ComputerUseFaraAction, observation: ComputerUseOwnedBrowser.AgentObservation) throws -> ComputerUsePredictedAction? {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        return try browserNavigationTask.predictedAgentAction(action, observation: observation)
    }

    /// Invoke inside the native browser's final pre-dispatch callback, after
    /// its asynchronous scene validation and before recording/posting input.
    func validateApprovedFingerprint(for action: ComputerUsePredictedAction, fingerprint: ComputerUseApprovalFingerprint,
                                     nativeTarget: ComputerUseOwnedBrowser.AgentTarget? = nil) throws {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard try prepareApproval(for: action, nativeTarget: nativeTarget).fingerprint == fingerprint else { throw ToolError.approvalTargetChanged }
    }

    func inspectOwnedBrowserAgentTarget(_ action: ComputerUseFaraAction, observation: ComputerUseOwnedBrowser.AgentObservation) async throws -> ComputerUseOwnedBrowser.AgentTarget? {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        // Explicit fixture providers retain their synthetic target contract.
        if accessibilityContextProvider != nil || approvalTargetProvider != nil { return nil }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        return try await browserNavigationTask.inspectAgentTarget(action, observation: observation)
    }

    fileprivate func validateOwnedBrowserAgentTarget(_ target: ComputerUseOwnedBrowser.AgentTarget) async throws {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        try await browserNavigationTask.validateAgentTarget(target)
    }

    func performOwnedBrowserAgentInput(_ action: ComputerUseFaraAction, observation: ComputerUseOwnedBrowser.AgentObservation, operationID: String? = nil,
                                      target: ComputerUseOwnedBrowser.AgentTarget? = nil,
                                      willBeginEffect: () throws -> Void) async throws {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        try await browserNavigationTask.performAgentInput(action, observation: observation, operationID: operationID, target: target, willBeginEffect: willBeginEffect)
    }

    func scrollOwnedBrowserViewport(_ direction: OSAtlasScrollDirection, evidence: ComputerUseBrowserPageEvidence,
                                    operationID: String, willBeginEffect: () -> Void) async throws -> ComputerUseBrowserViewportScrollReceipt {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        return try await browserNavigationTask.scrollViewport(direction, evidence: evidence,
            operationID: operationID, willBeginEffect: willBeginEffect)
    }

    /// Host capability surface for a task compiler. Page IDs select observed
    /// destinations; they do not authorize a goal or bypass its effect journal.
    func prepareOwnedBrowserLinkNavigation(linkID: String, evidence: ComputerUseBrowserPageEvidence) async throws -> ComputerUseBrowserNavigationTarget {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        return try await browserNavigationTask.prepareLinkNavigation(linkID: linkID, evidence: evidence)
    }

    func openOwnedBrowserDestination(_ target: ComputerUseBrowserNavigationTarget, promptDigest: String, operationID: String,
                                        willBeginEffect: () -> Void) async throws -> ComputerUseBrowserNavigationReceipt {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        return try await browserNavigationTask.openObservedDestination(target, promptDigest: promptDigest,
            operationID: operationID, willBeginEffect: willBeginEffect)
    }

    func prepareOwnedBrowserFormQuery(controlID: String, evidence: ComputerUseBrowserPageEvidence) async throws -> ComputerUseBrowserNavigationTarget {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.closed }
        return try await browserNavigationTask.prepareFormQuery(controlID: controlID, evidence: evidence)
    }

    func ownedBrowserHandbackRequirement(taskID: String, required: Bool = false) -> ComputerUseBrowserHandbackRequirement? {
        guard let browserNavigationTask else { return required ? .unavailable(taskID: taskID) : nil }
        return browserNavigationTask.handbackRequirement(taskID: ownedBrowserTaskID(forExecution: taskID), required: required)
    }

    func reacquireOwnedBrowserAfterUserControl(_ requirement: ComputerUseBrowserHandbackRequirement) async throws {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        guard let browserNavigationTask else { throw ComputerUseBrowserError.handbackContextLost }
        try await browserNavigationTask.reacquireAfterUserControl(requirement)
    }

    func bindOwnedBrowserTaskControls(
        handler: @escaping (ComputerUseBrowserTaskControls, ComputerUseBrowserTaskControls.Action) -> Void) {
        browserTaskControlHandler = handler
        publishOwnedBrowserTaskControls()
    }

    func updateOwnedBrowserTaskControls(_ controls: ComputerUseBrowserTaskControls?) {
        browserTaskControls = controls
        publishOwnedBrowserTaskControls()
    }

    func stopOwnedBrowserActivity() { browserNavigationTask?.stopBrowserActivity() }

    func stopOwnedBrowserActivity(taskID: String) {
        browserNavigationTask?.stopBrowserActivity(taskID: taskID)
    }

    private func publishOwnedBrowserTaskControls() {
        guard let browserTaskControlHandler else { return }
        browserNavigationTask?.updateTaskControls(browserTaskControls, handler: browserTaskControlHandler)
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
        guard mayAct() else { throw ToolError.paused }
        if let screenProvider {
            return try screenProvider()
        }
        // Read the focused-window geometry next to the display capture. The
        // screenshot remains a full-display input for visual control, while
        // fact extractors can fail closed to this one active window instead
        // of accepting a coherent stale result from another visible app.
        let windowBeforeCapture = liveFrontmostWindowSnapshot()
        let displayID = CGMainDisplayID()
        guard let image = CGDisplayCreateImage(displayID) else {
            throw ToolError.screenshotUnavailable
        }
        let windowAfterCapture = liveFrontmostWindowSnapshot()
        let frontmostWindowBounds = Self.stableFrontmostWindowBounds(
            before: windowBeforeCapture,
            after: windowAfterCapture)
        let displayBounds = CGDisplayBounds(displayID)
        let bounds = displayBounds.width > 0 && displayBounds.height > 0
            ? displayBounds
            : CGRect(
                x: 0,
                y: 0,
                width: CGDisplayPixelsWide(displayID),
                height: CGDisplayPixelsHigh(displayID))
        return ComputerUseScreenObservation(
            image: CIImage(cgImage: image),
            displayBounds: bounds,
            frontmostWindowBounds: frontmostWindowBounds)
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

    /// Reads only Calculator's visible input/result field from its bounded
    /// Accessibility subtree. The deterministic arithmetic route uses this
    /// as execution evidence and never reports completion from the injected
    /// keystrokes alone.
    func calculatorSnapshot() throws -> ComputerUseCalculatorSnapshot? {
        guard mayAct() else { throw ToolError.paused }
        if let calculatorSnapshotProvider {
            return calculatorSnapshotProvider()
        }
        return Self.liveCalculatorSnapshot()
    }

    private static func liveCalculatorSnapshot() -> ComputerUseCalculatorSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier == "com.apple.calculator",
              !application.isTerminated else {
            return nil
        }
        let root = AXUIElementCreateApplication(application.processIdentifier)
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
        guard let inputContainers = calculatorContainers(
            in: focusedWindow,
            identifier: "StandardInputView"),
              inputContainers.count == 1,
              let expressionContainers = calculatorContainers(
                in: focusedWindow,
                identifier: "StandardResultView"),
              expressionContainers.count <= 1 else {
            return nil
        }
        var inputVisited = 0
        let inputValue = firstStaticTextValue(
            in: inputContainers[0],
            depth: 0,
            visited: &inputVisited)
        let expressionValue: String?
        if let expressionContainer = expressionContainers.first {
            var expressionVisited = 0
            expressionValue = firstStaticTextValue(
                in: expressionContainer,
                depth: 0,
                visited: &expressionVisited)
        } else {
            expressionValue = nil
        }
        guard inputValue != nil else { return nil }
        return ComputerUseCalculatorSnapshot(
            inputValue: inputValue,
            expressionValue: expressionValue)
    }

    private static func calculatorContainers(
        in element: AXUIElement,
        identifier targetIdentifier: String
    ) -> [AXUIElement]? {
        var queue: [(AXUIElement, Int)] = [(element, 0)]
        var index = 0
        var matches: [AXUIElement] = []
        while index < queue.count, index < 500 {
            let (current, depth) = queue[index]
            index += 1
            guard depth <= 12 else { continue }
            if stringAttribute(
                kAXIdentifierAttribute as CFString,
                from: current) == targetIdentifier {
                matches.append(current)
                guard matches.count <= 1 else { return nil }
            }
            var childValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                current,
                kAXChildrenAttribute as CFString,
                &childValue) == .success,
               let children = childValue as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(80).map {
                    ($0, depth + 1)
                })
            }
        }
        guard index < 500 || index == queue.count else { return nil }
        return matches
    }

    private static func firstStaticTextValue(
        in element: AXUIElement,
        depth: Int,
        visited: inout Int
    ) -> String? {
        guard depth <= 6, visited < 80 else { return nil }
        visited += 1
        let role = stringAttribute(
            kAXRoleAttribute as CFString,
            from: element) ?? ""
        let identifier = stringAttribute(
            kAXIdentifierAttribute as CFString,
            from: element) ?? ""

        if role == kAXStaticTextRole as String,
           let value = stringAttribute(
               kAXValueAttribute as CFString,
               from: element),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        if identifier == "StandardInputView" || identifier == "StandardResultView",
           let value = stringAttribute(
               kAXValueAttribute as CFString,
               from: element),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }

        var childValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childValue) == .success,
              let children = childValue as? [AXUIElement] else {
            return nil
        }
        for child in children.prefix(80) {
            if let value = firstStaticTextValue(
                in: child,
                depth: depth + 1,
                visited: &visited) {
                return value
            }
        }
        return nil
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

    func approvalReason(for action: ComputerUsePredictedAction, nativeTarget: ComputerUseOwnedBrowser.AgentTarget? = nil) -> String? {
        if let nativeTarget, nativeTarget.action == action {
            // This retained target addresses the host's Find UI only. Its
            // query never enters a website field or submits a network request.
            // Explicit approval still uses prepareApproval and its fingerprint.
            if nativeTarget.findAction != nil { return nil }
            return ComputerUseActionSafetyPolicy.approvalReason(for: action, accessibilityContext: nativeTarget.context,
                verifiedSearchSubmission: nativeTarget.isSearchSubmission, verifiedLinkNavigation: nativeTarget.navigation != nil)
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

    private func actionableElementSnapshot(at point: CGPoint, requiringLabel: Bool = true) -> AccessibilitySnapshot? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &element) == .success,
              var current = element else { return nil }

        for _ in 0 ..< 8 {
            let snapshot = accessibilitySnapshot(for: current)
            if snapshot.isActionable,
               (!requiringLabel || snapshot.attestationLabel != nil),
               snapshot.frame?.contains(point) == true {
                return snapshot
            }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        return nil
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
        for action: ComputerUsePredictedAction,
        nativeTarget: ComputerUseOwnedBrowser.AgentTarget? = nil
    ) throws -> ComputerUsePreparedApproval {
        if let nativeTarget {
            try Task.checkCancellation()
            guard mayAct(), nativeTarget.action == action else { throw ToolError.approvalTargetChanged }
            return ComputerUsePreparedApproval(message: ComputerUseActionSafetyPolicy.approvalReason(
                for: action, accessibilityContext: nativeTarget.context, forceConfirmation: true,
                verifiedLinkNavigation: nativeTarget.navigation != nil) ?? "Perform this exact browser action",
                fingerprint: nativeTarget.fingerprint)
        }
        let target = try approvalTarget(for: action)
        var accessibilityIdentity = target.accessibilityIdentity
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
            visualDigest: try visualDigest(around: target.visualCheckpoints))
        return ComputerUsePreparedApproval(
            message: message,
            fingerprint: fingerprint)
    }

    fileprivate func performApproved(
        _ action: ComputerUsePredictedAction,
        fingerprint: ComputerUseApprovalFingerprint,
        browserPageEvidence: ComputerUseBrowserPageEvidence?,
        willBeginEffect: () throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        if let browserPageEvidence {
            do { try await validateOwnedBrowserPageEvidence(browserPageEvidence) }
            catch {
                try Task.checkCancellation()
                guard mayAct() else { throw ToolError.paused }
                switch error as? ComputerUseBrowserError {
                case .authenticationRequired: throw ComputerUseBrowserError.authenticationRequired
                case .pageChanged, .windowNotActive, .closed, .ownershipLost, .signInWindowOpen:
                    throw ToolError.approvalTargetChanged
                default: throw error
                }
            }
        }
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        // Recheck AX/pixels after the asynchronous browser read. The approved
        // page and the current native target must both still match.
        let current = try prepareApproval(for: action).fingerprint
        guard current == fingerprint else {
            throw ToolError.approvalTargetChanged
        }
        try willBeginEffect()
        if case .typeText = action {
            try await performVerified(action)
        } else {
            try perform(action, reportsPartialApprovedEffect: true)
        }
    }

    /// Native model adapters use the same target binding and verified text
    /// path as approved host input. The adapter still owns the policy decision
    /// and must persist its attempt in willBeginEffect before posting input.
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
        return actionableElementSnapshot(at: CGPoint(x: x, y: y), requiringLabel: false)?.frame
    }

    func nativeFocusedTextFrame() throws -> CGRect? {
        guard mayAct() else { throw ToolError.paused }
        guard screenProvider == nil, let snapshot = try currentTextSnapshot(), snapshot.selection.length == 0,
              let frame = focusedElementSnapshot()?.frame, !frame.isEmpty,
              try currentTextSnapshot() == snapshot else { return nil }
        return frame
    }

    func mcpFocusedTextSnapshot() throws -> ComputerUseMCPFocusedTextSnapshot? {
        try Task.checkCancellation()
        guard mayAct() else { throw ToolError.paused }
        if let mcpFocusedTextSnapshotProvider {
            return try mcpFocusedTextSnapshotProvider()
        }
        // Synthetic screens or app identities cannot authorize live AX reads.
        guard usesLiveFrontmostApplicationIdentity, screenProvider == nil,
              accessibilityContextProvider == nil else { return nil }
        let application = frontmostApplicationSnapshot()
        guard let window = liveFrontmostWindowSnapshot(),
              let text = try currentTextSnapshot(), let element = focusedElement(),
              let role = Self.stringAttribute(kAXRoleAttribute as CFString, from: element),
              let frame = accessibilitySnapshot(for: element).frame else { return nil }
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success,
              elementPID == window.applicationProcessIdentifier else { return nil }
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        let windowElement = unsafeBitCast(windowValue, to: AXUIElement.self)
        guard CFHash(windowElement) == window.accessibilityWindowHash else { return nil }
        let snapshot = ComputerUseMCPFocusedTextSnapshot(
            application: application, window: window, text: text, frame: frame, role: role,
            focusedElement: element,
            documentIdentity: Self.stringAttribute(kAXDocumentAttribute as CFString, from: windowElement))
        guard snapshot.isReadable, try currentTextSnapshot() == text,
              liveFrontmostWindowSnapshot() == window,
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

    func nativeFocusedEditorObservation() throws -> (description: String, textState: ComputerUseNativeTextState?)? {
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
            guard screenProvider == nil, let before = try currentTextSnapshot(),
                  let focused = focusedElementSnapshot() else { return nil }
            description = focused.summary
            observed = before
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
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (result, state)
    }

    func performNativeAction(_ action: ComputerUsePredictedAction, fingerprint: ComputerUseApprovalFingerprint,
                            willBeginEffect: () throws -> Void) async throws {
        try await performApproved(action, fingerprint: fingerprint, browserPageEvidence: nil, willBeginEffect: willBeginEffect)
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
            checkpoints = focused?.center.map { [$0] }
                ?? [CGPoint(x: CGDisplayBounds(CGMainDisplayID()).midX,
                            y: CGDisplayBounds(CGMainDisplayID()).midY)]

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
        guard !points.isEmpty else { return nil }
        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        let windowBefore = liveFrontmostWindowSnapshot()
        guard bounds.width > 0, bounds.height > 0,
              let image = CGDisplayCreateImage(displayID) else {
            throw ToolError.screenshotUnavailable
        }
        let windowAfter = liveFrontmostWindowSnapshot()
        guard windowBefore == windowAfter else { throw ToolError.approvalTargetChanged }
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
    /// A browser question retains the original research owner while the
    /// existing phone protocol correlates the next exact answer separately.
    case browserClarificationRequired(ComputerUseBrowserQuestionRequest)
    /// The requested task is still active, but the next step must be performed
    /// by the person (for example, entering account credentials). The manager
    /// preserves the task context and pauses all automation until Resume.
    case userInterventionRequired(String)
    /// A current reading to review while the original research remains paused.
    case browserResearchProgress(ComputerUseBrowserResearchReport)
    /// Complete quoted source findings admitted under the retained research goal.
    case browserResearchAnswer(ComputerUseBrowserResearchAnswer)
    case approvalRequired(
        message: String,
        action: ComputerUsePredictedAction,
        continuation: ComputerUseVisualApprovalContinuation)
    case mcpApprovalRequired(MCPPreparedApproval)
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
protocol MacControlMCPProvisioning: Sendable {
    func durableStatus() async -> MacControlMCPInstaller.DurableStatus
    func install(
        progress: @MainActor @Sendable @escaping (MacControlMCPInstaller.Update) -> Void
    ) async throws -> MacControlMCPInstallationReceipt
}

extension MacControlMCPInstaller: MacControlMCPProvisioning {}

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
    var requiresMacControlHelper: Bool { get }
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
            browserPageEvidence: continuation.browserPageEvidence, willBeginEffect: willBeginEffect)
    }
}

extension ComputerUseExecuting {
    var requiresMacControlHelper: Bool { true }
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

typealias ComputerUseExecutorComposer = @MainActor @Sendable (
    MacControlMCPInstallationReceipt,
    any ComputerUseExecuting
) async throws -> any ComputerUseExecuting

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
        didSet { refreshBrowserTaskControls() }
    }

    private struct BrowserControlIdentity: Equatable {
        let taskID: String
        let senderID: String
        let sessionID: String
        var executionToken: UUID?
        let authorizationGeneration: UInt64
        let transportGeneration: UInt64
        let remoteRevision: UInt64?
        let hostControlEpoch: UInt64
        let phase: ComputerUseBrowserTaskControls.Phase
        let canResume: Bool

        func sameOwner(as other: Self) -> Bool {
            taskID == other.taskID && senderID == other.senderID && sessionID == other.sessionID
                && authorizationGeneration == other.authorizationGeneration
                && transportGeneration == other.transportGeneration
        }
    }
    private var browserControlIdentity: BrowserControlIdentity?
    @Published private(set) var localTaskControls: ComputerUseBrowserTaskControls?
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
        guard let executor, executor.isReady else { return false }
        return !executor.requiresMacControlHelper || macControlReceipt != nil
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
                    detail: "Set up Mac control")
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
        /// Exact signed request body used to bind durable approval plans.
        /// Conversation/Resume prose changes model input, never this identity.
        let requestBody: String
        let supportsApprovedActionEvidence: Bool
        let textClarification: TextClarificationContinuation?
        let browserClarification: ComputerUseBrowserClarificationTransport.Continuation?
        /// False only when a versioned Pause reached the durable ledger before
        /// its Prompt. Resume can then claim and start that Prompt exactly once
        /// instead of treating it as work that needs a continuation replan.
        let hasStarted: Bool
        let browserHandbackRequirement: ComputerUseBrowserHandbackRequirement?

        init(
            envelope: ComputerUseEnvelope,
            channel: any HostComputerUseChannel,
            trustedUserPrompt: String? = nil,
            conversation: [ComputerUseConversationTurn]? = nil,
            requestBody: String? = nil,
            textClarification: TextClarificationContinuation? = nil,
            browserClarification: ComputerUseBrowserClarificationTransport.Continuation? = nil,
            hasStarted: Bool = true,
            browserHandbackRequirement: ComputerUseBrowserHandbackRequirement? = nil
        ) {
            self.envelope = envelope
            self.channel = channel
            self.trustedUserPrompt = trustedUserPrompt
                ?? ComputerUsePromptRequest.decodeCompatibleBody(
                    envelope.body).prompt
            self.conversation = conversation
                ?? ComputerUsePromptRequest.decodeCompatibleBody(
                    envelope.body).conversation
            self.requestBody = requestBody ?? envelope.body
            self.supportsApprovedActionEvidence = ComputerUsePromptRequest.decodeCompatibleBody(
                requestBody ?? envelope.body).supportsApprovedActionEvidence
            self.hasStarted = hasStarted
            self.textClarification = textClarification
            self.browserClarification = browserClarification
            self.browserHandbackRequirement = browserHandbackRequirement
        }

        func retainingBrowserHandback(_ requirement: ComputerUseBrowserHandbackRequirement?) -> Self {
            .init(envelope: envelope, channel: channel, trustedUserPrompt: trustedUserPrompt,
                conversation: conversation, requestBody: requestBody,
                textClarification: textClarification,
                browserClarification: browserClarification,
                hasStarted: hasStarted, browserHandbackRequirement: requirement)
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
        case mcp(MCPPreparedApproval)
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
    private let injector: InputInjector
    private let tools: ComputerUseHostTools
    private let actionGate: ComputerUseActionGate
    private let installer: any ComputerUseModelProvisioning
    private let nativeTextInstaller: (any ComputerUseModelProvisioning)?
    private let nativeTextLoader: ComputerUseNativeTextLoader
    private let nativeTextPreparer: ComputerUseNativeTextLoader
    private let macControlInstaller: any MacControlMCPProvisioning
    private let visualExecutorLoader: any ComputerUseVisualExecutorLoading
    private let executorComposer: ComputerUseExecutorComposer
    private let taskLedger: ComputerUseTaskLedger
    private let textClarifications: ComputerUseTextClarificationStore
    private let browserClarifications = ComputerUseBrowserClarificationTransport()
    private let transportTeardownTimeout: Duration
    /// False only for app-hosted test sessions. Direct manager constructions
    /// keep the production default so their installer lifecycle tests retain
    /// the behavior they are explicitly exercising.
    let allowsExternalServices: Bool
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
    private var actionEvidenceAuthorizationGeneration: UInt64 = 0
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
    private var macControlReceipt: MacControlMCPInstallationReceipt?
    private var authorizedPeerID: String? {
        didSet { refreshBrowserTaskControls() }
    }
    private var authorizedPeerSupportsOrderedComputerUseControls = false {
        didSet { refreshBrowserTaskControls() }
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
        injector: InputInjector,
        executor: (any ComputerUseExecuting)? = nil,
        installer: (any ComputerUseModelProvisioning)? = nil,
        nativeTextInstaller: (any ComputerUseModelProvisioning)? = nil,
        nativeTextLoader: ComputerUseNativeTextLoader? = nil,
        nativeTextPreparer: ComputerUseNativeTextLoader? = nil,
        macControlInstaller: (any MacControlMCPProvisioning)? = nil,
        visualExecutorLoader: (any ComputerUseVisualExecutorLoading)? = nil,
        executorComposer: ComputerUseExecutorComposer? = nil,
        taskLedger: ComputerUseTaskLedger = ComputerUseTaskLedger(),
        textClarifications: ComputerUseTextClarificationStore? = nil,
        browserNavigationFactory: ((@escaping () -> Bool) -> ComputerUseBrowserNavigationTask)? = nil,
        transportTeardownTimeout: Duration = .seconds(5),
        allowsExternalServices: Bool = true,
        approvalTargetProvider:
            ((ComputerUsePredictedAction) throws -> ComputerUseApprovalTargetSnapshot)? = nil,
        actionPerformer: ((ComputerUsePredictedAction) throws -> Void)? = nil,
        approvedActionStepDidPost: (@MainActor () -> Void)? = nil,
        screenProvider: (() throws -> ComputerUseScreenObservation)? = nil,
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
        let mayAct = { [weak gate] in gate?.allowsActions == true }
        self.executor = executor
        self.injector = injector
        self.actionGate = gate
        self.tools = ComputerUseHostTools(
            injector: injector,
            mayAct: mayAct,
            approvalTargetProvider: approvalTargetProvider,
            actionPerformer: actionPerformer,
            browserNavigationTask: browserNavigationFactory?(mayAct),
            approvedActionStepDidPost: approvedActionStepDidPost,
            screenProvider: screenProvider,
            accessibilityContextProvider: accessibilityContextProvider)
        self.installer = installer ?? ComputerUseInstaller()
        self.nativeTextInstaller = nativeTextInstaller
        self.nativeTextLoader = nativeTextLoader ?? { receipt, tools, progress in
            try await ComputerUseNativeTextExecutorLoader.load(receipt: receipt, tools: tools, progress: progress)
        }
        self.nativeTextPreparer = nativeTextPreparer ?? nativeTextLoader ?? { receipt, tools, progress in
            try await ComputerUseNativeTextExecutorLoader.prepare(receipt: receipt, tools: tools, progress: progress)
        }
        self.macControlInstaller = macControlInstaller ?? MacControlMCPInstaller()
        self.visualExecutorLoader = visualExecutorLoader
            ?? OSAtlasVisualExecutorLoader()
        self.executorComposer = executorComposer ?? { helperReceipt, visualFallback in
            try await MCPFirstComputerUseExecutor.load(
                binaryURL: URL(fileURLWithPath: helperReceipt.binaryPath),
                visualFallback: visualFallback,
                clientPool: MCPClientPool())
        }
        self.taskLedger = taskLedger
        self.textClarifications = textClarifications ?? ComputerUseTextClarificationStore()
        self.transportTeardownTimeout = transportTeardownTimeout
        self.allowsExternalServices = allowsExternalServices
        self.channelFactory = channelFactory
        if allowsExternalServices {
            refreshModelState()
            installLocalInterventionMonitors()
        }
        tools.bindOwnedBrowserTaskControls { [weak self] controls, action in
            self?.requestLocalTaskControl(action, displayed: controls)
        }
        refreshBrowserTaskControls()
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
            let helperStatus = await macControlInstaller.durableStatus()
            guard !Task.isCancelled, !isShuttingDown else { return }
            switch helperStatus {
            case .ready(let receipt):
                macControlReceipt = receipt
                if let executor, executor.isReady {
                    modelState = .ready(runtimeName: executor.runtimeName)
                } else if nativeTextInstaller != nil {
                    // The normal host can use the installed helper even when
                    // neither model package has finished installing.
                    let modelReceipt = await installer.currentInstallation()
                    guard !Task.isCancelled, !isShuttingDown else { return }
                    beginStructuredActivation(helperReceipt: receipt, visualReceipt: modelReceipt)
                } else if let modelReceipt = await installer.currentInstallation() {
                    modelState = .packageFound(fileName: "Verified model installation")
                    beginActivation(of: modelReceipt)
                } else if await installer.interruptedInstallationExists() {
                    // The helper receipt plus the model marker prove that this
                    // setup was explicitly initiated before the host exited.
                    modelState = .installing(
                        detail: "Resuming AI setup…",
                        fraction: nil)
                    startSetupPipeline()
                } else {
                    modelState = .downloadRequired
                }

            case .downloadPresent(let downloadedByteCount, _)
                where downloadedByteCount > 0:
                // Only real bytes in the installer's managed download area
                // authorize an automatic helper resume. A fresh status check,
                // repair state, or zero-byte marker never starts networking.
                macControlReceipt = nil
                modelState = .installing(
                    detail: "Resuming Mac control setup…",
                    fraction: nil)
                startSetupPipeline()

            case .notInstalled, .repairRequired, .downloadPresent:
                macControlReceipt = nil
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
            actionEvidenceAuthorizationGeneration &+= 1
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
        actionEvidenceAuthorizationGeneration &+= 1
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

        tools.closeOwnedBrowser()
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
            cancelActiveMCPWork()
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

    private func refreshBrowserTaskControls() {
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
        let phase: ComputerUseBrowserTaskControls.Phase
        switch activity {
        case .working: context = currentExecution; phase = .working
        case .paused: context = pausedExecution; phase = .paused
        case .awaitingApproval: context = pendingApproval?.context; phase = .awaitingApproval
        case .idle: context = nil; phase = .paused
        }
        guard !isShuttingDown, let context else {
            browserControlIdentity = nil
            localTaskControls = nil
            tools.updateOwnedBrowserTaskControls(nil)
            return
        }
        var identity = BrowserControlIdentity(taskID: tools.ownedBrowserTaskID(forExecution: context.envelope.id),
            senderID: context.envelope.senderID, sessionID: context.envelope.sessionID,
            executionToken: currentExecutionToken,
            authorizationGeneration: actionEvidenceAuthorizationGeneration,
            transportGeneration: transportGeneration,
            remoteRevision: taskLedger.appliedControlRevision(taskID: context.envelope.id),
            hostControlEpoch: taskLedger.hostControlEpoch(taskID: context.envelope.id),
            phase: phase, canResume: phase == .paused
                && isPeerAuthorizedForComputerUse(senderID: context.envelope.senderID)
                && taskLedger.canResumeLocally(taskID: context.envelope.id,
                    senderID: context.envelope.senderID, sessionID: context.envelope.sessionID))
        if identity.executionToken == nil, let previous = browserControlIdentity,
           identity.sameOwner(as: previous) {
            identity.executionToken = previous.executionToken
        }
        guard identity != browserControlIdentity else { return }
        let sameRun = browserControlIdentity.map {
            identity.sameOwner(as: $0) && identity.executionToken == $0.executionToken
        } ?? false
        let snapshot = ComputerUseBrowserTaskControls(taskID: identity.taskID,
            scopeID: sameRun ? (localTaskControls?.scopeID ?? UUID()) : UUID(),
            presentationID: UUID(), phase: phase, canResume: identity.canResume,
            ownerID: browserControlIdentity.map { identity.sameOwner(as: $0) } == true
                ? (localTaskControls?.ownerID ?? UUID()) : UUID())
        browserControlIdentity = identity
        localTaskControls = snapshot
        tools.updateOwnedBrowserTaskControls(snapshot)
    }

    func requestLocalTaskControl(_ action: ComputerUseBrowserTaskControls.Action,
                                         displayed: ComputerUseBrowserTaskControls) {
        refreshBrowserTaskControls()
        guard let current = localTaskControls,
              current.taskID == displayed.taskID, current.scopeID == displayed.scopeID,
              let context = currentExecution ?? pausedExecution ?? pendingApproval?.context,
              tools.ownedBrowserTaskID(forExecution: context.envelope.id) == current.taskID else { return }
        switch action {
        case .takeControl:
            guard current.phase != .paused else { return }
            pauseForLocalIntervention(context)
        case .resume:
            // Resume uses the exact rendered state. Local input may have
            // paused a run between mouse-down and a Stop click, so Stop below
            // instead accepts that same run's earlier presentation.
            guard displayed == current, current.phase == .paused, current.canResume,
                  isPeerAuthorizedForComputerUse(senderID: context.envelope.senderID) else { return }
            let input = pausedInputSnapshot(for: context)
            guard persistLocalControl(.resume, context: context, acknowledgingInput: input) else {
                pauseExecution(context, guidance: Self.localControlPersistenceFailureGuidance)
                return
            }
            resumeExecution(context, afterInput: input)
        case .stop:
            // Stop is absorbing. Its durable Cancel must be replayable with
            // the revision of a delayed phone control; an unversioned local
            // terminal alone could be ignored by a phone awaiting that control.
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
        refreshBrowserTaskControls()
        defer { refreshBrowserTaskControls() }
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
                browserClarifications.invalidateAnswerQuestion(rejectedQuestion, for: replyEnvelope)
                if taskLedger.terminalClarification(taskID: rejectedQuestion.taskID) == rejectedQuestion {
                    do { _ = try taskLedger.cancelLocally(taskID: rejectedQuestion.taskID,
                        senderID: envelope.senderID, sessionID: envelope.sessionID) }
                    catch { return false }
                }
            }
            browserClarifications.invalidate(for: replyEnvelope)
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
                    // delivery loop and held MCP generation, then replan from
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
        defer { refreshBrowserTaskControls() }
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
                                            requiresBrowserHandback: Bool = false,
                                            report: ComputerUseResearchProgress? = nil) {
        let context = context.retainingBrowserHandback(context.browserHandbackRequirement
            ?? (requiresBrowserHandback ? tools.ownedBrowserHandbackRequirement(taskID: context.envelope.id, required: true) : nil))
        actionGate.endAutomation(allowsActions: false)
        let persisted = persistLocalControl(.pause, context: context)
        pauseExecution(context, guidance: persisted ? guidance : Self.localControlPersistenceFailureGuidance,
            report: persisted ? report : nil)
    }

    private func pauseExecution(_ context: ExecutionContext, guidance: String? = nil,
                                report: ComputerUseResearchProgress? = nil) {
        let context = context.retainingBrowserHandback(context.browserHandbackRequirement
            ?? (context.hasStarted ? tools.ownedBrowserHandbackRequirement(taskID: context.envelope.id) : nil))
        let guidance = guidance ?? Self.userInterventionGuidance
        if postedApprovedVisualTaskID == context.envelope.id {
            terminalizePostedVisualActionForIntervention(context: context)
            return
        }
        if pausedExecution?.envelope.id == context.envelope.id {
            if let pausedExecution, pausedExecution.browserHandbackRequirement == nil {
                self.pausedExecution = pausedExecution.retainingBrowserHandback(context.browserHandbackRequirement)
            }
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
        tools.pauseOwnedBrowserForUserControl(taskID: context.envelope.id)
        let invalidatedApproval = pendingApproval
        pausedExecution = context
        currentExecution = nil
        pendingApproval = nil
        cancelApprovalIfNeeded(invalidatedApproval)
        approvalDeliveryTask?.cancel()
        approvalDeliveryTask = nil
        currentExecutionToken = nil
        cancelActiveVisualApprovalContinuation()
        cancelActiveMCPWork()
        executionTask?.cancel()
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
            requestBody: pausedExecution.requestBody,
            textClarification: pausedExecution.textClarification,
            browserClarification: pausedExecution.browserClarification,
            browserHandbackRequirement: pausedExecution.browserHandbackRequirement,
            channel: pausedExecution.channel,
            isResuming: true, pendingAutomationID: pendingAutomationID)
    }

    private func stopExecution(_ context: ExecutionContext) {
        let activeTaskID = currentExecution?.envelope.id
            ?? pausedExecution?.envelope.id
            ?? pendingApproval?.context.envelope.id
        guard activeTaskID == context.envelope.id else { return }
        browserClarifications.invalidate(for: context.envelope)
        textClarifications.invalidate(for: context.envelope)
        (executor as? any ComputerUseTextClarificationContinuing)?.invalidateClarification(taskID: context.envelope.id)
        // Cancel is terminal for this execution. Keep the automation gate
        // closed until a later, separately claimed Prompt explicitly begins;
        // never let cancellation-ignoring work inject during unwind.
        actionGate.endAutomation(allowsActions: false)
        // Phone and local Stop share browser retirement. Retiring only the
        // research planner left explicit workflows holding their document and
        // sign-in session after the client had already received a terminal.
        tools.stopOwnedBrowserActivity(taskID: context.envelope.id)
        let invalidatedApproval = pendingApproval
        postedApprovedVisualTaskID = nil
        cancelActiveVisualApprovalContinuation()
        cancelActiveMCPWork()
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
            cancelApprovalIfNeeded(pendingApproval)
            pauseForLocalIntervention(pendingApproval.context,
                guidance: Self.admissionGuidance(admission))
            return
        }

        switch pendingApproval.operation {
        case .mcp(let prepared):
            continueApprovedMCP(
                prepared,
                executor: executor,
                context: pendingApproval.context)

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

    private func cancelApprovalIfNeeded(_ approval: PendingApproval?) {
        guard let approval else { return }
        switch approval.operation {
        case .visual(let token, _, _):
            cancelVisualApprovalContinuation(token)
        case .mcp:
            guard let continuation =
                    executor as? any MCPApprovalContinuing else { return }
            continuation.cancelMCPWork()
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
        cancelActiveMCPWork()
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

    /// Captures and invalidates the currently owned helper generation before
    /// task cancellation can race an immediate Resume. MCPFirst binds the
    /// asynchronous stop to that captured generation, so stale cleanup cannot
    /// terminate the generation started by the resumed task.
    private func cancelActiveMCPWork() {
        guard let continuation = executor as? any MCPApprovalContinuing else { return }
        continuation.cancelMCPWork()
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
        modelCheckTask?.cancel()
        modelCheckTask = nil
        lastInstallerProgressPhase = nil
        lastInstallerProgressFraction = nil
        lastInstallerProgressDate = .distantPast
        publishSetupProgress(
            phase: .queued,
            fraction: 0,
            detail: "Checking this Mac…")
        modelState = .installing(detail: "Checking this Mac…", fraction: 0)
        setupTask = Task { [weak self] in
            guard let self else { return }
            defer { setupTask = nil }
            let previouslyAvailableExecutor = executor
            var activationReceipt: ComputerUseInstallationReceipt?
            var nativeExecutor: ComputerUseCapabilityExecutor?
            var composedExecutor: (any ComputerUseExecuting)?
            var retainedCapabilities: (any ComputerUseExecuting)?
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
                let helperReceipt = try await macControlInstaller.install { [weak self] update in
                    self?.consumeMacControlInstallerUpdate(update)
                }
                macControlReceipt = helperReceipt
                try Task.checkCancellation()
                if let nativeExecutor {
                    configureVisualFactory(nativeExecutor, receipt: nil)
                    let structured = try await executorComposer(helperReceipt, nativeExecutor)
                    composedExecutor = structured
                    retainedCapabilities = structured
                    try Task.checkCancellation()
                    executor = structured
                }
                let receipt = try await installer.install { [weak self] update in
                    self?.consumeInstallerUpdate(update)
                }
                activationReceipt = receipt
                try Task.checkCancellation()
                modelState = .installing(
                    detail: "Loading the on-device AI…",
                    fraction: 0.98)
                publishSetupProgress(
                    phase: .installingPackages,
                    fraction: 0.98,
                    detail: "Loading the on-device AI…")
                if nativeExecutor == nil { executor = nil }
                let loaded = try await visualExecutorLoader.load(
                    receipt: receipt,
                    progress: { [weak self] detail in
                        self?.consumeRuntimeActivationUpdate(detail)
                    })
                try Task.checkCancellation()
                modelState = .installing(
                    detail: "Starting verified local Mac tools…",
                    fraction: 0.99)
                publishSetupProgress(
                    phase: .installingPackages,
                    fraction: 0.99,
                    detail: "Starting verified local Mac tools…")
                let hybrid: any ComputerUseExecuting
                if let retainedCapabilities { hybrid = retainedCapabilities }
                else { hybrid = try await executorComposer(helperReceipt, loaded) }
                composedExecutor = hybrid
                try Task.checkCancellation()
                try await installer.recordRuntimeActivationSuccess(for: receipt)
                try Task.checkCancellation()
                if let nativeExecutor {
                    configureVisualFactory(nativeExecutor, receipt: receipt)
                }
                executor = hybrid
                modelState = .ready(runtimeName: executor?.runtimeName ?? hybrid.runtimeName)
                publishSetupProgress(
                    phase: .ready,
                    fraction: 1,
                    detail: executor?.readyDetail ?? "AI Computer Use is ready")
            } catch is CancellationError {
                (composedExecutor as? any MCPApprovalContinuing)?.cancelMCPWork()
                await visualExecutorLoader.deactivate()
                executor = retainedCapabilities ?? nativeExecutor ?? previouslyAvailableExecutor
                if let activationReceipt {
                    try? await installer.restorePreviousInstallation(
                        afterFailedActivationOf: activationReceipt)
                }
                modelState = executor.map { .ready(runtimeName: $0.runtimeName) } ?? .downloadRequired
                publishSetupProgress(
                    phase: .failed,
                    fraction: nil,
                    detail: "Setup stopped",
                    errorMessage: executor == nil
                        ? "Setup stopped before AI Computer Use was activated. Tap Retry to continue."
                        : "Available AI tools are ready. Additional setup stopped; tap Retry to finish it.")
                return
            } catch {
                (composedExecutor as? any MCPApprovalContinuing)?.cancelMCPWork()
                await visualExecutorLoader.deactivate()
                executor = retainedCapabilities ?? nativeExecutor ?? previouslyAvailableExecutor
                if let activationReceipt {
                    try? await installer.restorePreviousInstallation(
                        afterFailedActivationOf: activationReceipt)
                }
                await installer.clearInterruptedInstallationMarker()
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                modelState = executor.map { .ready(runtimeName: $0.runtimeName) } ?? .error(message)
                publishSetupProgress(
                    phase: .failed,
                    fraction: nil,
                    detail: "Setup needs attention",
                    errorMessage: message)
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

    private func beginStructuredActivation(helperReceipt: MacControlMCPInstallationReceipt,
                                           visualReceipt: ComputerUseInstallationReceipt?) {
        guard allowsExternalServices, !isShuttingDown, setupTask == nil else { return }
        modelState = .installing(detail: "Starting local Mac tools…", fraction: nil)
        setupTask = Task { [weak self] in
            guard let self else { return }
            var loaded: (any ComputerUseExecuting)?
            var finishRequestedSetup = false
            defer {
                setupTask = nil
                if finishRequestedSetup, !Task.isCancelled, !isShuttingDown { startSetupPipeline() }
            }
            do {
                let structured = try await executorComposer(helperReceipt, deferredVisualExecutor(receipt: visualReceipt))
                loaded = structured
                try Task.checkCancellation()
                let interrupted = visualReceipt == nil ? await installer.interruptedInstallationExists() : false
                try Task.checkCancellation()
                executor = structured
                modelState = .ready(runtimeName: structured.runtimeName)
                // A missing native package still needs full setup. Availability
                // of the helper is not a terminal full-setup response.
                if currentSetupProgress?.phase == .ready { currentSetupProgress = nil }
                finishRequestedSetup = interrupted || !setupRecipients.activeRecipients().isEmpty
            } catch {
                (loaded as? any MCPApprovalContinuing)?.cancelMCPWork()
                executor = nil
                modelState = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                publishRequestedActivationFailure(error)
            }
        }
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
            var structuredCandidate: (any ComputerUseExecuting)?
            defer {
                setupTask = nil
                if finishRequestedSetup, !Task.isCancelled, !isShuttingDown {
                    startSetupPipeline()
                }
            }
            do {
                let helperStatus = await macControlInstaller.durableStatus()
                try Task.checkCancellation()
                let native: ComputerUseCapabilityExecutor
                do {
                    native = try await nativeTextPreparer(receipt, tools) { [weak self] detail in
                        self?.consumeRuntimeActivationUpdate(detail)
                    }
                } catch {
                    try Task.checkCancellation()
                    guard !(error is CancellationError), case .ready(let helper) = helperStatus else { throw error }
                    // A missing/changed fallback package cannot disable an
                    // independently verified helper. Do not certify activation
                    // or silently start downloads to repair that package.
                    macControlReceipt = helper
                    let visualReceipt = await installer.currentInstallation()
                    try Task.checkCancellation()
                    let structured = try await executorComposer(helper, deferredVisualExecutor(receipt: visualReceipt))
                    structuredCandidate = structured
                    try Task.checkCancellation()
                    executor = structured
                    modelState = .ready(runtimeName: structured.runtimeName)
                    publishRequestedActivationFailure(error)
                    return
                }
                try Task.checkCancellation()
                var activated: any ComputerUseExecuting = native
                // Fresh missing packages remain optional. Preserve the
                // previous startup recovery policy for an installation that
                // was already explicitly started before this process exited.
                if case .ready(let helper) = helperStatus {
                    macControlReceipt = helper
                    let visualReceipt = await installer.currentInstallation()
                    configureVisualFactory(native, receipt: visualReceipt)
                    let structured = try await executorComposer(helper, native)
                    structuredCandidate = structured
                    activated = structured
                }
                try Task.checkCancellation()
                if native.hasAdditionalSetup {
                    // Capability readiness is not completion of an explicit
                    // full setup request. A request received during this load
                    // must enter the remaining pipeline after its slot clears.
                    if currentSetupProgress?.phase == .ready { currentSetupProgress = nil }
                    let interruptedDesktopSetup: Bool
                    switch helperStatus {
                    case .ready:
                        interruptedDesktopSetup = await installer.interruptedInstallationExists()
                    case .downloadPresent(let bytes, _):
                        interruptedDesktopSetup = bytes > 0
                    case .notInstalled, .repairRequired:
                        interruptedDesktopSetup = false
                    }
                    try Task.checkCancellation()
                    finishRequestedSetup = interruptedDesktopSetup || !setupRecipients.activeRecipients().isEmpty
                }
                // Publish capability state only after every asynchronous
                // package/recovery check has finished. Admission stays closed
                // until this activation slot is released below.
                executor = activated
                modelState = .ready(runtimeName: activated.runtimeName)
                if !native.hasAdditionalSetup {
                    publishSetupProgress(phase: .ready, fraction: 1, detail: native.readyDetail)
                }
            } catch is CancellationError {
                (structuredCandidate as? any MCPApprovalContinuing)?.cancelMCPWork()
                await visualExecutorLoader.deactivate()
                executor = nil
                modelState = .downloadRequired
                publishRequestedActivationFailure(CancellationError())
            } catch {
                (structuredCandidate as? any MCPApprovalContinuing)?.cancelMCPWork()
                await visualExecutorLoader.deactivate()
                executor = nil
                modelState = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                publishRequestedActivationFailure(error)
            }
        }
    }

    private func beginActivation(of receipt: ComputerUseInstallationReceipt) {
        guard allowsExternalServices,
              !isShuttingDown,
              setupTask == nil,
              let helperReceipt = macControlReceipt,
              executor?.isReady != true else { return }
        modelState = .installing(
            detail: "Loading the on-device AI…",
            fraction: 0.98)
        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                executor = nil
                let loaded = try await visualExecutorLoader.load(
                    receipt: receipt,
                    progress: { [weak self] detail in
                        self?.consumeRuntimeActivationUpdate(detail)
                    })
                try Task.checkCancellation()
                modelState = .installing(
                    detail: "Starting verified local Mac tools…",
                    fraction: 0.99)
                let hybrid = try await executorComposer(helperReceipt, loaded)
                try Task.checkCancellation()
                try await installer.recordRuntimeActivationSuccess(for: receipt)
                executor = hybrid
                modelState = .ready(runtimeName: hybrid.runtimeName)
                publishSetupProgress(
                    phase: .ready,
                    fraction: 1,
                    detail: "AI Computer Use is ready")
            } catch is CancellationError {
                await visualExecutorLoader.deactivate()
                executor = nil
                try? await installer.restorePreviousInstallation(
                    afterFailedActivationOf: receipt)
                modelState = .downloadRequired
            } catch {
                await visualExecutorLoader.deactivate()
                executor = nil
                try? await installer.restorePreviousInstallation(
                    afterFailedActivationOf: receipt)
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                modelState = .error(message)
            }
            setupTask = nil
        }
    }

    /// The small signed helper receives a visible 8% phase allocation. Its
    /// byte-count detail remains authoritative while the allocation prevents a
    /// 2.6 MB prerequisite from looking frozen beside the multi-GB model.
    private func consumeMacControlInstallerUpdate(_ update: MacControlMCPInstaller.Update) {
        let base = Self.visibleMacControlInstallerFraction(update)
        let candidate = nativeTextInstaller == nil ? base : 0.45 + 0.5 * base
        consumeProvisioningProgress(
            phase: .installingPackages,
            candidateFraction: candidate,
            detail: update.detail,
            minimumPublishDelta: 0.005,
            forcePublish: update.phase == .ready)
    }

    private func consumeInstallerUpdate(_ update: ComputerUseInstaller.Update, nativeText: Bool = false) {
        let base = Self.visibleModelInstallerFraction(update)
        let visibleFraction = base.map { value in
            nativeText ? value * 0.43
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

    nonisolated static let macControlSetupFraction = 0.08

    nonisolated static func visibleMacControlInstallerFraction(
        _ update: MacControlMCPInstaller.Update
    ) -> Double {
        guard update.fraction.isFinite else { return 0 }
        return min(1, max(0, update.fraction)) * macControlSetupFraction
    }

    nonisolated static func visibleModelInstallerFraction(
        _ update: ComputerUseInstaller.Update
    ) -> Double? {
        guard let internalFraction = visibleInstallerFraction(update) else { return nil }
        let normalized = internalFraction / 0.97
        return macControlSetupFraction
            + normalized * (0.97 - macControlSetupFraction)
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
                    browserClarifications.invalidateAnswerQuestion(reference, for: envelope)
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
                    clarification: taskLedger.terminalClarification(taskID: envelope.id),
                    clarificationRetry: taskLedger.terminalClarificationRetry(taskID: envelope.id))
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
                    if let action = try taskLedger.approvedAction(taskID: envelope.id,
                        senderID: envelope.senderID, sessionID: envelope.sessionID) {
                        let prompt = ComputerUsePromptRequest.decodeCompatibleBody(envelope.body).prompt
                        switch Self.resultForApprovedAction(action, trustedUserPrompt: prompt) {
                        case .completed(let response):
                            sendDurableTerminal(response, outcome: .taskCompleted, replyingTo: envelope, channel: channel)
                        case .unableToComplete(let response):
                            sendDurableTerminal(response, outcome: .unableToComplete, replyingTo: envelope, channel: channel)
                        default: preconditionFailure("Approved action reconciliation must return a bounded terminal disposition")
                        }
                    } else {
                        let response = "That request was received before the host restarted, so it was not run again. Send it as a new request if it is still needed."
                        sendDurableTerminal(response, outcome: .unableToComplete,
                            replyingTo: envelope, channel: channel)
                    }
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
        let browserContinuation: ComputerUseBrowserClarificationTransport.Continuation?
        do {
            if let reference = request.clarification, browserClarifications.matches(reference) {
                guard executor is any ComputerUseBrowserResearchContinuing else {
                    throw ComputerUseBrowserClarificationTransport.Failure.invalidOwner
                }
                browserContinuation = try browserClarifications.consume(reference, answer: request.prompt, for: envelope,
                    retainedOwner: { tools.ownedBrowserResearch(taskID: $0) })
                continuation = nil
            } else if let reference = request.clarification {
                guard let continuing = executor as? any ComputerUseTextClarificationContinuing,
                      let pending = try continuing.clarification(taskID: reference.taskID) else {
                    throw ComputerUseTextClarificationStore.Failure.invalidReference
                }
                let goal = try textClarifications.consume(reference, answer: request.prompt,
                    scope: pending.scope, for: envelope)
                continuation = TextClarificationContinuation(originatingTaskID: reference.taskID, goal: goal)
                browserContinuation = nil
            } else {
                continuation = nil
                browserContinuation = nil
            }
        } catch let rejection as ComputerUseBrowserClarificationTransport.RejectedAnswer
            where request.supportsClarificationRetry && (rejection.retry.reason != .formatMismatch || request.supportsClarificationFormatRetry) {
            sendClarificationRetry(rejection, replyingTo: envelope, channel: channel)
            sendStatus("ready", replyingTo: envelope, channel: channel)
            return
        } catch {
            sendDurableTerminal("I couldn't validate this request or its clarification. Start a new request with the complete instruction.",
                outcome: .unableToComplete, replyingTo: envelope, channel: channel)
            sendStatus("ready", replyingTo: envelope, channel: channel)
            return
        }
        let clarification: String?
        if continuation != nil || browserContinuation != nil {
            clarification = nil
        } else if request.prompt.isEmpty {
            clarification = "What would you like me to do on your Mac?"
        } else {
            clarification = ComputerUseClarificationPolicy.question(for: request)
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
            requestBody: envelope.body,
            textClarification: continuation,
            browserClarification: browserContinuation,
            channel: channel, pendingAutomationID: pendingAutomationID)
    }

    private func beginExecution(
        _ executor: any ComputerUseExecuting,
        for envelope: ComputerUseEnvelope,
        trustedUserPrompt: String,
        conversation: [ComputerUseConversationTurn],
        requestBody: String? = nil,
        textClarification: TextClarificationContinuation? = nil,
        browserClarification: ComputerUseBrowserClarificationTransport.Continuation? = nil,
        browserHandbackRequirement: ComputerUseBrowserHandbackRequirement? = nil,
        channel: any HostComputerUseChannel,
        isResuming: Bool = false,
        pendingAutomationID: UUID? = nil
    ) {
        let context = ExecutionContext(
            envelope: envelope,
            channel: channel,
            trustedUserPrompt: trustedUserPrompt,
            conversation: conversation,
            requestBody: requestBody,
            textClarification: textClarification,
            browserClarification: browserClarification,
            browserHandbackRequirement: browserHandbackRequirement)
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
                let result: ComputerUseExecutionResult
                if let action = try taskLedger.approvedAction(taskID: envelope.id,
                    senderID: envelope.senderID, sessionID: envelope.sessionID) {
                    // Resume joins the previous execution first. Reconcile a
                    // claimed approved effect instead of asking any executor
                    // to reconstruct or repeat this consequential task.
                    result = try await resultAfterApprovedAction(action, executor: executor,
                        context: context, token: token, progress: progress)
                } else {
                    if isResuming {
                        do {
                            if let requirement = context.browserHandbackRequirement {
                                try await tools.reacquireOwnedBrowserAfterUserControl(requirement)
                            }
                            try await tools.resumeOwnedBrowserResearch(taskID: context.envelope.id)
                        } catch {
                            let guidance: String
                            switch error as? ComputerUseBrowserError {
                            case .signInWindowOpen?, .handbackContextLost?, .windowNotActive?, .sourceNotAllowed?:
                                guidance = error.localizedDescription
                            default:
                                guidance = "The AI browser is not ready to continue. Finish signing in or loading the page, then choose Resume."
                            }
                            try await acceptExecutionResult(.userInterventionRequired(
                                guidance),
                                executor: executor, context: context, token: token)
                            return
                        }
                    }
                    try Task.checkCancellation()
                    guard currentExecutionToken == token else { throw CancellationError() }
                    // The requirement protects this handback only. A later
                    // pause captures the session then owned by the same task.
                    context = context.retainingBrowserHandback(nil)
                    currentExecution = context
                    if let browserClarification {
                        guard let continuing = executor as? any ComputerUseBrowserResearchContinuing,
                              tools.ownedBrowserResearch(taskID: browserClarification.owner.taskID) === browserClarification.owner,
                              browserClarification.answerTaskID == envelope.id,
                              browserClarification.owner.executionTaskID == envelope.id,
                              browserClarification.owner.input.digest == browserClarification.inputDigest else {
                            throw ComputerUseBrowserClarificationTransport.Failure.invalidOwner
                        }
                        result = try await continuing.continueBrowserResearch(taskID: envelope.id, research: browserClarification.owner,
                            tools: tools, progress: progress)
                    } else if let textClarification {
                        guard let continuing = executor as? any ComputerUseTextClarificationContinuing else {
                            throw ComputerUseTextClarificationStore.Failure.invalidReference
                        }
                        result = try await continuing.continueClarification(taskID: envelope.id,
                            originatingTaskID: textClarification.originatingTaskID, goal: textClarification.goal, progress: progress)
                    } else {
                        result = try await executor.execute(
                            taskID: envelope.id,
                            modelPrompt: envelope.body,
                            currentUserPrompt: trustedUserPrompt,
                            conversation: conversation,
                            tools: tools,
                            progress: progress)
                    }
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
            } catch let admission as ComputerUseBrowserResearchAdmissionPause {
                guard currentExecutionToken == token else { return }
                // No session may belong to this root yet. Preserve the goal
                // and let explicit Resume retry its current owner admission;
                // an unavailable fabricated handback seal would strand it.
                pauseForLocalIntervention(context, guidance: admission.reason.localizedDescription)
            } catch ComputerUseBrowserError.authenticationRequired {
                guard currentExecutionToken == token else { return }
                pauseForLocalIntervention(context, guidance: ComputerUseBrowserError.authenticationRequired.localizedDescription,
                    requiresBrowserHandback: true)
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
            } catch ComputerUseBrowserError.authenticationRequired {
                postedApprovedVisualTaskID = nil
                guard currentExecutionToken == executionToken else { return }
                cancelActiveVisualApprovalContinuation()
                pauseForLocalIntervention(context, guidance: ComputerUseBrowserError.authenticationRequired.localizedDescription,
                    requiresBrowserHandback: true)
                return
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
            requestBody: context.requestBody,
            textClarification: context.textClarification,
            browserClarification: context.browserClarification,
            channel: context.channel,
            isResuming: true)
    }

    private func continueApprovedMCP(
        _ prepared: MCPPreparedApproval,
        executor: any ComputerUseExecuting,
        context: ExecutionContext
    ) {
        guard let continuation = executor as? any MCPApprovalContinuing else {
            finishApprovedActionFailure(
                MCPClientError.approvalMismatch,
                context: context)
            return
        }

        let evidenceTransportGeneration = transportGeneration
        let evidenceAuthorizationGeneration = actionEvidenceAuthorizationGeneration
        let precedingExecution = executionTask
        precedingExecution?.cancel()
        let token = UUID()
        currentExecution = context
        currentExecutionToken = token
        activity = .working("Performing the one approved Mac action…")
        sendStatus(
            "Performing the one approved Mac action…",
            replyingTo: context.envelope,
            channel: context.channel)

        executionTask = Task { [weak self] in
            guard let self else { return }
            await precedingExecution?.value
            guard !Task.isCancelled,
                  currentExecutionToken == token else { return }
            guard actionGate.allowsActions else {
                pauseAfterApprovedOperationWasBlocked(context: context)
                return
            }
            do {
                let result: ComputerUseExecutionResult
                let claim: ComputerUseTaskLedger.ApprovedActionClaim
                if let plan = try continuation.approvedActionPlan(taskID: context.envelope.id, promptBody: context.requestBody) {
                    claim = try taskLedger.claimApprovedAction(taskID: context.envelope.id,
                        senderID: context.envelope.senderID, sessionID: context.envelope.sessionID,
                        prepared: prepared, plan: plan)
                } else {
                    claim = try taskLedger.claimApprovedAction(taskID: context.envelope.id,
                        senderID: context.envelope.senderID, sessionID: context.envelope.sessionID, prepared: prepared)
                }
                let progress: (String) -> Void = { [weak self] value in
                    guard self?.currentExecutionToken == token else { return }
                    self?.activity = .working(value)
                    self?.sendStatus(value, replyingTo: context.envelope, channel: context.channel)
                }
                switch claim {
                case .existing(let action):
                    result = try await resultAfterApprovedAction(action, executor: executor,
                        context: context, token: token, progress: progress)
                case .new:
                    sendApprovedActionEvidence(for: context, transportGeneration: evidenceTransportGeneration,
                        authorizationGeneration: evidenceAuthorizationGeneration)
                    let confirmation = try await continuation.continueAfterApproval(
                        prepared,
                        tools: tools,
                        progress: { [weak self] value in
                            guard self?.currentExecutionToken == token else { return }
                            self?.activity = .working(value)
                            self?.sendStatus(value, replyingTo: context.envelope, channel: context.channel)
                        })
                    let trustedPromptDigest = try MCPDigest.sha256(of: .string(context.trustedUserPrompt))
                    guard confirmation.callDigest == prepared.call.canonicalDigest,
                          confirmation.completionPromptDigest == nil
                            || confirmation.completionPromptDigest == trustedPromptDigest else {
                        throw MCPClientError.serverMismatch("The approved operation returned a confirmation for another task.")
                    }
                    // Record the exact old task's confirmed effect before
                    // checking its UI token. Stop's first terminal still wins;
                    // a stale completion may not clear or update a newer task.
                    try taskLedger.recordApprovedActionResult(taskID: context.envelope.id,
                        senderID: context.envelope.senderID, sessionID: context.envelope.sessionID,
                        fingerprint: prepared.fingerprint, response: confirmation.response,
                        completionPromptDigest: confirmation.completionPromptDigest)
                    guard let recorded = try taskLedger.approvedAction(taskID: context.envelope.id,
                        senderID: context.envelope.senderID, sessionID: context.envelope.sessionID, fingerprint: prepared.fingerprint) else {
                        throw MCPClientError.serverMismatch("The approved action confirmation could not be retained.")
                    }
                    sendApprovedActionEvidence(for: context, transportGeneration: evidenceTransportGeneration,
                        authorizationGeneration: evidenceAuthorizationGeneration)
                    result = try await resultAfterApprovedAction(recorded, executor: executor,
                        context: context, token: token, progress: progress)
                }
                guard currentExecutionToken == token else { return }
                try await acceptExecutionResult(
                    result,
                    executor: executor,
                    context: context,
                    token: token)
            } catch is CancellationError {
                finishUnexpectedCancellationIfCurrent(
                    context: context,
                    token: token)
                return
            } catch {
                guard currentExecutionToken == token else { return }
                currentExecution = nil
                currentExecutionToken = nil
                executionTask = nil
                finishApprovedActionFailure(error, context: context)
            }
        }
    }

    private static let unconfirmedApprovedActionResponse = "The approved action may already have been performed. I couldn't confirm its result, so I will not repeat it. Check the Mac before starting another request for this action."

    private func resultAfterApprovedAction(_ action: ComputerUseTaskLedger.ApprovedActionRecord,
        executor: any ComputerUseExecuting, context: ExecutionContext, token: UUID,
        progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard action.stepEffectID != nil, action.response != nil else {
            return Self.resultForApprovedAction(action, trustedUserPrompt: context.trustedUserPrompt)
        }
        try Task.checkCancellation()
        guard currentExecutionToken == token, actionGate.allowsActions else { throw CancellationError() }
        let envelope = context.envelope
        guard let continuation = executor as? any MCPApprovalContinuing,
              let plan = try taskLedger.approvedActionPlan(taskID: envelope.id,
                  senderID: envelope.senderID, sessionID: envelope.sessionID),
              try continuation.approvedActionPlan(taskID: envelope.id, promptBody: context.requestBody) == plan else { throw MCPClientError.approvalMismatch }
        let history = try taskLedger.approvedActionHistory(taskID: envelope.id,
            senderID: envelope.senderID, sessionID: envelope.sessionID)
        guard !history.isEmpty, history.count <= plan.steps.count,
              history.last == action,
              zip(history, plan.steps).allSatisfy({ record, step in
                  record.stepEffectID == step.effectID && record.fingerprint.canonicalDigest == step.callDigest
                    && record.response != nil && record.completionPromptDigest == nil
              }) else { throw MCPClientError.approvalMismatch }
        // The confirmed prefix is durable before continuing. An executor may
        // verify outcomes, ask for the next exact approval, or hand control
        // back; it must never reconstruct earlier effects from the prompt.
        let result = try await continuation.continueApprovedActionPlan(taskID: envelope.id,
            confirmedActions: history, tools: tools, progress: progress)
        try Task.checkCancellation()
        guard currentExecutionToken == token, actionGate.allowsActions else { throw CancellationError() }
        switch result {
        case .completed:
            guard history.count == plan.steps.count else { throw MCPClientError.approvalMismatch }
        case .mcpApprovalRequired(let prepared):
            guard history.count < plan.steps.count, prepared.call.taskID == envelope.id,
                  prepared.call.stepEffectID == plan.steps[history.count].effectID,
                  prepared.call.canonicalDigest == plan.steps[history.count].callDigest,
                  prepared.fingerprint == MCPApprovalFingerprint(call: prepared.call) else { throw MCPClientError.approvalMismatch }
        case .unableToComplete, .userInterventionRequired:
            break
        default:
            // A clarification or a different action capability needs an
            // explicit transfer of this retained plan before it can continue.
            throw MCPClientError.approvalMismatch
        }
        return result
    }

    private static func resultForApprovedAction(_ action: ComputerUseTaskLedger.ApprovedActionRecord,
                                               trustedUserPrompt: String) -> ComputerUseExecutionResult {
        if let response = action.response {
            if let proof = action.completionPromptDigest,
               proof == (try? MCPDigest.sha256(of: .string(trustedUserPrompt))) { return .completed(response) }
            return .unableToComplete("The full request remains unverified. I retained this action confirmation and will not repeat it:\n\n" + response)
        }
        return .unableToComplete(unconfirmedApprovedActionResponse)
    }

    private func actionEvidence(for envelope: ComputerUseEnvelope) -> ComputerUseApprovedActionEvidence? {
        guard let action = try? taskLedger.approvedAction(taskID: envelope.id,
            senderID: envelope.senderID, sessionID: envelope.sessionID) else { return nil }
        let summary = action.response.map { response in
            var bounded = "", byteCount = 0
            for character in response.prefix(4_000) {
                let bytes = String(character).utf8.count
                guard byteCount + bytes <= 16_000 else { break }
                bounded.append(character)
                byteCount += bytes
            }
            return bounded.isEmpty ? "The Mac confirmed the approved action." : bounded
        }
        return try? ComputerUseApprovedActionEvidence(actionID: action.fingerprint.canonicalDigest,
            state: action.response == nil ? .unconfirmed : .confirmed,
            summary: summary, resultDigest: action.responseDigest)
    }

    private func sendApprovedActionEvidence(for context: ExecutionContext, transportGeneration: UInt64,
        authorizationGeneration: UInt64) {
        // A late result may annotate its original task while a newer task is
        // active. Check again after queued delivery to fence a later revocation.
        guard context.supportsApprovedActionEvidence,
              self.transportGeneration == transportGeneration,
              actionEvidenceAuthorizationGeneration == authorizationGeneration,
              authorizedPeerID == context.envelope.senderID else { return }
        send(kind: .status, body: "", replyingTo: context.envelope,
            channel: context.channel, isApprovedActionEvidenceOnly: true,
            evidenceDeliveryGeneration: (transportGeneration, authorizationGeneration))
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
        case .browserResearchAnswer(let answer):
            guard executor is any ComputerUseBrowserResearchContinuing,
                  let owner = tools.ownedBrowserResearch(taskID: answer.rootTaskID),
                  owner.executionTaskID == envelope.id else { throw ComputerUseBrowserClarificationTransport.Failure.invalidOwner }
            try owner.validateAnswer(answer)
            // Use the existing durable terminal/first-result-wins path only
            // after the exact retained source answer has been admitted.
            try await acceptExecutionResult(.completed(answer.message), executor: executor, context: context, token: token)
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
            guard context.browserClarification == nil else { throw ComputerUseBrowserClarificationTransport.Failure.invalidOwner }
            let reference: ComputerUseClarificationReference?
            if let pending = try (executor as? any ComputerUseTextClarificationContinuing)?.clarification(taskID: envelope.id) {
                let goal = try context.textClarification?.goal
                    ?? ComputerUseUnresolvedTextGoal(userRequest: context.trustedUserPrompt)
                guard pending.taskID == envelope.id, pending.goal == goal,
                      pending.question.utf8.elementsEqual(response.utf8) else {
                    throw ComputerUseTextClarificationStore.Failure.invalidReference
                }
                reference = try textClarifications.issue(goal: goal, question: response, scope: pending.scope,
                    expiresAt: pending.expiresAt, for: envelope)
            } else {
                guard context.textClarification == nil else { throw ComputerUseTextClarificationStore.Failure.invalidReference }
                reference = nil
            }
            sendDurableTerminal(
                response,
                outcome: .userInterventionRequired,
                replyingTo: envelope,
                channel: context.channel,
                clarification: reference)
            currentExecution = nil
            currentExecutionToken = nil
            executionTask = nil
            actionGate.endAutomation(allowsActions: true)
            activity = .idle
            sendStatus("ready", replyingTo: envelope, channel: context.channel)

        case .browserClarificationRequired(let request):
            guard executor is any ComputerUseBrowserResearchContinuing, context.textClarification == nil,
                  let owner = tools.ownedBrowserResearch(taskID: request.taskID), owner.executionTaskID == envelope.id else {
                throw ComputerUseBrowserClarificationTransport.Failure.invalidOwner
            }
            if let guidance = owner.input.clarificationLimitMessage {
                pauseForLocalIntervention(context, guidance: guidance)
                return
            }
            textClarifications.invalidate()
            (executor as? any ComputerUseTextClarificationContinuing)?.invalidateClarification(taskID: nil)
            let question = try browserClarifications.issue(request, owner: owner, for: envelope)
            try Task.checkCancellation()
            sendDurableTerminal(question.text, outcome: .userInterventionRequired, replyingTo: envelope,
                channel: context.channel, clarification: question.reference)
            currentExecution = nil
            currentExecutionToken = nil
            executionTask = nil
            actionGate.endAutomation(allowsActions: true)
            activity = .idle
            sendStatus("ready", replyingTo: envelope, channel: context.channel)

        case .browserResearchProgress(let report):
            guard executor is any ComputerUseBrowserResearchContinuing,
                  let owner = tools.ownedBrowserResearch(taskID: report.rootTaskID),
                  owner.executionTaskID == envelope.id, let progress = report.progress else {
                throw ComputerUseBrowserClarificationTransport.Failure.invalidOwner
            }
            try owner.validateProgressReport(report)
            pauseForLocalIntervention(context, guidance: report.interventionGuidance, report: progress)

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
            guard continuationToken.taskID == envelope.id,
                  continuationToken.browserPageEvidence.map({ $0.document.taskID == envelope.id }) ?? true,
                  continuationToken.nativeBrowserTarget.map({ $0.pageEvidence == continuationToken.browserPageEvidence && $0.action == proposedAction }) ?? true else {
                continuationExecutor.cancelVisualApprovalContinuation(
                    continuationToken)
                throw VisualApprovalContinuationError.invalidContinuation
            }
            // The visual model's confirmation copy is untrusted. Build the
            // user-facing description and TOCTOU fingerprint from the exact
            // action and host-observed native browser or Accessibility target.
            let prepared: ComputerUsePreparedApproval
            do {
                if let target = continuationToken.nativeBrowserTarget { try await tools.validateOwnedBrowserAgentTarget(target) }
                try Task.checkCancellation()
                guard currentExecutionToken == token else { throw CancellationError() }
                prepared = try tools.prepareApproval(for: proposedAction, nativeTarget: continuationToken.nativeBrowserTarget)
            } catch {
                continuationExecutor.cancelVisualApprovalContinuation(
                    continuationToken)
                throw error
            }
            let request = ComputerUseApprovalRequest(
                taskID: envelope.id,
                message: prepared.message)
            enterApproval(
                PendingApproval(
                    request: request,
                    context: context,
                    operation: .visual(
                        continuation: continuationToken,
                        action: proposedAction,
                        fingerprint: prepared.fingerprint)))

        case .mcpApprovalRequired(let prepared):
            guard prepared.call.taskID == envelope.id else {
                throw MCPClientError.approvalMismatch
            }
            let presentation = prepared.computerUsePresentation
            let request = ComputerUseApprovalRequest(
                taskID: envelope.id,
                message: presentation.message,
                details: presentation.details,
                confirmLabel: presentation.confirmLabel)
            enterApproval(PendingApproval(
                request: request,
                context: context,
                operation: .mcp(prepared)))
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
            cancelApprovalIfNeeded(approval)
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
            evidenceDeliveryGeneration: report == nil ? nil :
                (transport: transportGeneration, authorization: actionEvidenceAuthorizationGeneration))
    }

    /// A terminal reply is authoritative only after its first-result-wins
    /// ledger record reaches durable storage. If that write fails, never emit
    /// the requested result (especially success); report the storage failure
    /// directly and leave the poisoned ledger to reject future retries.
    private func sendClarificationRetry(_ rejection: ComputerUseBrowserClarificationTransport.RejectedAnswer,
                                        replyingTo envelope: ComputerUseEnvelope, channel: any HostComputerUseChannel) {
        guard browserClarifications.retainsRetry(rejection.retry, for: envelope,
            retainedOwner: { tools.ownedBrowserResearch(taskID: $0) }) else {
            sendDurableTerminal("The original question is no longer active. Start a new request with the complete instruction.",
                outcome: .unableToComplete, replyingTo: envelope, channel: channel)
            return
        }
        do {
            let terminal = try taskLedger.complete(taskID: envelope.id, response: rejection.text,
                outcome: .userInterventionRequired, clarificationRetry: rejection.retry)
            send(kind: .assistant, body: terminal.response, replyingTo: envelope, channel: channel,
                outcome: terminal.outcome, clarification: terminal.clarification, clarificationRetry: terminal.clarificationRetry)
        } catch {
            // No answer was accepted and no executor ran. Persistence failure
            // cannot publish an unrecorded retry or consume the original scope.
            send(kind: .assistant, body: Self.terminalPersistenceFailureResponse, replyingTo: envelope,
                channel: channel, outcome: .unableToComplete)
        }
    }

    private func sendDurableTerminal(
        _ response: String,
        outcome: ComputerUseTerminalOutcome,
        replyingTo envelope: ComputerUseEnvelope,
        channel: any HostComputerUseChannel,
        clarification: ComputerUseClarificationReference? = nil
    ) {
        // Only this host's exact retained browser question can carry its
        // original owner across a terminal transport reply. All other results
        // end the current execution, including failed terminal persistence.
        // Origin classification survives a failed liveness check. Otherwise
        // a retired browser question could be stored as an unclassified one.
        let identifiesBrowserQuestion = clarification.map { browserClarifications.matches($0) } ?? false
        let identifiesTextQuestion = clarification.map { textClarifications.matches($0) } ?? false
        let preservesBrowserQuestion = browserClarifications.retainsRegisteredQuestion(clarification, for: envelope,
            retainedOwner: { tools.ownedBrowserResearch(taskID: $0) })
        if !preservesBrowserQuestion { tools.retireOwnedBrowserResearch(taskID: envelope.id) }
        do {
            let terminal = try taskLedger.complete(
                taskID: envelope.id,
                response: response,
                outcome: outcome,
                clarification: clarification,
                clarificationOwner: identifiesBrowserQuestion ? .browser : identifiesTextQuestion ? .text : nil)
            if !preservesBrowserQuestion || terminal.clarification != clarification || terminal.outcome != .userInterventionRequired {
                browserClarifications.invalidate(for: envelope)
                tools.retireOwnedBrowserResearch(taskID: envelope.id)
            }
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
                clarification: terminal.clarification)
        } catch {
            browserClarifications.invalidate(for: envelope)
            tools.retireOwnedBrowserResearch(taskID: envelope.id)
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
        browserClarifications.invalidate()
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
        clarificationRetry: ComputerUseClarificationRetry? = nil,
        researchProgress: ComputerUseResearchProgress? = nil,
        isApprovedActionEvidenceOnly: Bool = false,
        evidenceDeliveryGeneration: (transport: UInt64, authorization: UInt64)? = nil
    ) {
        // Gate every projection of an older unbound result, including Cancel
        // replies with no prompt body. Preserve the durable result for future
        // reconciliation; do not attach its clarification or action evidence.
        let needsIdentityRecovery = taskLedger.requiresPromptIdentityRecovery(taskID: envelope.id)
        let evidence = needsIdentityRecovery ? nil : actionEvidence(for: envelope)
        if isApprovedActionEvidenceOnly && evidence == nil { return }
        let liveRetry = clarificationRetry.flatMap { retry in
            !needsIdentityRecovery && !taskLedger.isCancelled(taskID: envelope.id) && browserClarifications.retainsRetry(retry, for: envelope,
                retainedOwner: { tools.ownedBrowserResearch(taskID: $0) }) ? retry : nil
        }
        let unavailableRetry = clarificationRetry != nil && liveRetry == nil
        let responseBody = needsIdentityRecovery && kind == .assistant ? Self.promptIdentityRecoveryResponse
            : unavailableRetry ? "The original question is no longer active. Start a new request with the complete instruction." : body
        let wireBody: String
        switch kind {
        case .assistant, .status:
            wireBody = (try? ComputerUseTaskUpdate(
                taskID: envelope.id,
                text: responseBody,
                appliedControlRevision: isApprovedActionEvidenceOnly ? nil : taskLedger.appliedControlRevision(
                    taskID: envelope.id),
                hostControlEpoch: isApprovedActionEvidenceOnly ? nil : taskLedger.hostControlEpoch(taskID: envelope.id),
                outcome: (needsIdentityRecovery && kind == .assistant) || unavailableRetry ? .unableToComplete : outcome,
                clarification: needsIdentityRecovery ? nil : clarification,
                clarificationAnswerPolicy: needsIdentityRecovery ? nil : browserClarifications.answerPolicy(for: clarification, envelope: envelope),
                clarificationRetry: liveRetry,
                supportsClarificationRecovery: !needsIdentityRecovery && (clarification != nil || liveRetry != nil),
                approvedActionEvidence: evidence,
                isApprovedActionEvidenceOnly: isApprovedActionEvidenceOnly,
                researchProgress: needsIdentityRecovery ? nil : researchProgress).encodedBody()) ?? responseBody
        default:
            wireBody = body
        }
        let previousDelivery = outboundDeliveryTask
        let guardedGeneration = clarification != nil || clarificationRetry != nil
            ? (transport: transportGeneration, authorization: actionEvidenceAuthorizationGeneration) : evidenceDeliveryGeneration
        let delivery = Task { [weak self] in
            if let previousDelivery { await previousDelivery.value }
            if let guardedGeneration {
                guard let self, self.transportGeneration == guardedGeneration.transport,
                      self.actionEvidenceAuthorizationGeneration == guardedGeneration.authorization,
                      self.authorizedPeerID == envelope.senderID else { return }
            }
            var deliveredBody = wireBody
            if clarification != nil || liveRetry != nil {
                guard let self, let freshBody = self.revalidateClarificationDelivery(wireBody, replyingTo: envelope,
                    question: clarification, retry: liveRetry) else { return }
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
                                                question: ComputerUseClarificationReference?,
                                                retry: ComputerUseClarificationRetry?) -> String? {
        guard let original = try? ComputerUseTaskUpdate.decodeBody(body), original.taskID == envelope.id,
              original.clarification == question, original.clarificationRetry == retry else { return nil }
        let liveQuestion = question.map {
            taskLedger.terminalClarification(taskID: envelope.id) == $0
                && retainsNativeQuestion($0, for: envelope)
        } ?? true
        let liveRetry = retry.map {
            taskLedger.terminalClarificationRetry(taskID: envelope.id) == $0
                && browserClarifications.retainsRetry($0, for: envelope,
                    retainedOwner: { tools.ownedBrowserResearch(taskID: $0) })
        } ?? true
        guard !liveQuestion || !liveRetry else { return body }
        return try? ComputerUseTaskUpdate(taskID: original.taskID,
            text: "The original question is no longer active. Start a new request with the complete instruction.",
            appliedControlRevision: original.appliedControlRevision, hostControlEpoch: original.hostControlEpoch,
            outcome: .unableToComplete, approvedActionEvidence: original.approvedActionEvidence).encodedBody()
    }

    private func retainsNativeQuestion(_ reference: ComputerUseClarificationReference, for envelope: ComputerUseEnvelope) -> Bool {
        let kind = taskLedger.clarificationOwner(taskID: envelope.id)
        if kind != .text, browserClarifications.retainsRegisteredQuestion(reference, for: envelope,
            retainedOwner: { tools.ownedBrowserResearch(taskID: $0) }) { return true }
        guard kind != .browser, textClarifications.matches(reference),
              let native = try? (executor as? any ComputerUseTextClarificationContinuing)?.clarification(taskID: envelope.id) else { return false }
        return textClarifications.retains(reference, native: native, for: envelope)
    }

    private func sendClarificationProbeResult(_ probe: ComputerUseClarificationProbe, replyingTo envelope: ComputerUseEnvelope,
                                              channel: any HostComputerUseChannel) {
        let previousDelivery = outboundDeliveryTask
        let generation = (transport: transportGeneration, authorization: actionEvidenceAuthorizationGeneration)
        let delivery = Task { [weak self] in
            if let previousDelivery { await previousDelivery.value }
            guard let self, self.transportGeneration == generation.transport,
                  self.actionEvidenceAuthorizationGeneration == generation.authorization,
                  self.authorizedPeerID == envelope.senderID else { return }
            // This is a read-only lookup. Never claim a new prompt, change
            // controls, interpret a goal or reconstruct a missing owner.
            let original = self.controlReplyEnvelope(taskID: probe.reference.taskID, basedOn: envelope)
            let available = !self.taskLedger.requiresPromptIdentityRecovery(taskID: probe.reference.taskID)
                && self.taskLedger.terminalClarification(taskID: probe.reference.taskID) == probe.reference
                && self.retainsNativeQuestion(probe.reference, for: original)
            guard let result = try? ComputerUseClarificationProbeResult(probeID: probe.probeID, reference: probe.reference,
                question: available ? self.taskLedger.terminalClarificationText(taskID: probe.reference.taskID) : nil,
                answerPolicy: available ? self.browserClarifications.answerPolicy(for: probe.reference, envelope: original) : nil),
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
