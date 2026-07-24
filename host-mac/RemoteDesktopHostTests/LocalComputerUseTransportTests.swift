import CloudKit
import Foundation
import Network
import Security
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class LocalComputerUseTransportTests: XCTestCase {
    private let hostID = "8A2269A1-A94C-4FA2-BD63-BEAEEA79A97A"
    private let peerID = "53A8D639-5DE2-4786-BE26-2AC9F853D3B6"
    private let pairingCode = "123456"
    private let sessionID = "local-session-1"
    private let accountA = CloudKitAccountBinding(
        rawValue: String(repeating: "1", count: 64))!
    private let accountB = CloudKitAccountBinding(
        rawValue: String(repeating: "2", count: 64))!

    func testCloudKitAuthenticationFailuresNeverPreserveConfirmedAccount() {
        XCTAssertEqual(
            CloudKitAccountBinding.resolutionError(for: .notAuthenticated),
            .noAccount)
        XCTAssertEqual(
            CloudKitAccountBinding.resolutionError(for: .permissionFailure),
            .restricted)
        XCTAssertFalse(
            CloudKitAccountBinding.resolutionError(
                for: CKError.Code.notAuthenticated
            ).preservesConfirmedBinding)
        XCTAssertFalse(
            CloudKitAccountBinding.resolutionError(
                for: CKError.Code.permissionFailure
            ).preservesConfirmedBinding)
    }

    func testCredentialRoundTripsGroupedAccessKeyWithoutDisclosingSecret() throws {
        let rawKey = Data((0 ..< 32).map(UInt8.init))
        let credential = try LocalComputerUseCredential(rawKey: rawKey)

        XCTAssertEqual(
            try LocalComputerUseCredential(
                accessKey: credential.displayAccessKey),
            credential)
        XCTAssertEqual(credential.credentialID.count, 64)
        XCTAssertFalse(credential.description.contains(credential.accessKey))
        XCTAssertThrowsError(try LocalComputerUseCredential(accessKey: "short"))
    }

    func testClientCredentialStoreIsBoundToExactAccountHostAndFingerprint() throws {
        let store = LocalComputerUseCredentialStore(
            service: "com.threadmark.remotedesktop.tests.\(UUID().uuidString)")
        let credential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0xA5, count: 32))
        let otherAccountCredential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0xB5, count: 32))
        defer {
            store.removeClientCredential(
                hostID: hostID,
                credentialID: credential.credentialID,
                accountBinding: accountA)
            store.removeClientCredential(
                hostID: hostID,
                credentialID: otherAccountCredential.credentialID,
                accountBinding: accountB)
        }

        try store.saveClientCredential(
            credential,
            hostID: hostID,
            accountBinding: accountA)

        XCTAssertEqual(
            store.clientCredential(
                hostID: hostID,
                credentialID: credential.credentialID,
                accountBinding: accountA),
            credential)
        XCTAssertNil(store.clientCredential(
            hostID: peerID,
            credentialID: credential.credentialID,
            accountBinding: accountA))
        XCTAssertNil(store.clientCredential(
            hostID: hostID,
            credentialID: String(repeating: "0", count: 64),
            accountBinding: accountA))
        XCTAssertNil(store.clientCredential(
            hostID: hostID,
            credentialID: credential.credentialID,
            accountBinding: accountB))

        try store.saveClientCredential(
            otherAccountCredential,
            hostID: hostID,
            accountBinding: accountB)
        XCTAssertEqual(
            store.clientCredential(
                hostID: hostID,
                credentialID: credential.credentialID,
                accountBinding: accountA),
            credential)
        XCTAssertEqual(
            store.clientCredential(
                hostID: hostID,
                credentialID: otherAccountCredential.credentialID,
                accountBinding: accountB),
            otherAccountCredential)
    }

    func testSavingRotatedClientCredentialRevokesOldFingerprintWithoutAffectingOtherHost() throws {
        let store = LocalComputerUseCredentialStore(
            service: "com.threadmark.remotedesktop.tests.\(UUID().uuidString)")
        let otherHostID = "\(hostID).other"
        let oldCredential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0xA5, count: 32))
        let rotatedCredential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0xB6, count: 32))
        let otherHostCredential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0xC7, count: 32))
        defer {
            for (savedHostID, credential) in [
                (hostID, oldCredential),
                (hostID, rotatedCredential),
                (otherHostID, otherHostCredential),
            ] {
                store.removeClientCredential(
                    hostID: savedHostID,
                    credentialID: credential.credentialID,
                    accountBinding: accountA)
            }
        }

        try store.saveClientCredential(
            oldCredential,
            hostID: hostID,
            accountBinding: accountA)
        try store.saveClientCredential(
            otherHostCredential,
            hostID: otherHostID,
            accountBinding: accountA)

        XCTAssertEqual(
            store.clientCredential(
                hostID: hostID,
                credentialID: oldCredential.credentialID,
                accountBinding: accountA),
            oldCredential)
        XCTAssertEqual(
            store.clientCredential(
                hostID: otherHostID,
                credentialID: otherHostCredential.credentialID,
                accountBinding: accountA),
            otherHostCredential)

        try store.saveClientCredential(
            rotatedCredential,
            hostID: hostID,
            accountBinding: accountA)

        XCTAssertNil(store.clientCredential(
            hostID: hostID,
            credentialID: oldCredential.credentialID,
            accountBinding: accountA))
        XCTAssertEqual(
            store.clientCredential(
                hostID: hostID,
                credentialID: rotatedCredential.credentialID,
                accountBinding: accountA),
            rotatedCredential)
        XCTAssertEqual(
            store.clientCredential(
                hostID: otherHostID,
                credentialID: otherHostCredential.credentialID,
                accountBinding: accountA),
            otherHostCredential)

        store.removeClientCredential(
            hostID: hostID,
            credentialID: oldCredential.credentialID,
            accountBinding: accountA)
        XCTAssertEqual(
            store.clientCredential(
                hostID: hostID,
                credentialID: rotatedCredential.credentialID,
                accountBinding: accountA),
            rotatedCredential)

        store.removeClientCredential(
            hostID: hostID,
            credentialID: rotatedCredential.credentialID,
            accountBinding: accountA)
        XCTAssertNil(store.clientCredential(
            hostID: hostID,
            credentialID: rotatedCredential.credentialID,
            accountBinding: accountA))
        XCTAssertEqual(
            store.clientCredential(
                hostID: otherHostID,
                credentialID: otherHostCredential.credentialID,
                accountBinding: accountA),
            otherHostCredential)
    }

    func testUnboundLegacyCredentialsNeverAuthorizeAnAccountBoundRoute() throws {
        let service =
            "com.threadmark.remotedesktop.tests.\(UUID().uuidString)"
        let store = LocalComputerUseCredentialStore(service: service)
        let legacyCredential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0x31, count: 32))
        let stableUnboundAccount = "client.\(hostID)"
        let fingerprintUnboundAccount =
            "client.\(hostID).\(legacyCredential.credentialID)"
        defer { deleteTestKeychainService(service) }

        try addTestCredential(
            legacyCredential,
            service: service,
            account: stableUnboundAccount)
        try addTestCredential(
            legacyCredential,
            service: service,
            account: fingerprintUnboundAccount)

        XCTAssertNil(store.clientCredential(
            hostID: hostID,
            credentialID: legacyCredential.credentialID,
            accountBinding: accountA))
        XCTAssertEqual(
            testCredentialData(service: service, account: stableUnboundAccount),
            legacyCredential.rawKey)
        XCTAssertEqual(
            testCredentialData(
                service: service,
                account: fingerprintUnboundAccount),
            legacyCredential.rawKey)
    }

    func testHostCredentialsAreIsolatedAndRotationIsScopedByAccount() throws {
        let service =
            "com.threadmark.remotedesktop.tests.\(UUID().uuidString)"
        let store = LocalComputerUseCredentialStore(service: service)
        let unboundHostCredential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0x64, count: 32))
        defer { deleteTestKeychainService(service) }
        try addTestCredential(
            unboundHostCredential,
            service: service,
            account: "host")

        let firstA = try store.hostCredential(accountBinding: accountA)
        let secondA = try store.hostCredential(accountBinding: accountA)
        let firstB = try store.hostCredential(accountBinding: accountB)
        let rotatedA = try store.rotateHostCredential(
            accountBinding: accountA)

        XCTAssertEqual(firstA, secondA)
        XCTAssertNotEqual(firstA, unboundHostCredential)
        XCTAssertEqual(
            testCredentialData(service: service, account: "host"),
            unboundHostCredential.rawKey)
        XCTAssertNotEqual(firstA, firstB)
        XCTAssertNotEqual(firstA, rotatedA)
        XCTAssertEqual(
            try store.hostCredential(accountBinding: accountA),
            rotatedA)
        XCTAssertEqual(
            try store.hostCredential(accountBinding: accountB),
            firstB)
    }

    func testConfirmedAccountBindingMarkerIsDeviceLocalReplaceableAndClearable() throws {
        let service =
            "com.threadmark.remotedesktop.tests.\(UUID().uuidString)"
        let store = LocalComputerUseCredentialStore(service: service)
        defer { deleteTestKeychainService(service) }

        XCTAssertNil(try store.confirmedAccountBinding())

        try store.setConfirmedAccountBinding(accountA)
        XCTAssertEqual(try store.confirmedAccountBinding(), accountA)
        XCTAssertEqual(
            testCredentialData(
                service: service,
                account: LocalComputerUseCredentialStore
                    .confirmedAccountBindingAccount),
            Data(accountA.rawValue.utf8))
        // A false synchronizable value is a Keychain search predicate rather
        // than a returned macOS attribute. Prove that the item is available
        // only to the non-synchronizable query and cannot be selected as an
        // iCloud Keychain item. (The ThisDeviceOnly accessibility class is
        // enforced on iOS; macOS documents it as unsupported for local items.)
        XCTAssertNil(testCredentialData(
            service: service,
            account: LocalComputerUseCredentialStore
                .confirmedAccountBindingAccount,
            synchronizable: true))

        try store.setConfirmedAccountBinding(accountB)
        XCTAssertEqual(try store.confirmedAccountBinding(), accountB)

        try store.clearConfirmedAccountBinding()
        XCTAssertNil(try store.confirmedAccountBinding())
        XCTAssertNoThrow(try store.clearConfirmedAccountBinding())
    }

    func testRPCCodecRoundTripsAndRejectsCrossSessionEnvelopeAtomically() throws {
        let envelope = makeEnvelope(id: "prompt-1")
        let request = LocalComputerUseRPCRequest(
            requestID: "request-1",
            senderID: peerID,
            targetID: hostID,
            sessionID: sessionID,
            envelopes: [envelope],
            acknowledgedEnvelopeIDs: ["assistant-0"])

        let decoded = try LocalComputerUseRPCCodec.decodeRequest(
            LocalComputerUseRPCCodec.encode(request))
        XCTAssertEqual(decoded.version, request.version)
        XCTAssertEqual(decoded.requestID, request.requestID)
        XCTAssertEqual(decoded.senderID, request.senderID)
        XCTAssertEqual(decoded.targetID, request.targetID)
        XCTAssertEqual(decoded.sessionID, request.sessionID)
        XCTAssertEqual(
            decoded.acknowledgedEnvelopeIDs,
            request.acknowledgedEnvelopeIDs)
        XCTAssertEqual(decoded.envelopes.count, 1)
        assertWireEquivalent(
            try XCTUnwrap(decoded.envelopes.first),
            envelope)

        let wrongSession = ComputerUseEnvelope(
            id: "prompt-2",
            senderID: peerID,
            targetID: hostID,
            pairingCode: pairingCode,
            sessionID: "different-session",
            kind: .prompt,
            body: "Open Calculator")
        let invalid = LocalComputerUseRPCRequest(
            senderID: peerID,
            targetID: hostID,
            sessionID: sessionID,
            envelopes: [wrongSession])
        XCTAssertThrowsError(try LocalComputerUseRPCCodec.encode(invalid))
    }

    private func addTestCredential(
        _ credential: LocalComputerUseCredential,
        service: String,
        account: String
    ) throws {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: credential.rawKey,
        ]
#if os(iOS)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif
        let status = SecItemAdd(attributes as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)
    }

    private func testCredentialData(
        service: String,
        account: String,
        synchronizable: Bool = false
    ) -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        XCTAssertEqual(status, errSecSuccess)
        return result as? Data
    }

    private func deleteTestKeychainService(_ service: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ] as CFDictionary)
    }

    func testLocalMailboxRejectsSpoofAndWholeMalformedBatchWithoutPartialQueue() async throws {
        let channel = LocalHostComputerUseChannel(
            hostID: hostID,
            pairingCode: pairingCode)
        let valid = makeEnvelope(id: "prompt-valid")
        let malformed = ComputerUseEnvelope(
            id: "prompt-malformed",
            senderID: peerID,
            targetID: hostID,
            pairingCode: pairingCode,
            sessionID: "different-session",
            kind: .prompt,
            body: "Must not run")

        do {
            _ = try await channel.applyClientFrame(
                envelopes: [valid, malformed],
                acknowledgedEnvelopeIDs: [],
                authenticatedSenderID: peerID,
                sessionID: sessionID)
            XCTFail("Malformed batch was accepted")
        } catch {
            // Expected fail-closed rejection.
        }
        let queuedAfterMalformedBatch = try await channel.poll()
        XCTAssertTrue(queuedAfterMalformedBatch.isEmpty)

        do {
            try await channel.receiveFromClient(
                valid,
                authenticatedSenderID: hostID)
            XCTFail("Spoofed authenticated sender was accepted")
        } catch {
            // Expected fail-closed rejection.
        }
        let queuedAfterSpoof = try await channel.poll()
        XCTAssertTrue(queuedAfterSpoof.isEmpty)
    }

    func testLocalMailboxIsIdempotentButRejectsIdentifierCollision() async throws {
        let channel = LocalHostComputerUseChannel(
            hostID: hostID,
            pairingCode: pairingCode)
        let original = makeEnvelope(id: "stable-prompt")
        try await channel.receiveFromClient(
            original,
            authenticatedSenderID: peerID)
        try await channel.receiveFromClient(
            original,
            authenticatedSenderID: peerID)

        var queued = try await channel.poll()
        XCTAssertEqual(queued, [original])

        let collision = ComputerUseEnvelope(
            id: original.id,
            senderID: original.senderID,
            targetID: original.targetID,
            pairingCode: original.pairingCode,
            sessionID: original.sessionID,
            kind: .prompt,
            body: "Different task")
        do {
            try await channel.receiveFromClient(
                collision,
                authenticatedSenderID: peerID)
            XCTFail("Message identifier collision was accepted")
        } catch {
            // Expected fail-closed rejection.
        }
        queued = try await channel.poll()
        XCTAssertEqual(queued, [original])
    }

    func testBrokerRejectsPublicInternetEndpointsBeforeTLS() throws {
        func endpoint(_ address: String) throws -> NWEndpoint {
            let ipv4 = try XCTUnwrap(IPv4Address(address))
            return .hostPort(host: .ipv4(ipv4), port: .https)
        }

        XCTAssertTrue(LocalComputerUseBrokerServer.isPrivateLocalEndpoint(
            try endpoint("127.0.0.1")))
        XCTAssertTrue(LocalComputerUseBrokerServer.isPrivateLocalEndpoint(
            try endpoint("10.20.30.40")))
        XCTAssertTrue(LocalComputerUseBrokerServer.isPrivateLocalEndpoint(
            try endpoint("172.31.255.254")))
        XCTAssertTrue(LocalComputerUseBrokerServer.isPrivateLocalEndpoint(
            try endpoint("192.168.123.45")))
        XCTAssertTrue(LocalComputerUseBrokerServer.isPrivateLocalEndpoint(
            try endpoint("169.254.10.20")))
        XCTAssertFalse(LocalComputerUseBrokerServer.isPrivateLocalEndpoint(
            try endpoint("8.8.8.8")))
        XCTAssertFalse(LocalComputerUseBrokerServer.isPrivateLocalEndpoint(
            try endpoint("172.32.0.1")))
    }

    func testTLSPSKBrokerCarriesPromptResultAndAcknowledgementEndToEnd() async throws {
        let credential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0x5A, count: 32))
        let channel = LocalHostComputerUseChannel(
            hostID: hostID,
            pairingCode: pairingCode)
        var authorizedPeers: [String] = []
        var revocationCount = 0
        let server = LocalComputerUseBrokerServer(
            credential: credential,
            hostID: hostID,
            channel: channel,
            authorizePeer: {
                authorizedPeers.append($0)
                return true
            },
            revokePeer: { _ in revocationCount += 1 })
        let port = try await server.start()
        defer { server.stop() }
        let endpoint = LocalComputerUseEndpoint(
            host: "127.0.0.1",
            port: port)

        let prompt = makeEnvelope(id: "prompt-live")
        let submit = LocalComputerUseRPCRequest(
            requestID: "submit-live",
            senderID: peerID,
            targetID: hostID,
            sessionID: sessionID,
            envelopes: [prompt])
        let submitResponse = try await LocalComputerUseRPCTransport.call(
            endpoint: endpoint,
            credential: credential,
            request: submit)

        XCTAssertEqual(submitResponse.acceptedEnvelopeIDs, [prompt.id])
        let submittedPrompts = try await channel.poll()
        XCTAssertEqual(submittedPrompts.count, 1)
        assertWireEquivalent(
            try XCTUnwrap(submittedPrompts.first),
            prompt)
        XCTAssertEqual(authorizedPeers.last, peerID)

        let result = try await channel.send(
            kind: .assistant,
            body: "Calculator displays 1161.",
            to: peerID,
            sessionID: sessionID,
            messageID: "result-live")
        let poll = LocalComputerUseRPCRequest(
            requestID: "poll-live",
            senderID: peerID,
            targetID: hostID,
            sessionID: sessionID)
        let pollResponse = try await LocalComputerUseRPCTransport.call(
            endpoint: endpoint,
            credential: credential,
            request: poll)
        XCTAssertEqual(pollResponse.envelopes.count, 1)
        assertWireEquivalent(
            try XCTUnwrap(pollResponse.envelopes.first),
            result)

        let acknowledge = LocalComputerUseRPCRequest(
            requestID: "ack-live",
            senderID: peerID,
            targetID: hostID,
            sessionID: sessionID,
            acknowledgedEnvelopeIDs: [result.id])
        let acknowledged = try await LocalComputerUseRPCTransport.call(
            endpoint: endpoint,
            credential: credential,
            request: acknowledge)
        XCTAssertTrue(acknowledged.envelopes.isEmpty)
        XCTAssertEqual(revocationCount, 0)
    }

    func testBrokerRejectsWrongTLSPSKWithoutAuthorizingOrQueuing() async throws {
        let credential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0x5A, count: 32))
        let wrongCredential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0xA5, count: 32))
        let channel = LocalHostComputerUseChannel(
            hostID: hostID,
            pairingCode: pairingCode)
        var authorizedPeers: [String] = []
        var revokedPeers: [String] = []
        let server = LocalComputerUseBrokerServer(
            credential: credential,
            hostID: hostID,
            channel: channel,
            authorizePeer: {
                authorizedPeers.append($0)
                return true
            },
            revokePeer: { revokedPeers.append($0) })
        let port = try await server.start()
        defer { server.stop() }

        let prompt = makeEnvelope(id: "wrong-key-prompt")
        let request = LocalComputerUseRPCRequest(
            requestID: "wrong-key-request",
            senderID: peerID,
            targetID: hostID,
            sessionID: sessionID,
            envelopes: [prompt])

        let clock = ContinuousClock()
        let startedAt = clock.now
        var handshakeFailure: Error?
        do {
            _ = try await LocalComputerUseRPCTransport.call(
                endpoint: LocalComputerUseEndpoint(
                    host: "127.0.0.1",
                    port: port),
                credential: wrongCredential,
                request: request,
                readinessTimeout: .milliseconds(500))
            XCTFail("A client with the wrong TLS PSK completed the handshake")
        } catch {
            handshakeFailure = error
        }

        let elapsed = clock.now - startedAt
        XCTAssertNotNil(handshakeFailure)
        XCTAssertLessThan(elapsed, .seconds(5))
        XCTAssertTrue(authorizedPeers.isEmpty)
        XCTAssertTrue(revokedPeers.isEmpty)
        let queuedAfterRejectedHandshake = try await channel.poll()
        XCTAssertTrue(queuedAfterRejectedHandshake.isEmpty)
    }

    func testSimultaneousFirstRequestsAuthorizeExactlyOnePeer() async throws {
        let secondPeerID = "89CD465C-BE5D-4B48-B758-4C94206891D8"
        let credential = try LocalComputerUseCredential(
            rawKey: Data(repeating: 0x3C, count: 32))
        let channel = LocalHostComputerUseChannel(
            hostID: hostID,
            pairingCode: pairingCode)
        var authorizedPeers: [String] = []
        let server = LocalComputerUseBrokerServer(
            credential: credential,
            hostID: hostID,
            channel: channel,
            authorizePeer: {
                authorizedPeers.append($0)
                return true
            },
            revokePeer: { _ in })
        let port = try await server.start()
        defer { server.stop() }
        let endpoint = LocalComputerUseEndpoint(
            host: "127.0.0.1",
            port: port)

        let firstPrompt = makeEnvelope(
            id: "simultaneous-first",
            senderID: peerID,
            sessionID: "simultaneous-session-a")
        let secondPrompt = makeEnvelope(
            id: "simultaneous-second",
            senderID: secondPeerID,
            sessionID: "simultaneous-session-b")
        let firstRequest = LocalComputerUseRPCRequest(
            requestID: "simultaneous-request-a",
            senderID: peerID,
            targetID: hostID,
            sessionID: firstPrompt.sessionID,
            envelopes: [firstPrompt])
        let secondRequest = LocalComputerUseRPCRequest(
            requestID: "simultaneous-request-b",
            senderID: secondPeerID,
            targetID: hostID,
            sessionID: secondPrompt.sessionID,
            envelopes: [secondPrompt])

        let firstTask = Task {
            do {
                return Result<LocalComputerUseRPCResponse, Error>.success(
                    try await LocalComputerUseRPCTransport.call(
                        endpoint: endpoint,
                        credential: credential,
                        request: firstRequest))
            } catch {
                return Result<LocalComputerUseRPCResponse, Error>.failure(error)
            }
        }
        let secondTask = Task {
            do {
                return Result<LocalComputerUseRPCResponse, Error>.success(
                    try await LocalComputerUseRPCTransport.call(
                        endpoint: endpoint,
                        credential: credential,
                        request: secondRequest))
            } catch {
                return Result<LocalComputerUseRPCResponse, Error>.failure(error)
            }
        }
        let results = await [firstTask.value, secondTask.value]
        let responses = results.compactMap { try? $0.get() }

        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(authorizedPeers.count, 1)
        let queued = try await channel.poll()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.senderID, authorizedPeers.first)
        XCTAssertEqual(
            Set(responses.flatMap(\.acceptedEnvelopeIDs)),
            Set(queued.map(\.id)))
    }

    func testSetupOnlyCloudChannelAllowsRequestAcknowledgementAndProgress() async throws {
        let request = makeEnvelope(
            id: "cloud-setup-request",
            kind: .setupRequest,
            body: #"{"request_id":"setup"}"#)
        let child = BufferedHostComputerUseChannel(
            hostID: hostID,
            pairingCode: pairingCode,
            incoming: [request])
        let setupOnly = SetupOnlyHostComputerUseChannel(wrapping: child)

        let received = try await setupOnly.poll()
        XCTAssertEqual(received, [request])
        let acknowledgementsBeforeManager = await child.acknowledgedIDs()
        XCTAssertTrue(acknowledgementsBeforeManager.isEmpty)

        try await setupOnly.acknowledge(received)
        let acknowledged = await child.acknowledgedIDs()
        XCTAssertEqual(acknowledged, [request.id])

        let progress = try await setupOnly.send(
            kind: .setupProgress,
            body: #"{"phase":"queued"}"#,
            to: peerID,
            sessionID: sessionID,
            messageID: "cloud-setup-progress")
        XCTAssertEqual(progress.kind, .setupProgress)
        let sent = await child.sentMessages()
        XCTAssertEqual(sent, [progress])
    }

    func testSetupOnlyCloudChannelFiltersAndAcknowledgesEveryTaskKind() async throws {
        let rejectedKinds: [ComputerUseEnvelope.Kind] = [
            .prompt,
            .assistant,
            .status,
            .pause,
            .resume,
            .cancel,
            .setupProgress,
            .approvalRequest,
            .approvalResponse,
        ]
        let rejected = rejectedKinds.enumerated().map { index, kind in
            makeEnvelope(
                id: "cloud-rejected-\(index)",
                kind: kind,
                body: "must not reach host task handling")
        }
        let child = BufferedHostComputerUseChannel(
            hostID: hostID,
            pairingCode: pairingCode,
            incoming: rejected)
        let setupOnly = SetupOnlyHostComputerUseChannel(wrapping: child)

        let received = try await setupOnly.poll()
        XCTAssertTrue(received.isEmpty)
        let acknowledged = await child.acknowledgedIDs()
        XCTAssertEqual(acknowledged, rejected.map(\.id))
    }

    func testSetupOnlyCloudChannelFailsClosedWhenTaskCleanupFails() async {
        let setupRequest = makeEnvelope(
            id: "setup-hidden-until-cleanup",
            kind: .setupRequest)
        let rejectedPrompt = makeEnvelope(id: "cleanup-failure-prompt")
        let child = BufferedHostComputerUseChannel(
            hostID: hostID,
            pairingCode: pairingCode,
            incoming: [setupRequest, rejectedPrompt],
            rejectAcknowledgements: true)
        let setupOnly = SetupOnlyHostComputerUseChannel(wrapping: child)

        do {
            _ = try await setupOnly.poll()
            XCTFail("A setup request escaped before task-record cleanup")
        } catch let SignalingError.transport(message) {
            XCTAssertEqual(message, "test acknowledgement failure")
        } catch {
            XCTFail("Unexpected cleanup error: \(error)")
        }
        let attemptedCleanup = await child.acknowledgedIDs()
        XCTAssertEqual(attemptedCleanup, [rejectedPrompt.id])
    }

    func testSetupOnlyCloudChannelRejectsEveryNonProgressSend() async {
        let disallowedKinds: [ComputerUseEnvelope.Kind] = [
            .prompt,
            .assistant,
            .status,
            .pause,
            .resume,
            .cancel,
            .setupRequest,
            .approvalRequest,
            .approvalResponse,
        ]
        let child = BufferedHostComputerUseChannel(
            hostID: hostID,
            pairingCode: pairingCode)
        let setupOnly = SetupOnlyHostComputerUseChannel(wrapping: child)

        for kind in disallowedKinds {
            do {
                _ = try await setupOnly.send(
                    kind: kind,
                    body: "must stay local",
                    to: peerID,
                    sessionID: sessionID,
                    messageID: "rejected-\(kind.rawValue)")
                XCTFail("CloudKit accepted outbound \(kind)")
            } catch let SignalingError.transport(message) {
                XCTAssertEqual(
                    message,
                    SetupOnlyHostComputerUseChannel.rejectedSendMessage)
            } catch {
                XCTFail("Unexpected outbound rejection error: \(error)")
            }
        }

        let sent = await child.sentMessages()
        XCTAssertTrue(sent.isEmpty)
    }

    func testMultiplexKeepsSameSessionCloudSetupAndLANResultsOnSeparateRoutes() async throws {
        let setupRequest = makeEnvelope(
            id: "same-session-setup",
            kind: .setupRequest,
            body: #"{"request_id":"setup"}"#)
        let rejectedCloudPrompt = makeEnvelope(
            id: "same-session-cloud-prompt",
            kind: .prompt,
            body: "CloudKit must not run this task")
        let localPrompt = makeEnvelope(
            id: "same-session-local-prompt",
            kind: .prompt,
            body: "Open Calculator")
        let cloudChild = BufferedHostComputerUseChannel(
            hostID: hostID,
            pairingCode: pairingCode,
            incoming: [setupRequest, rejectedCloudPrompt])
        let cloudSetupOnly = SetupOnlyHostComputerUseChannel(
            wrapping: cloudChild)
        let lan = BufferedHostComputerUseChannel(
            hostID: hostID,
            pairingCode: pairingCode,
            incoming: [localPrompt])
        let multiplex = MultiplexHostComputerUseChannel(
            channels: [cloudSetupOnly, lan])
        defer { Task { await multiplex.stopPolling() } }

        _ = try await multiplex.poll()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var received: [ComputerUseEnvelope] = []
        while clock.now < deadline {
            received = try await multiplex.poll()
            if Set(received.map(\.id))
                == Set([setupRequest.id, localPrompt.id]) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            Set(received.map(\.id)),
            Set([setupRequest.id, localPrompt.id]))
        XCTAssertFalse(received.contains(rejectedCloudPrompt))
        try await multiplex.acknowledge(received)

        let progress = try await multiplex.send(
            kind: .setupProgress,
            body: #"{"phase":"ready"}"#,
            to: peerID,
            sessionID: sessionID,
            messageID: "same-session-progress")
        let assistant = try await multiplex.send(
            kind: .assistant,
            body: "Task completed",
            to: peerID,
            sessionID: sessionID,
            messageID: "same-session-assistant")

        let cloudSent = await cloudChild.sentMessages()
        let lanSent = await lan.sentMessages()
        XCTAssertEqual(cloudSent, [progress])
        XCTAssertEqual(lanSent, [assistant])
        let cloudAcknowledged = await cloudChild.acknowledgedIDs()
        let lanAcknowledged = await lan.acknowledgedIDs()
        XCTAssertEqual(
            Set(cloudAcknowledged),
            Set([rejectedCloudPrompt.id, setupRequest.id]))
        XCTAssertEqual(lanAcknowledged, [localPrompt.id])
        await multiplex.stopPolling()
    }

    func testMultiplexDrainsLANPromptWhileAnotherChildPollIsStalled() async throws {
        let stalled = StalledHostComputerUseChannel()
        let lan = LocalHostComputerUseChannel(
            hostID: hostID,
            pairingCode: pairingCode)
        let prompt = makeEnvelope(id: "lan-ready")
        try await lan.receiveFromClient(
            prompt,
            authenticatedSenderID: peerID)
        let multiplex = MultiplexHostComputerUseChannel(
            channels: [stalled, lan])
        defer { Task { await multiplex.stopPolling() } }

        let clock = ContinuousClock()
        _ = try await multiplex.poll()
        var received: [ComputerUseEnvelope] = []
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            received = try await multiplex.poll()
            if received.contains(prompt) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let stalledPollDidStart = await stalled.pollDidStart()
        XCTAssertTrue(stalledPollDidStart)
        XCTAssertTrue(received.contains(prompt))
        await multiplex.stopPolling()
    }

    func testStopPollingCancelsPollersButPreservesLearnedRouteForFinalSend() async throws {
        let inbound = makeEnvelope(id: "route-learning-prompt")
        let child = LifecycleHostComputerUseChannel(
            hostID: hostID,
            pairingCode: pairingCode,
            initialEnvelope: inbound)
        let multiplex = MultiplexHostComputerUseChannel(channels: [child])

        _ = try await multiplex.poll()
        var received: [ComputerUseEnvelope] = []
        let clock = ContinuousClock()
        let receiveDeadline = clock.now.advanced(by: .seconds(5))
        while clock.now < receiveDeadline {
            received = try await multiplex.poll()
            if received.contains(inbound) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(received.contains(inbound))

        // The multiplexer waits two seconds between child polls. Let this
        // child enter its cancellable long poll so stopPolling is proven to
        // cancel an in-flight poller, rather than merely setting a flag before
        // the next poll begins.
        let secondPollDeadline = clock.now.advanced(by: .seconds(5))
        while await child.pollCallCount() < 2,
              clock.now < secondPollDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pollCallCountBeforeStop = await child.pollCallCount()
        XCTAssertGreaterThanOrEqual(pollCallCountBeforeStop, 2)

        await multiplex.stopPolling()
        let cancellationDeadline = clock.now.advanced(by: .seconds(5))
        while await child.cancelledPollCount() == 0,
              clock.now < cancellationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        let didStopPolling = await child.didStopPolling()
        let cancelledPollCount = await child.cancelledPollCount()
        XCTAssertTrue(didStopPolling)
        XCTAssertGreaterThanOrEqual(cancelledPollCount, 1)

        let terminal = try await multiplex.send(
            kind: .assistant,
            body: "Task completed",
            to: peerID,
            sessionID: sessionID,
            messageID: "terminal-after-stop")
        XCTAssertEqual(terminal.id, "terminal-after-stop")
        XCTAssertEqual(terminal.targetID, peerID)
        let sentMessages = await child.sentMessages()
        XCTAssertEqual(sentMessages, [terminal])
    }

    private func makeEnvelope(
        id: String,
        senderID: String? = nil,
        sessionID: String? = nil,
        kind: ComputerUseEnvelope.Kind = .prompt,
        body: String = "Open Calculator and calculate 27 times 43"
    ) -> ComputerUseEnvelope {
        ComputerUseEnvelope(
            id: id,
            senderID: senderID ?? peerID,
            targetID: hostID,
            pairingCode: pairingCode,
            sessionID: sessionID ?? self.sessionID,
            kind: kind,
            body: body)
    }

    private func assertWireEquivalent(
        _ actual: ComputerUseEnvelope,
        _ expected: ComputerUseEnvelope,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(
            actual.senderID,
            expected.senderID,
            file: file,
            line: line)
        XCTAssertEqual(
            actual.targetID,
            expected.targetID,
            file: file,
            line: line)
        XCTAssertEqual(
            actual.pairingCode,
            expected.pairingCode,
            file: file,
            line: line)
        XCTAssertEqual(
            actual.sessionID,
            expected.sessionID,
            file: file,
            line: line)
        XCTAssertEqual(actual.kind, expected.kind, file: file, line: line)
        XCTAssertEqual(actual.body, expected.body, file: file, line: line)
        XCTAssertEqual(
            actual.createdAt.timeIntervalSince1970,
            expected.createdAt.timeIntervalSince1970,
            accuracy: 0.001,
            file: file,
            line: line)
    }
}

private actor BufferedHostComputerUseChannel: HostComputerUseChannel {
    private let hostID: String
    private let pairingCode: String
    private var incoming: [ComputerUseEnvelope]
    private var sent: [ComputerUseEnvelope] = []
    private var acknowledged: [String] = []
    private var wasStopped = false
    private let rejectAcknowledgements: Bool

    init(
        hostID: String,
        pairingCode: String,
        incoming: [ComputerUseEnvelope] = [],
        rejectAcknowledgements: Bool = false
    ) {
        self.hostID = hostID
        self.pairingCode = pairingCode
        self.incoming = incoming
        self.rejectAcknowledgements = rejectAcknowledgements
    }

    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        let envelope = ComputerUseEnvelope(
            id: explicitMessageID ?? UUID().uuidString,
            senderID: hostID,
            targetID: explicitTargetID ?? "",
            pairingCode: pairingCode,
            sessionID: explicitSessionID ?? "",
            kind: kind,
            body: body)
        sent.append(envelope)
        return envelope
    }

    func poll() async throws -> [ComputerUseEnvelope] {
        guard !wasStopped else { throw CancellationError() }
        let result = incoming
        incoming.removeAll()
        return result
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {
        acknowledged.append(contentsOf: envelopes.map(\.id))
        if rejectAcknowledgements {
            throw SignalingError.transport("test acknowledgement failure")
        }
    }

    func stopPolling() async {
        wasStopped = true
    }

    func sentMessages() -> [ComputerUseEnvelope] { sent }

    func acknowledgedIDs() -> [String] { acknowledged }
}

private actor StalledHostComputerUseChannel: HostComputerUseChannel {
    private var pollStarted = false
    private var pollContinuation:
        CheckedContinuation<[ComputerUseEnvelope], Never>?

    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        throw CancellationError()
    }

    func poll() async throws -> [ComputerUseEnvelope] {
        pollStarted = true
        return await withCheckedContinuation { continuation in
            pollContinuation = continuation
        }
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}

    func stopPolling() async {
        pollContinuation?.resume(returning: [])
        pollContinuation = nil
    }

    func pollDidStart() -> Bool { pollStarted }
}

private actor LifecycleHostComputerUseChannel: HostComputerUseChannel {
    private let hostID: String
    private let pairingCode: String
    private let initialEnvelope: ComputerUseEnvelope
    private var didDeliverInitialEnvelope = false
    private var pollCalls = 0
    private var cancelledPolls = 0
    private var wasStopped = false
    private var sent: [ComputerUseEnvelope] = []

    init(
        hostID: String,
        pairingCode: String,
        initialEnvelope: ComputerUseEnvelope
    ) {
        self.hostID = hostID
        self.pairingCode = pairingCode
        self.initialEnvelope = initialEnvelope
    }

    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        let envelope = ComputerUseEnvelope(
            id: explicitMessageID ?? UUID().uuidString,
            senderID: hostID,
            targetID: explicitTargetID ?? initialEnvelope.senderID,
            pairingCode: pairingCode,
            sessionID: explicitSessionID ?? initialEnvelope.sessionID,
            kind: kind,
            body: body)
        sent.append(envelope)
        return envelope
    }

    func poll() async throws -> [ComputerUseEnvelope] {
        pollCalls += 1
        if !didDeliverInitialEnvelope {
            didDeliverInitialEnvelope = true
            return [initialEnvelope]
        }
        do {
            try await Task.sleep(for: .seconds(30))
            return []
        } catch {
            if error is CancellationError { cancelledPolls += 1 }
            throw error
        }
    }

    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}

    func stopPolling() async { wasStopped = true }

    func didStopPolling() -> Bool { wasStopped }

    func cancelledPollCount() -> Int { cancelledPolls }

    func pollCallCount() -> Int { pollCalls }

    func sentMessages() -> [ComputerUseEnvelope] { sent }
}
