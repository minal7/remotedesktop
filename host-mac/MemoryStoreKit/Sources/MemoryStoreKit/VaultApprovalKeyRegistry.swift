import CryptoKit
import CSQLCipherBridge
import Foundation

extension PersonalMemoryService {
    /// Stores a paired peer's public approval key in the encrypted, generation-scoped database.
    /// A different key cannot silently replace an existing enrollment; replacement requires the
    /// owner's separate Forget/re-enrollment flow.
    public func enrollVaultApprovalKey(peerID: String, publicKeyX963: Data,
                                       context: OwnerMemoryContext) throws {
        guard Self.validApprovalContext(context), Self.validApprovalPeer(peerID),
              publicKeyX963.count == 65,
              (try? P256.Signing.PublicKey(x963Representation: publicKeyX963)) != nil else {
            throw MemoryStoreError.invalidInput
        }
        try writer.withVaultEntryOperation(context: context) { revalidate in
            try revalidate()
            try store.enrollVaultApprovalKey(ownerID: context.ownerID,
                                             peerID: peerID,
                                             publicKey: publicKeyX963)
            try revalidate()
        }
    }

    /// Returns the enrolled public key for an authorized peer, or nil when it is not enrolled.
    public func vaultApprovalKey(peerID: String, context: OwnerMemoryContext) throws -> Data? {
        guard Self.validApprovalContext(context), Self.validApprovalPeer(peerID) else {
            throw MemoryStoreError.invalidInput
        }
        return try writer.withVaultEntryStatus(context: context) {
            let key = try store.vaultApprovalKey(ownerID: context.ownerID, peerID: peerID)
            if let key, (try? P256.Signing.PublicKey(x963Representation: key)) == nil {
                throw MemoryStoreError.storageFailure(Int32(MemorySQLCipherStatusDatabaseError.rawValue))
            }
            return key
        }
    }

    private static func validApprovalPeer(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.utf8.contains(0)
    }

    private static func validApprovalContext(_ value: OwnerMemoryContext) -> Bool {
        validApprovalPeer(value.ownerID) && validApprovalPeer(value.sessionID)
            && (value.taskID.map(validApprovalPeer) ?? true)
    }
}
