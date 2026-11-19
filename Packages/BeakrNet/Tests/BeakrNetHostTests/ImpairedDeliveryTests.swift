import Foundation
import Testing
import BeakrNetCore
import BeakrNetData
import BeakrNetHost

@Suite("Isolated LAN delivery impairment", .timeLimit(.minutes(1)))
struct ImpairedDeliveryTests {
    @Test("Durable LAN delivery survives scripted delay and failures without duplicate acceptance",
          arguments: Impairment.allCases)
    func durableDelivery(impairment: Impairment) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("outgoing.json")
        // Use an exactly representable timestamp for equality across JSON's
        // millisecond date encoding; measure injected delay with a monotonic clock.
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let network = NetworkID()
        let source = NodeID()
        let destination = NodeID()
        let sessionID = SessionID()
        let sender = BeakrNetSession(id: sessionID, networkID: network,
                                    localNodeID: source, remoteNodeID: destination, state: .active, now: now)
        let receiver = BeakrNetSession(id: sessionID, networkID: network,
                                      localNodeID: destination, remoteNodeID: source, state: .active, now: now)
        let routes = PeerRouteCoordinator(networkID: network, remoteNodeID: destination)
        let driver = SessionDeliveryDriver(session: sender, coordinator: routes, clock: { now })
        let firstLink = ImpairedLANTransport(receiver: receiver, impairment: impairment)
        var link = firstLink
        var generation = await register(link, routes: routes, driver: driver)
        let state = try await PersistentDataState.open(fileURL: file, now: now)
        let service = PersistentHostMessagingService(
            state: state, clock: { now },
            contextProvider: { _ in
                HostDeliveryContext(networkID: network, sessionID: sessionID,
                                    sourceNodeID: source, sequenceNumber: 1)
            },
            submit: { envelope in
                if case .sent = try await driver.deliver(envelope) { return .submitted }
                return .routeUnavailable
            }
        )
        let correlation = DataCorrelationID()
        let clock = ContinuousClock()
        let start = clock.now
        let original = try await service.sendRecordingEnvelope(.text(
            destination: destination, body: "E11 isolated fixture", correlationID: correlation
        ))
        let elapsed = start.duration(to: clock.now)
        if impairment == .delay {
            #expect(elapsed >= .milliseconds(250))
        }
        print("E11 fixture \(impairment.rawValue): configured delay=\(impairment == .delay ? 250 : 0)ms, initial submission elapsed=\(elapsed)")
        #expect(await firstLink.attempts == [original])
        #expect(await sender.pendingDelivery(for: original.messageID)?.attemptCount == 1)
        #expect(try await state.pending(now: now) == [original])

        // Reopen only the durable sender store, not the receiver/session. No new
        // identity, sequence number, or logical message may be created on retry.
        let reopened = try await PersistentDataState.open(fileURL: file, now: now)
        #expect(try await reopened.pending(now: now) == [original])
        let retryService = PersistentHostMessagingService(
            state: reopened, clock: { now },
            contextProvider: { _ in
                Issue.record("Retry must reuse the persisted envelope")
                return HostDeliveryContext(networkID: network, sessionID: sessionID,
                                           sourceNodeID: source, sequenceNumber: 99)
            },
            submit: { envelope in
                if case .sent = try await driver.deliver(envelope) { return .submitted }
                return .routeUnavailable
            }
        )

        if impairment == .beforeAcceptance || impairment == .afterAcceptance {
            #expect(await firstLink.latestAcknowledgement == nil)
            #expect(await routes.candidate(transportID: firstLink.id) == nil)
            // Three explicit scheduler ticks while disconnected must not spin
            // or issue more transport attempts. This does not test timer cadence.
            for _ in 0..<3 { try await retryService.retryPending() }
            #expect(await firstLink.attempts.count == 1)
            #expect(await sender.pendingDelivery(for: original.messageID)?.attemptCount == 1)
            #expect(try await reopened.pending(now: now) == [original])
            await driver.unregister(transportID: firstLink.id, generation: generation)
            link = ImpairedLANTransport(receiver: receiver, impairment: .baseline)
            generation = await register(link, routes: routes, driver: driver)
        }
        if impairment.requiresRetry {
            #expect(await firstLink.latestAcknowledgement == nil)
            try await retryService.retryPending()
        }
        let attempts = await firstLink.attempts + (link.id == firstLink.id ? [] : await link.attempts)
        let acceptances = await firstLink.acceptances + (link.id == firstLink.id ? [] : await link.acceptances)
        let expectedAttempts = impairment.requiresRetry ? 2 : 1
        #expect(attempts.count == expectedAttempts)
        #expect(attempts.allSatisfy { $0 == original })
        #expect(acceptances.filter { $0 == .accepted }.count == 1)
        #expect(acceptances.filter { $0 == .duplicate }.count ==
                (impairment == .afterAcceptance || impairment == .lostAcknowledgement ? 1 : 0))
        #expect(try DataCodec().decode(envelope: original).correlationID == correlation)
        #expect(try await reopened.pending(now: now) == [original])
        #expect(await sender.pendingDelivery(for: original.messageID)?.attemptCount == expectedAttempts)

        let acknowledgement = try #require(await link.latestAcknowledgement)
        // A stale route generation cannot clear the durable queue.
        #expect(!(await driver.acknowledge(acknowledgement, receivedOn: link.id, generation: generation + 1)))
        #expect(await sender.pendingDelivery(for: original.messageID) != nil)
        let acknowledged = await driver.acknowledge(acknowledgement, receivedOn: link.id, generation: generation)
        try #require(acknowledged)
        // The fixture bridges accepted session acknowledgements to durable state,
        // as a host would. It does not exercise the app's acknowledgement wiring.
        #expect(try await reopened.acknowledge(acknowledgement.messageID))
        #expect(await sender.pendingDelivery(for: original.messageID) == nil)
        #expect(try await reopened.pending(now: now).isEmpty)
        let finalStore = try await PersistentDataState.open(fileURL: file, now: now)
        #expect(try await finalStore.pending(now: now).isEmpty)
        try await retryService.retryPending()
        #expect(await link.attempts.count == (link.id == firstLink.id ? expectedAttempts : 1))
        await driver.unregister(transportID: link.id, generation: generation)
    }

    private func register(_ link: ImpairedLANTransport, routes: PeerRouteCoordinator,
                          driver: SessionDeliveryDriver) async -> UInt64 {
        let generation = await routes.beginCandidate(transportID: link.id, kind: .local,
                                                     capabilities: link.capabilities)
        // Authentication is a fixture precondition, not a TLS/trust test.
        #expect(await routes.candidateAuthenticated(transportID: link.id, generation: generation))
        #expect(await routes.candidateReady(transportID: link.id, generation: generation))
        await driver.register(link, generation: generation)
        return generation
    }
}

enum Impairment: String, CaseIterable, Sendable {
    case baseline, delay, beforeAcceptance, afterAcceptance, lostAcknowledgement

    var requiresRetry: Bool {
        self == .beforeAcceptance || self == .afterAcceptance || self == .lostAcknowledgement
    }
}

private enum ImpairedLANError: Error { case disconnected }

/// Scripted application-envelope faults, not raw IP packet loss or real TLS.
private actor ImpairedLANTransport: BeakrNetTransport {
    nonisolated let id = TransportID()
    nonisolated let kind = TransportKind.local
    nonisolated let capabilities = TransportCapabilities(
        preservesOrder: true, supportsImmediateDelivery: true,
        supportsQueuedDelivery: true, supportsBackgroundDelivery: false
    )
    let receiver: BeakrNetSession
    let impairment: Impairment
    private(set) var attempts: [BeakrNetEnvelope] = []
    private(set) var acceptances: [SessionAcceptance] = []
    private(set) var latestAcknowledgement: DeliveryAcknowledgement?

    init(receiver: BeakrNetSession, impairment: Impairment) {
        self.receiver = receiver
        self.impairment = impairment
    }

    func send(_ envelope: BeakrNetEnvelope) async throws {
        attempts.append(envelope)
        let firstAttempt = attempts.count == 1
        if firstAttempt && impairment == .delay { try await Task.sleep(for: .milliseconds(250)) }
        if firstAttempt && impairment == .beforeAcceptance { throw ImpairedLANError.disconnected }
        let acceptance = try await receiver.accept(envelope, now: envelope.createdAt)
        acceptances.append(acceptance)
        if firstAttempt && impairment == .afterAcceptance { throw ImpairedLANError.disconnected }
        if firstAttempt && impairment == .lostAcknowledgement { return }
        if acceptance == .accepted || acceptance == .duplicate {
            latestAcknowledgement = DeliveryAcknowledgement(
                networkID: envelope.networkID, sessionID: envelope.sessionID, messageID: envelope.messageID
            )
        }
    }

    func receive() async -> BeakrNetEnvelope? { nil }
    func close() async {}
}
