import Foundation
import Testing
import BeakrNetCore
import BeakrNetData

@Suite("Application Data route handoff")
struct DataHandoffTests {
    @Test("An ambiguous LAN write retries unchanged over relay and mutates once")
    func unchangedRetryMutatesOnce() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let localNode = NodeID()
        let remoteNode = NodeID()
        let sessionID = SessionID()
        let operation = DataOperation(namespace: "com.example", name: "mutate", version: 1)
        let correlation = DataCorrelationID()
        let handler = HandoffHandler(response: DataMessage(
            kind: .response, operation: operation, correlationID: correlation, body: Data("done".utf8)
        ))
        let dispatcher = DataDispatcher(supportedOperations: [operation], handler: handler, clock: { now })
        let receiver = BeakrNetSession(id: sessionID, localNodeID: remoteNode, remoteNodeID: localNode, state: .active, now: now)
        let sender = BeakrNetSession(id: sessionID, localNodeID: localNode, remoteNodeID: remoteNode, state: .active, now: now)
        let coordinator = PeerRouteCoordinator(remoteNodeID: remoteNode)
        let driver = SessionDeliveryDriver(session: sender, coordinator: coordinator, clock: { now })
        let relay = DispatchingTransport(kind: .relay, receiver: receiver, dispatcher: dispatcher, ambiguousAfterWrite: false)
        let lan = DispatchingTransport(kind: .local, receiver: receiver, dispatcher: dispatcher, ambiguousAfterWrite: true)
        _ = await register(relay, coordinator: coordinator, driver: driver)
        _ = await register(lan, coordinator: coordinator, driver: driver)

        let request = DataMessage(
            kind: .request, operation: operation, correlationID: correlation,
            idempotencyKey: DataIdempotencyKey(), deadline: now.addingTimeInterval(30)
        )
        let envelope = try DataCodec().makeEnvelope(
            for: request, sessionID: sessionID, sourceNodeID: localNode, destinationNodeID: remoteNode,
            sequenceNumber: 1, createdAt: now,
            deliveryPolicy: .init(durability: .durable, expiresAt: now.addingTimeInterval(60))
        )

        guard case .sent(let route, let attempts) = try await driver.deliver(envelope) else {
            Issue.record("Expected relay fallback"); return
        }
        #expect(route.transportID == relay.id)
        #expect(attempts == 2)
        #expect(await lan.sent == [envelope])
        #expect(await relay.sent == [envelope])
        #expect(await handler.count == 1)
        #expect(await lan.response?.correlationID == correlation)
        #expect(await relay.response == nil)
    }

    private func register(
        _ transport: DispatchingTransport,
        coordinator: PeerRouteCoordinator,
        driver: SessionDeliveryDriver
    ) async -> UInt64 {
        let generation = await coordinator.beginCandidate(
            transportID: transport.id, kind: transport.kind, capabilities: transport.capabilities
        )
        #expect(await coordinator.candidateAuthenticated(transportID: transport.id, generation: generation))
        #expect(await coordinator.candidateReady(transportID: transport.id, generation: generation))
        await driver.register(transport, generation: generation)
        return generation
    }
}

private enum HandoffError: Error { case ambiguous }

private actor DispatchingTransport: BeakrNetTransport {
    nonisolated let id = TransportID()
    nonisolated let kind: TransportKind
    nonisolated let capabilities = TransportCapabilities(
        preservesOrder: true, supportsImmediateDelivery: true,
        supportsQueuedDelivery: true, supportsBackgroundDelivery: false
    )
    let receiver: BeakrNetSession
    let dispatcher: DataDispatcher
    let ambiguousAfterWrite: Bool
    private(set) var sent: [BeakrNetEnvelope] = []
    private(set) var response: DataMessage?

    init(kind: TransportKind, receiver: BeakrNetSession, dispatcher: DataDispatcher, ambiguousAfterWrite: Bool) {
        self.kind = kind
        self.receiver = receiver
        self.dispatcher = dispatcher
        self.ambiguousAfterWrite = ambiguousAfterWrite
    }

    func send(_ envelope: BeakrNetEnvelope) async throws {
        sent.append(envelope)
        if try await receiver.accept(envelope, now: envelope.createdAt) == .accepted {
            if case .handled(let dispatchedResponse) = await dispatcher.dispatch(envelope) {
                response = dispatchedResponse
            }
        }
        if ambiguousAfterWrite { throw HandoffError.ambiguous }
    }

    func receive() async -> BeakrNetEnvelope? { nil }
    func close() async {}
}

private actor HandoffHandler: DataMessageHandler {
    private(set) var count = 0
    let response: DataMessage

    init(response: DataMessage) { self.response = response }

    func handle(_ message: DataMessage, envelope: BeakrNetEnvelope) async throws -> DataMessage? {
        count += 1
        return response
    }
}
