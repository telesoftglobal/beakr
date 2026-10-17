import Foundation
import BeakrNetCore

@main
struct BeakrNetHandoffLab {
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let nodeA = NodeID()
        let nodeB = NodeID()
        let networkID = NetworkID()
        let sessionID = SessionID()
        let senderSession = BeakrNetSession(
            id: sessionID,
            networkID: networkID,
            localNodeID: nodeA,
            remoteNodeID: nodeB,
            state: .active
        )
        let receiverSession = BeakrNetSession(
            id: sessionID,
            networkID: networkID,
            localNodeID: nodeB,
            remoteNodeID: nodeA,
            state: .active
        )
        let coordinator = PeerRouteCoordinator(networkID: networkID, remoteNodeID: nodeB)
        let driver = SessionDeliveryDriver(
            session: senderSession,
            coordinator: coordinator,
            clock: { now }
        )
        let relay = LabTransport(kind: .relay, receiverSession: receiverSession)
        let lan = LabTransport(
            kind: .local,
            receiverSession: receiverSession,
            reportsAmbiguousAfterWrite: true
        )

        let relayGeneration = await registerReady(
            relay,
            with: coordinator,
            driver: driver,
            requiresAuthentication: false
        )
        let persistence = try await RelayPersistenceProbe.make(
            networkID: networkID,
            destination: nodeB,
            sessionID: sessionID,
            source: nodeA,
            now: now
        )

        let relayEnvelope = makeEnvelope(
            networkID: networkID,
            sessionID: sessionID,
            source: nodeA,
            destination: nodeB,
            sequenceNumber: 1,
            now: now
        )
        let relayOutcome = try await driver.deliver(relayEnvelope)
        guard case .sent(let initialRoute, _) = relayOutcome,
              initialRoute.transportID == relay.id,
              let relayAcknowledgement = await relay.latestAcknowledgement,
              await driver.acknowledge(
                relayAcknowledgement,
                receivedOn: relay.id,
                generation: relayGeneration
              ) else {
            throw LabError.verificationFailed("initial relay delivery")
        }
        print("Route active: relay")

        let lanGeneration = await registerReady(
            lan,
            with: coordinator,
            driver: driver,
            requiresAuthentication: true
        )
        print("Route changed: relay → authenticated LAN")

        let expiresAt = now.addingTimeInterval(120)
        let handoffEnvelope = makeEnvelope(
            networkID: networkID,
            sessionID: sessionID,
            source: nodeA,
            destination: nodeB,
            sequenceNumber: 2,
            now: now,
            expiresAt: expiresAt
        )
        let fallbackOutcome = try await driver.deliver(handoffEnvelope)
        guard case .sent(let fallbackRoute, let attemptCount) = fallbackOutcome,
              fallbackRoute.transportID == relay.id,
              attemptCount == 2 else {
            throw LabError.verificationFailed("relay fallback")
        }
        print("LAN write completed but result was ambiguous")
        print("Route changed: authenticated LAN → relay")

        guard let fallbackAcknowledgement = await relay.latestAcknowledgement,
              await driver.acknowledge(
                fallbackAcknowledgement,
                receivedOn: relay.id,
                generation: relayGeneration
              ) else {
            throw LabError.verificationFailed("cross-route acknowledgement")
        }

        let lanDeliveries = await lan.deliveries
        let relayDeliveries = await relay.deliveries
        let targetRelayDeliveries = relayDeliveries.filter { $0.envelope.messageID == handoffEnvelope.messageID }
        let pendingCount = await senderSession.allPendingDeliveries().count
        let senderState = await senderSession.state
        let persistenceUnchanged = try await persistence.isUnchanged(now: now)
        let routeHistory = await coordinator.diagnosticHistory

        guard lanDeliveries.count == 1,
              targetRelayDeliveries.count == 1,
              lanDeliveries[0].acceptance == .accepted,
              targetRelayDeliveries[0].acceptance == .duplicate,
              lanDeliveries[0].envelope == handoffEnvelope,
              targetRelayDeliveries[0].envelope == handoffEnvelope,
              lanDeliveries[0].envelope.messageID == targetRelayDeliveries[0].envelope.messageID,
              lanDeliveries[0].envelope.channel == .data,
              lanDeliveries[0].envelope.representation == .compact,
              lanDeliveries[0].envelope.deliveryPolicy.expiresAt == expiresAt,
              pendingCount == 0,
              senderState == .active,
              persistenceUnchanged,
              routeHistory.contains(.handoffCompleted(
                fromTransportID: relay.id,
                toTransportID: lan.id,
                generation: lanGeneration
              )),
              routeHistory.contains(.fallbackSelected(
                transportID: relay.id,
                generation: relayGeneration
              )) else {
            throw LabError.verificationFailed("end-to-end invariants")
        }
        try persistence.removeArtifacts()

        print("Application acceptances for retried Message ID: 1")
        print("Duplicate retries acknowledged: 1")
        print("Pending deliveries: 0")
        print("Relay persistence unchanged: true")
        print("Session, Message ID, channel metadata, and expiry preserved")
        print("Authenticated LAN handoff verified")
    }

    private static func registerReady(
        _ transport: LabTransport,
        with coordinator: PeerRouteCoordinator,
        driver: SessionDeliveryDriver,
        requiresAuthentication: Bool
    ) async -> UInt64 {
        let generation = await coordinator.beginCandidate(
            transportID: transport.id,
            kind: transport.kind,
            capabilities: transport.capabilities
        )
        if requiresAuthentication {
            guard await coordinator.candidateAuthenticated(
                transportID: transport.id,
                generation: generation
            ) else { preconditionFailure("LAN authentication transition failed") }
        }
        guard await coordinator.candidateReady(
            transportID: transport.id,
            generation: generation
        ) else { preconditionFailure("route readiness transition failed") }
        await driver.register(transport, generation: generation)
        return generation
    }

    private static func makeEnvelope(
        networkID: NetworkID,
        sessionID: SessionID,
        source: NodeID,
        destination: NodeID,
        sequenceNumber: UInt64,
        now: Date,
        expiresAt: Date? = nil
    ) -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            networkID: networkID,
            sessionID: sessionID,
            sourceNodeID: source,
            destinationNodeID: destination,
            sequenceNumber: sequenceNumber,
            channel: .data,
            representation: .compact,
            deliveryPolicy: DeliveryPolicy(durability: .queued, expiresAt: expiresAt),
            payloadType: "com.beakrnet-lab.handoff",
            payload: Data("handoff-\(sequenceNumber)".utf8),
            createdAt: now
        )
    }
}

private struct LabDelivery: Sendable {
    let envelope: BeakrNetEnvelope
    let acceptance: SessionAcceptance
}

private actor LabTransport: BeakrNetTransport {
    nonisolated let id = TransportID()
    nonisolated let kind: TransportKind
    nonisolated let capabilities = TransportCapabilities(
        preservesOrder: true,
        supportsImmediateDelivery: true,
        supportsQueuedDelivery: true,
        supportsBackgroundDelivery: false
    )

    private let receiverSession: BeakrNetSession
    private let reportsAmbiguousAfterWrite: Bool
    private(set) var deliveries: [LabDelivery] = []
    private(set) var latestAcknowledgement: DeliveryAcknowledgement?
    private var hasReportedAmbiguity = false

    init(
        kind: TransportKind,
        receiverSession: BeakrNetSession,
        reportsAmbiguousAfterWrite: Bool = false
    ) {
        self.kind = kind
        self.receiverSession = receiverSession
        self.reportsAmbiguousAfterWrite = reportsAmbiguousAfterWrite
    }

    func send(_ envelope: BeakrNetEnvelope) async throws {
        let acceptance = try await receiverSession.accept(envelope)
        deliveries.append(LabDelivery(envelope: envelope, acceptance: acceptance))
        latestAcknowledgement = DeliveryAcknowledgement(
            networkID: envelope.networkID,
            sessionID: envelope.sessionID,
            messageID: envelope.messageID
        )
        if reportsAmbiguousAfterWrite && !hasReportedAmbiguity {
            hasReportedAmbiguity = true
            throw LabError.ambiguousAfterWrite
        }
    }

    func receive() async -> BeakrNetEnvelope? { nil }
    func close() async {}
}

private struct RelayPersistenceProbe {
    let queue: PersistentRelayQueue
    let destination: NodeID
    let fileURL: URL
    let originalBytes: Data

    static func make(
        networkID: NetworkID,
        destination: NodeID,
        sessionID: SessionID,
        source: NodeID,
        now: Date
    ) async throws -> RelayPersistenceProbe {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeakrNetHandoffLab-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("relay-queue.json")
        let queue = try await PersistentRelayQueue.open(
            networkID: networkID,
            policy: .development,
            fileURL: fileURL,
            now: now
        )
        let sentinel = BeakrNetEnvelope(
            networkID: networkID,
            sessionID: sessionID,
            sourceNodeID: source,
            destinationNodeID: destination,
            sequenceNumber: 999,
            deliveryPolicy: .standard,
            payloadType: "com.beakrnet-lab.persisted-sentinel",
            payload: Data("sentinel".utf8),
            createdAt: now
        )
        _ = try await queue.enqueue(sentinel, for: destination, now: now)
        return RelayPersistenceProbe(
            queue: queue,
            destination: destination,
            fileURL: fileURL,
            originalBytes: try Data(contentsOf: fileURL)
        )
    }

    func isUnchanged(now: Date) async throws -> Bool {
        let count = await queue.count(for: destination, now: now)
        let currentBytes = try Data(contentsOf: fileURL)
        return count == 1 && currentBytes == originalBytes
    }

    func removeArtifacts() throws {
        try FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}

private enum LabError: Error {
    case ambiguousAfterWrite
    case verificationFailed(String)
}
