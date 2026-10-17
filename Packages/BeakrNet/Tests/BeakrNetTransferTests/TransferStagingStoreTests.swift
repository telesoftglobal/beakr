import Foundation
import CryptoKit
import Testing
import BeakrNetCore
import BeakrNetTransfer

@Suite("Transfer staging store")
struct TransferStagingStoreTests {
    @Test("Chunks resume after restart and publish only after final verification")
    func restartAndFinalize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("abcdef".utf8), id = TransferID(), now = Date(timeIntervalSince1970: 1_000)
        let manifest = TransferManifest(
            transferID: id, context: .init(networkID: .test, sessionID: SessionID(), sourceNodeID: NodeID(), destinationNodeID: NodeID()),
            byteCount: 6, chunkSize: 3, chunkCount: 2, contentDigest: Data(SHA256.hash(data: bytes)),
            mediaType: "application/octet-stream", expiresAt: now.addingTimeInterval(60)
        )
        let first = try await TransferStagingStore.open(rootURL: root, now: now)
        try await first.admit(manifest, now: now)
        let a = Data(bytes.prefix(3))
        _ = try await first.receive(.init(transferID: id, index: 0, offset: 0, bytes: a, digest: Data(SHA256.hash(data: a))), now: now)
        let restored = try await TransferStagingStore.open(rootURL: root, now: now)
        #expect(try await restored.missingRanges(for: id) == [.init(lowerBound: 1, upperBound: 2)])
        let b = Data(bytes.suffix(3))
        _ = try await restored.receive(.init(transferID: id, index: 1, offset: 3, bytes: b, digest: Data(SHA256.hash(data: b))), now: now)
        let completed = try await restored.finalize(id)
        #expect(try Data(contentsOf: completed) == bytes)
    }

    @Test("Restart rejects a corrupt staged chunk and requests it again")
    func corruptRestartChunk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_000), bytes = Data("abc".utf8), id = TransferID()
        let manifest = makeManifest(id: id, bytes: bytes, now: now)
        let store = try await TransferStagingStore.open(rootURL: root, now: now)
        try await store.admit(manifest, now: now)
        _ = try await store.receive(chunk(id: id, bytes: bytes), now: now)
        try Data("bad".utf8).write(to: root.appendingPathComponent(id.rawValue.uuidString).appendingPathComponent("chunk-0.data"))
        let restored = try await TransferStagingStore.open(rootURL: root, now: now)
        #expect(try await restored.missingRanges(for: id) == [.init(lowerBound: 0, upperBound: 1)])
    }

    @Test("Conflicting duplicates, storage pressure, cancellation, and expiry fail safely")
    func resourceAndCleanupBounds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_000), bytes = Data("abc".utf8), id = TransferID()
        let store = try await TransferStagingStore.open(rootURL: root, policy: .init(maximumConcurrentTransfers: 1, maximumReservedBytes: 3), now: now)
        try await store.admit(makeManifest(id: id, bytes: bytes, now: now), now: now)
        _ = try await store.receive(chunk(id: id, bytes: bytes), now: now)
        let other = Data("xyz".utf8)
        await #expect(throws: TransferStagingError.conflictingChunk) {
            try await store.receive(chunk(id: id, bytes: other), now: now)
        }
        await #expect(throws: TransferStagingError.storageLimit) {
            try await store.admit(makeManifest(id: TransferID(), bytes: Data([1]), now: now), now: now)
        }
        try await store.cancel(id)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id.rawValue.uuidString).path))
        let expiring = makeManifest(id: TransferID(), bytes: Data([1]), now: now, lifetime: 1)
        try await store.admit(expiring, now: now)
        try await store.garbageCollect(now: now.addingTimeInterval(2))
        await #expect(throws: TransferStagingError.unknownTransfer) { try await store.manifest(for: expiring.transferID) }
    }

    @Test("A wrong final digest never publishes an artifact")
    func finalDigestFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_000), bytes = Data("abc".utf8), id = TransferID()
        var manifest = makeManifest(id: id, bytes: bytes, now: now)
        manifest = .init(transferID: id, context: manifest.context, byteCount: manifest.byteCount,
                         chunkSize: manifest.chunkSize, chunkCount: manifest.chunkCount,
                         contentDigest: Data(repeating: 0, count: 32), mediaType: manifest.mediaType,
                         expiresAt: manifest.expiresAt)
        let store = try await TransferStagingStore.open(rootURL: root, now: now)
        try await store.admit(manifest, now: now)
        _ = try await store.receive(chunk(id: id, bytes: bytes), now: now)
        await #expect(throws: TransferStagingError.integrityFailure) { try await store.finalize(id) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id.rawValue.uuidString).appendingPathComponent("completed.data").path))
    }

    private func makeManifest(id: TransferID, bytes: Data, now: Date, lifetime: TimeInterval = 60) -> TransferManifest {
        .init(transferID: id, context: .init(networkID: .test, sessionID: SessionID(), sourceNodeID: NodeID(), destinationNodeID: NodeID()),
              byteCount: UInt64(bytes.count), chunkSize: UInt32(bytes.count), chunkCount: 1,
              contentDigest: Data(SHA256.hash(data: bytes)), mediaType: "x", expiresAt: now.addingTimeInterval(lifetime))
    }
    private func chunk(id: TransferID, bytes: Data) -> TransferChunk {
        .init(transferID: id, index: 0, offset: 0, bytes: bytes, digest: Data(SHA256.hash(data: bytes)))
    }
}
