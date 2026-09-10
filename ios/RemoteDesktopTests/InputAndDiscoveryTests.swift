import Foundation
import CloudKit
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
        let session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        session.connect(code: "123456")
        transport.makeScreenReady()

        let field = SoftKeyboardCapture.CaptureField(frame: .zero)
        let keyboardWindow = try RemoteKeyboardTestWindow()
        defer { keyboardWindow.close() }
        try keyboardWindow.focus(field, in: session)

        field.insertText("HUMAN-CONTROL-2468")

        let payload = try XCTUnwrap(transport.sentPayloads.last)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["t"] as? String, "text")
        XCTAssertEqual(object["s2"] as? String, "HUMAN-CONTROL-2468")
        XCTAssertEqual(object["s"] as? Int, 2)
        XCTAssertEqual(field.text, "")
    }

    @MainActor
    func test_softKeyboardCaptureRejectsRetiredBindingUntilExplicitRebind() throws {
        let transport = RecordingSoftKeyboardTransport(), session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        session.connect(code: "123456"); transport.makeScreenReady()
        let field = SoftKeyboardCapture.CaptureField(frame: .zero)
        let keyboardWindow = try RemoteKeyboardTestWindow()
        defer { keyboardWindow.close() }
        try keyboardWindow.focus(field, in: session)
        XCTAssertTrue(field.canSendInput)
        session.toggleSoftModifier(.cmd)
        transport.onInputUnavailable?()
        let count = transport.sentPayloads.count
        field.deleteBackward()
        field.insertText("old text")
        XCTAssertEqual(transport.sentPayloads.count, count); XCTAssertFalse(field.canSendInput)
        transport.makeScreenReady()
        let afterHandshake = transport.sentPayloads.count
        field.deleteBackward()
        field.insertText("late old text")
        XCTAssertEqual(transport.sentPayloads.count, afterHandshake)
        field.bindSession(session)
        XCTAssertFalse(field.canSendInput, "A retired native text input object cannot acquire a new generation")
        let replacement = SoftKeyboardCapture.CaptureField(frame: .zero)
        try keyboardWindow.focus(replacement, in: session)
        XCTAssertTrue(replacement.canSendInput); XCTAssertEqual(session.softModifierMask, 0)
        let expected = "  e\u{301} 😀\n"
        field.insertText("late native commit")
        XCTAssertEqual(transport.sentPayloads.count, afterHandshake)
        replacement.insertText(expected)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(transport.sentPayloads.last)) as? [String: Any])
        XCTAssertEqual(object["t"] as? String, "text"); XCTAssertEqual(object["s2"] as? String, expected)
    }

    @MainActor
    func test_softKeyboardProposedEditsDoNotSendUntilNativeCommit() throws {
        let (transport, session, field, keyboardWindow) = try makeCompositionFixture()
        defer { keyboardWindow.close(); field.stopCapture(); session.reset() }
        XCTAssertTrue(field.textField(field, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "proposed"))
        XCTAssertEqual(try inputSourceTrace(transport), [])
        XCTAssertFalse(field.textField(field, shouldChangeCharactersIn: NSRange(location: NSNotFound, length: 0), replacementString: "invalid"))
        XCTAssertFalse(field.textField(field, shouldChangeCharactersIn: NSRange(location: 0, length: 1), replacementString: "invalid"))
        XCTAssertFalse(field.textField(UITextField(), shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "foreign"))
        for value in ["A", "  e\u{301} 😀\n", "東京", " "] { field.insertText(value) }
        XCTAssertEqual(try inputSourceTrace(transport), ["text:A", "text:  e\u{301} 😀\n", "text:東京", "text: "])
        XCTAssertEqual(field.text, "")
    }

    @MainActor
    func test_softKeyboardCompositionCommitsOnceAndKeepsLocalDeleteAndReturnLocal() throws {
        let (transport, session, field, keyboardWindow) = try makeCompositionFixture()
        defer { keyboardWindow.close(); field.stopCapture(); session.reset() }
        field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(field.markedTextRange)
        field.deleteBackward()
        XCTAssertEqual(try inputSourceTrace(transport), [], "Delete edits the local composition")
        field.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(try inputSourceTrace(transport), [])
        XCTAssertFalse(field.textFieldShouldReturn(field))
        XCTAssertEqual(try inputSourceTrace(transport), ["text:你"], "Confirmation must not submit the remote form")
        field.unmarkText()
        XCTAssertEqual(try inputSourceTrace(transport), ["text:你"], "A repeated unmark has no new content")
        XCTAssertEqual(field.text, ""); XCTAssertNil(field.markedTextRange)
        XCTAssertFalse(field.textFieldShouldReturn(field))
        XCTAssertEqual(try inputSourceTrace(transport), ["text:你", "key:40:true:0", "key:40:false:0"])
        field.setMarkedText("e\u{301}", selectedRange: NSRange(location: 2, length: 0))
        field.unmarkText()
        XCTAssertEqual(try inputSourceTrace(transport).last, "text:e\u{301}")
    }

    @MainActor
    func test_softKeyboardCompositionIsDiscardedAcrossRetirementAndFocusLoss() throws {
        for boundary in ["focus", "activity", "replacement", "stop"] {
            let (transport, session, field, keyboardWindow) = try makeCompositionFixture()
            defer { keyboardWindow.close(); field.stopCapture(); session.reset() }
            field.setMarkedText("未確定", selectedRange: NSRange(location: 3, length: 0))
            XCTAssertNotNil(field.markedTextRange)
            var replacement: SoftKeyboardCapture.CaptureField?
            switch boundary {
            case "focus": _ = field.resignFirstResponder()
            case "activity":
                session.setApplicationInputActive(false); session.setApplicationInputActive(true)
                field.bindSession(session)
            case "replacement":
                replacement = SoftKeyboardCapture.CaptureField(frame: .zero)
                try keyboardWindow.focus(try XCTUnwrap(replacement), in: session)
            default: field.stopCapture()
            }
            field.unmarkText()
            XCTAssertEqual(try inputSourceTrace(transport), [], boundary)
            XCTAssertEqual(field.text, "", boundary)
            replacement?.insertText("new owner")
            if boundary == "replacement" {
                XCTAssertEqual(try inputSourceTrace(transport), ["text:new owner"])
            }
            replacement?.stopCapture()
        }
    }

    @MainActor
    func test_softKeyboardDeferredNativeCommitCannotReachAReplacementSource() async throws {
        let (transport, session, field, keyboardWindow) = try makeCompositionFixture()
        let replacement = SoftKeyboardCapture.CaptureField(frame: .zero)
        defer { keyboardWindow.close(); field.stopCapture(); replacement.stopCapture(); session.reset() }
        // An editing notification outside the overridden native mutation calls
        // is observed on the next actor turn, after UIKit has set marked ranges.
        field.text = "retired value"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(try inputSourceTrace(transport), [])
        try keyboardWindow.focus(replacement, in: session)
        replacement.insertText("current value")
        await Task.yield()
        field.unmarkText()
        XCTAssertEqual(try inputSourceTrace(transport), ["text:current value"])
        XCTAssertEqual(field.text, "")
    }

    @MainActor
    func test_softKeyboardCommitKeepsItsSourceAcrossReentrantReplacement() throws {
        let (transport, session, field, keyboardWindow) = try makeCompositionFixture()
        let replacement = SoftKeyboardCapture.CaptureField(frame: .zero)
        defer { transport.onSend = nil; keyboardWindow.close(); field.stopCapture(); replacement.stopCapture(); session.reset() }
        field.setMarkedText("first", selectedRange: NSRange(location: 5, length: 0))
        transport.onSend = {
            transport.onSend = nil
            XCTAssertEqual(field.text, "", "Retire the local buffer before external delivery")
            do { try keyboardWindow.focus(replacement, in: session) }
            catch { XCTFail("Could not focus replacement: \(error)") }
            field.unmarkText()
            replacement.insertText("second")
        }
        field.unmarkText()
        XCTAssertEqual(try inputSourceTrace(transport), ["text:first", "text:second"])
        XCTAssertFalse(field.canSendInput); XCTAssertTrue(replacement.canSendInput)
    }

    @MainActor
    func test_softKeyboardEmptyDeleteAndExplicitShortcutsSendOneOwnedKeyPair() throws {
        let (transport, session, field, keyboardWindow) = try makeCompositionFixture()
        defer { keyboardWindow.close(); field.stopCapture(); session.reset() }
        XCTAssertTrue(field.hasText)
        field.deleteBackward()
        field.insertText("\n")
        XCTAssertEqual(try inputSourceTrace(transport), ["key:42:true:0", "key:42:false:0", "key:40:true:0", "key:40:false:0"])
        session.toggleSoftModifier(.cmd)
        field.insertText("c")
        XCTAssertEqual(Array(try inputSourceTrace(transport).suffix(2)), ["key:6:true:8", "key:6:false:8"])
        session.releaseSoftModifiers()
        field.insertText("A")
        XCTAssertEqual(try inputSourceTrace(transport).last, "text:A", "Capitalization alone is not a physical shortcut")
    }

    @MainActor
    func test_softCaptureCannotSendBeforeSuccessfulNativeFocus() throws {
        let transport = RecordingSoftKeyboardTransport()
        let session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        let field = SoftKeyboardCapture.CaptureField()
        defer { field.stopCapture(); session.reset() }
        session.connect(code: "123456"); transport.makeScreenReady()
        field.bindSession(session)
        XCTAssertFalse(field.canBecomeFirstResponder)
        XCTAssertFalse(field.becomeFirstResponder())
        XCTAssertFalse(field.canSendInput)
        field.insertText("windowless"); field.deleteBackward()
        XCTAssertFalse(field.textFieldShouldReturn(field))
        XCTAssertFalse(field.textField(field, shouldChangeCharactersIn: NSRange(location: 0, length: 0), replacementString: "proposed"))
        XCTAssertEqual(try inputSourceTrace(transport), [])
        let keyboardWindow = try RemoteKeyboardTestWindow()
        defer { keyboardWindow.close() }
        try keyboardWindow.focus(field, in: session)
        field.insertText("focused")
        XCTAssertEqual(try inputSourceTrace(transport), ["text:focused"])
    }

    @MainActor
    func test_softCaptureLocalFocusLossRejectsLateCommitsAndReleasesModifiers() async throws {
        let (transport, session, field, keyboardWindow) = try makeCompositionFixture()
        defer { keyboardWindow.close(); session.reset() }
        let dismissed = expectation(description: "Close the retired remote keyboard")
        var dismissals = 0
        field.onKeyboardDismiss = { dismissals += 1; dismissed.fulfill() }
        field.setMarkedText("未確定", selectedRange: NSRange(location: 3, length: 0))
        session.toggleSoftModifier(.cmd)
        let local = focusLocalField(in: keyboardWindow)
        XCTAssertFalse(field.canSendInput); XCTAssertEqual(session.softModifierMask, 0)
        field.bindSession(session)
        XCTAssertFalse(field.becomeFirstResponder())
        field.insertText("late commit"); field.deleteBackward()
        field.setMarkedText("late marked text", selectedRange: NSRange(location: 0, length: 0))
        field.unmarkText(); XCTAssertFalse(field.textFieldShouldReturn(field))
        field.text = "late native notification"
        field.sendActions(for: .editingChanged)
        await fulfillment(of: [dismissed], timeout: 1)
        XCTAssertEqual(dismissals, 1)
        XCTAssertTrue(local.isFirstResponder)
        XCTAssertEqual(field.text, "")
        XCTAssertEqual(try inputSourceTrace(transport), ["key:227:true:8", "key:227:false:0"])
    }

    @MainActor
    func test_softCaptureDelayedDismissalCannotCloseItsReplacement() async throws {
        let (transport, session, field, keyboardWindow) = try makeCompositionFixture()
        defer { keyboardWindow.close(); session.reset() }
        var oldDismissals = 0, nextDismissals = 0
        field.onKeyboardDismiss = { oldDismissals += 1 }
        let local = focusLocalField(in: keyboardWindow)
        XCTAssertTrue(local.isFirstResponder)
        let replacement = SoftKeyboardCapture.CaptureField()
        replacement.onKeyboardDismiss = { nextDismissals += 1 }
        try keyboardWindow.focus(replacement, in: session)
        // Both the deferred native resignation callback and an old accessory
        // action refer to the retired field, even in the same input generation.
        let toolbar = try XCTUnwrap(field.inputAccessoryView as? UIToolbar)
        let oldButton = try XCTUnwrap(toolbar.items?.compactMap { $0.customView as? UIButton }.first)
        oldButton.sendActions(for: .touchUpInside)
        await Task.yield()
        field.insertText("retired"); replacement.insertText("current")
        XCTAssertEqual(oldDismissals, 0); XCTAssertEqual(nextDismissals, 0)
        XCTAssertTrue(replacement.isFirstResponder); XCTAssertTrue(replacement.canSendInput)
        XCTAssertEqual(try inputSourceTrace(transport), ["text:current"])
    }

    @MainActor
    func test_softCaptureWindowLossRequiresANewNativeField() throws {
        for boundary in ["detach", "key window"] {
            let (transport, session, field, keyboardWindow) = try makeCompositionFixture()
            defer { keyboardWindow.close(); session.reset() }
            field.setMarkedText("provisional", selectedRange: NSRange(location: 11, length: 0))
            if boundary == "detach" {
                field.removeFromSuperview()
                keyboardWindow.window.rootViewController?.view.addSubview(field)
            } else {
                let other = try RemoteKeyboardTestWindow()
                XCTAssertFalse(keyboardWindow.window.isKeyWindow)
                other.close()
                keyboardWindow.window.makeKey()
            }
            field.bindSession(session)
            XCTAssertFalse(field.becomeFirstResponder(), boundary)
            XCTAssertFalse(field.canSendInput, boundary)
            field.unmarkText(); field.insertText("late text")
            XCTAssertEqual(try inputSourceTrace(transport), [], boundary)
            let replacement = SoftKeyboardCapture.CaptureField()
            try keyboardWindow.focus(replacement, in: session)
            replacement.insertText("reopened")
            XCTAssertEqual(try inputSourceTrace(transport), ["text:reopened"], boundary)
        }
    }

    @MainActor
    func test_softCaptureFocusLossDuringKeyDownReleasesExactlyOnce() throws {
        let (transport, session, field, keyboardWindow) = try makeCompositionFixture()
        defer { transport.onSend = nil; keyboardWindow.close(); session.reset() }
        var local: UITextField?
        transport.onSend = {
            transport.onSend = nil
            local = self.focusLocalField(in: keyboardWindow)
        }
        field.insertText("\n")
        XCTAssertTrue(local?.isFirstResponder == true)
        XCTAssertFalse(field.canSendInput)
        XCTAssertEqual(try inputSourceTrace(transport), ["key:40:true:0", "key:40:false:0"])
        field.insertText("late text"); field.deleteBackward()
        XCTAssertEqual(try inputSourceTrace(transport), ["key:40:true:0", "key:40:false:0"])
    }

    @MainActor
    func test_softCaptureDelayedFocusCannotStealANewerLocalResponder() async throws {
        let transport = RecordingSoftKeyboardTransport()
        let session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        session.connect(code: "123456"); transport.makeScreenReady()
        let keyboardWindow = try RemoteKeyboardTestWindow(), field = SoftKeyboardCapture.CaptureField()
        defer { field.stopCapture(); keyboardWindow.close(); session.reset() }
        let dismissed = expectation(description: "Retire the superseded focus request")
        field.onKeyboardDismiss = { dismissed.fulfill() }
        keyboardWindow.window.rootViewController?.view.addSubview(field)
        field.bindSession(session) // Schedules focus; no native source exists yet.
        XCTAssertFalse(field.canSendInput)
        let local = focusLocalField(in: keyboardWindow)
        await fulfillment(of: [dismissed], timeout: 1)
        XCTAssertTrue(local.isFirstResponder)
        XCTAssertFalse(field.canSendInput); XCTAssertFalse(field.becomeFirstResponder())
        field.insertText("obsolete focus request")
        XCTAssertEqual(try inputSourceTrace(transport), [])
    }

    @MainActor
    private func focusLocalField(in fixture: RemoteKeyboardTestWindow,
                                 file: StaticString = #filePath, line: UInt = #line) -> UITextField {
        let field = UITextField(frame: CGRect(x: 20, y: 160, width: 280, height: 44))
        fixture.window.rootViewController?.view.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder(), file: file, line: line)
        return field
    }

    @MainActor
    private func makeCompositionFixture() throws -> (RecordingSoftKeyboardTransport, SessionModel, SoftKeyboardCapture.CaptureField, RemoteKeyboardTestWindow) {
        let transport = RecordingSoftKeyboardTransport()
        let session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        session.connect(code: "123456"); transport.makeScreenReady()
        let field = SoftKeyboardCapture.CaptureField(frame: .zero)
        do {
            let keyboardWindow = try RemoteKeyboardTestWindow()
            try keyboardWindow.focus(field, in: session)
            return (transport, session, field, keyboardWindow)
        } catch {
            field.stopCapture(); session.reset()
            throw error
        }
    }

    @MainActor
    func test_replacingKeyboardSourceReleasesItsHoldsAndRejectsLateCleanup() throws {
        let transport = RecordingSoftKeyboardTransport(), session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        session.connect(code: "123456"); transport.makeScreenReady()
        let generation = session.remoteInputGeneration
        let old = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
        session.send(.key(usage: 0xE3, down: true, modifiers: 8), from: old)
        session.send(.key(usage: 4, down: true, modifiers: 8), from: old)
        let replacement = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
        XCTAssertEqual(try inputSourceTrace(transport), ["key:227:true:8", "key:4:true:8", "key:4:false:8", "key:227:false:0"])
        session.send(.key(usage: 4, down: true, modifiers: 0), from: replacement)
        let count = transport.sentPayloads.count
        session.send(.key(usage: 4, down: false, modifiers: 0), from: old)
        session.send(.key(usage: 5, down: true, modifiers: 0), from: old)
        session.endRemoteInputSource(old)
        XCTAssertEqual(transport.sentPayloads.count, count)
        XCTAssertTrue(session.isRemoteInputSourceCurrent(replacement))
        session.endRemoteInputSource(replacement)
        XCTAssertEqual(try inputSourceTrace(transport).suffix(2), ["key:4:true:0", "key:4:false:0"])
    }

    @MainActor
    func test_inputSourceCleanupPreservesSharedModifiersAndOtherKeyOwners() throws {
        let transport = RecordingSoftKeyboardTransport(), session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        session.connect(code: "123456"); transport.makeScreenReady()
        session.toggleSoftModifier(.cmd)
        let hardware = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard,
            expectedInputGeneration: session.remoteInputGeneration))
        session.send(.key(usage: 0xE3, down: true, modifiers: 8), from: hardware)
        session.send(.key(usage: 4, down: true, modifiers: 8), from: hardware)
        session.releaseSoftModifiers()
        XCTAssertEqual(session.softModifierMask, 0)
        XCTAssertEqual(try inputSourceTrace(transport), ["key:227:true:8", "key:4:true:8"])
        let soft = try XCTUnwrap(session.beginRemoteInputSource(.softKeyboard,
            expectedInputGeneration: session.remoteInputGeneration))
        session.send(.key(usage: 4, down: true, modifiers: 0), from: soft)
        session.send(.key(usage: 5, down: true, modifiers: 0), from: soft)
        XCTAssertEqual(try inputSourceTrace(transport).last, "key:5:true:8", "Hardware modifiers also apply to a soft key")
        session.endRemoteInputSource(hardware)
        XCTAssertEqual(try inputSourceTrace(transport).last, "key:227:false:0", "The other source still owns A")
        session.endRemoteInputSource(soft)
        XCTAssertEqual(try inputSourceTrace(transport).suffix(2), ["key:4:false:0", "key:5:false:0"])
        session.toggleSoftModifier(.shift)
        let secondHardware = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard,
            expectedInputGeneration: session.remoteInputGeneration))
        session.send(.key(usage: 6, down: true, modifiers: 0), from: secondHardware)
        session.endRemoteInputSource(secondHardware)
        XCTAssertEqual(try inputSourceTrace(transport).suffix(2), ["key:6:true:1", "key:6:false:1"])
        XCTAssertTrue(session.isSoftModifierLatched(.shift))
        session.releaseSoftModifiers()
        XCTAssertEqual(try inputSourceTrace(transport).last, "key:225:false:0")
    }

    @MainActor
    func test_pointerSourceReplacementEndsDragAndScrollAtTheirOwnedCoordinates() throws {
        let transport = RecordingSoftKeyboardTransport(), session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        session.connect(code: "123456"); transport.makeScreenReady()
        let generation = session.remoteInputGeneration
        let old = try XCTUnwrap(session.beginRemoteInputSource(.pointer, expectedInputGeneration: generation))
        session.send(.pointer(x: 17, y: 29, buttons: 3), from: old)
        session.send(.scroll(x: 31, y: 43, dx: 0, dy: 12, phase: .begin), from: old)
        let next = try XCTUnwrap(session.beginRemoteInputSource(.pointer, expectedInputGeneration: generation))
        XCTAssertEqual(try inputSourceTrace(transport), ["pointer:17:29:3", "scroll:31:43:0:12:begin", "pointer:17:29:0", "scroll:31:43:0:0:end"])
        session.send(.pointer(x: 80, y: 90, buttons: 1), from: next)
        let count = transport.sentPayloads.count
        session.endRemoteInputSource(old)
        session.send(.pointer(x: 17, y: 29, buttons: 0), from: old)
        session.send(.scroll(x: 31, y: 43, dx: 0, dy: 12, phase: .changed), from: old)
        XCTAssertEqual(transport.sentPayloads.count, count)
        session.endRemoteInputSource(next)
        XCTAssertEqual(try inputSourceTrace(transport).last, "pointer:80:90:0")
    }

    @MainActor
    func test_retiredInputSourceCannotReleaseOrAppendAcrossRecovery() throws {
        let transport = RecordingSoftKeyboardTransport(), session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        session.connect(code: "123456"); transport.makeScreenReady()
        let generation = session.remoteInputGeneration
        let old = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
        session.send(.key(usage: 4, down: true, modifiers: 0), from: old)
        transport.onInputUnavailable?()
        transport.makeScreenReady()
        let next = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard,
            expectedInputGeneration: session.remoteInputGeneration))
        session.send(.key(usage: 4, down: true, modifiers: 0), from: next)
        let count = transport.sentPayloads.count
        XCTAssertNil(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
        session.endRemoteInputSource(old)
        session.send(.key(usage: 4, down: false, modifiers: 0), from: old)
        XCTAssertEqual(transport.sentPayloads.count, count)
        session.endRemoteInputSource(next)
        XCTAssertEqual(try inputSourceTrace(transport), ["key:4:true:0", "key:4:true:0", "key:4:false:0"])
    }

    @MainActor
    func test_inputSourceReplacementDoesNotAdmitAfterCleanupLosesTransport() throws {
        let transport = RecordingSoftKeyboardTransport(), session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        session.connect(code: "123456"); transport.makeScreenReady()
        let generation = session.remoteInputGeneration
        let old = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
        session.send(.key(usage: 4, down: true, modifiers: 0), from: old)
        session.send(.key(usage: 5, down: true, modifiers: 0), from: old)
        transport.onSend = { [weak transport] in transport?.onInputUnavailable?() }
        XCTAssertNil(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
        XCTAssertEqual(try inputSourceTrace(transport), ["key:4:true:0", "key:5:true:0", "key:4:false:0"])
        XCTAssertFalse(session.isRemoteInputSourceCurrent(old))
        transport.onSend = nil
        transport.makeScreenReady()
        let next = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard,
            expectedInputGeneration: session.remoteInputGeneration))
        session.send(.key(usage: 5, down: true, modifiers: 0), from: next)
        let count = transport.sentPayloads.count
        session.endRemoteInputSource(old)
        XCTAssertEqual(transport.sentPayloads.count, count)
        session.endRemoteInputSource(next)
        XCTAssertEqual(try inputSourceTrace(transport).last, "key:5:false:0")
    }

    @MainActor
    func test_accountFreezeReleasesAllInputSourcesBeforeClosingAdmission() throws {
        let transport = RecordingSoftKeyboardTransport(), notifications = NotificationCenter()
        let session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport }, localAccountBindingValidator: { _ in },
            accountChangeNotificationCenter: notifications)
        defer { session.reset() }
        session.connect(code: "123456", localCloudAccountBinding: accountBinding)
        transport.makeScreenReady()
        let generation = session.remoteInputGeneration
        let keyboard = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
        let pointer = try XCTUnwrap(session.beginRemoteInputSource(.pointer, expectedInputGeneration: generation))
        session.toggleSoftModifier(.cmd)
        session.send(.key(usage: 4, down: true, modifiers: 8), from: keyboard)
        session.send(.pointer(x: 17, y: 29, buttons: 1), from: pointer)
        notifications.post(name: NSNotification.Name.CKAccountChanged, object: nil)
        XCTAssertTrue(session.isCloudAccountRevalidationPending)
        XCTAssertNotEqual(session.remoteInputGeneration, generation)
        XCTAssertEqual(session.softModifierMask, 0)
        XCTAssertEqual(try inputSourceTrace(transport).suffix(3), ["key:4:false:8", "pointer:17:29:0", "key:227:false:0"])
        let count = transport.sentPayloads.count
        session.endRemoteInputSource(keyboard); session.endRemoteInputSource(pointer)
        session.send(.key(usage: 4, down: false, modifiers: 0), from: keyboard)
        XCTAssertEqual(transport.sentPayloads.count, count)
    }

    @MainActor
    func test_inputSourcesRejectUnmatchedReleasesAndForeignMessageKinds() throws {
        let transport = RecordingSoftKeyboardTransport(), session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        session.connect(code: "123456"); transport.makeScreenReady()
        let generation = session.remoteInputGeneration
        let keyboard = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
        let pointer = try XCTUnwrap(session.beginRemoteInputSource(.pointer, expectedInputGeneration: generation))
        session.send(.key(usage: 4, down: false, modifiers: 0), from: keyboard)
        session.send(.pointer(x: 1, y: 2, buttons: 1), from: keyboard)
        session.send(.text("foreign text"), from: keyboard)
        session.send(.key(usage: 4, down: true, modifiers: 0), from: pointer)
        session.send(.bye(reason: "foreign control"), from: pointer)
        XCTAssertEqual(try inputSourceTrace(transport), [])
        session.send(.key(usage: 4, down: true, modifiers: 0), from: keyboard)
        session.send(.key(usage: 4, down: true, modifiers: 0), from: keyboard)
        session.send(.key(usage: 4, down: false, modifiers: 0), from: keyboard)
        XCTAssertEqual(try inputSourceTrace(transport), ["key:4:true:0", "key:4:true:0", "key:4:false:0"])
    }

    @MainActor
    func test_softKeyboardReplacementAndDismantleCannotTypeIntoSuccessor() throws {
        let transport = RecordingSoftKeyboardTransport(), session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        session.connect(code: "123456"); transport.makeScreenReady()
        let old = SoftKeyboardCapture.CaptureField(frame: .zero)
        let keyboardWindow = try RemoteKeyboardTestWindow()
        defer { keyboardWindow.close() }
        try keyboardWindow.focus(old, in: session)
        let next = SoftKeyboardCapture.CaptureField(frame: .zero)
        try keyboardWindow.focus(next, in: session)
        XCTAssertFalse(old.canSendInput); XCTAssertTrue(next.canSendInput)
        old.bindSession(session)
        old.deleteBackward()
        old.insertText("late")
        old.stopCapture()
        old.bindSession(session)
        XCTAssertFalse(old.canSendInput); XCTAssertTrue(next.canSendInput)
        XCTAssertEqual(try inputSourceTrace(transport), [])
        next.insertText("current")
        XCTAssertEqual(try inputSourceTrace(transport), ["text:current"])
        next.stopCapture()
        next.deleteBackward()
        XCTAssertEqual(try inputSourceTrace(transport), ["text:current"])
    }

    @MainActor
    func test_inputStartsClosedAndRequiresBothApplicationAndOwnedSceneActivity() throws {
        for applicationFirst in [true, false] {
            let transport = RecordingSoftKeyboardTransport(), notifications = NotificationCenter()
            let session = SessionModel(applicationNotificationCenter: notifications, transportFactory: { transport })
            defer { session.reset() }
            session.connect(code: "123456"); transport.makeScreenReady()
            XCTAssertFalse(session.hasInteractiveRemoteScreen)
            XCTAssertNil(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: session.remoteInputGeneration))
            session.send(.text("not active"))
            let scene = session.bindRemoteInputScene(isActive: !applicationFirst)
            if applicationFirst { notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil) }
            XCTAssertFalse(session.hasInteractiveRemoteScreen)
            if applicationFirst { session.setRemoteInputSceneActive(true, lease: scene) }
            else { notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil) }
            XCTAssertTrue(session.hasInteractiveRemoteScreen)
            XCTAssertEqual(try inputSourceTrace(transport), [])
            let source = try XCTUnwrap(session.beginRemoteInputSource(.softKeyboard, expectedInputGeneration: session.remoteInputGeneration))
            session.send(.text("current"), from: source)
            XCTAssertEqual(try inputSourceTrace(transport), ["text:current"])
        }
    }

    @MainActor
    func test_applicationInactivityReleasesHoldsBeforeClosingInputAndDuplicateEdgesAreIdle() throws {
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.willTerminateNotification] {
            let transport = RecordingSoftKeyboardTransport(), notifications = NotificationCenter()
            let session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: notifications,
                transportFactory: { transport })
            defer { session.reset() }
            session.connect(code: "123456"); transport.makeScreenReady()
            let generation = session.remoteInputGeneration
            let keyboard = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
            let pointer = try XCTUnwrap(session.beginRemoteInputSource(.pointer, expectedInputGeneration: generation))
            session.toggleSoftModifier(.cmd)
            session.send(.key(usage: 4, down: true, modifiers: 8), from: keyboard)
            session.send(.pointer(x: 17, y: 29, buttons: 1), from: pointer)
            session.send(.scroll(x: 31, y: 43, dx: 0, dy: 12, phase: .begin), from: pointer)
            notifications.post(name: name, object: nil)
            XCTAssertFalse(session.hasInteractiveRemoteScreen); XCTAssertEqual(session.state, .connected)
            XCTAssertEqual(session.softModifierMask, 0)
            XCTAssertNotEqual(session.remoteInputGeneration, generation)
            XCTAssertEqual(try inputSourceTrace(transport).suffix(4), ["key:4:false:8", "pointer:17:29:0", "scroll:31:43:0:0:end", "key:227:false:0"])
            let retiredGeneration = session.remoteInputGeneration, count = transport.sentPayloads.count
            notifications.post(name: name, object: nil)
            session.endRemoteInputSource(keyboard); session.endRemoteInputSource(pointer)
            session.send(.key(usage: 5, down: true, modifiers: 0), from: keyboard)
            session.send(.text("background callback")); session.toggleSoftModifier(.shift)
            XCTAssertEqual(transport.sentPayloads.count, count)
            XCTAssertEqual(session.remoteInputGeneration, retiredGeneration)
        }
    }

    @MainActor
    func test_sceneInactivityCannotBeOverriddenByApplicationActivityOrOldInput() throws {
        let transport = RecordingSoftKeyboardTransport(), notifications = NotificationCenter()
        let session = SessionModel(applicationNotificationCenter: notifications, transportFactory: { transport })
        defer { session.reset() }
        let scene = session.bindRemoteInputScene(isActive: true)
        notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        session.connect(code: "123456"); transport.makeScreenReady()
        let old = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: session.remoteInputGeneration))
        session.send(.key(usage: 4, down: true, modifiers: 0), from: old)
        session.setRemoteInputSceneActive(false, lease: scene)
        XCTAssertEqual(try inputSourceTrace(transport).last, "key:4:false:0")
        notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(session.hasInteractiveRemoteScreen)
        XCTAssertTrue(session.inputActivity.applicationIsActive); XCTAssertFalse(session.inputActivity.sceneIsActive)
        session.setRemoteInputSceneActive(true, lease: scene)
        transport.onFirstVideoFrame?()
        let count = transport.sentPayloads.count
        session.send(.key(usage: 4, down: false, modifiers: 0), from: old)
        session.endRemoteInputSource(old)
        XCTAssertEqual(transport.sentPayloads.count, count)
        let current = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: session.remoteInputGeneration))
        session.send(.key(usage: 5, down: true, modifiers: 0), from: current)
        XCTAssertEqual(try inputSourceTrace(transport).last, "key:5:true:0")
    }

    @MainActor
    func test_replacedSceneCallbacksCannotDeactivateOrReopenTheCurrentScene() throws {
        let transport = RecordingSoftKeyboardTransport()
        let session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        let oldScene = session.bindRemoteInputScene(isActive: true)
        session.connect(code: "123456"); transport.makeScreenReady()
        let old = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: session.remoteInputGeneration))
        session.send(.key(usage: 4, down: true, modifiers: 0), from: old)
        let scene = session.bindRemoteInputScene(isActive: true)
        transport.onFirstVideoFrame?()
        XCTAssertEqual(try inputSourceTrace(transport).last, "key:4:false:0")
        let current = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: session.remoteInputGeneration))
        session.send(.key(usage: 5, down: true, modifiers: 0), from: current)
        let generation = session.remoteInputGeneration, count = transport.sentPayloads.count
        session.setRemoteInputSceneActive(false, lease: oldScene); session.endRemoteInputScene(oldScene)
        XCTAssertTrue(session.hasInteractiveRemoteScreen); XCTAssertEqual(session.remoteInputGeneration, generation)
        XCTAssertEqual(transport.sentPayloads.count, count)
        session.setRemoteInputSceneActive(false, lease: scene)
        session.setRemoteInputSceneActive(true, lease: oldScene)
        XCTAssertFalse(session.hasInteractiveRemoteScreen)
        XCTAssertEqual(try inputSourceTrace(transport).last, "key:5:false:0")
    }

    @MainActor
    func test_activityCleanupRejectsReentrantInputAndRetainsTheLatestLifecycleEdges() throws {
        let transport = RecordingSoftKeyboardTransport()
        let session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        let scene = session.bindRemoteInputScene(isActive: true)
        session.connect(code: "123456"); transport.makeScreenReady()
        let generation = session.remoteInputGeneration
        let source = try XCTUnwrap(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
        session.send(.key(usage: 4, down: true, modifiers: 0), from: source)
        transport.onSend = { [weak transport, weak session] in
            transport?.onSend = nil
            guard let session else { return }
            XCTAssertNil(session.beginRemoteInputSource(.hardwareKeyboard, expectedInputGeneration: generation))
            session.send(.text("during cleanup"))
            session.setRemoteInputSceneActive(false, lease: scene)
            session.setApplicationInputActive(true)
        }
        session.setApplicationInputActive(false)
        XCTAssertTrue(session.inputActivity.applicationIsActive, "Keep the later activation edge")
        XCTAssertFalse(session.inputActivity.sceneIsActive, "Keep the scene's independent deactivation edge")
        XCTAssertFalse(session.hasInteractiveRemoteScreen)
        XCTAssertEqual(try inputSourceTrace(transport), ["key:4:true:0", "key:4:false:0"])
        XCTAssertNotEqual(session.remoteInputGeneration, generation)
        session.setRemoteInputSceneActive(true, lease: scene)
        transport.onFirstVideoFrame?()
        XCTAssertTrue(session.hasInteractiveRemoteScreen)
    }

    @MainActor
    func test_activityCannotBypassTransportRecoveryOrAccountRevalidation() {
        let transport = RecordingSoftKeyboardTransport(), accounts = NotificationCenter()
        let session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(),
            transportFactory: { transport }, localAccountBindingValidator: { _ in }, accountChangeNotificationCenter: accounts)
        defer { session.reset() }
        session.connect(code: "123456", localCloudAccountBinding: accountBinding); transport.makeScreenReady()
        transport.onInputUnavailable?()
        session.setApplicationInputActive(false); session.setApplicationInputActive(true)
        XCTAssertFalse(session.hasInteractiveRemoteScreen)
        transport.makeScreenReady()
        XCTAssertTrue(session.hasInteractiveRemoteScreen)
        accounts.post(name: NSNotification.Name.CKAccountChanged, object: nil)
        session.setApplicationInputActive(false); session.setApplicationInputActive(true)
        XCTAssertTrue(session.isCloudAccountRevalidationPending)
        XCTAssertFalse(session.hasInteractiveRemoteScreen)
    }

    @MainActor
    func test_softCaptureRequiresExplicitRebindAfterActivityLossEvenWithoutViewRemoval() throws {
        let transport = RecordingSoftKeyboardTransport()
        let session = SessionModel(initialInputActivity: .active, applicationNotificationCenter: NotificationCenter(), transportFactory: { transport })
        defer { session.reset() }
        session.connect(code: "123456"); transport.makeScreenReady()
        let field = SoftKeyboardCapture.CaptureField(frame: .zero)
        let keyboardWindow = try RemoteKeyboardTestWindow()
        defer { keyboardWindow.close() }
        try keyboardWindow.focus(field, in: session)
        session.setApplicationInputActive(false)
        session.setApplicationInputActive(true)
        transport.onFirstVideoFrame?()
        let count = transport.sentPayloads.count
        field.deleteBackward()
        field.insertText("old callback")
        XCTAssertFalse(field.canSendInput); XCTAssertEqual(transport.sentPayloads.count, count)
        field.bindSession(session)
        XCTAssertFalse(field.canSendInput)
        let replacement = SoftKeyboardCapture.CaptureField(frame: .zero)
        try keyboardWindow.focus(replacement, in: session)
        XCTAssertTrue(replacement.canSendInput)
        field.insertText("late native commit")
        XCTAssertEqual(transport.sentPayloads.count, count)
        replacement.insertText("current")
        XCTAssertEqual(try inputSourceTrace(transport).last, "text:current")
    }

    @MainActor
    private func inputSourceTrace(_ transport: RecordingSoftKeyboardTransport) throws -> [String] {
        try transport.sentPayloads.compactMap { payload in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let kind = try XCTUnwrap(object["t"] as? String)
            switch kind {
            case "qos": return nil
            case "key":
                return "key:\(try XCTUnwrap(object["usage"] as? Int)):\(try XCTUnwrap(object["down"] as? Bool)):\(try XCTUnwrap(object["modifiers"] as? Int))"
            case "pointer":
                return "pointer:\(try XCTUnwrap(object["x"] as? Int)):\(try XCTUnwrap(object["y"] as? Int)):\(try XCTUnwrap(object["buttons"] as? Int))"
            case "scroll":
                return "scroll:\(try XCTUnwrap(object["x"] as? Int)):\(try XCTUnwrap(object["y"] as? Int)):\(try XCTUnwrap(object["dx"] as? Int)):\(try XCTUnwrap(object["dy"] as? Int)):\(try XCTUnwrap(object["phase"] as? String))"
            case "text": return "text:\(try XCTUnwrap(object["s2"] as? String))"
            default: return kind
            }
        }
    }

    @MainActor
    func test_softKeyboardCapture_exposesHittableDismissAccessory() throws {
        let (_, session, field, keyboardWindow) = try makeCompositionFixture()
        defer { keyboardWindow.close(); session.reset() }
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
    var onInputUnavailable: (@MainActor () -> Void)?
    var onVideoFrameUnavailable: (@MainActor () -> Void)?
    var onFirstVideoFrame: (@MainActor () -> Void)?
    var onDisconnect: (@MainActor (String) -> Void)?
    private(set) var sentPayloads: [Data] = []
    var onSend: (@MainActor () -> Void)?

    func makeScreenReady() {
        onHostHello?(HostHello(app: "Fixture", version: "1", hostname: "Mac", os: "macOS", audio: false, monitors: 1))
        onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1))
        onFirstVideoFrame?()
    }

    func connect(pairingCode: String, expectedHostID: String?) async throws {}

    func send(_ message: ControlMessage, seq: UInt32, ts: UInt64) {
        sentPayloads.append(message.encoded(seq: seq, ts: ts))
        onSend?()
    }

    func disconnect(reason: String) {}
}
