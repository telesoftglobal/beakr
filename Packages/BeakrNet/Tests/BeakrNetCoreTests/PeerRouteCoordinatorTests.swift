import Foundation
import Testing
import BeakrNetCore

@Suite("Per-peer route coordinator")
struct PeerRouteCoordinatorTests {
    @Test("Generations increase and stale callbacks cannot replace newer state")
    func rejectsStaleCallbacks() async {
        let peer = NodeID()
        let transportID = id(10)
        let coordinator = PeerRouteCoordinator(networkID: .test, remoteNodeID: peer)

        let first = await coordinator.beginCandidate(
            transportID: transportID,
            kind: .local,
            capabilities: capabilities
        )
        let second = await coordinator.beginCandidate(
            transportID: transportID,
            kind: .local,
            capabilities: capabilities
        )

        #expect(second > first)
        #expect(await !coordinator.candidateReady(transportID: transportID, generation: first))
        #expect(await coordinator.candidate(transportID: transportID)?.generation == second)
        #expect(await coordinator.candidate(transportID: transportID)?.isReady == false)
        #expect(await coordinator.diagnosticHistory.last == .staleCallbackIgnored(
            transportID: transportID,
            callbackGeneration: first,
            currentGeneration: second
        ))
    }

    @Test("LAN promotion is make-before-break")
    func promotesReadyLANWithoutDroppingRelay() async {
        let peer = NodeID()
        let envelope = makeEnvelope(destination: peer)
        let relayID = id(1)
        let localID = id(2)
        let coordinator = PeerRouteCoordinator(networkID: .test, remoteNodeID: peer)

        let relayGeneration = await coordinator.beginCandidate(
            transportID: relayID,
            kind: .relay,
            capabilities: capabilities
        )
        #expect(await coordinator.candidateReady(transportID: relayID, generation: relayGeneration))
        #expect(await coordinator.route(for: envelope, envelopeSizeBytes: 64)?.transportID == relayID)

        let localGeneration = await coordinator.beginCandidate(
            transportID: localID,
            kind: .local,
            capabilities: capabilities
        )
        #expect(await coordinator.route(for: envelope, envelopeSizeBytes: 64)?.transportID == relayID)

        #expect(await coordinator.candidateAuthenticated(transportID: localID, generation: localGeneration))
        #expect(await coordinator.route(for: envelope, envelopeSizeBytes: 64)?.transportID == relayID)

        #expect(await coordinator.candidateReady(transportID: localID, generation: localGeneration))
        #expect(await coordinator.route(for: envelope, envelopeSizeBytes: 64)?.transportID == localID)
        #expect(await coordinator.candidate(transportID: relayID)?.isReady == true)

        let history = await coordinator.diagnosticHistory
        #expect(history.contains(.handoffStarted(
            fromTransportID: relayID,
            toTransportID: localID,
            generation: localGeneration
        )))
        #expect(history.contains(.handoffCompleted(
            fromTransportID: relayID,
            toTransportID: localID,
            generation: localGeneration
        )))
    }

    @Test("LAN loss falls back to the still-ready relay")
    func relayFallback() async {
        let peer = NodeID()
        let envelope = makeEnvelope(destination: peer)
        let relayID = id(1)
        let localID = id(2)
        let coordinator = PeerRouteCoordinator(networkID: .test, remoteNodeID: peer)
        let relayGeneration = await coordinator.beginCandidate(
            transportID: relayID,
            kind: .relay,
            capabilities: capabilities
        )
        let localGeneration = await coordinator.beginCandidate(
            transportID: localID,
            kind: .local,
            capabilities: capabilities
        )
        _ = await coordinator.candidateReady(transportID: relayID, generation: relayGeneration)
        _ = await coordinator.candidateReady(transportID: localID, generation: localGeneration)
        #expect(await coordinator.route(for: envelope, envelopeSizeBytes: 64)?.transportID == localID)

        #expect(await coordinator.removeCandidate(
            transportID: localID,
            generation: localGeneration,
            reason: .connectionFailed
        ))
        #expect(await coordinator.route(for: envelope, envelopeSizeBytes: 64)?.transportID == relayID)
        #expect(await coordinator.diagnosticHistory.contains(.fallbackSelected(
            transportID: relayID,
            generation: relayGeneration
        )))
    }

    @Test("Incompatible LAN remains available without displacing a compatible relay")
    func envelopeSpecificCompatibility() async {
        let peer = NodeID()
        let envelope = makeEnvelope(destination: peer)
        let coordinator = PeerRouteCoordinator(networkID: .test, remoteNodeID: peer)
        let relayID = id(1)
        let localID = id(2)
        let relayGeneration = await coordinator.beginCandidate(
            transportID: relayID,
            kind: .relay,
            capabilities: capabilities
        )
        let localGeneration = await coordinator.beginCandidate(
            transportID: localID,
            kind: .local,
            capabilities: TransportCapabilities(
                supportedChannels: [.control],
                preservesOrder: true,
                supportsImmediateDelivery: true,
                supportsQueuedDelivery: true,
                supportsBackgroundDelivery: false
            )
        )
        _ = await coordinator.candidateReady(transportID: relayID, generation: relayGeneration)
        _ = await coordinator.candidateReady(transportID: localID, generation: localGeneration)

        #expect(await coordinator.route(for: envelope, envelopeSizeBytes: 64)?.transportID == relayID)
        #expect(await coordinator.candidate(transportID: localID)?.isReady == true)
    }

    @Test("Routing never mutates session pending delivery state")
    func doesNotOwnPendingDeliveries() async throws {
        let localNode = NodeID()
        let peer = NodeID()
        let session = BeakrNetSession(networkID: .test, localNodeID: localNode, remoteNodeID: peer)
        let envelope = makeEnvelope(
            sessionID: await session.id,
            source: localNode,
            destination: peer
        )
        try await session.queueForDelivery(envelope)
        let before = await session.pendingDelivery(for: envelope.messageID)
        let coordinator = PeerRouteCoordinator(networkID: .test, remoteNodeID: peer)
        let relayID = id(1)
        let generation = await coordinator.beginCandidate(
            transportID: relayID,
            kind: .relay,
            capabilities: capabilities
        )
        _ = await coordinator.candidateReady(transportID: relayID, generation: generation)
        _ = await coordinator.route(for: envelope, envelopeSizeBytes: 64)
        _ = await coordinator.removeCandidate(
            transportID: relayID,
            generation: generation,
            reason: .connectionFailed
        )
        _ = await coordinator.route(for: envelope, envelopeSizeBytes: 64)

        #expect(await session.pendingDelivery(for: envelope.messageID) == before)
    }

    private var capabilities: TransportCapabilities {
        TransportCapabilities(
            preservesOrder: true,
            supportsImmediateDelivery: true,
            supportsQueuedDelivery: true,
            supportsBackgroundDelivery: false
        )
    }

    private func makeEnvelope(
        sessionID: SessionID = SessionID(),
        source: NodeID = NodeID(),
        destination: NodeID
    ) -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            networkID: .test,
            sessionID: sessionID,
            sourceNodeID: source,
            destinationNodeID: destination,
            sequenceNumber: 1,
            channel: .data,
            representation: .full,
            deliveryPolicy: .standard,
            payloadType: "com.example.message",
            payload: Data()
        )
    }

    private func id(_ byte: UInt8) -> TransportID {
        TransportID(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte)))
    }
}
