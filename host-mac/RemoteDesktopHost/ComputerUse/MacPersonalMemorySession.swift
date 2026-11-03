import Foundation

/// Narrow host-authority bridge. The session stores no owner credential or manager;
/// production closures capture the manager's opaque local-owner scope lease.
struct MacPersonalMemoryErasureBoundary {
    let authorizationGeneration: UInt64
    let isScopeCurrent: @MainActor () -> Bool
    let hasMatchingErasure: @MainActor () -> Bool
    let begin: PersonalMemoryCoordinator.BeginErasure
    let isQuiescent: PersonalMemoryCoordinator.IsErasureQuiescent
    let end: PersonalMemoryCoordinator.EndErasure
    let revokeScope: @MainActor () -> Void

    init(authorizationGeneration: UInt64,
         isScopeCurrent: @escaping @MainActor () -> Bool,
         hasMatchingErasure: @escaping @MainActor () -> Bool,
         begin: @escaping PersonalMemoryCoordinator.BeginErasure,
         isQuiescent: @escaping PersonalMemoryCoordinator.IsErasureQuiescent,
         end: @escaping PersonalMemoryCoordinator.EndErasure,
         revokeScope: @escaping @MainActor () -> Void = {}) {
        self.authorizationGeneration = authorizationGeneration
        self.isScopeCurrent = isScopeCurrent
        self.hasMatchingErasure = hasMatchingErasure
        self.begin = begin
        self.isQuiescent = isQuiescent
        self.end = end
        self.revokeScope = revokeScope
    }

    static let unavailable = MacPersonalMemoryErasureBoundary(
        authorizationGeneration: 0,
        isScopeCurrent: { false }, hasMatchingErasure: { false },
        begin: { _ in nil }, isQuiescent: { _ in false }, end: { _ in })
}

/// Default-off in-process owner display scope. It binds one controller to an
/// already-resolved owner and a fresh context; it never reads network identity.
@MainActor
final class MacPersonalMemorySession {
    let scopeNonce: UUID
    let controller: PersonalMemoryViewModel
    private let channel: MacPersonalMemoryCommandChannel
    private let lifetime: MacMemoryScopeLifetime
    private let erasureBoundary: MacPersonalMemoryErasureBoundary

    init(
        enabled: Bool = false,
        ownerID: String?,
        serviceFactory: PersonalMemoryCoordinator.ServiceFactory? = nil,
        writerFactory: PersonalMemoryCoordinator.WriterFactory? = nil,
        erasureBoundary: MacPersonalMemoryErasureBoundary = .unavailable,
        forgetRecovery: PersonalMemoryCoordinator.ForgetRecovery? = nil,
        captureBinding: PersonalMemoryCoordinator.CaptureBinding? = nil,
        boundServiceFactory: PersonalMemoryCoordinator.BoundServiceFactory? = nil,
        boundForgetRecovery: PersonalMemoryCoordinator.BoundForgetRecovery? = nil
    ) {
        let nonce = UUID()
        let context = LocalMemoryRPCContext(
            peerID: "mac-owner-view-\(UUID().uuidString.lowercased())",
            sessionID: nonce.uuidString.lowercased())
        let lifetime = MacMemoryScopeLifetime()
        let validOwner = ownerID.map(Self.isValidOwnerID) == true
        let active = enabled && validOwner && erasureBoundary.isScopeCurrent()
        let coordinator: PersonalMemoryCoordinator?
        if active, let ownerID {
            coordinator = PersonalMemoryCoordinator(
                enabled: true,
                ownerID: ownerID,
                leaseProvider: { [weak lifetime] candidate, requiresTask in
                    guard lifetime?.isActive == true,
                          erasureBoundary.isScopeCurrent(),
                          !requiresTask, candidate == context else { return nil }
                    return LocalMemoryHostLease(
                        peerID: context.peerID,
                        sessionID: context.sessionID,
                        taskID: nil,
                        authorizationGeneration: erasureBoundary.authorizationGeneration,
                        taskAuthority: .none)
                },
                serviceFactory: serviceFactory,
                writerFactory: writerFactory,
                beginErasure: erasureBoundary.begin,
                isErasureQuiescent: erasureBoundary.isQuiescent,
                endErasure: erasureBoundary.end,
                forgetRecovery: forgetRecovery,
                captureBinding: captureBinding,
                boundServiceFactory: boundServiceFactory,
                boundForgetRecovery: boundForgetRecovery)
        } else {
            coordinator = nil
        }
        let commandChannel = MacPersonalMemoryCommandChannel(
            coordinator: coordinator,
            context: context,
            lifetime: lifetime,
            disabledStatus: enabled ? .unauthorized : .disabled,
            isScopeCurrent: erasureBoundary.isScopeCurrent,
            hasMatchingErasure: erasureBoundary.hasMatchingErasure)
        scopeNonce = nonce
        self.lifetime = lifetime
        self.erasureBoundary = erasureBoundary
        channel = commandChannel
        controller = PersonalMemoryViewModel(enabled: active, channel: commandChannel)
        commandChannel.bind(controller)
    }

    /// A deliberately context-free command seam for tests and the display
    /// composition. Owner and lease material never comes from the caller.
    func sendMemoryCommand(_ command: LocalMemoryRPCCommand) async throws -> LocalMemoryRPCReply {
        try await channel.sendMemoryCommand(command)
    }

    func close() {
        lifetime.invalidate()
        channel.invalidate()
        controller.disconnect()
        erasureBoundary.revokeScope()
    }

    func invalidate() { close() }

    /// Called synchronously by the host's pre-automation hook. Only an already
    /// confirmed command with a matching manager fence may retain a retry lane.
    @discardableResult
    func willBeginAutomation() -> Bool {
        guard controller.forgetCommandID != nil, lifetime.isActive,
              channel.hasMatchingErasure else { return false }
        guard let commandID = controller.forgetCommandID else { return false }
        channel.enterForgetOnly(commandID: commandID)
        return true
    }

    private static func isValidOwnerID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

@MainActor
private final class MacPersonalMemoryCommandChannel: PersonalMemoryChannel {
    private let context: LocalMemoryRPCContext
    private let disabledStatus: LocalMemoryRPCReply.Status
    private weak var lifetime: MacMemoryScopeLifetime?
    private var coordinator: PersonalMemoryCoordinator?
    private var isClosed = false
    private weak var controller: PersonalMemoryViewModel?
    private var forgetOnlyCommandID: String?
    private let scopeCurrentCheck: @MainActor () -> Bool
    private let matchingErasureCheck: @MainActor () -> Bool

    init(coordinator: PersonalMemoryCoordinator?, context: LocalMemoryRPCContext,
         lifetime: MacMemoryScopeLifetime,
         disabledStatus: LocalMemoryRPCReply.Status,
         isScopeCurrent: @escaping @MainActor () -> Bool = { false },
         hasMatchingErasure: @escaping @MainActor () -> Bool = { false }) {
        self.coordinator = coordinator
        self.context = context
        self.lifetime = lifetime
        self.disabledStatus = disabledStatus
        self.scopeCurrentCheck = isScopeCurrent
        self.matchingErasureCheck = hasMatchingErasure
    }

    func bind(_ controller: PersonalMemoryViewModel) { self.controller = controller }

    var hasMatchingErasure: Bool { matchingErasureCheck() }

    func enterForgetOnly(commandID: String) { forgetOnlyCommandID = commandID }

    func invalidate() {
        guard !isClosed else { return }
        isClosed = true
        coordinator?.close()
        coordinator = nil
    }

    func sendMemoryCommand(_ command: LocalMemoryRPCCommand) async throws -> LocalMemoryRPCReply {
        guard !Task.isCancelled else { return reply(command, status: .unauthorized) }
        guard !isClosed else { return reply(command, status: .unauthorized) }
        guard lifetime?.isActive == true else { return reply(command, status: .unauthorized) }
        guard let coordinator else { return reply(command, status: disabledStatus) }
        guard scopeCurrentCheck() else { return reply(command, status: .unauthorized) }
        guard Self.isAllowed(command, acceptedCommandID: controller?.forgetCommandID,
                             acceptedGenerationReference: controller?.confirmedForgetGenerationReference,
                             forgetOnlyCommandID: forgetOnlyCommandID) else {
            return reply(command, status: .unauthorized)
        }
        let response = await coordinator.handle(command, context: context)
        guard !Task.isCancelled, !isClosed, lifetime?.isActive == true,
              matchingErasureCheckIsCurrentAfter(command),
              Self.replyMatches(response, command: command) else {
            return reply(command, status: .unauthorized)
        }
        return response
    }

    private func matchingErasureCheckIsCurrentAfter(_ command: LocalMemoryRPCCommand) -> Bool {
        guard scopeCurrentCheck() else { return false }
        if command.operation == .forgetEverything {
            guard let commandID = command.commandID else { return false }
            if let forgetOnlyCommandID {
                // endErasure clears the active fence before the coordinator
                // returns. The still-current owner scope and exact accepted ID
                // carry only this reply through that boundary.
                return forgetOnlyCommandID == commandID
                    && controller?.forgetCommandID == commandID
                    && controller?.confirmedForgetGenerationReference == command.generationReference
            }
            return controller?.forgetCommandID == commandID
                && controller?.confirmedForgetGenerationReference == command.generationReference
        }
        return forgetOnlyCommandID == nil && controller?.forgetCommandID == nil
    }

    private func reply(_ command: LocalMemoryRPCCommand,
                       status: LocalMemoryRPCReply.Status) -> LocalMemoryRPCReply {
        LocalMemoryRPCReply(operation: command.operation, commandID: command.commandID,
                            rememberKind: command.rememberKind, status: status,
                            generationReference: command.operation == .forgetEverything
                                || command.operation == .initializeMemoryGeneration
                                ? command.generationReference : nil)
    }

    private static func isAllowed(_ command: LocalMemoryRPCCommand,
                                  acceptedCommandID: String?,
                                  acceptedGenerationReference: String?,
                                  forgetOnlyCommandID: String?) -> Bool {
        if command.operation == .forgetEverything {
            guard let commandID = command.commandID,
                  command.generationReference == acceptedGenerationReference else { return false }
            return forgetOnlyCommandID.map { $0 == commandID } ?? (acceptedCommandID == commandID)
        }
        guard forgetOnlyCommandID == nil, acceptedCommandID == nil else { return false }
        return switch command.operation {
        case .captureMemoryGeneration: true
        case .listRecords, .searchRecords, .editRecord, .deleteMetadata: true
        case .remember, .confirmProposal, .listMetadata, .forgetEverything,
             .initializeMemoryGeneration: false
        }
    }

    private static func replyMatches(_ reply: LocalMemoryRPCReply,
                                     command: LocalMemoryRPCCommand) -> Bool {
        do { try reply.validate() } catch { return false }
        guard reply.operation == command.operation,
              reply.commandID == command.commandID else { return false }
        if command.operation == .captureMemoryGeneration {
            return reply.status != .completed || reply.generationReference != nil
        }
        if command.operation == .forgetEverything {
            guard reply.generationReference == command.generationReference else { return false }
        }
        guard command.operation == .forgetEverything else { return true }
        if reply.status == .completed {
            return reply.rememberKind == nil && reply.recordID == nil
                && reply.idempotentRetry == nil && reply.metadata.isEmpty
                && reply.records.isEmpty && reply.nextRecordID == nil
        }
        return true
    }
}

/// Shared only as a weak capability marker. The scope owns it; retained
/// controllers/channels cannot keep an otherwise-deallocated owner view alive.
private final class MacMemoryScopeLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    func invalidate() {
        lock.lock(); active = false; lock.unlock()
    }
}
