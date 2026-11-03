import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Detects the exact macOS system sheet shown when RemoteDesktopHost requests
/// direct screen-and-audio capture. The same deterministic matcher consumes a
/// bounded Accessibility slice first and locally recognized pixels second.
/// It intentionally recognizes no generic permission wording: the host name,
/// private-window-picker request, screen/audio scope, and both system choices
/// must agree before manual takeover is requested. Either of the prompt's two
/// screen/audio clauses is sufficient so one missed OCR line cannot expose the
/// secure sheet to model inference.
enum ComputerUseScreenCaptureConsentDetector {
    static func materializedRecognitionImage(_ image: CIImage) throws -> CIImage {
        let extent = image.extent
        guard extent.origin.x.isFinite, extent.origin.y.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.origin.x.rounded() == extent.origin.x,
              extent.origin.y.rounded() == extent.origin.y,
              extent.width.rounded() == extent.width,
              extent.height.rounded() == extent.height,
              extent.width > 0, extent.height > 0,
              extent.width < CGFloat(Int.max), extent.height < CGFloat(Int.max) else {
            throw NSError(domain: "ComputerUseScreenCaptureConsentDetector", code: 1)
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw NSError(domain: "ComputerUseScreenCaptureConsentDetector", code: 2)
        }
        // Use a standard full-size bitmap backing for Vision's direct
        // Core Graphics image input; preserve all captured pixels.
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let bitmap = context.createCGImage(image, from: extent,
            format: .RGBA8, colorSpace: colorSpace),
              bitmap.width == Int(extent.width), bitmap.height == Int(extent.height) else {
            throw NSError(domain: "ComputerUseScreenCaptureConsentDetector", code: 3)
        }
        return CIImage(cgImage: bitmap)
    }

    static func requiresUserIntervention(
        _ snapshot: ComputerUseAuthenticationContextSnapshot
    ) -> Bool {
        requiresUserIntervention(inRecognizedText: [
            snapshot.focusedElement,
            snapshot.boundedWindowContext,
        ].compactMap { $0 }.joined(separator: "\n"))
    }

    static func requiresUserIntervention(from image: CIImage) throws -> Bool {
        let recognitionImage = try materializedRecognitionImage(image)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        guard let bitmap = recognitionImage.cgImage else {
            throw NSError(domain: "ComputerUseScreenCaptureConsentDetector", code: 4)
        }
        let handler = VNImageRequestHandler(cgImage: bitmap, options: [:])
        try handler.perform([request])

        let visibleText = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }.joined(separator: " ")
        return requiresUserIntervention(inRecognizedText: visibleText)
    }

    static func requiresUserIntervention(
        inRecognizedText text: String
    ) -> Bool {
        let normalized = normalizedWords(text)
        let identifiesHost = normalized.contains(" remotedesktophost ")
            || normalized.contains(" remote desktop host ")
        let requestsPrivatePickerBypass =
            normalized.contains(" bypass the system private window picker ")
            || (normalized.contains(" bypass ")
                && normalized.contains(" private window picker "))
        let requestsDirectScreenAccess =
            normalized.contains(" directly access your screen and audio ")
            || (normalized.contains(" directly access ")
                && normalized.contains(" screen and audio "))
        let statesCaptureConsequence =
            normalized.contains(" record your screen and system audio ")
            || (normalized.contains(" record your screen ")
                && normalized.contains(" system audio "))
        let statesScreenAndAudioScope = requestsDirectScreenAccess
            || statesCaptureConsequence
        let exposesSystemChoices = normalized.contains(" allow ")
            && normalized.contains(" open system settings ")
        return identifiesHost
            && requestsPrivatePickerBypass
            && statesScreenAndAudioScope
            && exposesSystemChoices
    }

    private static func normalizedWords(_ value: String) -> String {
        " " + value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar)
                ? Character(scalar) : " "
        }.split(whereSeparator: \.isWhitespace).joined(separator: " ") + " "
    }
}

/// Detects only high-confidence authentication barriers from a bounded,
/// value-redacted Accessibility snapshot. A focused credential field is
/// sufficient. Otherwise a sign-in/verification heading must be accompanied
/// by at least two independent provider or credential signals. A lone Sign In
/// label or ordinary prose about passwords is deliberately insufficient.
enum ComputerUseAuthenticationBarrierDetector {
    static func requiresUserIntervention(
        _ snapshot: ComputerUseAuthenticationContextSnapshot
    ) -> Bool {
        let focused = normalizedWords(snapshot.focusedElement ?? "")
        let hasFocusedEditableRole = [
            " axtextfield ",
            " axtextarea ",
            " text field ",
            " text area ",
        ].contains(where: focused.contains)
        let isFocusedSecureField = focused.contains(" axsecuretextfield ")
            || focused.contains(" secure text field ")
        let focusedCredentialMarkers = [
            " password ",
            " passcode ",
            " verification code ",
            " verification field ",
            " one time code ",
            " one time password ",
            " otp ",
            " two factor code ",
            " authentication code ",
            " security code ",
        ]
        if isFocusedSecureField
            || (hasFocusedEditableRole
                && focusedCredentialMarkers.contains(where: focused.contains)) {
            return true
        }

        let contextEntries = [snapshot.focusedElement]
            .compactMap { $0 }
            + snapshot.boundedWindowContext
                .components(separatedBy: .newlines)
        let normalizedEntries = contextEntries.map(normalizedWords)
        let context = normalizedEntries.joined(separator: " ")
        let hasStructuralAccountChooserHeading = normalizedEntries.contains { entry in
            let structuralRole = [" axheading ", " axdialog ", " axwindow "]
                .contains(where: entry.contains)
            let chooserText = [" choose an account ", " pick an account ", " select an account "]
                .contains(where: entry.contains)
            return structuralRole && chooserText
        }
        if hasStructuralAccountChooserHeading,
           normalizedEntries.contains(where: { entry in
               let actionable = entry.contains(" axlink ") || entry.contains(" axbutton ")
               return actionable && (entry.contains(" signed out ") || entry.contains(" use another account "))
           }) {
            return true
        }

        let hasAuthenticationHeading = [
            " sign in ",
            " sign into ",
            " sign up ",
            " log in ",
            " login ",
            " authenticate ",
            " verify your account ",
            " account verification ",
        ].contains(where: context.contains)
        guard hasAuthenticationHeading else { return false }

        // Signal words in a help article are not an authentication barrier.
        // Providers must label actionable controls; credential terms must
        // label editable/secure controls. The heading may remain static text.
        let providerControls = normalizedEntries.filter { entry in
            entry.contains(" axbutton ")
                || entry.contains(" axlink ")
                || entry.contains(" axradiobutton ")
        }
        let credentialControls = normalizedEntries.filter { entry in
            entry.contains(" axtextfield ")
                || entry.contains(" axtextarea ")
                || entry.contains(" axsecuretextfield ")
                || entry.contains(" axcombobox ")
                || entry.contains(" text field ")
                || entry.contains(" text area ")
        }
        func hasSignal(_ phrases: [String], in entries: [String]) -> Bool {
            entries.contains { entry in
                phrases.contains(where: entry.contains)
            }
        }
        let providerSignalGroups: [[String]] = [
            [" continue with google ", " sign in with google "],
            [" continue with apple ", " sign in with apple "],
            [" continue with microsoft ", " sign in with microsoft "],
            [" continue with facebook ", " sign in with facebook "],
            [" continue with github ", " sign in with github "],
            [" single sign on ", " sso "],
        ]
        let credentialSignalGroups: [[String]] = [
            [" email ", " email address ", " email required ", " username "],
            [" password ", " passcode ", " passkey "],
            [
                " verification code ", " one time code ",
                " one time password ", " otp ", " two factor ",
            ],
        ]
        let signalCount = providerSignalGroups.reduce(into: 0) {
            if hasSignal($1, in: providerControls) { $0 += 1 }
        } + credentialSignalGroups.reduce(into: 0) {
            if hasSignal($1, in: credentialControls) { $0 += 1 }
        }
        return signalCount >= 2
    }

    private static func normalizedWords(_ value: String) -> String {
        " " + value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }.split(whereSeparator: \.isWhitespace).joined(separator: " ") + " "
    }
}
