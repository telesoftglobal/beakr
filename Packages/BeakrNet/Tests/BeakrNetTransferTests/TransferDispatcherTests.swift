import Foundation
import CryptoKit
import Testing
import BeakrNetCore
import BeakrNetTransfer

@Suite("Transfer dispatcher")
struct TransferDispatcherTests {
    @Test("Authorization precedes staging mutation")
    func authorization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_000), source = NodeID(), destination = NodeID(), session = SessionID(), id = TransferID()
        let context = TransferContext(networkID: .test, sessionID: session, sourceNodeID: source, destinationNodeID: destination)
        let manifest = TransferManifest(transferID: id, context: context, byteCount: 1, chunkSize: 1, chunkCount: 1,
                                        contentDigest: Data(SHA256.hash(data: Data([1]))), mediaType: "x", expiresAt: now.addingTimeInterval(60))
        let store = try await TransferStagingStore.open(rootURL: root, now: now)
        let dispatcher = TransferDispatcher(store: store, authorization: .init { _, _, _ in false }, clock: { now })
        let envelope = try TransferCodec().makeEnvelope(for: .init(kind: .manifest, transferID: id, manifest: manifest),
                                                        context: context, sequenceNumber: 1, createdAt: now,
                                                        deliveryPolicy: .init(durability: .durable))
        guard case .rejected(.unauthorized, let response) = await dispatcher.dispatch(envelope) else {
            Issue.record("Expected rejection"); return
        }
        #expect(response?.errorCode == .unauthorized)
        await #expect(throws: TransferStagingError.unknownTransfer) { try await store.manifest(for: id) }
    }
}
