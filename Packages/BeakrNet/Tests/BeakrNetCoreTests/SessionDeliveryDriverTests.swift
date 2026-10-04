import Foundation
import Testing
@testable import BeakrNetCore

@Suite("Session delivery driver")
struct SessionDeliveryDriverTests {
    @Test("Successful delivery queues once and records its route generation")
    func successfulDelivery() async throws {
        let fixture = Fixture()
        let relay = ScriptedTransport(id: id(1), kind: .relay, results: [.success])
        let generation = await fixture.add(relay)

        let outcome = try await fixture.driver.deliver(fixture.envelope)

        #expect(outcome == .sent(route: snapshot(fixture.remote, relay, generation), attemptCount: 1))
        #expect(await relay.sent == [fixture.envelope])
        #expect(await fixture.session.pendingDelivery(for: fixture.envelope.messageID)?.attemptCount == 1)
        _ = try await fixture.driver.deliver(fixture.envelope)
        let queuedEvents = await fixture.session.diagnosticHistory.filter {
            if case .deliveryQueued(messageID: fixture.envelope.messageID, sequenceNumber: _) = $0 { return true }
            return false
        }
        #expect(queuedEvents.count == 1)
    }

    @Test("An ambiguous LAN failure retries the identical envelope over relay")
    func ambiguousLANFailureFallsBackToRelay() async throws {
        let fixture = Fixture()
        let local = ScriptedTransport(id: id(2), kind: .local, results: [.failure])
        let relay = ScriptedTransport(id: id(1), kind: .relay, results: [.success])
        let localGeneration = await fixture.add(local)
        let relayGeneration = await fixture.add(relay)

        let outcome = try await fixture.driver.deliver(fixture.envelope)

        #expect(outcome == .sent(route: snapshot(fixture.remote, relay, relayGeneration), attemptCount: 2))
        #expect(await local.sent == [fixture.envelope])
        #expect(await relay.sent == [fixture.envelope])
        let localMessageID = await local.sent.first?.messageID
        let relayMessageID = await relay.sent.first?.messageID
        #expect(localMessageID == relayMessageID)
        #expect(await fixture.coordinator.candidate(transportID: local.id) == nil)
        #expect(await fixture.driver.diagnosticHistory.contains(.sendFailedAmbiguously(
            messageID: fixture.envelope.messageID,
            transportID: local.id,
            generation: localGeneration
        )))
    }

    @Test("A duplicate receiver rejection still produces an acknowledgement")
    func duplicateReceiverAcknowledges() async throws {
        let local = NodeID()
        let remote = NodeID()
        let sessionID = SessionID()
        let session = BeakrNetSession(id: sessionID, localNodeID: local, remoteNodeID: remote, state: .active)
        let coordinator = PeerRouteCoordinator(remoteNodeID: remote)
        let driver = SessionDeliveryDriver(session: session, coordinator: coordinator)
        let relay = ScriptedTransport(id: id(1), kind: .relay, results: [])
        let generation = await add(relay, to: coordinator, driver: driver)
        let incoming = makeEnvelope(sessionID: sessionID, source: remote, destination: local)

        let first = try #require(try await driver.receive(incoming, receivedOn: relay.id, generation: generation))
        let duplicate = try #require(try await driver.receive(incoming, receivedOn: relay.id, generation: generation))

        #expect(first.acceptance == .accepted)
        #expect(duplicate.acceptance == .duplicate)
        #expect(duplicate.acknowledgement == DeliveryAcknowledgement(sessionID: sessionID, messageID: incoming.messageID))
    }

    @Test("Acknowledgement may arrive on a different authenticated route")
    func acknowledgementOnDifferentRoute() async throws {
        let fixture = Fixture()
        let local = ScriptedTransport(id: id(2), kind: .local, results: [.success])
        let relay = ScriptedTransport(id: id(1), kind: .relay, results: [])
        _ = await fixture.add(local)
        let relayGeneration = await fixture.add(relay)
        _ = try await fixture.driver.deliver(fixture.envelope)

        let accepted = await fixture.driver.acknowledge(
            DeliveryAcknowledgement(sessionID: fixture.sessionID, messageID: fixture.envelope.messageID),
            receivedOn: relay.id,
            generation: relayGeneration
        )

        #expect(accepted)
        #expect(await fixture.session.pendingDelivery(for: fixture.envelope.messageID) == nil)
    }

    @Test("Authenticated LAN after-write ambiguity preserves one logical delivery through relay fallback")
    func endToEndAmbiguousHandoff() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let localNode = NodeID()
        let remoteNode = NodeID()
        let sessionID = SessionID()
        let sender = BeakrNetSession(
            id: sessionID,
            localNodeID: localNode,
            remoteNodeID: remoteNode,
            state: .active
        )
        let receiver = BeakrNetSession(
            id: sessionID,
            localNodeID: remoteNode,
            remoteNodeID: localNode,
            state: .active
        )
        let coordinator = PeerRouteCoordinator(remoteNodeID: remoteNode)
        let driver = SessionDeliveryDriver(session: sender, coordinator: coordinator, clock: { now })
        let relay = DeliveringTransport(id: id(1), kind: .relay, receiver: receiver)
        let lan = DeliveringTransport(
            id: id(2),
            kind: .local,
            receiver: receiver,
            reportsAmbiguousAfterWrite: true
        )
        let relayGeneration = await addReady(relay, to: coordinator, driver: driver)
        let lanGeneration = await coordinator.beginCandidate(
            transportID: lan.id,
            kind: lan.kind,
            capabilities: lan.capabilities
        )
        #expect(await coordinator.candidateAuthenticated(transportID: lan.id, generation: lanGeneration))
        #expect(await coordinator.candidateReady(transportID: lan.id, generation: lanGeneration))
        await driver.register(lan, generation: lanGeneration)
        let expiry = now.addingTimeInterval(120)
        let envelope = makeEnvelope(
            sessionID: sessionID,
            source: localNode,
            destination: remoteNode,
            policy: DeliveryPolicy(durability: .queued, expiresAt: expiry)
        )

        let outcome = try await driver.deliver(envelope)
        guard case .sent(let route, let attemptCount) = outcome else {
            Issue.record("Expected relay fallback success")
            return
        }
        #expect(route.transportID == relay.id)
        #expect(attemptCount == 2)
        let lanDeliveries = await lan.deliveries
        let relayDeliveries = await relay.deliveries
        #expect(lanDeliveries.map(\.envelope) == [envelope])
        #expect(relayDeliveries.map(\.envelope) == [envelope])
        #expect(lanDeliveries.map(\.acceptance) == [.accepted])
        #expect(relayDeliveries.map(\.acceptance) == [.duplicate])
        #expect(lanDeliveries[0].envelope.messageID == relayDeliveries[0].envelope.messageID)
        #expect(lanDeliveries[0].envelope.channel == .data)
        #expect(lanDeliveries[0].envelope.representation == .compact)
        #expect(lanDeliveries[0].envelope.deliveryPolicy.expiresAt == expiry)

        let acknowledgement = try #require(await relay.latestAcknowledgement)
        #expect(await driver.acknowledge(
            acknowledgement,
            receivedOn: relay.id,
            generation: relayGeneration
        ))
        #expect(await sender.pendingDelivery(for: envelope.messageID) == nil)
        #expect(await sender.state == .active)
    }

    @Test("Expiry during handoff removes the pending delivery")
    func expiryDuringHandoff() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = LockedClock(values: [start, start, start, start.addingTimeInterval(2)])
        let fixture = Fixture(
            policy: DeliveryPolicy(durability: .queued, expiresAt: start.addingTimeInterval(1)),
            clock: clock.callAsFunction
        )
        let local = ScriptedTransport(id: id(2), kind: .local, results: [.failure])
        let relay = ScriptedTransport(id: id(1), kind: .relay, results: [.success])
        _ = await fixture.add(local)
        _ = await fixture.add(relay)

        #expect(try await fixture.driver.deliver(fixture.envelope) == .expired)
        #expect(await local.sent == [fixture.envelope])
        #expect(await relay.sent.isEmpty)
        #expect(await fixture.session.pendingDelivery(for: fixture.envelope.messageID) == nil)
    }

    @Test("A selected generation cannot use a transport registered for an older generation")
    func staleRouteGeneration() async throws {
        let fixture = Fixture()
        let local = ScriptedTransport(id: id(2), kind: .local, results: [.success])
        let oldGeneration = await fixture.add(local)
        let newGeneration = await fixture.coordinator.beginCandidate(
            transportID: local.id,
            kind: .local,
            capabilities: local.capabilities
        )
        _ = await fixture.coordinator.candidateReady(transportID: local.id, generation: newGeneration)

        #expect(oldGeneration != newGeneration)
        #expect(try await fixture.driver.deliver(fixture.envelope) == .staleRouteGeneration(
            route: snapshot(fixture.remote, local, newGeneration)
        ))
        #expect(await local.sent.isEmpty)
        #expect(await fixture.session.pendingDelivery(for: fixture.envelope.messageID)?.attemptCount == 0)
    }

    @Test("An unavailable fallback leaves the ambiguous delivery pending")
    func unavailableFallback() async throws {
        let fixture = Fixture()
        let local = ScriptedTransport(id: id(2), kind: .local, results: [.failure])
        _ = await fixture.add(local)

        #expect(try await fixture.driver.deliver(fixture.envelope) == .routeUnavailable)
        #expect(await fixture.session.pendingDelivery(for: fixture.envelope.messageID)?.attemptCount == 1)
        #expect(await fixture.driver.diagnosticHistory.contains(.routeUnavailable(messageID: fixture.envelope.messageID)))
    }

    @Test("Delivery acknowledgement envelopes do not create acknowledgement loops")
    func acknowledgementLoopPrevention() async throws {
        let fixture = Fixture()
        let relay = ScriptedTransport(id: id(1), kind: .relay, results: [.success])
        let generation = await fixture.add(relay)
        let envelope = BeakrNetEnvelope(
            sessionID: fixture.sessionID,
            sourceNodeID: fixture.remote,
            destinationNodeID: fixture.local,
            sequenceNumber: 8,
            channel: .control,
            deliveryPolicy: DeliveryPolicy(durability: .ephemeral),
            payloadType: DeliveryAcknowledgement.payloadType,
            payload: Data()
        )

        let result = try #require(await fixture.driver.receive(envelope, receivedOn: relay.id, generation: generation))

        #expect(result.acceptance == .accepted)
        #expect(result.acknowledgement == nil)
    }

    private final class Fixture: @unchecked Sendable {
        let local = NodeID()
        let remote = NodeID()
        let sessionID = SessionID()
        let session: BeakrNetSession
        let coordinator: PeerRouteCoordinator
        let driver: SessionDeliveryDriver
        let envelope: BeakrNetEnvelope

        init(policy: DeliveryPolicy = .standard, clock: @escaping SessionDeliveryDriver.Clock = Date.init) {
            session = BeakrNetSession(id: sessionID, localNodeID: local, remoteNodeID: remote, state: .active)
            coordinator = PeerRouteCoordinator(remoteNodeID: remote)
            driver = SessionDeliveryDriver(session: session, coordinator: coordinator, clock: clock)
            envelope = BeakrNetEnvelope(
                sessionID: sessionID,
                sourceNodeID: local,
                destinationNodeID: remote,
                sequenceNumber: 7,
                channel: .data,
                representation: .compact,
                deliveryPolicy: policy,
                payloadType: "com.example.delivery",
                payload: Data("payload".utf8)
            )
        }

        func add(_ transport: ScriptedTransport) async -> UInt64 {
            await SessionDeliveryDriverTests().add(transport, to: coordinator, driver: driver)
        }
    }

    private func add(
        _ transport: ScriptedTransport,
        to coordinator: PeerRouteCoordinator,
        driver: SessionDeliveryDriver
    ) async -> UInt64 {
        let generation = await coordinator.beginCandidate(
            transportID: transport.id,
            kind: transport.kind,
            capabilities: transport.capabilities
        )
        _ = await coordinator.candidateReady(transportID: transport.id, generation: generation)
        await driver.register(transport, generation: generation)
        return generation
    }

    private func addReady(
        _ transport: DeliveringTransport,
        to coordinator: PeerRouteCoordinator,
        driver: SessionDeliveryDriver
    ) async -> UInt64 {
        let generation = await coordinator.beginCandidate(
            transportID: transport.id,
            kind: transport.kind,
            capabilities: transport.capabilities
        )
        _ = await coordinator.candidateReady(transportID: transport.id, generation: generation)
        await driver.register(transport, generation: generation)
        return generation
    }

    private func makeEnvelope(
        sessionID: SessionID,
        source: NodeID,
        destination: NodeID,
        policy: DeliveryPolicy = .standard
    ) -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            sessionID: sessionID,
            sourceNodeID: source,
            destinationNodeID: destination,
            sequenceNumber: 7,
            channel: .data,
            representation: .compact,
            deliveryPolicy: policy,
            payloadType: "com.example.delivery",
            payload: Data("payload".utf8)
        )
    }

    private func snapshot(_ peer: NodeID, _ transport: ScriptedTransport, _ generation: UInt64) -> RouteSnapshot {
        RouteSnapshot(candidate: RouteCandidate(
            remoteNodeID: peer,
            transportID: transport.id,
            transportKind: transport.kind,
            capabilities: transport.capabilities,
            generation: generation,
            isAuthenticated: true,
            isReady: true
        ))
    }

    private func id(_ byte: UInt8) -> TransportID {
        TransportID(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte)))
    }
}

private enum ScriptedSendResult: Sendable {
    case success
    case failure
}

private enum ScriptedTransportError: Error {
    case ambiguous
}

private actor ScriptedTransport: BeakrNetTransport {
    nonisolated let id: TransportID
    nonisolated let kind: TransportKind
    nonisolated let capabilities = TransportCapabilities(
        preservesOrder: true,
        supportsImmediateDelivery: true,
        supportsQueuedDelivery: true,
        supportsBackgroundDelivery: false
    )

    private var results: [ScriptedSendResult]
    private(set) var sent: [BeakrNetEnvelope] = []

    init(id: TransportID, kind: TransportKind, results: [ScriptedSendResult]) {
        self.id = id
        self.kind = kind
        self.results = results
    }

    func send(_ envelope: BeakrNetEnvelope) async throws {
        sent.append(envelope)
        let result = results.isEmpty ? .success : results.removeFirst()
        if result == .failure { throw ScriptedTransportError.ambiguous }
    }

    func receive() async -> BeakrNetEnvelope? { nil }
    func close() async {}
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]

    init(values: [Date]) {
        self.values = values
    }

    func callAsFunction() -> Date {
        lock.lock()
        defer { lock.unlock() }
        if values.count > 1 { return values.removeFirst() }
        return values[0]
    }
}

private struct RecordedDelivery: Sendable {
    let envelope: BeakrNetEnvelope
    let acceptance: SessionAcceptance
}

private actor DeliveringTransport: BeakrNetTransport {
    nonisolated let id: TransportID
    nonisolated let kind: TransportKind
    nonisolated let capabilities = TransportCapabilities(
        preservesOrder: true,
        supportsImmediateDelivery: true,
        supportsQueuedDelivery: true,
        supportsBackgroundDelivery: false
    )

    private let receiver: BeakrNetSession
    private let reportsAmbiguousAfterWrite: Bool
    private var didReportAmbiguity = false
    private(set) var deliveries: [RecordedDelivery] = []
    private(set) var latestAcknowledgement: DeliveryAcknowledgement?

    init(
        id: TransportID,
        kind: TransportKind,
        receiver: BeakrNetSession,
        reportsAmbiguousAfterWrite: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.receiver = receiver
        self.reportsAmbiguousAfterWrite = reportsAmbiguousAfterWrite
    }

    func send(_ envelope: BeakrNetEnvelope) async throws {
        let acceptance = try await receiver.accept(envelope)
        deliveries.append(RecordedDelivery(envelope: envelope, acceptance: acceptance))
        latestAcknowledgement = DeliveryAcknowledgement(
            sessionID: envelope.sessionID,
            messageID: envelope.messageID
        )
        if reportsAmbiguousAfterWrite && !didReportAmbiguity {
            didReportAmbiguity = true
            throw ScriptedTransportError.ambiguous
        }
    }

    func receive() async -> BeakrNetEnvelope? { nil }
    func close() async {}
}
