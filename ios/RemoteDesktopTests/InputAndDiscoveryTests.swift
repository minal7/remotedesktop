import Foundation
import Security
import UIKit
import XCTest
@testable import RemoteDesktop

final class InputAndDiscoveryTests: XCTestCase {
    private let hostID = "8A2269A1-A94C-4FA2-BD63-BEAEEA79A97A"
    private let accountBinding = CloudKitAccountBinding(
        rawValue: String(repeating: "a", count: 64))!

    func test_privacyPolicyURL_isPublishedHTTPSPage() {
        XCTAssertEqual(Config.privacyPolicyURL.scheme, "https")
        XCTAssertEqual(Config.privacyPolicyURL.host, "minal7.github.io")
        XCTAssertEqual(
            Config.privacyPolicyURL.path,
            "/remotedesktop/privacy.html")
    }

    func test_localCloudAccountPairingStatus_mapsEveryResolutionFailure() {
        let mappings: [(
            CloudKitAccountBindingResolutionError,
            LocalCloudAccountPairingStatus
        )] = [
            (.noAccount, .signInRequired),
            (.restricted, .accessRestricted),
            (.temporarilyUnavailable, .temporarilyUnavailable),
            (.couldNotDetermine, .couldNotDetermine),
        ]

        for (resolution, expected) in mappings {
            XCTAssertEqual(
                LocalCloudAccountPairingStatus.updated(
                    after: .failed(resolution),
                    hasUsableAuthenticatedSnapshot: false),
                expected)
        }
    }

    func test_localCloudAccountPairingStatus_clearsOnBindingAndKeepsTransientSnapshotUsable() {
        var status = LocalCloudAccountPairingStatus.updated(
            after: .failed(.noAccount),
            hasUsableAuthenticatedSnapshot: false)
        XCTAssertEqual(status, .signInRequired)

        status = LocalCloudAccountPairingStatus.updated(
            after: .bound,
            hasUsableAuthenticatedSnapshot: false)
        XCTAssertNil(status)

        for transient in [
            CloudKitAccountBindingResolutionError.temporarilyUnavailable,
            .couldNotDetermine,
        ] {
            XCTAssertNil(LocalCloudAccountPairingStatus.updated(
                after: .failed(transient),
                hasUsableAuthenticatedSnapshot: true))
        }
    }

    func test_localCloudAccountPairingStatus_secureStorageFailureIsActionable() {
        let status = LocalCloudAccountPairingStatus.updated(
            after: .secureStorageUnavailable,
            hasUsableAuthenticatedSnapshot: false)

        XCTAssertEqual(status, .secureStorageUnavailable)
        XCTAssertTrue(status?.title.contains("Secure pairing storage") == true)
        XCTAssertTrue(status?.guidance.contains("Restart this app") == true)
        XCTAssertTrue(status?.guidance.contains("pairing stays disabled") == true)
    }

    func test_localCloudAccountPairingStatus_copyIsBoundedConfigurationNeutralAndSecretFree() {
        let forbiddenFragments = [
            hostID,
            "123456",
            accountBinding.rawValue,
            Config.cloudKitContainerIdentifier,
            "CloudKit",
            "Debug",
            "Release",
            "Development",
            "Production",
        ]

        for status in LocalCloudAccountPairingStatus.allCases {
            XCTAssertLessThanOrEqual(status.title.utf8.count, 64)
            XCTAssertLessThanOrEqual(status.guidance.utf8.count, 192)
            let copy = "\(status.title) \(status.guidance)"
            for (index, forbidden) in forbiddenFragments.enumerated() {
                XCTAssertFalse(
                    copy.localizedCaseInsensitiveContains(forbidden),
                    "User-facing account guidance exposed forbidden fragment \(index)")
            }
        }
    }

    func test_localHostAdvertisement_roundTripsServiceName() {
        let name = LocalHostAdvertisement.legacyServiceName(
            hostname: "Studio Mac",
            code: "123456")
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

    func test_localHostAdvertisement_readsRoutingBindingWithoutVisibleCode() throws {
        let metadata = try XCTUnwrap(LocalHostBonjourMetadata(
            senderID: hostID,
            computerUseCapability: .ready,
            routingBinding: "123456"))

        let parsed = LocalHostAdvertisement.parse(
            serviceName: "Studio Mac",
            txtRecordData: metadata.txtRecordData())

        XCTAssertEqual(parsed?.hostname, "Studio Mac")
        XCTAssertEqual(parsed?.code, "123456")
        XCTAssertEqual(parsed?.senderID, hostID)
        XCTAssertFalse(parsed?.hasAuthenticatedCloudMatch == true)
    }

    func test_hostnameOnlyBonjourBrowseWaitsForResolvedTXTAndEndpoint() throws {
        let serviceName = "Studio Mac"
        XCTAssertNil(LocalHostAdvertisement.parse(
            serviceName: serviceName,
            txtRecordData: nil))
        XCTAssertTrue(
            LocalHostAdvertisement.shouldResolveBonjourService(
                serviceName: serviceName,
                txtRecordData: nil),
            "a PTR-only browse result must be retained for TXT/SRV resolution")

        let metadata = try XCTUnwrap(LocalHostBonjourMetadata(
            senderID: hostID,
            computerUseCapability: .ready,
            localCredentialID: String(repeating: "b", count: 64),
            routingBinding: "123456"))
        let endpoint = LocalComputerUseEndpoint(
            host: "studio-mac.local.",
            port: 54_321)
        let resolved = try XCTUnwrap(LocalHostAdvertisement.parse(
            serviceName: serviceName,
            txtRecordData: metadata.txtRecordData(),
            localEndpoint: endpoint))

        XCTAssertEqual(resolved.code, "123456")
        XCTAssertEqual(resolved.senderID, hostID)
        XCTAssertEqual(resolved.localEndpoint, endpoint)
        XCTAssertEqual(
            resolved.localCredentialID,
            String(repeating: "b", count: 64))
        XCTAssertFalse(resolved.hasAuthenticatedCloudMatch)
    }

    func test_localHostAdvertisement_rejectsMalformedPlainNameRoutingMetadata() throws {
        let metadata = try XCTUnwrap(LocalHostBonjourMetadata(
            senderID: hostID,
            computerUseCapability: .ready,
            routingBinding: "123456"))
        var values = NetService.dictionary(
            fromTXTRecord: metadata.txtRecordData())
        values["rb"] = Data("12ab56".utf8)

        XCTAssertNil(LocalHostAdvertisement.parse(
            serviceName: "Studio Mac",
            txtRecordData: NetService.data(fromTXTRecord: values)))
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
            computerUseCapability: .setupRequired,
            accountBinding: accountBinding)

        let merged = LocalHostDiscovery.mergedHosts(
            localHosts: [local],
            cloudHosts: [cloud])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].source, .localNetwork)
        XCTAssertEqual(merged[0].senderID, hostID)
        XCTAssertEqual(merged[0].computerUseCapability, .setupRequired)
        XCTAssertTrue(merged[0].hasAuthenticatedCloudMatch)
        XCTAssertEqual(merged[0].accountBinding, accountBinding)
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

        XCTAssertTrue(merged.isEmpty)
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
        XCTAssertEqual(conflicting.count, 1)
        XCTAssertTrue(conflicting.contains(conflictingCloud))
        XCTAssertFalse(conflicting.contains { $0.senderID == self.hostID })
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

    func test_sameNameHostsExposeDistinctNonSecretPresentationIdentities() {
        let first = LocalHostAdvertisement(
            hostname: "MacBook Pro",
            code: "123456",
            source: .cloudKit,
            senderID: "53A8D639-5DE2-4786-BE26-2AC9F853D3B6",
            computerUseCapability: .ready)
        let second = LocalHostAdvertisement(
            hostname: "MacBook Pro",
            code: "654321",
            source: .cloudKit,
            senderID: "A917FBE5-0E0C-47F0-A927-D4C4CCF59080",
            computerUseCapability: .ready)

        XCTAssertEqual(first.hostname, second.hostname)
        XCTAssertNotEqual(
            first.presentationDiscriminator,
            second.presentationDiscriminator)
        XCTAssertNotEqual(
            first.accessibilityDisplayName,
            second.accessibilityDisplayName)
        XCTAssertFalse(first.accessibilityDisplayName.contains(first.code))
        XCTAssertFalse(second.accessibilityDisplayName.contains(second.code))
        XCTAssertFalse(
            first.accessibilityDisplayName.contains(first.senderID!))
        XCTAssertFalse(
            second.accessibilityDisplayName.contains(second.senderID!))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.senderID, "53A8D639-5DE2-4786-BE26-2AC9F853D3B6")
        XCTAssertEqual(second.senderID, "A917FBE5-0E0C-47F0-A927-D4C4CCF59080")
    }

    func test_localHostDiscoveryOrderingIsStableAcrossCaseEquivalentPermutations() {
        let upper = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "123456",
            source: .cloudKit,
            senderID: "10000000-0000-4000-8000-000000000001",
            computerUseCapability: .ready)
        let lower = LocalHostAdvertisement(
            hostname: "studio mac",
            code: "123456",
            source: .cloudKit,
            senderID: "10000000-0000-4000-8000-000000000002",
            computerUseCapability: .ready)
        let sameNameFirstID = LocalHostAdvertisement(
            hostname: "Work Mac",
            code: "111111",
            source: .cloudKit,
            senderID: "20000000-0000-4000-8000-000000000001",
            computerUseCapability: .ready)
        let sameNameSecondID = LocalHostAdvertisement(
            hostname: "Work Mac",
            code: "111111",
            source: .cloudKit,
            senderID: "20000000-0000-4000-8000-000000000002",
            computerUseCapability: .ready)
        let sameNameLaterCode = LocalHostAdvertisement(
            hostname: "Work Mac",
            code: "222222",
            source: .cloudKit,
            senderID: "20000000-0000-4000-8000-000000000003",
            computerUseCapability: .ready)
        let expected = [
            upper.id,
            lower.id,
            sameNameFirstID.id,
            sameNameSecondID.id,
            sameNameLaterCode.id,
        ]
        let permutations = [
            [
                lower, sameNameLaterCode, upper, sameNameSecondID,
                sameNameFirstID,
            ],
            [
                sameNameFirstID, upper, sameNameSecondID, lower,
                sameNameLaterCode,
            ],
            [
                sameNameLaterCode, sameNameSecondID, sameNameFirstID,
                lower, upper,
            ],
        ]

        for cloudHosts in permutations {
            let merged = LocalHostDiscovery.mergedHosts(
                localHosts: [],
                cloudHosts: cloudHosts)
            XCTAssertEqual(merged.map(\.id), expected)

            // Selecting the lower-case row by its stable row identity must
            // retain that exact authenticated Mac, even though its visible name
            // compares case-insensitively equal to another row.
            let selected = merged.first { $0.id == lower.id }
            XCTAssertEqual(selected?.senderID, lower.senderID)
            XCTAssertEqual(selected?.code, lower.code)
            XCTAssertEqual(selected?.hostname, lower.hostname)
        }
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

        XCTAssertEqual(merged.count, 2)
        XCTAssertFalse(merged.contains { $0.source == .localNetwork })
        XCTAssertEqual(
            Set(merged.filter(\.hasAuthenticatedCloudMatch).compactMap(\.senderID)),
            Set([firstCloud.senderID!, secondCloud.senderID!]))
    }

    func test_localHostAdvertisement_requiresCompleteValidatedLocalRoute() {
        let endpoint = LocalComputerUseEndpoint(
            host: "studio-mac.local.",
            port: 54_321)
        let base = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "123456",
            senderID: hostID,
            computerUseCapability: .ready,
            hasAuthenticatedCloudMatch: true,
            accountBinding: accountBinding,
            localEndpoint: endpoint,
            localCredentialID: String(repeating: "b", count: 64))
        XCTAssertTrue(base.canOfferLocalComputerUse)

        let malformedCredential = LocalHostAdvertisement(
            hostname: base.hostname,
            code: base.code,
            senderID: base.senderID,
            computerUseCapability: base.computerUseCapability,
            hasAuthenticatedCloudMatch: true,
            accountBinding: accountBinding,
            localEndpoint: endpoint,
            localCredentialID: "NOT-A-SHA256-SELECTOR")
        XCTAssertFalse(malformedCredential.canOfferLocalComputerUse)

        let invalidEndpoint = LocalHostAdvertisement(
            hostname: base.hostname,
            code: base.code,
            senderID: base.senderID,
            computerUseCapability: base.computerUseCapability,
            hasAuthenticatedCloudMatch: true,
            accountBinding: accountBinding,
            localEndpoint: LocalComputerUseEndpoint(
                host: "studio-mac.local.",
                port: 0),
            localCredentialID: base.localCredentialID)
        XCTAssertFalse(invalidEndpoint.canOfferLocalComputerUse)
    }

    func test_localHostDiscovery_deterministicallySelectsCompleteDuplicateRoute() {
        let credentialID = String(repeating: "b", count: 64)
        let cloud = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "123456",
            source: .cloudKit,
            senderID: hostID,
            computerUseCapability: .ready,
            accountBinding: accountBinding)
        let incomplete = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "123456",
            senderID: hostID,
            computerUseCapability: .ready)
        let laterEndpoint = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "123456",
            senderID: hostID,
            computerUseCapability: .ready,
            localEndpoint: LocalComputerUseEndpoint(
                host: "zulu.local.",
                port: 44_444),
            localCredentialID: credentialID)
        let expectedEndpoint = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "123456",
            senderID: hostID,
            computerUseCapability: .ready,
            localEndpoint: LocalComputerUseEndpoint(
                host: "alpha.local.",
                port: 55_555),
            localCredentialID: credentialID)
        let permutations = [
            [incomplete, laterEndpoint, expectedEndpoint],
            [expectedEndpoint, incomplete, laterEndpoint],
            [laterEndpoint, expectedEndpoint, incomplete],
        ]

        for localHosts in permutations {
            let merged = LocalHostDiscovery.mergedHosts(
                localHosts: localHosts,
                cloudHosts: [cloud])
            XCTAssertEqual(merged.count, 1)
            XCTAssertEqual(
                merged[0].localEndpoint,
                expectedEndpoint.localEndpoint)
            XCTAssertEqual(merged[0].localCredentialID, credentialID)
            XCTAssertTrue(merged[0].canOfferLocalComputerUse)
        }
    }

    func test_nearbyServiceStore_removesSameNameServiceByObjectIdentity() throws {
        let first = NetService(
            domain: "local.",
            type: LocalHostAdvertisement.serviceType,
            name: "Studio Mac",
            port: 44_444)
        let second = NetService(
            domain: "local.",
            type: LocalHostAdvertisement.serviceType,
            name: "Studio Mac",
            port: 55_555)
        let firstHost = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "111111")
        let secondHost = LocalHostAdvertisement(
            hostname: "Studio Mac",
            code: "222222")
        var store = LocalHostNearbyServiceStore()

        store.retain(first)
        store.retain(second)
        XCTAssertTrue(store.setAdvertisement(firstHost, for: first))
        XCTAssertTrue(store.setAdvertisement(secondHost, for: second))
        XCTAssertEqual(store.instances.count, 2)
        XCTAssertEqual(Set(store.hosts.map(\.code)), Set(["111111", "222222"]))

        let removed = try XCTUnwrap(store.remove(first))
        XCTAssertTrue(removed === first)
        XCTAssertFalse(store.contains(first))
        XCTAssertTrue(store.contains(second))
        XCTAssertEqual(store.instances.count, 1)
        XCTAssertEqual(store.hosts, [secondHost])
        XCTAssertNil(store.remove(first))
    }

    func test_deviceIdentityResolver_serializesConcurrentFirstCreation() {
        let expected = "8A2269A1-A94C-4FA2-BD63-BEAEEA79A97A"
        let storage = TestDeviceIdentityStorage()
        let resolver = DeviceIdentityResolver(
            read: storage.read,
            write: storage.write,
            generate: { expected })
        let results = LockedStringResults()

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            results.append(resolver.get())
        }

        XCTAssertEqual(Set(results.snapshot()), Set([expected]))
        XCTAssertEqual(storage.snapshot().readCount, 1)
        XCTAssertEqual(storage.snapshot().writeCount, 1)
        XCTAssertEqual(storage.snapshot().value, expected)
    }

    func test_deviceIdentityResolver_writeFailureIsStickyAndFailsClosed() {
        let storage = TestDeviceIdentityStorage(
            writeMode: .fail(OSStatus(-34_018)))
        let resolver = DeviceIdentityResolver(
            read: storage.read,
            write: storage.write,
            generate: { "8A2269A1-A94C-4FA2-BD63-BEAEEA79A97A" })

        XCTAssertEqual(resolver.get(), "")
        XCTAssertEqual(resolver.get(), "")
        XCTAssertEqual(storage.snapshot().readCount, 1)
        XCTAssertEqual(storage.snapshot().writeCount, 1)
        XCTAssertNil(storage.snapshot().value)
    }

    func test_deviceIdentityResolver_adoptsValidatedCrossProcessWinner() {
        let winner = "A917FBE5-0E0C-47F0-A927-D4C4CCF59080"
        let storage = TestDeviceIdentityStorage(
            writeMode: .duplicate(winner: winner))
        let resolver = DeviceIdentityResolver(
            read: storage.read,
            write: storage.write,
            generate: { "8A2269A1-A94C-4FA2-BD63-BEAEEA79A97A" })

        XCTAssertEqual(resolver.get(), winner)
        XCTAssertEqual(storage.snapshot().readCount, 2)
        XCTAssertEqual(storage.snapshot().writeCount, 1)
    }

    func test_deviceIdentityResolver_rejectsMalformedDurableIdentity() {
        let storage = TestDeviceIdentityStorage(initialValue: "not-a-uuid")
        let resolver = DeviceIdentityResolver(
            read: storage.read,
            write: storage.write,
            generate: { "8A2269A1-A94C-4FA2-BD63-BEAEEA79A97A" })

        XCTAssertEqual(resolver.get(), "")
        XCTAssertEqual(storage.snapshot().readCount, 1)
        XCTAssertEqual(storage.snapshot().writeCount, 0)
        XCTAssertEqual(storage.snapshot().value, "not-a-uuid")
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

private final class LockedStringResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class TestDeviceIdentityStorage: @unchecked Sendable {
    enum WriteMode {
        case store
        case fail(OSStatus)
        case duplicate(winner: String)
    }

    struct Snapshot {
        let value: String?
        let readCount: Int
        let writeCount: Int
    }

    init(
        initialValue: String? = nil,
        writeMode: WriteMode = .store
    ) {
        value = initialValue
        self.writeMode = writeMode
    }

    func read() -> DeviceIdentityStorageRead {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        guard let value else { return .missing }
        return .value(value)
    }

    func write(_ candidate: String) -> DeviceIdentityStorageWrite {
        lock.lock()
        defer { lock.unlock() }
        writeCount += 1
        switch writeMode {
        case .store:
            value = candidate
            return .stored
        case .fail(let status):
            return .failed(status)
        case .duplicate(let winner):
            value = winner
            return .duplicate
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            value: value,
            readCount: readCount,
            writeCount: writeCount)
    }

    private let lock = NSLock()
    private let writeMode: WriteMode
    private var value: String?
    private var readCount = 0
    private var writeCount = 0
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
