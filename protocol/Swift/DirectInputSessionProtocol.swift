import Foundation

/// Optional protocol-v1 direct-input freshness. These identifiers carry no
/// account credentials or input contents. Counters never wrap within a channel.
struct DirectInputHello: Codable, Equatable, Sendable {
    let version: Int
    let clientID: UUID
    let revision: UInt32
    init(clientID: UUID, revision: UInt32) {
        version = 1; self.clientID = clientID; self.revision = revision
    }
    var isValid: Bool { version == 1 && revision > 0 }
}

struct DirectInputAcknowledgement: Codable, Equatable, Sendable {
    let version: Int
    let clientID: UUID
    let revision: UInt32
    let hostID: UUID
    let generation: UInt32
    init(hello: DirectInputHello, hostID: UUID, generation: UInt32) {
        version = 1; clientID = hello.clientID; revision = hello.revision
        self.hostID = hostID; self.generation = generation
    }
    var isValid: Bool { version == 1 && revision > 0 && generation > 0 }
}

struct DirectInputStamp: Codable, Equatable, Sendable {
    let hostID: UUID
    let generation: UInt32
    let sequence: UInt32
    var isValid: Bool { generation > 0 && sequence > 0 }
}

enum DirectInputWire {
    static let version = 1
    static let inputInvalidationVersion = 1
    static let captureRecoveryTimeoutSeconds = 30
    static let captureHandshakeTimeout: Duration = .seconds(captureRecoveryTimeoutSeconds + 5)
    private struct Capabilities: Decodable { let inputSessions: Int }
    static func capability(in object: [String: Any]?) -> Int? {
        guard let object, object["inputSessions"] != nil else { return 0 }
        guard let value = decode(object, as: Capabilities.self), value.inputSessions >= 0 else { return nil }
        return value.inputSessions
    }
    private struct InvalidationCapability: Decodable { let inputInvalidation: Int }
    static func invalidationCapability(in object: [String: Any]?) -> Int? {
        guard let object, object["inputInvalidation"] != nil else { return 0 }
        guard let value = decode(object, as: InvalidationCapability.self),
              (0...inputInvalidationVersion).contains(value.inputInvalidation) else { return nil }
        return value.inputInvalidation
    }
    static func object<Value: Encodable>(_ value: Value) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func decode<Value: Decodable>(_ value: Any, as type: Value.Type) -> Value? {
        guard let object = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Value state owned by the client's MainActor transport. It never queues or
/// replays input. A failed send terminates the transport rather than retrying
/// a possibly accepted key/text effect.
struct DirectInputClientState {
    enum AckResult: Equatable { case accepted, ignored, invalid }
    enum PacketAuthorization: Equatable { case legacy, scoped(DirectInputStamp) }
    private(set) var hello: DirectInputHello
    private(set) var isClosed = false
    private var connected = false
    private var helloSent = false
    private var legacyReady = false
    private var acknowledged: DirectInputAcknowledgement?
    private var lastAcknowledged: DirectInputAcknowledgement?
    private var sequence: UInt32 = 0
    private var inputInvalidationVersion: Int?

    init(clientID: UUID = UUID()) { hello = .init(clientID: clientID, revision: 1) }

    @discardableResult
    mutating func connectionChanged(connected next: Bool) -> Bool {
        guard !isClosed else { return false }
        guard connected != next else { return true }
        connected = next
        if !next {
            let legacy = legacyReady
            legacyReady = false; acknowledged = nil; helloSent = false; sequence = 0
            guard !legacy, hello.revision < UInt32.max else { close(); return false }
            hello = .init(clientID: hello.clientID, revision: hello.revision + 1)
        }
        return true
    }

    var helloToSend: DirectInputHello? { connected && !helloSent && !isClosed ? hello : nil }

    @discardableResult
    mutating func markHelloSent(_ sent: DirectInputHello) -> Bool {
        guard helloToSend == sent else { return false }
        helloSent = true
        return true
    }

    mutating func accept(version: Int, acknowledgement: DirectInputAcknowledgement?,
                         inputInvalidation: Int = 0) -> AckResult {
        guard !isClosed, connected, helloSent else { return .ignored }
        guard (0...DirectInputWire.inputInvalidationVersion).contains(inputInvalidation),
              inputInvalidation == 0 || (version == DirectInputWire.version && acknowledgement != nil),
              inputInvalidationVersion == nil || inputInvalidationVersion == inputInvalidation else { return .invalid }
        if version == 0 {
            guard acknowledgement == nil, lastAcknowledged == nil, hello.revision == 1 else { return .invalid }
            legacyReady = true
            inputInvalidationVersion = inputInvalidation
            return .accepted
        }
        guard version == DirectInputWire.version, !legacyReady,
              let acknowledgement, acknowledgement.isValid else { return .invalid }
        guard acknowledgement.clientID == hello.clientID,
              acknowledgement.revision == hello.revision else { return .ignored }
        if let lastAcknowledged {
            guard acknowledgement.generation >= lastAcknowledged.generation else { return .ignored }
            if acknowledgement.generation == lastAcknowledged.generation {
                guard acknowledgement == lastAcknowledged else { return .invalid }
            }
        }
        if acknowledgement != acknowledged { sequence = 0 }
        acknowledged = acknowledgement; lastAcknowledged = acknowledgement
        inputInvalidationVersion = inputInvalidation
        return .accepted
    }

    /// Invalidate only the currently acknowledged host scope. Advancing the
    /// hello revision makes a delayed duplicate acknowledgement unable to
    /// reopen input while capture is still unavailable.
    mutating func invalidate(_ scope: DirectInputAcknowledgement) -> AckResult {
        guard !isClosed, connected, scope == acknowledged else { return .ignored }
        guard scope.isValid, inputInvalidationVersion == DirectInputWire.inputInvalidationVersion else { return .invalid }
        acknowledged = nil; helloSent = false; sequence = 0
        guard hello.revision < UInt32.max else { close(); return .invalid }
        hello = .init(clientID: hello.clientID, revision: hello.revision + 1)
        return .accepted
    }

    var isReady: Bool { !isClosed && connected && helloSent && (legacyReady || acknowledged != nil) }

    mutating func authorizeNextInput() -> PacketAuthorization? {
        guard isReady else { return nil }
        if legacyReady { return .legacy }
        guard let acknowledged, sequence < UInt32.max else { close(); return nil }
        sequence += 1
        return .scoped(.init(hostID: acknowledged.hostID, generation: acknowledged.generation, sequence: sequence))
    }

    mutating func close() {
        isClosed = true; connected = false; helloSent = false; legacyReady = false
        acknowledged = nil; lastAcknowledged = nil; sequence = 0
        inputInvalidationVersion = nil
    }
}
