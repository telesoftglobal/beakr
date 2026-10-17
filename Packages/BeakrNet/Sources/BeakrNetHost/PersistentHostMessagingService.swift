import Foundation
import BeakrNetCore
import BeakrNetData

public struct HostDeliveryContext: Equatable, Sendable {
    public let networkID: NetworkID
    public let sessionID: SessionID
    public let sourceNodeID: NodeID
    public let sequenceNumber: UInt64

    public init(networkID: NetworkID, sessionID: SessionID, sourceNodeID: NodeID, sequenceNumber: UInt64) {
        self.networkID = networkID
        self.sessionID = sessionID
        self.sourceNodeID = sourceNodeID
        self.sequenceNumber = sequenceNumber
    }
}

public enum HostDeliveryAttempt: Equatable, Sendable {
    case submitted
    case routeUnavailable
}

/// Persists a stable Data envelope before attempting delivery. A missing route is a normal
/// offline state: the unchanged envelope remains authoritative in `PersistentDataState`.
public actor PersistentHostMessagingService: HostMessagingService {
    public typealias ContextProvider = @Sendable (NodeID) async throws -> HostDeliveryContext
    public typealias Submit = @Sendable (BeakrNetEnvelope) async throws -> HostDeliveryAttempt
    public typealias Clock = @Sendable () -> Date

    private let state: PersistentDataState
    private let contextProvider: ContextProvider
    private let submit: Submit
    private let clock: Clock
    private let messageLifetime: TimeInterval
    private let codec: DataCodec

    public init(
        state: PersistentDataState,
        messageLifetime: TimeInterval = 30 * 24 * 60 * 60,
        codec: DataCodec = DataCodec(),
        clock: @escaping Clock = Date.init,
        contextProvider: @escaping ContextProvider,
        submit: @escaping Submit
    ) {
        precondition(messageLifetime > 0)
        self.state = state
        self.messageLifetime = messageLifetime
        self.codec = codec
        self.clock = clock
        self.contextProvider = contextProvider
        self.submit = submit
    }

    public func send(_ request: HostMessageRequest) async throws {
        _ = try await sendRecordingEnvelope(request)
    }

    /// Sends while returning the exact durable envelope, allowing an application to
    /// persist diagnostic provenance without reconstructing routing decisions.
    public func sendRecordingEnvelope(_ request: HostMessageRequest) async throws -> BeakrNetEnvelope {
        let now = clock()
        let context = try await contextProvider(request.destination)
        let envelope = try codec.makeEnvelope(
            for: request.message,
            networkID: context.networkID,
            sessionID: context.sessionID,
            sourceNodeID: context.sourceNodeID,
            destinationNodeID: request.destination,
            sequenceNumber: context.sequenceNumber,
            createdAt: now,
            deliveryPolicy: DeliveryPolicy(
                durability: .durable,
                priority: 0,
                expiresAt: now.addingTimeInterval(messageLifetime)
            )
        )
        try await state.enqueue(envelope, now: now)
        _ = try await submit(envelope)
        return envelope
    }

    public func cancel(correlationID: DataCorrelationID) async throws {
        let pending = try await state.pending(now: clock())
        for envelope in pending {
            guard let message = try? codec.decode(envelope: envelope),
                  message.correlationID == correlationID else { continue }
            _ = try await state.acknowledge(envelope.messageID)
        }
    }

    public func retryPending() async throws {
        for envelope in try await state.pending(now: clock()) {
            _ = try await submit(envelope)
        }
    }
}

public extension HostMessageRequest {
    static func text(destination: NodeID, body: String,
                     correlationID: DataCorrelationID = DataCorrelationID(),
                     deadline: Date? = nil) -> HostMessageRequest {
        HostMessageRequest(
            destination: destination,
            message: DataMessage(
                kind: .message,
                operation: DataOperation(namespace: "beakr", name: "text-message", version: 1),
                correlationID: correlationID,
                idempotencyKey: DataIdempotencyKey(),
                deadline: deadline,
                body: Data(body.utf8)
            )
        )
    }
}
