import Foundation

public struct SessionDeliveryRetryPolicy: Equatable, Sendable {
    public let permitsEphemeralRetry: Bool

    public init(permitsEphemeralRetry: Bool = false) {
        self.permitsEphemeralRetry = permitsEphemeralRetry
    }
}

public enum SessionDeliveryOutcome: Equatable, Sendable {
    case sent(route: RouteSnapshot, attemptCount: Int)
    case ambiguousFailure(route: RouteSnapshot, attemptCount: Int)
    case expired
    case routeUnavailable
    case staleRouteGeneration(route: RouteSnapshot)
}

public struct IncomingDeliveryResult: Equatable, Sendable {
    public let acceptance: SessionAcceptance
    public let acknowledgement: DeliveryAcknowledgement?

    public init(acceptance: SessionAcceptance, acknowledgement: DeliveryAcknowledgement?) {
        self.acceptance = acceptance
        self.acknowledgement = acknowledgement
    }
}

public enum SessionDeliveryDiagnosticEvent: Equatable, Sendable {
    case attempt(messageID: MessageID, transportID: TransportID, generation: UInt64, attempt: Int)
    case sendSucceeded(messageID: MessageID, transportID: TransportID, generation: UInt64)
    case sendFailedAmbiguously(messageID: MessageID, transportID: TransportID, generation: UInt64)
    case staleRouteGeneration(transportID: TransportID, generation: UInt64)
    case routeUnavailable(messageID: MessageID)
    case expired(messageID: MessageID)
    case acknowledgementAccepted(messageID: MessageID, transportID: TransportID, generation: UInt64)
    case acknowledgementRejected(messageID: MessageID, transportID: TransportID, generation: UInt64)
}

/// Drives logical-session delivery across authenticated route handoffs.
/// Transports never own replay state; every retry uses the session's immutable envelope.
public actor SessionDeliveryDriver {
    public typealias Clock = @Sendable () -> Date
    public typealias EventSink = @Sendable (SessionDeliveryDiagnosticEvent) -> Void

    private struct RegisteredTransport: Sendable {
        let generation: UInt64
        let transport: any BeakrNetTransport
    }

    private let session: BeakrNetSession
    private let coordinator: PeerRouteCoordinator
    private let clock: Clock
    private let eventSink: EventSink
    private var transports: [TransportID: RegisteredTransport] = [:]

    public private(set) var diagnosticHistory: [SessionDeliveryDiagnosticEvent] = []

    public init(
        session: BeakrNetSession,
        coordinator: PeerRouteCoordinator,
        clock: @escaping Clock = Date.init,
        eventSink: @escaping EventSink = { _ in }
    ) {
        self.session = session
        self.coordinator = coordinator
        self.clock = clock
        self.eventSink = eventSink
    }

    public func register(_ transport: any BeakrNetTransport, generation: UInt64) async {
        transports[await transport.id] = RegisteredTransport(generation: generation, transport: transport)
    }

    public func unregister(transportID: TransportID, generation: UInt64) {
        guard transports[transportID]?.generation == generation else { return }
        transports.removeValue(forKey: transportID)
    }

    public func deliver(
        _ envelope: BeakrNetEnvelope,
        retryPolicy: SessionDeliveryRetryPolicy = SessionDeliveryRetryPolicy()
    ) async throws -> SessionDeliveryOutcome {
        let now = clock()
        try await session.queueForDelivery(envelope, now: now)

        while true {
            if isExpired(envelope, at: clock()) {
                await expire(envelope.messageID)
                return .expired
            }

            let envelopeSize = try JSONEncoder().encode(envelope).count
            guard let route = await coordinator.route(for: envelope, envelopeSizeBytes: envelopeSize) else {
                emit(.routeUnavailable(messageID: envelope.messageID))
                return .routeUnavailable
            }
            guard let registered = transports[route.transportID], registered.generation == route.generation else {
                emit(.staleRouteGeneration(transportID: route.transportID, generation: route.generation))
                return .staleRouteGeneration(route: route)
            }

            await session.recordDeliveryAttempt(for: envelope.messageID, now: clock())
            let attemptCount = await session.pendingDelivery(for: envelope.messageID)?.attemptCount ?? 0
            emit(.attempt(
                messageID: envelope.messageID,
                transportID: route.transportID,
                generation: route.generation,
                attempt: attemptCount
            ))

            do {
                try await registered.transport.send(envelope)
                emit(.sendSucceeded(
                    messageID: envelope.messageID,
                    transportID: route.transportID,
                    generation: route.generation
                ))
                return .sent(route: route, attemptCount: attemptCount)
            } catch {
                emit(.sendFailedAmbiguously(
                    messageID: envelope.messageID,
                    transportID: route.transportID,
                    generation: route.generation
                ))
                guard await coordinator.markRouteUnhealthy(route) else {
                    emit(.staleRouteGeneration(transportID: route.transportID, generation: route.generation))
                    return .staleRouteGeneration(route: route)
                }
                if envelope.deliveryPolicy.durability == .ephemeral && !retryPolicy.permitsEphemeralRetry {
                    return .ambiguousFailure(route: route, attemptCount: attemptCount)
                }
            }
        }
    }

    public func acknowledge(
        _ acknowledgement: DeliveryAcknowledgement,
        receivedOn transportID: TransportID,
        generation: UInt64
    ) async -> Bool {
        guard await coordinator.isAuthenticatedRoute(transportID: transportID, generation: generation) else {
            emit(.acknowledgementRejected(
                messageID: acknowledgement.messageID,
                transportID: transportID,
                generation: generation
            ))
            return false
        }
        let accepted = await session.acknowledge(acknowledgement)
        emit(accepted
            ? .acknowledgementAccepted(messageID: acknowledgement.messageID, transportID: transportID, generation: generation)
            : .acknowledgementRejected(messageID: acknowledgement.messageID, transportID: transportID, generation: generation))
        return accepted
    }

    public func receive(
        _ envelope: BeakrNetEnvelope,
        receivedOn transportID: TransportID,
        generation: UInt64
    ) async throws -> IncomingDeliveryResult? {
        guard await coordinator.isAuthenticatedRoute(transportID: transportID, generation: generation) else {
            return nil
        }
        let acceptance = try await session.accept(envelope, now: clock())
        let acknowledgement: DeliveryAcknowledgement?
        switch acceptance {
        case .accepted, .duplicate:
            acknowledgement = envelope.payloadType == DeliveryAcknowledgement.payloadType
                ? nil
                : DeliveryAcknowledgement(
                    networkID: envelope.networkID,
                    sessionID: envelope.sessionID,
                    messageID: envelope.messageID
                )
        case .wrongNetwork, .wrongSession, .wrongDestination:
            acknowledgement = nil
        }
        return IncomingDeliveryResult(acceptance: acceptance, acknowledgement: acknowledgement)
    }

    private func isExpired(_ envelope: BeakrNetEnvelope, at date: Date) -> Bool {
        guard let expiresAt = envelope.deliveryPolicy.expiresAt else { return false }
        return expiresAt <= date
    }

    private func expire(_ messageID: MessageID) async {
        _ = await session.removePendingDelivery(for: messageID, reason: .expired)
        emit(.expired(messageID: messageID))
    }

    private func emit(_ event: SessionDeliveryDiagnosticEvent) {
        diagnosticHistory.append(event)
        eventSink(event)
    }
}
