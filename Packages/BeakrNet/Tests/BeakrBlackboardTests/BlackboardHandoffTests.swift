import Foundation
import Testing
import BeakrNetCore
import BeakrBlackboard

@Suite("Blackboard route handoff")
struct BlackboardHandoffTests {
    @Test("Ambiguous LAN delivery retries the identical operation over relay and applies once")
    func unchangedOperationRetry() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let source = NodeID(), destination = NodeID(), sessionID = SessionID(), space = BlackboardSpaceID()
        let repository = BlackboardRepository()
        try await repository.createSpace(id: space, name: "Notes", owner: source)
        let dispatcher = BlackboardDispatcher(repository: repository)
        let receiver = BeakrNetSession(id: sessionID, localNodeID: destination, remoteNodeID: source, state: .active, now: now)
        let sender = BeakrNetSession(id: sessionID, localNodeID: source, remoteNodeID: destination, state: .active, now: now)
        let coordinator = PeerRouteCoordinator(remoteNodeID: destination)
        let driver = SessionDeliveryDriver(session: sender, coordinator: coordinator, clock: { now })
        let relay = BlackboardTransport(kind: .relay, receiver: receiver, dispatcher: dispatcher, ambiguous: false)
        let lan = BlackboardTransport(kind: .local, receiver: receiver, dispatcher: dispatcher, ambiguous: true)
        for transport in [relay, lan] {
            let generation = await coordinator.beginCandidate(transportID: transport.id, kind: transport.kind, capabilities: transport.capabilities)
            _ = await coordinator.candidateAuthenticated(transportID: transport.id, generation: generation)
            _ = await coordinator.candidateReady(transportID: transport.id, generation: generation)
            await driver.register(transport, generation: generation)
        }
        let operation = BlackboardOperation(
            spaceID: space, recordID: BlackboardRecordID(), dot: .init(replicaID: BlackboardReplicaID(), counter: 1),
            context: .init(), kind: .write, value: .init(schema: "com.example", schemaVersion: 1, bytes: Data("value".utf8)), authoredAt: now
        )
        let message = BlackboardWireMessage(kind: .operationBatch, spaceID: space, operations: [operation])
        let envelope = try BlackboardCodec().makeEnvelope(
            for: message, sessionID: sessionID, sourceNodeID: source, destinationNodeID: destination,
            sequenceNumber: 1, createdAt: now, deliveryPolicy: .init(durability: .durable, expiresAt: now.addingTimeInterval(60))
        )
        guard case .sent(let route, let attempts) = try await driver.deliver(envelope) else { Issue.record("Expected fallback"); return }
        #expect(route.transportID == relay.id)
        #expect(attempts == 2)
        #expect(await lan.sent == [envelope])
        #expect(await relay.sent == [envelope])
        let snapshot = try await repository.snapshot(spaceID: space, authorizedNodeID: source)
        #expect(snapshot.journalOffset == 1)
        #expect(snapshot.records.count == 1)
    }
}

private enum BlackboardHandoffError: Error { case ambiguous }

private actor BlackboardTransport: BeakrNetTransport {
    nonisolated let id = TransportID()
    nonisolated let kind: TransportKind
    nonisolated let capabilities = TransportCapabilities(preservesOrder: true, supportsImmediateDelivery: true, supportsQueuedDelivery: true, supportsBackgroundDelivery: false)
    let receiver: BeakrNetSession
    let dispatcher: BlackboardDispatcher
    let ambiguous: Bool
    private(set) var sent: [BeakrNetEnvelope] = []
    init(kind: TransportKind, receiver: BeakrNetSession, dispatcher: BlackboardDispatcher, ambiguous: Bool) {
        self.kind = kind; self.receiver = receiver; self.dispatcher = dispatcher; self.ambiguous = ambiguous
    }
    func send(_ envelope: BeakrNetEnvelope) async throws {
        sent.append(envelope)
        if try await receiver.accept(envelope, now: envelope.createdAt) == .accepted { _ = await dispatcher.dispatch(envelope) }
        if ambiguous { throw BlackboardHandoffError.ambiguous }
    }
    func receive() async -> BeakrNetEnvelope? { nil }
    func close() async {}
}
