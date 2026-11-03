import CryptoKit
import Foundation

/// Opaque correlation value for one immutable local storage generation.
/// Callers can carry and compare it, but cannot construct a binding or inspect its storage paths.
public struct MemoryStoreBinding: Sendable, Equatable {
    public let reference: String

    let generation: MemoryStoreGeneration
    let device: UInt64
    let inode: UInt64

    init(generation: MemoryStoreGeneration, device: UInt64, inode: UInt64) {
        self.generation = generation
        self.device = device
        self.inode = inode
        self.reference = Self.makeReference(generation: generation, device: device, inode: inode)
    }

    /// Checks only that the opaque reference matches its captured fields; owner authorization
    /// remains the host's responsibility and is never implied by this correlation value.
    func hasConsistentReference() -> Bool {
        reference == Self.makeReference(generation: generation, device: device, inode: inode)
    }

    private static func makeReference(generation: MemoryStoreGeneration,
                                      device: UInt64, inode: UInt64) -> String {
        let fields = ["personal-memory-binding-v1", String(device), String(inode),
            generation.baseNamespace.databaseKeyService, generation.baseNamespace.vaultService,
            generation.identifier]
        var bytes = Data()
        for field in fields {
            let value = Data(field.utf8)
            var count = UInt32(value.count).bigEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
            bytes.append(value)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
