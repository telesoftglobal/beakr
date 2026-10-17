import Foundation
import CryptoKit
import Testing
import BeakrNetCore
import BeakrNetTransfer

@Suite("Transfer route handoff and fairness")
struct TransferHandoffTests {
    @Test("An ambiguous manifest retries unchanged and chunks continue over relay")
    func handoffContinuation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_000), source = NodeID(), destination = NodeID(), sessionID = SessionID()
        let context = TransferContext(networkID: .test, sessionID: sessionID, sourceNodeID: source, destinationNodeID: destination)
        let bytes = Data("payload".utf8), id = TransferID()
        let manifest = TransferManifest(transferID: id, context: context, byteCount: UInt64(bytes.count),
                                        chunkSize: UInt32(bytes.count), chunkCount: 1,
                                        contentDigest: Data(SHA256.hash(data: bytes)), mediaType: "x", expiresAt: now.addingTimeInterval(60))
        let store = try await TransferStagingStore.open(rootURL: root, now: now)
        let dispatcher = TransferDispatcher(store: store, clock: { now })
        let receiving = BeakrNetSession(id: sessionID, networkID: .test, localNodeID: destination, remoteNodeID: source, state: .active, now: now)
        let sending = BeakrNetSession(id: sessionID, networkID: .test, localNodeID: source, remoteNodeID: destination, state: .active, now: now)
        let coordinator = PeerRouteCoordinator(networkID: .test, remoteNodeID: destination)
        let driver = SessionDeliveryDriver(session: sending, coordinator: coordinator, clock: { now })
        let relay = TransferTransport(kind: .relay, receiver: receiving, dispatcher: dispatcher, ambiguous: false)
        let lan = TransferTransport(kind: .local, receiver: receiving, dispatcher: dispatcher, ambiguous: true)
        for transport in [relay, lan] {
            let generation = await coordinator.beginCandidate(transportID: transport.id, kind: transport.kind, capabilities: transport.capabilities)
            _ = await coordinator.candidateAuthenticated(transportID: transport.id, generation: generation)
            _ = await coordinator.candidateReady(transportID: transport.id, generation: generation)
            await driver.register(transport, generation: generation)
        }
        let codec = TransferCodec()
        let manifestEnvelope = try codec.makeEnvelope(for: .init(kind: .manifest, transferID: id, manifest: manifest),
                                                      context: context, sequenceNumber: 1, createdAt: now,
                                                      deliveryPolicy: .init(durability: .durable, expiresAt: manifest.expiresAt))
        guard case .sent(let route, let attempts) = try await driver.deliver(manifestEnvelope) else { Issue.record("Expected fallback"); return }
        #expect(route.transportID == relay.id); #expect(attempts == 2)
        #expect(await lan.sent == [manifestEnvelope]); #expect(await relay.sent == [manifestEnvelope])
        let chunk = TransferChunk(transferID: id, index: 0, offset: 0, bytes: bytes, digest: Data(SHA256.hash(data: bytes)))
        let chunkEnvelope = try codec.makeEnvelope(for: .init(kind: .chunk, transferID: id, chunk: chunk), context: context,
                                                   sequenceNumber: 2, createdAt: now,
                                                   deliveryPolicy: .init(durability: .durable, expiresAt: manifest.expiresAt))
        _ = try await driver.deliver(chunkEnvelope)
        #expect(try await store.missingRanges(for: id).isEmpty)
    }

    @Test("Sustained transfer Data cannot consume reserved Control service")
    func controlFairness() async throws {
        let queue = BoundedRelayQueue(networkID: .test, policy: .init(maximumMessagesPerNode: 8, maximumTotalMessages: 8,
                                                     reservedControlMessagesPerNode: 2, reservedControlMessagesTotal: 2,
                                                     maximumConsecutiveControlMessages: 2, messageTimeToLive: 60))
        let node = NodeID(), now = Date(timeIntervalSince1970: 1_000), session = SessionID(), source = NodeID()
        for index in 0..<6 {
            try await queue.enqueue(.init(networkID: .test, sessionID: session, sourceNodeID: source, destinationNodeID: node,
                                      sequenceNumber: UInt64(index), channel: .data,
                                      deliveryPolicy: .init(durability: .queued, expiresAt: now.addingTimeInterval(30)),
                                      payloadType: TransferWireMessage.payloadType, payload: Data(), createdAt: now), for: node, now: now)
        }
        try await queue.enqueue(.init(networkID: .test, sessionID: session, sourceNodeID: source, destinationNodeID: node,
                                  sequenceNumber: 99, channel: .control, deliveryPolicy: .init(durability: .ephemeral),
                                  payloadType: "beakrnet.session-liveness", payload: Data(), createdAt: now), for: node, now: now)
        #expect(await queue.drain(for: node, now: now).first?.channel == .control)
    }
}

private enum TransferHandoffError: Error { case ambiguous }
private actor TransferTransport: BeakrNetTransport {
    nonisolated let id = TransportID(); nonisolated let kind: TransportKind
    nonisolated let capabilities = TransportCapabilities(preservesOrder: true, supportsImmediateDelivery: true, supportsQueuedDelivery: true, supportsBackgroundDelivery: false)
    let receiver: BeakrNetSession; let dispatcher: TransferDispatcher; let ambiguous: Bool
    private(set) var sent: [BeakrNetEnvelope] = []
    init(kind: TransportKind, receiver: BeakrNetSession, dispatcher: TransferDispatcher, ambiguous: Bool) { self.kind = kind; self.receiver = receiver; self.dispatcher = dispatcher; self.ambiguous = ambiguous }
    func send(_ envelope: BeakrNetEnvelope) async throws { sent.append(envelope); if try await receiver.accept(envelope, now: envelope.createdAt) == .accepted { _ = await dispatcher.dispatch(envelope) }; if ambiguous { throw TransferHandoffError.ambiguous } }
    func receive() async -> BeakrNetEnvelope? { nil }; func close() async {}
}
