import Foundation
import Testing
import BeakrNetCore

@Suite("Route selection")
struct RouteSelectionTests {
    @Test("Capabilities intersect every routed envelope dimension")
    func capabilityCompatibility() {
        let envelope = makeEnvelope(channel: .data, representation: .compact)
        let capabilities = TransportCapabilities(
            supportedChannels: [.data],
            supportedRepresentations: [.compact],
            maximumEnvelopeBytes: 128,
            preservesOrder: true,
            supportsImmediateDelivery: false,
            supportsQueuedDelivery: true,
            supportsBackgroundDelivery: false
        )

        #expect(capabilities.supports(envelope, envelopeSizeBytes: 128))
        #expect(!capabilities.supports(envelope, envelopeSizeBytes: 129))
        #expect(!capabilities.supports(makeEnvelope(channel: .blackboard), envelopeSizeBytes: 64))
        #expect(!TransportCapabilities(
            protocolVersion: 2,
            preservesOrder: true,
            supportsImmediateDelivery: true,
            supportsQueuedDelivery: true,
            supportsBackgroundDelivery: false
        ).supports(envelope, envelopeSizeBytes: 64))
    }

    @Test("Authenticated ready LAN wins regardless of callback order")
    func localPreferredOverRelay() {
        let envelope = makeEnvelope()
        let relay = candidate(idByte: 1, kind: .relay, destination: envelope.destinationNodeID)
        let local = candidate(idByte: 255, kind: .local, destination: envelope.destinationNodeID)
        let selector = RouteSelector()

        #expect(selector.select(for: envelope, envelopeSizeBytes: 64, from: [relay, local]).selected == local)
        #expect(selector.select(for: envelope, envelopeSizeBytes: 64, from: [local, relay]).selected == local)
    }

    @Test("Transport ID provides a stable final tie-breaker")
    func stableTieBreak() {
        let envelope = makeEnvelope()
        let first = candidate(idByte: 1, kind: .relay, destination: envelope.destinationNodeID)
        let second = candidate(idByte: 2, kind: .relay, destination: envelope.destinationNodeID)

        #expect(RouteSelector().select(for: envelope, envelopeSizeBytes: 64, from: [second, first]).selected == first)
    }

    @Test("Ineligible candidates are rejected with safe diagnostics")
    func eligibilityDiagnostics() {
        let envelope = makeEnvelope()
        let unauthenticated = candidate(
            idByte: 3,
            kind: .local,
            destination: envelope.destinationNodeID,
            isAuthenticated: false
        )

        let result = RouteSelector().select(for: envelope, envelopeSizeBytes: 64, from: [unauthenticated])

        #expect(result.selected == nil)
        #expect(result.diagnostics == [
            .candidateRejected(transportID: unauthenticated.transportID, reason: .unauthenticated),
            .routeUnavailable(remoteNodeID: envelope.destinationNodeID)
        ])
    }

    private func makeEnvelope(
        channel: BeakrNetChannel = .data,
        representation: RepresentationProfile = .full
    ) -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            sessionID: SessionID(),
            sourceNodeID: NodeID(),
            destinationNodeID: NodeID(),
            sequenceNumber: 1,
            channel: channel,
            representation: representation,
            deliveryPolicy: .standard,
            payloadType: "com.example.message",
            payload: Data()
        )
    }

    private func candidate(
        idByte: UInt8,
        kind: TransportKind,
        destination: NodeID,
        isAuthenticated: Bool = true
    ) -> RouteCandidate {
        RouteCandidate(
            remoteNodeID: destination,
            transportID: TransportID(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, idByte))),
            transportKind: kind,
            capabilities: TransportCapabilities(
                preservesOrder: true,
                supportsImmediateDelivery: true,
                supportsQueuedDelivery: true,
                supportsBackgroundDelivery: false
            ),
            generation: 1,
            isAuthenticated: isAuthenticated,
            isReady: true
        )
    }
}
