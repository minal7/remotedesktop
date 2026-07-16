import XCTest
import UIKit
@testable import RemoteDesktop

final class InputAndDiscoveryTests: XCTestCase {
    private let hostID = "8A2269A1-A94C-4FA2-BD63-BEAEEA79A97A"

    func test_localHostAdvertisement_roundTripsServiceName() {
        let name = LocalHostAdvertisement.serviceName(hostname: "Studio Mac", code: "123456")
        let parsed = LocalHostAdvertisement.parse(serviceName: name)

        XCTAssertEqual(parsed?.hostname, "Studio Mac")
        XCTAssertEqual(parsed?.code, "123456")
        XCTAssertEqual(parsed?.source, .localNetwork)
    }

    func test_localHostAdvertisement_rejects_invalid_names() {
        XCTAssertNil(LocalHostAdvertisement.parse(serviceName: "Studio Mac"))
        XCTAssertNil(LocalHostAdvertisement.parse(serviceName: "Studio Mac [12ab56]"))
    }

    func test_localHostAdvertisement_identityIncludesPairingCode() {
        let first = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "123456",
            senderID: hostID)
        let second = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "654321",
            senderID: hostID)

        XCTAssertNotEqual(first.id, second.id)
    }

    func test_localHostAdvertisement_enrichesLegacyNameFromValidatedTXTRecord() throws {
        let capability = ComputerUseCapability(
            state: .installing,
            detail: "Downloading AI — 42%")
        let metadata = try XCTUnwrap(LocalHostBonjourMetadata(
            senderID: hostID,
            computerUseCapability: capability))

        let parsed = LocalHostAdvertisement.parse(
            serviceName: "Studio Mac [123456]",
            txtRecordData: metadata.txtRecordData())

        XCTAssertEqual(parsed?.hostname, "Studio Mac")
        XCTAssertEqual(parsed?.code, "123456")
        XCTAssertEqual(parsed?.source, .localNetwork)
        XCTAssertEqual(parsed?.senderID, hostID)
        XCTAssertEqual(parsed?.computerUseCapability, capability)
    }

    func test_localHostAdvertisement_invalidOrFutureTXTRecordFallsBackToLegacyRow() throws {
        let metadata = try XCTUnwrap(LocalHostBonjourMetadata(
            senderID: hostID,
            computerUseCapability: .ready))
        var futureValues = NetService.dictionary(
            fromTXTRecord: metadata.txtRecordData())
        futureValues["v"] = Data("2".utf8)

        let parsed = LocalHostAdvertisement.parse(
            serviceName: "Studio Mac [123456]",
            txtRecordData: NetService.data(fromTXTRecord: futureValues))

        XCTAssertEqual(parsed?.hostname, "Studio Mac")
        XCTAssertNil(parsed?.senderID)
        XCTAssertEqual(parsed?.computerUseCapability, .unavailable)
    }

    func test_localHostDiscovery_retainsCloudKitMergeForLegacyBonjourHosts() throws {
        let local = try XCTUnwrap(LocalHostAdvertisement.parse(
            serviceName: "Studio Mac [123456]"))
        let cloud = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "123456",
            source: .cloudKit,
            senderID: hostID,
            computerUseCapability: .setupRequired)

        let merged = LocalHostDiscovery.mergedHosts(
            localHosts: [local],
            cloudHosts: [cloud])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].source, .localNetwork)
        XCTAssertEqual(merged[0].senderID, hostID)
        XCTAssertEqual(merged[0].computerUseCapability, .setupRequired)
        XCTAssertTrue(merged[0].hasAuthenticatedCloudMatch)
    }

    func test_localHostDiscovery_doesNotTrustBonjourForComputerUseBeforeCloudKitSnapshot() {
        let nearby = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "123456",
            senderID: hostID,
            computerUseCapability: .ready)

        let merged = LocalHostDiscovery.mergedHosts(
            localHosts: [nearby],
            cloudHosts: [])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].source, .localNetwork)
        XCTAssertEqual(merged[0].senderID, hostID)
        XCTAssertEqual(merged[0].computerUseCapability, .ready)
        XCTAssertFalse(merged[0].hasAuthenticatedCloudMatch)
        XCTAssertFalse(merged[0].canOfferComputerUse)
    }

    func test_localHostDiscovery_prefersMonitoredCapabilityOnlyForMatchingIdentity() {
        let local = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "123456",
            senderID: hostID,
            computerUseCapability: ComputerUseCapability(
                state: .installing,
                detail: "Downloading AI — 42%"))
        let matchingCloud = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "123456",
            source: .cloudKit,
            senderID: hostID,
            computerUseCapability: .setupRequired)

        let matching = LocalHostDiscovery.mergedHosts(
            localHosts: [local],
            cloudHosts: [matchingCloud])
        XCTAssertEqual(matching[0].computerUseCapability.state, .installing)
        XCTAssertTrue(matching[0].hasAuthenticatedCloudMatch)

        let conflictingCloud = LocalHostAdvertisement(
            hostname: "Trusted Mac",
            code: "123456",
            source: .cloudKit,
            senderID: "53A8D639-5DE2-4786-BE26-2AC9F853D3B6",
            computerUseCapability: .ready)
        let conflicting = LocalHostDiscovery.mergedHosts(
            localHosts: [local],
            cloudHosts: [conflictingCloud])
        XCTAssertEqual(conflicting.count, 2)
        XCTAssertTrue(conflicting.contains(conflictingCloud))
        XCTAssertTrue(conflicting.contains {
            $0.senderID == self.hostID
                && !$0.hasAuthenticatedCloudMatch
        })
    }

    func test_localHostDiscovery_hidesWrongEnvironmentCodeForSameMac() {
        let developmentBonjour = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "111111",
            senderID: hostID,
            computerUseCapability: .ready)
        let productionBonjour = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "222222",
            senderID: hostID,
            computerUseCapability: .ready)
        let productionCloud = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "222222",
            source: .cloudKit,
            senderID: hostID,
            computerUseCapability: .ready)

        let merged = LocalHostDiscovery.mergedHosts(
            localHosts: [developmentBonjour, productionBonjour],
            cloudHosts: [productionCloud])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].code, productionBonjour.code)
        XCTAssertEqual(merged[0].senderID, productionBonjour.senderID)
        XCTAssertTrue(merged[0].hasAuthenticatedCloudMatch)
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count)
    }

    func test_localHostDiscovery_keepsAuthenticatedSameCodeMacsSeparate() {
        let firstID = "53A8D639-5DE2-4786-BE26-2AC9F853D3B6"
        let secondID = "A917FBE5-0E0C-47F0-A927-D4C4CCF59080"
        let firstCloud = LocalHostAdvertisement(
            hostname: "Office Mac",
            code: "123456",
            source: .cloudKit,
            senderID: firstID,
            computerUseCapability: .ready)
        let secondCloud = LocalHostAdvertisement(
            hostname: "Home Mac",
            code: "123456",
            source: .cloudKit,
            senderID: secondID,
            computerUseCapability: .setupRequired)
        let firstNearby = LocalHostAdvertisement(
            hostname: "Office Mac nearby",
            code: "123456",
            senderID: firstID,
            computerUseCapability: .ready)
        let secondNearby = LocalHostAdvertisement(
            hostname: "Home Mac nearby",
            code: "123456",
            senderID: secondID,
            computerUseCapability: .setupRequired)

        let merged = LocalHostDiscovery.mergedHosts(
            localHosts: [firstNearby, secondNearby],
            cloudHosts: [firstCloud, secondCloud])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(Set(merged.map(\.senderID)), Set([firstID, secondID]))
        XCTAssertEqual(Set(merged.map(\.id)).count, 2)
        XCTAssertTrue(merged.allSatisfy(\.hasAuthenticatedCloudMatch))
        XCTAssertTrue(merged.allSatisfy(\.canOfferComputerUse))
    }

    func test_localHostDiscovery_doesNotLegacyMergeAmbiguousSameCodeHosts() throws {
        let legacy = try XCTUnwrap(LocalHostAdvertisement.parse(
            serviceName: "Nearby Mac [123456]"))
        let firstCloud = LocalHostAdvertisement(
            hostname: "Office Mac",
            code: "123456",
            source: .cloudKit,
            senderID: "53A8D639-5DE2-4786-BE26-2AC9F853D3B6",
            computerUseCapability: .ready)
        let secondCloud = LocalHostAdvertisement(
            hostname: "Home Mac",
            code: "123456",
            source: .cloudKit,
            senderID: "A917FBE5-0E0C-47F0-A927-D4C4CCF59080",
            computerUseCapability: .ready)

        let merged = LocalHostDiscovery.mergedHosts(
            localHosts: [legacy],
            cloudHosts: [firstCloud, secondCloud])

        XCTAssertEqual(merged.count, 3)
        let retainedLegacy = try XCTUnwrap(merged.first {
            $0.source == .localNetwork && $0.senderID == nil
        })
        XCTAssertFalse(retainedLegacy.hasAuthenticatedCloudMatch)
        XCTAssertEqual(
            Set(merged.filter(\.hasAuthenticatedCloudMatch).compactMap(\.senderID)),
            Set([firstCloud.senderID!, secondCloud.senderID!]))
    }

    func test_computerUseCapability_onlyEnablesHonestReadyStates() {
        XCTAssertFalse(ComputerUseCapability.unavailable.isAvailable)
        XCTAssertFalse(ComputerUseCapability.setupRequired.isAvailable)
        XCTAssertTrue(ComputerUseCapability.ready.isAvailable)
        XCTAssertTrue(ComputerUseCapability(
            state: .paused,
            detail: "Paused").isAvailable)
    }

    func test_localHostAdvertisement_carriesComputerUseReadiness() {
        let host = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "123456",
            source: .cloudKit,
            senderID: "HOST-ID",
            computerUseCapability: .ready)

        XCTAssertEqual(host.senderID, "HOST-ID")
        XCTAssertTrue(host.computerUseCapability.isAvailable)
    }

    func test_softKeyboardShortcutMapper_maps_command_c() {
        let mapped = SoftKeyboardShortcutMapper.map("c", baseModifiers: SoftModifier.cmd.mask)

        XCTAssertEqual(mapped?.usage, 0x06)
        XCTAssertEqual(mapped?.modifiers, SoftModifier.cmd.mask)
    }

    func test_softKeyboardShortcutMapper_adds_shift_for_uppercase() {
        let mapped = SoftKeyboardShortcutMapper.map("A", baseModifiers: 0)

        XCTAssertEqual(mapped?.usage, 0x04)
        XCTAssertEqual(mapped?.modifiers, SoftModifier.shift.mask)
    }

    @MainActor
    func test_softKeyboardCapture_forwardsExactTextThroughSessionTransport() throws {
        let transport = RecordingSoftKeyboardTransport()
        let session = SessionModel(transportFactory: { transport })
        session.connect(code: "123456")

        let field = SoftKeyboardCapture.CaptureField(frame: .zero)
        field.session = session

        XCTAssertFalse(field.textField(
            field,
            shouldChangeCharactersIn: NSRange(location: 0, length: 1),
            replacementString: "HUMAN-CONTROL-2468"))

        let payload = try XCTUnwrap(transport.sentPayloads.last)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["t"] as? String, "text")
        XCTAssertEqual(object["s2"] as? String, "HUMAN-CONTROL-2468")
        XCTAssertEqual(object["s"] as? Int, 1)
        XCTAssertEqual(field.text, " ")
    }

    @MainActor
    func test_softKeyboardCapture_exposesHittableDismissAccessory() throws {
        let field = SoftKeyboardCapture.CaptureField(frame: .zero)
        var didDismiss = false
        field.onKeyboardDismiss = { didDismiss = true }

        let toolbar = try XCTUnwrap(field.inputAccessoryView as? UIToolbar)
        let dismissButton = try XCTUnwrap(
            toolbar.items?.compactMap { $0.customView as? UIButton }.first)

        XCTAssertEqual(
            dismissButton.accessibilityIdentifier,
            "computer-use-hide-remote-keyboard")
        XCTAssertEqual(dismissButton.accessibilityLabel, "Hide remote keyboard")
        XCTAssertGreaterThan(dismissButton.intrinsicContentSize.width, 0)
        XCTAssertGreaterThan(toolbar.intrinsicContentSize.height, 0)

        dismissButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(didDismiss)
    }
}

@MainActor
private final class RecordingSoftKeyboardTransport: Transport {
    var onHostHello: (@MainActor (HostHello) -> Void)?
    var onDisplay: (@MainActor (DisplayInfo) -> Void)?
    var onFirstVideoFrame: (@MainActor () -> Void)?
    var onDisconnect: (@MainActor (String) -> Void)?
    private(set) var sentPayloads: [Data] = []

    func connect(pairingCode: String, expectedHostID: String?) async throws {}

    func send(_ message: ControlMessage, seq: UInt32, ts: UInt64) {
        sentPayloads.append(message.encoded(seq: seq, ts: ts))
    }

    func disconnect(reason: String) {}
}
