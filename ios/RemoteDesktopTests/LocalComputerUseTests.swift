import CloudKit
import Foundation
import XCTest
@testable import RemoteDesktop

final class LocalComputerUseTests: XCTestCase {
    private let hostID = "8A2269A1-A94C-4FA2-BD63-BEAEEA79A97A"
    private let credentialID = String(repeating: "a", count: 64)
    private let accountA = CloudKitAccountBinding(
        rawValue: String(repeating: "1", count: 64))!
    private let accountB = CloudKitAccountBinding(
        rawValue: String(repeating: "2", count: 64))!
    private let endpoint = LocalComputerUseEndpoint(
        host: "studio-mac.local.",
        port: 54_321)

    func testBonjourMetadataCarriesNonSecretRoutingWithoutVisibleCode() throws {
        let metadata = try XCTUnwrap(LocalHostBonjourMetadata(
            senderID: hostID,
            computerUseCapability: .ready,
            localCredentialID: credentialID,
            routingBinding: "123456"))
        let decoded = try XCTUnwrap(LocalHostBonjourMetadata.decode(
            txtRecordData: metadata.txtRecordData()))

        XCTAssertEqual(decoded, metadata)
        XCTAssertEqual(decoded.localCredentialID, credentialID)
        XCTAssertEqual(decoded.routingBinding, "123456")
        XCTAssertLessThanOrEqual(
            metadata.txtRecordData().count,
            LocalHostBonjourMetadata.maximumTXTRecordBytes)

        let advertisement = try XCTUnwrap(LocalHostAdvertisement.parse(
            serviceName: "Studio Mac",
            txtRecordData: metadata.txtRecordData(),
            localEndpoint: endpoint))
        XCTAssertEqual(advertisement.hostname, "Studio Mac")
        XCTAssertEqual(advertisement.code, "123456")
        XCTAssertEqual(advertisement.localEndpoint, endpoint)
        XCTAssertFalse(advertisement.canOfferLocalComputerUse)
        XCTAssertFalse(advertisement.canOfferComputerUse)
        XCTAssertFalse(advertisement.hasAuthenticatedCloudMatch)
        XCTAssertNil(advertisement.accountBinding)
    }

    func testMalformedCredentialFingerprintFallsBackWithoutEnablingLocalAI() throws {
        let metadata = try XCTUnwrap(LocalHostBonjourMetadata(
            senderID: hostID,
            computerUseCapability: .ready))
        var values = NetService.dictionary(
            fromTXTRecord: metadata.txtRecordData())
        values["lci"] = Data("not-a-fingerprint".utf8)

        let advertisement = try XCTUnwrap(LocalHostAdvertisement.parse(
            serviceName: "Studio Mac [123456]",
            txtRecordData: NetService.data(fromTXTRecord: values),
            localEndpoint: endpoint))

        XCTAssertNil(advertisement.senderID)
        XCTAssertNil(advertisement.localCredentialID)
        XCTAssertFalse(advertisement.canOfferLocalComputerUse)
        XCTAssertFalse(advertisement.canOfferComputerUse)
    }

    func testStaleCloudKitCodeCannotAuthenticateBonjourRouteForSameMac() {
        let nearby = LocalHostAdvertisement(
            hostname: "Studio Mac nearby",
            code: "111111",
            senderID: hostID,
            computerUseCapability: .ready,
            localEndpoint: endpoint,
            localCredentialID: credentialID)
        let staleCloud = LocalHostAdvertisement(
            hostname: "Studio Mac cloud",
            code: "222222",
            source: .cloudKit,
            senderID: hostID,
            computerUseCapability: .ready,
            accountBinding: accountA)

        let merged = LocalHostDiscovery.mergedHosts(
            localHosts: [nearby],
            cloudHosts: [staleCloud])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].code, staleCloud.code)
        XCTAssertEqual(merged[0].accountBinding, accountA)
        XCTAssertNil(merged[0].localEndpoint)
        XCTAssertFalse(merged[0].canOfferLocalComputerUse)
    }

    func testExactPrivateCloudKitMatchPropagatesBindingToBonjourRoute() {
        let nearby = LocalHostAdvertisement(
            hostname: "Studio Mac nearby",
            code: "123456",
            senderID: hostID,
            computerUseCapability: .ready,
            accountBinding: accountB,
            localEndpoint: endpoint,
            localCredentialID: credentialID)
        let cloud = LocalHostAdvertisement(
            hostname: "Studio Mac cloud",
            code: "123456",
            source: .cloudKit,
            senderID: hostID,
            computerUseCapability: .ready,
            accountBinding: accountA)

        let merged = LocalHostDiscovery.mergedHosts(
            localHosts: [nearby],
            cloudHosts: [cloud])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].source, .localNetwork)
        XCTAssertEqual(merged[0].accountBinding, accountA)
        XCTAssertTrue(merged[0].hasAuthenticatedCloudMatch)
        XCTAssertTrue(merged[0].canOfferLocalComputerUse)
        XCTAssertTrue(merged[0].canOfferComputerUse)
    }

    func testBonjourCannotInjectAccountBindingWithoutCloudKitMatch() {
        let nearby = LocalHostAdvertisement(
            hostname: "Studio Mac nearby",
            code: "123456",
            senderID: hostID,
            computerUseCapability: .ready,
            accountBinding: accountB,
            localEndpoint: endpoint,
            localCredentialID: credentialID)

        let merged = LocalHostDiscovery.mergedHosts(
            localHosts: [nearby],
            cloudHosts: [])

        XCTAssertTrue(merged.isEmpty)
    }

    @MainActor
    func testSessionModelRejectsLocalRouteWithoutCloudAccountBinding() {
        let model = SessionModel()

        model.connect(
            code: "123456",
            experience: .computerUse,
            computerUseHostID: hostID,
            hostName: "Studio Mac",
            localComputerUseEndpoint: endpoint,
            localCredentialID: credentialID)

        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.error?.contains("same Apple Account") == true)
        XCTAssertNil(model.computerUseSession)
    }

    func testCredentialParserAcceptsDisplayedGroupingButRejectsMutation() throws {
        let credential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0xC3, count: 32))
        XCTAssertEqual(
            try LocalComputerUseCredential(
                accessKey: credential.displayAccessKey),
            credential)
        XCTAssertThrowsError(try LocalComputerUseCredential(
            accessKey: credential.accessKey + "A"))
        XCTAssertFalse(credential.description.contains(credential.accessKey))
    }

    func testCloudKitAutomaticPairingRoundTripsWithoutPlaintextCredential() throws {
        let clientID = "1EAF6D0A-047E-4D46-AB7A-2A7D0DC9C61C"
        let credential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0xA7, count: 32))
        let request = try LocalComputerUseCloudPairingWire.makeRequest(
            clientID: clientID,
            hostID: hostID,
            pairingCode: "123456",
            expectedCredentialID: credential.credentialID,
            accountBinding: accountA,
            requestID: "4847971B-2344-4E74-8A57-776450C0EF43")
        let response = try LocalComputerUseCloudPairingWire.makeResponse(
            to: request.record,
            hostID: hostID,
            pairingCode: "123456",
            credential: credential,
            accountBinding: accountA,
            responseID: "6E0994DF-A7D9-40A2-85BC-B107F55092D9")

        XCTAssertEqual(
            try LocalComputerUseCloudPairingWire.openResponse(
                response,
                request: request),
            credential)
        let payload = try XCTUnwrap(response["payload"] as? String)
        XCTAssertFalse(payload.contains(credential.accessKey))
        XCTAssertFalse(payload.contains(credential.displayAccessKey))
    }

    func testCloudKitAccountBindingIsStableSeparatedAndRedacted() throws {
        let first = try CloudKitAccountBinding.derived(
            containerIdentifier: "iCloud.com.threadmark.remotedesktop",
            userRecordName: "account-a")
        let same = try CloudKitAccountBinding.derived(
            containerIdentifier: "iCloud.com.threadmark.remotedesktop",
            userRecordName: "account-a")
        let otherAccount = try CloudKitAccountBinding.derived(
            containerIdentifier: "iCloud.com.threadmark.remotedesktop",
            userRecordName: "account-b")
        let otherContainer = try CloudKitAccountBinding.derived(
            containerIdentifier: "iCloud.com.threadmark.other",
            userRecordName: "account-a")

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, otherAccount)
        XCTAssertNotEqual(first, otherContainer)
        XCTAssertEqual(first.rawValue.count, 64)
        XCTAssertFalse(first.description.contains(first.rawValue))
        XCTAssertNil(CloudKitAccountBinding(
            rawValue: String(repeating: "A", count: 64)))
        XCTAssertNil(CloudKitAccountBinding(rawValue: "short"))
    }

    func testCloudKitAccountStatusClassifiesCachePreservation() {
        XCTAssertNil(CloudKitAccountBinding.resolutionError(for: .available))

        let transientStatuses: [CKAccountStatus] = [
            .temporarilyUnavailable,
            .couldNotDetermine,
        ]
        for status in transientStatuses {
            let error = CloudKitAccountBinding.resolutionError(for: status)
            XCTAssertTrue(error?.preservesConfirmedBinding == true)
        }

        let confirmedUnavailableStatuses: [CKAccountStatus] = [
            .noAccount,
            .restricted,
        ]
        for status in confirmedUnavailableStatuses {
            let error = CloudKitAccountBinding.resolutionError(for: status)
            XCTAssertTrue(error?.preservesConfirmedBinding == false)
        }

        XCTAssertEqual(
            CloudKitAccountBinding.resolutionError(for: .temporarilyUnavailable),
            .temporarilyUnavailable)
        XCTAssertEqual(
            CloudKitAccountBinding.resolutionError(for: .couldNotDetermine),
            .couldNotDetermine)
        XCTAssertEqual(
            CloudKitAccountBinding.resolutionError(for: .noAccount),
            .noAccount)
        XCTAssertEqual(
            CloudKitAccountBinding.resolutionError(for: .restricted),
            .restricted)
    }

    func testCloudKitAutomaticPairingRejectsAndCryptographicallyBindsAnotherAccount() throws {
        let clientID = "1EAF6D0A-047E-4D46-AB7A-2A7D0DC9C61C"
        let credential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0xA8, count: 32))
        let request = try LocalComputerUseCloudPairingWire.makeRequest(
            clientID: clientID,
            hostID: hostID,
            pairingCode: "123456",
            expectedCredentialID: credential.credentialID,
            accountBinding: accountA)

        XCTAssertThrowsError(try LocalComputerUseCloudPairingWire.makeResponse(
            to: request.record,
            hostID: hostID,
            pairingCode: "123456",
            credential: credential,
            accountBinding: accountB)) {
            XCTAssertEqual(
                $0 as? LocalComputerUseCloudPairingError,
                .accountMismatch)
        }

        let response = try LocalComputerUseCloudPairingWire.makeResponse(
            to: request.record,
            hostID: hostID,
            pairingCode: "123456",
            credential: credential,
            accountBinding: accountA)

        let payloadString = try XCTUnwrap(response["payload"] as? String)
        let payloadData = try XCTUnwrap(payloadString.data(using: .utf8))
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payloadData)
                as? [String: Any])
        payload["accountBinding"] = accountB.rawValue
        let reboundPayload = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys])
        response["payload"] = try XCTUnwrap(
            String(data: reboundPayload, encoding: .utf8)) as CKRecordValue
        let forgedContext = LocalComputerUseCloudPairingWire.RequestContext(
            requestID: request.requestID,
            clientID: request.clientID,
            hostID: request.hostID,
            pairingCode: request.pairingCode,
            expectedCredentialID: request.expectedCredentialID,
            accountBinding: accountB,
            createdAt: request.createdAt,
            privateKey: request.privateKey,
            record: request.record)

        XCTAssertThrowsError(try LocalComputerUseCloudPairingWire.openResponse(
            response,
            request: forgedContext)) {
            XCTAssertEqual(
                $0 as? LocalComputerUseCloudPairingError,
                .invalidRecord)
        }
    }

    func testCloudKitAutomaticPairingRejectsWrongHostCodeAndFingerprint() throws {
        let clientID = "1EAF6D0A-047E-4D46-AB7A-2A7D0DC9C61C"
        let current = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0x31, count: 32))
        let stale = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0x32, count: 32))
        let request = try LocalComputerUseCloudPairingWire.makeRequest(
            clientID: clientID,
            hostID: hostID,
            pairingCode: "123456",
            expectedCredentialID: stale.credentialID,
            accountBinding: accountA)

        XCTAssertThrowsError(try LocalComputerUseCloudPairingWire.makeResponse(
            to: request.record,
            hostID: hostID,
            pairingCode: "123456",
            credential: current,
            accountBinding: accountA)) {
            XCTAssertEqual(
                $0 as? LocalComputerUseCloudPairingError,
                .credentialMismatch)
        }
        XCTAssertThrowsError(try LocalComputerUseCloudPairingWire.makeResponse(
            to: request.record,
            hostID: "970F008F-CF3E-4A79-A8DA-721BB30BD88A",
            pairingCode: "123456",
            credential: stale,
            accountBinding: accountA)) {
            XCTAssertEqual(
                $0 as? LocalComputerUseCloudPairingError,
                .requestNotForHost)
        }
        XCTAssertThrowsError(try LocalComputerUseCloudPairingWire.makeResponse(
            to: request.record,
            hostID: hostID,
            pairingCode: "654321",
            credential: stale,
            accountBinding: accountA)) {
            XCTAssertEqual(
                $0 as? LocalComputerUseCloudPairingError,
                .requestNotForHost)
        }
    }

    func testCloudKitAutomaticPairingRejectsTamperCrossClientAndReplay() throws {
        let clientID = "1EAF6D0A-047E-4D46-AB7A-2A7D0DC9C61C"
        let credential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0xD4, count: 32))
        let request = try LocalComputerUseCloudPairingWire.makeRequest(
            clientID: clientID,
            hostID: hostID,
            pairingCode: "123456",
            expectedCredentialID: credential.credentialID,
            accountBinding: accountA,
            requestID: "4847971B-2344-4E74-8A57-776450C0EF43")
        let pristineResponse = try LocalComputerUseCloudPairingWire.makeResponse(
            to: request.record,
            hostID: hostID,
            pairingCode: "123456",
            credential: credential,
            accountBinding: accountA)
        let response = try LocalComputerUseCloudPairingWire.makeResponse(
            to: request.record,
            hostID: hostID,
            pairingCode: "123456",
            credential: credential,
            accountBinding: accountA)

        // Default response IDs are request-stable. Even if bounded replay
        // memory is evicted or the host restarts, CloudKit sees a conflict on
        // this same record instead of accepting a second response record.
        XCTAssertEqual(pristineResponse.recordID, response.recordID)

        response["targetID"] =
            "C7D5CB5E-A886-45E6-8C39-D0F603226B85" as CKRecordValue
        XCTAssertThrowsError(try LocalComputerUseCloudPairingWire.openResponse(
            response,
            request: request))
        response["targetID"] = clientID as CKRecordValue

        let payloadString = try XCTUnwrap(response["payload"] as? String)
        let payloadData = try XCTUnwrap(payloadString.data(using: .utf8))
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payloadData)
                as? [String: Any])
        var sealed = try XCTUnwrap(payload["sealedCredential"] as? String)
        let first = sealed.removeFirst()
        sealed.insert(first == "A" ? "B" : "A", at: sealed.startIndex)
        payload["sealedCredential"] = sealed
        let tampered = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys])
        response["payload"] = try XCTUnwrap(
            String(data: tampered, encoding: .utf8)) as CKRecordValue
        XCTAssertThrowsError(try LocalComputerUseCloudPairingWire.openResponse(
            response,
            request: request))

        let replayContext = try LocalComputerUseCloudPairingWire.makeRequest(
            clientID: clientID,
            hostID: hostID,
            pairingCode: "123456",
            expectedCredentialID: credential.credentialID,
            accountBinding: accountA,
            requestID: "850B9D6D-74DC-4128-9B7A-E3D90E24CC43")
        XCTAssertThrowsError(try LocalComputerUseCloudPairingWire.openResponse(
            pristineResponse,
            request: replayContext))
    }

    func testCloudKitReplayRetentionIsBoundedAndExpiresAtRequestDeadline() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let clock = LocalComputerUsePairingTestClock(now: start)
        var retention = LocalComputerUsePairingReplayRetention(
            validityWindow: 300,
            maximumEntries: 64,
            clock: { clock.now })

        // A unique malformed-record flood can consume no more than the hard
        // cap, and its most recently observed duplicate stays suppressed.
        for index in 0..<10_000 {
            retention.recordHandled(
                recordName: "malformed-\(index)",
                requestCreatedAt: nil)
        }
        XCTAssertEqual(retention.count, 64)
        XCTAssertFalse(retention.shouldHandle(recordName: "malformed-9999"))

        // A valid request is retained only through its original five-minute
        // lifetime, not five additional minutes from when it was handled.
        let requestName = "request-near-expiry"
        retention.recordHandled(
            recordName: requestName,
            requestCreatedAt: start.addingTimeInterval(-240))
        XCTAssertFalse(retention.shouldHandle(recordName: requestName))

        clock.now = start.addingTimeInterval(59)
        XCTAssertFalse(retention.shouldHandle(recordName: requestName))
        clock.now = start.addingTimeInterval(61)
        XCTAssertTrue(retention.shouldHandle(recordName: requestName))
        XCTAssertLessThanOrEqual(retention.count, 64)
    }

    func testCloudKitResponseLifecycleBlocksAtCapacityUntilDeleteConfirmed() {
        let start = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let clock = LocalComputerUsePairingTestClock(now: start)
        let store = LocalComputerUsePairingMemoryResponseStore()
        let namespace = "host-account-a"
        let firstName = localPairingResponseName(
            "00000000-0000-4000-8000-000000000001")
        let secondName = localPairingResponseName(
            "00000000-0000-4000-8000-000000000002")
        let thirdName = localPairingResponseName(
            "00000000-0000-4000-8000-000000000003")

        var firstRun = LocalComputerUsePairingResponseLifecycle(
            namespace: namespace,
            validityWindow: 300,
            maximumEntries: 2,
            clock: { clock.now },
            store: store)
        XCTAssertEqual(
            firstRun.track(
                recordName: firstName,
                responseCreatedAt: start),
            .tracked)
        XCTAssertEqual(
            firstRun.track(
                recordName: secondName,
                responseCreatedAt: start),
            .tracked)
        XCTAssertEqual(
            firstRun.track(
                recordName: thirdName,
                responseCreatedAt: start),
            .cleanupRequired([firstName]))
        XCTAssertEqual(firstRun.count, 2)
        XCTAssertEqual(store.load(namespace: namespace)?.count, 2)
        XCTAssertEqual(
            firstRun.recordsForShutdownCleanup(),
            [firstName, secondName],
            "A failed capacity delete must not orphan its cleanup identity")

        // A restart after the failed delete still owns both original IDs and
        // still refuses to pre-track a third response.
        var failedDeleteRestart = LocalComputerUsePairingResponseLifecycle(
            namespace: namespace,
            validityWindow: 300,
            maximumEntries: 2,
            clock: { clock.now },
            store: store)
        XCTAssertEqual(
            failedDeleteRestart.recordsForShutdownCleanup(),
            [firstName, secondName])
        XCTAssertEqual(
            failedDeleteRestart.track(
                recordName: thirdName,
                responseCreatedAt: start),
            .cleanupRequired([firstName]))

        // Only a confirmed CloudKit delete frees the durable slot.
        failedDeleteRestart.markCleaned(recordNames: [firstName])
        XCTAssertEqual(
            failedDeleteRestart.track(
                recordName: thirdName,
                responseCreatedAt: start),
            .tracked)
        XCTAssertEqual(
            failedDeleteRestart.recordsForShutdownCleanup(),
            [secondName, thirdName])
        XCTAssertEqual(store.load(namespace: namespace)?.count, 2)

        // Reconstructing from the injected store simulates a later host run.
        // Live responses survive until their validity window closes, then are
        // surfaced for deletion and removed durably after cleanup succeeds.
        clock.now = start.addingTimeInterval(299)
        var successfulDeleteRestart = LocalComputerUsePairingResponseLifecycle(
            namespace: namespace,
            validityWindow: 300,
            maximumEntries: 2,
            clock: { clock.now },
            store: store)
        XCTAssertEqual(successfulDeleteRestart.recordsDueForCleanup(), [])
        clock.now = start.addingTimeInterval(301)
        XCTAssertEqual(
            successfulDeleteRestart.recordsDueForCleanup(),
            [secondName, thirdName])
        successfulDeleteRestart.markCleaned(
            recordNames: [secondName, thirdName])
        XCTAssertEqual(successfulDeleteRestart.count, 0)
        XCTAssertEqual(store.load(namespace: namespace)?.count, 0)
    }

    func testCloudKitResponseLifecyclePersistsRestoredOverflowUntilCleaned() {
        let now = Date(timeIntervalSinceReferenceDate: 3_000_000)
        let clock = LocalComputerUsePairingTestClock(now: now)
        let store = LocalComputerUsePairingMemoryResponseStore()
        let namespace = "restored-flood"
        let restored = (0..<1_000).map { index in
            LocalComputerUsePairingTrackedResponse(
                recordName: localPairingResponseName(String(
                    format: "00000000-0000-4000-8000-%012d",
                    index)),
                deleteAfter: now.addingTimeInterval(300))
        }
        store.save(restored, namespace: namespace)

        let lifecycle = LocalComputerUsePairingResponseLifecycle(
            namespace: namespace,
            validityWindow: 300,
            maximumEntries: 32,
            clock: { clock.now },
            store: store)

        XCTAssertEqual(lifecycle.count, 1_000)
        XCTAssertEqual(
            lifecycle.restorationOverflowRecordNames.count,
            968)
        XCTAssertEqual(
            store.load(namespace: namespace)?.count,
            1_000,
            "Startup must persist every overflow delete candidate until CloudKit confirms deletion")

        let firstCleanupAttempt = Array(
            lifecycle.restorationOverflowRecordNames.prefix(900))
        var partiallyCleaned = lifecycle
        partiallyCleaned.markCleaned(recordNames: firstCleanupAttempt)
        XCTAssertEqual(partiallyCleaned.count, 100)
        XCTAssertEqual(store.load(namespace: namespace)?.count, 100)

        // Simulate a partial CloudKit failure and another process launch. The
        // 68 unconfirmed overflow IDs remain durable and block a new response.
        var partialFailureRestart = LocalComputerUsePairingResponseLifecycle(
            namespace: namespace,
            validityWindow: 300,
            maximumEntries: 32,
            clock: { clock.now },
            store: store)
        XCTAssertEqual(
            partialFailureRestart.restorationOverflowRecordNames.count,
            68)
        let newName = localPairingResponseName(
            "00000000-0000-4000-8000-000000001001")
        let requiredCleanup = partialFailureRestart.track(
            recordName: newName,
            responseCreatedAt: now)
        guard case .cleanupRequired(let retainedNames) = requiredCleanup else {
            return XCTFail("Restored overflow unexpectedly allowed a new write")
        }
        XCTAssertEqual(retainedNames.count, 69)
        XCTAssertTrue(Set(retainedNames).isSubset(of:
            Set(partialFailureRestart.recordsForShutdownCleanup())))

        partialFailureRestart.markCleaned(recordNames: retainedNames)
        XCTAssertEqual(
            partialFailureRestart.track(
                recordName: newName,
                responseCreatedAt: now),
            .tracked)
        XCTAssertEqual(partialFailureRestart.count, 32)
        XCTAssertEqual(store.load(namespace: namespace)?.count, 32)
    }

    func testCloudKitRequestCleanupIdentitySurvivesFailedDeleteAndRestart() {
        let now = Date(timeIntervalSinceReferenceDate: 3_500_000)
        let clock = LocalComputerUsePairingTestClock(now: now)
        let store = LocalComputerUsePairingMemoryResponseStore()
        let namespace = "client-account-a"
        let requestName = localPairingRequestName(
            "00000000-0000-4000-8000-000000000101")
        let nextRequestName = localPairingRequestName(
            "00000000-0000-4000-8000-000000000102")

        var firstRun = LocalComputerUsePairingResponseLifecycle(
            namespace: namespace,
            validityWindow: 300,
            maximumEntries: 1,
            clock: { clock.now },
            store: store)
        XCTAssertEqual(
            firstRun.track(
                recordName: requestName,
                responseCreatedAt: now),
            .tracked)
        XCTAssertEqual(
            firstRun.track(
                recordName: nextRequestName,
                responseCreatedAt: now),
            .cleanupRequired([requestName]))

        let failedDeleteRestart = LocalComputerUsePairingResponseLifecycle(
            namespace: namespace,
            validityWindow: 300,
            maximumEntries: 1,
            clock: { clock.now },
            store: store)
        XCTAssertEqual(
            failedDeleteRestart.recordsForShutdownCleanup(),
            [requestName])
        XCTAssertEqual(store.load(namespace: namespace)?.count, 1)
    }

    func testCloudKitPairingLifecycleFailsClosedWhenStoredStateIsUnreadable() {
        let now = Date(timeIntervalSinceReferenceDate: 3_750_000)
        let clock = LocalComputerUsePairingTestClock(now: now)
        let store = LocalComputerUsePairingMemoryResponseStore()
        store.allowsLoads = false
        let requestName = localPairingRequestName(
            "00000000-0000-4000-8000-000000000201")

        var lifecycle = LocalComputerUsePairingResponseLifecycle(
            namespace: "unreadable-client-state",
            validityWindow: 300,
            maximumEntries: 4,
            clock: { clock.now },
            store: store)

        XCTAssertEqual(
            lifecycle.track(
                recordName: requestName,
                responseCreatedAt: now),
            .retentionUnavailable,
            "An unreadable cleanup ledger must block the CloudKit create")
        XCTAssertEqual(lifecycle.count, 0)
    }

    func testCloudKitPairingLifecycleKeepsIdentityWhenPersistenceFails() {
        let now = Date(timeIntervalSinceReferenceDate: 3_800_000)
        let clock = LocalComputerUsePairingTestClock(now: now)
        let store = LocalComputerUsePairingMemoryResponseStore()
        let namespace = "unwritable-host-state"
        let firstName = localPairingResponseName(
            "00000000-0000-4000-8000-000000000301")
        let secondName = localPairingResponseName(
            "00000000-0000-4000-8000-000000000302")

        var lifecycle = LocalComputerUsePairingResponseLifecycle(
            namespace: namespace,
            validityWindow: 300,
            maximumEntries: 4,
            clock: { clock.now },
            store: store)
        XCTAssertEqual(
            lifecycle.track(
                recordName: firstName,
                responseCreatedAt: now),
            .tracked)

        store.allowsSaves = false
        XCTAssertFalse(lifecycle.markCleaned(recordNames: [firstName]))
        XCTAssertEqual(
            lifecycle.recordsForShutdownCleanup(),
            [firstName],
            "A confirmed CloudKit delete must not erase the in-memory identity when durable cleanup accounting fails")
        XCTAssertEqual(store.load(namespace: namespace)?.map(\.recordName), [
            firstName,
        ])
        XCTAssertEqual(
            lifecycle.track(
                recordName: secondName,
                responseCreatedAt: now),
            .retentionUnavailable,
            "A failed ledger write must close the write barrier for this run")
    }

    func testCloudKitPairingUserDefaultsStoreRejectsCorruptAndOversizedState() throws {
        let suiteName = "LocalComputerUsePairingStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let namespace = "account"
        let key = "RemoteDesktop.CloudKitLocalPairing.responses.\(namespace)"
        let store = UserDefaultsLocalComputerUsePairingResponseStore(
            defaults: defaults)

        defaults.set(Data("not-json".utf8), forKey: key)
        XCTAssertNil(store.load(namespace: namespace))

        defaults.set(Data(repeating: 0, count: 128 * 1_024 + 1), forKey: key)
        XCTAssertNil(store.load(namespace: namespace))
    }

    func testCloudKitQueryAccumulatorFailsClosedAtFloodBoundary() throws {
        var accumulator = LocalComputerUsePairingRecordAccumulator<Int>(
            maximumObservedRecords: 5,
            maximumPages: 4)
        try accumulator.append(
            [10, 11],
            observedRecordCount: 2,
            hasMore: true)
        XCTAssertEqual(accumulator.records, [10, 11])
        XCTAssertEqual(accumulator.observedRecordCount, 2)

        XCTAssertThrowsError(try accumulator.append(
            [12, 13, 14],
            observedRecordCount: 3,
            hasMore: true)) { error in
            XCTAssertEqual(
                error as? LocalComputerUseCloudPairingError,
                .queryLimitExceeded)
        }
        XCTAssertEqual(
            accumulator.records,
            [10, 11],
            "An incomplete flood page must not become an actionable prefix")
        XCTAssertEqual(accumulator.observedRecordCount, 2)

        try accumulator.append(
            [12, 13, 14],
            observedRecordCount: 3,
            hasMore: false)
        XCTAssertEqual(accumulator.records, [10, 11, 12, 13, 14])
        XCTAssertEqual(accumulator.observedRecordCount, 5)
    }

    func testCloudKitQueryAccumulatorCountsFailedRowsTowardBound() throws {
        var accumulator = LocalComputerUsePairingRecordAccumulator<String>(
            maximumObservedRecords: 4,
            maximumPages: 4)
        try accumulator.append(
            ["valid-a"],
            observedRecordCount: 3,
            hasMore: true)
        XCTAssertEqual(accumulator.records, ["valid-a"])
        XCTAssertEqual(accumulator.observedRecordCount, 3)

        XCTAssertThrowsError(try accumulator.append(
            ["valid-b"],
            observedRecordCount: 2,
            hasMore: false)) { error in
            XCTAssertEqual(
                error as? LocalComputerUseCloudPairingError,
                .queryLimitExceeded)
        }
        XCTAssertEqual(accumulator.records, ["valid-a"])
        XCTAssertEqual(accumulator.observedRecordCount, 3)
    }

    func testCloudKitQueryAccumulatorBoundsEmptyCursorPages() throws {
        var accumulator = LocalComputerUsePairingRecordAccumulator<Int>(
            maximumObservedRecords: 100,
            maximumPages: 2)
        try accumulator.append(
            [],
            observedRecordCount: 0,
            hasMore: true)
        XCTAssertEqual(accumulator.observedPageCount, 1)

        XCTAssertThrowsError(try accumulator.append(
            [],
            observedRecordCount: 0,
            hasMore: true)) { error in
            XCTAssertEqual(
                error as? LocalComputerUseCloudPairingError,
                .queryLimitExceeded)
        }
        XCTAssertEqual(accumulator.observedPageCount, 1)
        XCTAssertEqual(accumulator.records, [])
    }

    func testCloudKitPairingRejectsAnyFailedRecordBeforeSelection() throws {
        let firstID = CKRecord.ID(recordName: "first")
        let first = CKRecord(
            recordType: CloudKitComputerUseChannel.recordType,
            recordID: firstID)
        let failure = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.networkFailure.rawValue)

        XCTAssertThrowsError(
            try CloudKitLocalComputerUsePairing.successfulRecords(from: [
                (firstID, .success(first)),
                (CKRecord.ID(recordName: "failed"), .failure(failure)),
            ])
        ) { error in
            XCTAssertEqual((error as NSError).domain, CKErrorDomain)
            XCTAssertEqual(
                (error as NSError).code,
                CKError.Code.networkFailure.rawValue)
        }
    }

    func testCloudKitPairingRecordOrderIsTotalAtEqualTimestamps() throws {
        let createdAt = Date(timeIntervalSinceReferenceDate: 7_000_000)
        func makeRecord(name: String, sender: String) -> CKRecord {
            let record = CKRecord(
                recordType: CloudKitComputerUseChannel.recordType,
                recordID: CKRecord.ID(recordName: name))
            record["createdAt"] = createdAt as CKRecordValue
            record["senderID"] = sender as CKRecordValue
            return record
        }
        let records = [
            makeRecord(name: "record-c", sender: "sender-a"),
            makeRecord(name: "record-a", sender: "sender-z"),
            makeRecord(name: "record-b", sender: "sender-m"),
        ]

        XCTAssertEqual(
            records.sorted(
                by: CloudKitLocalComputerUsePairing.recordPrecedes
            ).map(\.recordID.recordName),
            ["record-a", "record-b", "record-c"])
        XCTAssertEqual(
            records.reversed().sorted(
                by: CloudKitLocalComputerUsePairing.recordPrecedes
            ).map(\.recordID.recordName),
            ["record-a", "record-b", "record-c"])
    }

    func testSharedCloudKitQueryAccumulatorRejectsIncompletePrefix() throws {
        var accumulator = BoundedCloudKitRecordAccumulator<Int>(
            maximumObservedRecords: 4,
            maximumPages: 2)
        try accumulator.append(
            [1, 2],
            observedRecordCount: 2,
            hasMore: true)

        XCTAssertThrowsError(try accumulator.append(
            [3, 4],
            observedRecordCount: 2,
            hasMore: true)) { error in
            XCTAssertEqual(
                error as? BoundedCloudKitRecordError,
                .queryLimitExceeded)
        }
        XCTAssertEqual(
            accumulator.records,
            [1, 2],
            "An incomplete bounded prefix must never become actionable")
    }

    func testSharedCloudKitOwnedLifecycleBlocksUntilConfirmedCleanup() {
        let now = Date(timeIntervalSinceReferenceDate: 4_000_000)
        let clock = LocalComputerUsePairingTestClock(now: now)
        let store = BoundedCloudKitMemoryOwnedRecordStore()
        let namespace = BoundedCloudKitOwnedRecordLifecycle.namespace(
            purpose: "computer-use",
            containerIdentifier: "iCloud.example",
            senderID: hostID,
            accountBinding: accountA)
        let otherAccountNamespace =
            BoundedCloudKitOwnedRecordLifecycle.namespace(
                purpose: "computer-use",
                containerIdentifier: "iCloud.example",
                senderID: hostID,
                accountBinding: accountB)
        XCTAssertNotEqual(namespace, otherAccountNamespace)

        var firstRun = BoundedCloudKitOwnedRecordLifecycle(
            namespace: namespace,
            validityWindow: 300,
            maximumEntries: 1,
            clock: { clock.now },
            store: store,
            ownsRecordName: { $0.hasPrefix("Owned-") })
        XCTAssertEqual(
            firstRun.track(
                recordName: "Owned-first",
                createdAt: now,
                refreshesDeadline: false),
            .tracked)
        XCTAssertEqual(
            firstRun.track(
                recordName: "Owned-second",
                createdAt: now,
                refreshesDeadline: false),
            .cleanupRequired(["Owned-first"]))

        var restarted = BoundedCloudKitOwnedRecordLifecycle(
            namespace: namespace,
            validityWindow: 300,
            maximumEntries: 1,
            clock: { clock.now },
            store: store,
            ownsRecordName: { $0.hasPrefix("Owned-") })
        XCTAssertEqual(
            restarted.recordsForShutdownCleanup(),
            ["Owned-first"])
        XCTAssertTrue(restarted.markCleaned(
            recordNames: ["Owned-first"]))
        XCTAssertEqual(
            restarted.track(
                recordName: "Owned-second",
                createdAt: now,
                refreshesDeadline: false),
            .tracked)

        store.allowsSaves = false
        XCTAssertEqual(
            restarted.track(
                recordName: "Owned-second",
                createdAt: now.addingTimeInterval(10),
                refreshesDeadline: true),
            .retentionUnavailable)
        XCTAssertEqual(
            restarted.recordsForShutdownCleanup(),
            ["Owned-second"])

        let unavailableStore = BoundedCloudKitMemoryOwnedRecordStore()
        unavailableStore.allowsLoads = false
        var unavailable = BoundedCloudKitOwnedRecordLifecycle(
            namespace: "unreadable",
            validityWindow: 300,
            maximumEntries: 1,
            clock: { clock.now },
            store: unavailableStore,
            ownsRecordName: { $0.hasPrefix("Owned-") })
        XCTAssertEqual(
            unavailable.track(
                recordName: "Owned-third",
                createdAt: now,
                refreshesDeadline: false),
            .retentionUnavailable)
    }

    func testSharedCloudKitOwnedUserDefaultsStoreVerifiesRoundTripAndRejectsInvalidState()
        throws {
        let suiteName =
            "BoundedCloudKitOwnedRecordStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let namespace = "account"
        let key =
            "RemoteDesktop.BoundedCloudKitOwnedRecords.\(namespace)"
        let store = UserDefaultsBoundedCloudKitOwnedRecordStore(
            defaults: defaults)
        let records = [
            BoundedCloudKitTrackedRecord(
                recordName: "Owned-first",
                deleteAfter: Date(
                    timeIntervalSinceReferenceDate: 4_000_300)),
        ]

        XCTAssertTrue(store.save(records, namespace: namespace))
        XCTAssertEqual(store.load(namespace: namespace), records)

        XCTAssertTrue(store.save([], namespace: namespace))
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertEqual(store.load(namespace: namespace), [])

        defaults.set(Data("not-json".utf8), forKey: key)
        XCTAssertNil(store.load(namespace: namespace))

        defaults.set(
            Data(repeating: 0, count: 512 * 1_024 + 1),
            forKey: key)
        XCTAssertNil(store.load(namespace: namespace))
    }

    func testSharedCloudKitReplayRetentionFailsClosedAndExpires() {
        let start = Date(timeIntervalSinceReferenceDate: 4_500_000)
        let clock = LocalComputerUsePairingTestClock(now: start)
        var retention = BoundedCloudKitReplayRetention(
            validityWindow: 60,
            maximumEntries: 2,
            clock: { clock.now })

        XCTAssertTrue(retention.reserve(
            recordName: "first",
            createdAt: start))
        XCTAssertTrue(retention.reserve(
            recordName: "second",
            createdAt: start.addingTimeInterval(10_000)))
        XCTAssertFalse(retention.reserve(
            recordName: "third",
            createdAt: start))
        XCTAssertEqual(retention.count, 2)

        clock.now = start.addingTimeInterval(61)
        XCTAssertTrue(retention.reserve(
            recordName: "third",
            createdAt: clock.now))
        XCTAssertEqual(retention.count, 1)
    }

    func testSharedCloudKitDeleteAccountingRetainsExactPartialFailures() {
        let first = CKRecord.ID(recordName: "first")
        let second = CKRecord.ID(recordName: "second")
        let third = CKRecord.ID(recordName: "third")
        let partial = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    first: NSError(
                        domain: CKErrorDomain,
                        code: CKError.Code.unknownItem.rawValue),
                    second: NSError(
                        domain: CKErrorDomain,
                        code: CKError.Code.networkFailure.rawValue),
                ],
            ])

        XCTAssertEqual(
            BoundedCloudKitDeleteAccounting.confirmedRecordIDs(
                in: [first, second, third],
                result: .failure(partial)),
            Set([first, third]))
    }

    func testEndpointValidationRejectsEmptyControlAndZeroPort() {
        XCTAssertTrue(endpoint.isValid)
        XCTAssertFalse(LocalComputerUseEndpoint(host: "", port: 42).isValid)
        XCTAssertFalse(LocalComputerUseEndpoint(
            host: "bad\nhost",
            port: 42).isValid)
        XCTAssertFalse(LocalComputerUseEndpoint(
            host: "studio-mac.local.",
            port: 0).isValid)
    }

    func testPendingPromptRebindPreservesExactTaskAcrossHostRestart() throws {
        let store = ComputerUsePendingPromptStore(
            service: "com.threadmark.remotedesktop.tests.pending.\(UUID().uuidString)")
        let oldCode = "123456"
        let newCode = "654321"
        let pending = ComputerUsePendingPrompt(
            hostID: hostID,
            pairingCode: oldCode,
            sessionID: "stable-session",
            messageID: "stable-task",
            prompt: "Complete the local browser quote",
            wireBody: "{\"exact\":true}",
            createdAt: Date(),
            localAccountBinding: accountA,
            controlRevision: 7,
            lastControlKind: .resume,
            interventionGuidance: "Sign in on the Mac")
        defer {
            store.remove(
                hostID: hostID,
                localAccountBinding: accountA)
        }

        XCTAssertTrue(store.save(pending))
        XCTAssertNil(store.load(
            hostID: hostID,
            pairingCode: newCode,
            localAccountBinding: accountA))

        let recovered = try XCTUnwrap(
            store.loadForLocalRecovery(
                hostID: hostID,
                localAccountBinding: accountA))
        let rebound = recovered.rebindingPairingCode(newCode)
        XCTAssertTrue(store.save(rebound))

        let restored = try XCTUnwrap(
            store.load(
                hostID: hostID,
                pairingCode: newCode,
                localAccountBinding: accountA))
        XCTAssertEqual(restored.sessionID, pending.sessionID)
        XCTAssertEqual(restored.messageID, pending.messageID)
        XCTAssertEqual(restored.exactWireBody, pending.exactWireBody)
        XCTAssertEqual(restored.controlRevision, pending.controlRevision)
        XCTAssertEqual(restored.lastControlKind, pending.lastControlKind)
        XCTAssertEqual(
            restored.interventionGuidance,
            pending.interventionGuidance)
        XCTAssertEqual(restored.localAccountBinding, accountA)
    }

    func testPendingPromptRecoveryAndRemovalAreAccountNamespaced() throws {
        let store = ComputerUsePendingPromptStore(
            service: "com.threadmark.remotedesktop.tests.pending.account.\(UUID().uuidString)")
        let pendingA = ComputerUsePendingPrompt(
            hostID: hostID,
            pairingCode: "123456",
            sessionID: "account-a-session",
            messageID: "account-a-task",
            prompt: "Account A browser task",
            createdAt: Date(),
            localAccountBinding: accountA)
        let pendingB = ComputerUsePendingPrompt(
            hostID: hostID,
            pairingCode: "123456",
            sessionID: "account-b-session",
            messageID: "account-b-task",
            prompt: "Account B browser task",
            createdAt: Date(),
            localAccountBinding: accountB)
        defer {
            store.remove(
                hostID: hostID,
                localAccountBinding: accountA)
            store.remove(
                hostID: hostID,
                localAccountBinding: accountB)
            store.remove(hostID: hostID)
        }

        XCTAssertTrue(store.save(pendingA))
        XCTAssertTrue(store.save(pendingB))
        XCTAssertEqual(
            store.loadForLocalRecovery(
                hostID: hostID,
                localAccountBinding: accountA)?.messageID,
            pendingA.messageID)
        XCTAssertEqual(
            store.loadForLocalRecovery(
                hostID: hostID,
                localAccountBinding: accountB)?.messageID,
            pendingB.messageID)
        XCTAssertNil(store.load(hostID: hostID, pairingCode: "123456"))

        store.remove(
            hostID: hostID,
            localAccountBinding: accountA)

        XCTAssertNil(store.loadForLocalRecovery(
            hostID: hostID,
            localAccountBinding: accountA))
        XCTAssertEqual(
            store.loadForLocalRecovery(
                hostID: hostID,
                localAccountBinding: accountB)?.messageID,
            pendingB.messageID)
    }
}

private final class LocalComputerUsePairingTestClock: @unchecked Sendable {
    init(now: Date) {
        self.now = now
    }

    var now: Date
}

private final class LocalComputerUsePairingMemoryResponseStore:
    LocalComputerUsePairingResponseStore, @unchecked Sendable {
    var allowsLoads = true
    var allowsSaves = true

    func load(
        namespace: String
    ) -> [LocalComputerUsePairingTrackedResponse]? {
        guard allowsLoads else { return nil }
        return values[namespace] ?? []
    }

    @discardableResult
    func save(
        _ responses: [LocalComputerUsePairingTrackedResponse],
        namespace: String
    ) -> Bool {
        guard allowsSaves else { return false }
        values[namespace] = responses
        return true
    }

    private var values:
        [String: [LocalComputerUsePairingTrackedResponse]] = [:]
}

private final class BoundedCloudKitMemoryOwnedRecordStore:
    BoundedCloudKitOwnedRecordStore, @unchecked Sendable {
    var allowsLoads = true
    var allowsSaves = true

    func load(namespace: String) -> [BoundedCloudKitTrackedRecord]? {
        guard allowsLoads else { return nil }
        return values[namespace] ?? []
    }

    @discardableResult
    func save(
        _ records: [BoundedCloudKitTrackedRecord],
        namespace: String
    ) -> Bool {
        guard allowsSaves else { return false }
        values[namespace] = records
        return true
    }

    private var values: [String: [BoundedCloudKitTrackedRecord]] = [:]
}

private func localPairingResponseName(_ suffix: String) -> String {
    "WebRTCSignal-LocalCredentialResponse-\(suffix)"
}

private func localPairingRequestName(_ suffix: String) -> String {
    "WebRTCSignal-LocalCredentialRequest-\(suffix)"
}
