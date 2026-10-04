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
            transferID: id, context: .init(sessionID: SessionID(), sourceNodeID: NodeID(), destinationNodeID: NodeID()),
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
}
