import Foundation

public enum SessionState: Codable, Equatable, Sendable {
    case establishing
    case active
    case suspended
    case ended
}

public struct TransportBinding: Codable, Equatable, Sendable {
    public let transportID: TransportID
    public let kind: TransportKind
    public let boundAt: Date

    public init(transportID: TransportID, kind: TransportKind, boundAt: Date = Date()) {
        self.transportID = transportID
        self.kind = kind
        self.boundAt = boundAt
    }
}

public enum SessionAcceptance: Equatable, Sendable {
    case accepted
    case duplicate
    case wrongSession
    case wrongDestination
}

public actor BeakrNetSession {
    public let id: SessionID
    public let localNodeID: NodeID
    public let remoteNodeID: NodeID

    public private(set) var state: SessionState
    public private(set) var transportBindings: [TransportID: TransportBinding]
    public private(set) var lastActivityAt: Date
    public private(set) var diagnosticHistory: [SessionDiagnosticEvent]

    private var receivedMessageIDs: Set<MessageID>
    private var pendingDeliveries: [MessageID: PendingDelivery]

    public init(
        id: SessionID = SessionID(),
        localNodeID: NodeID,
        remoteNodeID: NodeID,
        state: SessionState = .establishing,
        now: Date = Date()
    ) {
        self.id = id
        self.localNodeID = localNodeID
        self.remoteNodeID = remoteNodeID
        self.state = state
        self.transportBindings = [:]
        self.lastActivityAt = now
        self.receivedMessageIDs = []
        self.pendingDeliveries = [:]
        self.diagnosticHistory = []
    }

    public func bind(
        transportID: TransportID,
        kind: TransportKind,
        now: Date = Date()
    ) {
        let binding = TransportBinding(
            transportID: transportID,
            kind: kind,
            boundAt: now
        )
        transportBindings[transportID] = binding
        state = .active
        lastActivityAt = now
        diagnosticHistory.append(.transportBound(binding))
        diagnosticHistory.append(.stateChanged(.active))
    }

    public func unbind(transportID: TransportID, now: Date = Date()) {
        transportBindings.removeValue(forKey: transportID)
        if transportBindings.isEmpty, state != .ended {
            state = .suspended
            diagnosticHistory.append(.stateChanged(.suspended))
        }
        lastActivityAt = now
        diagnosticHistory.append(.transportUnbound(transportID: transportID))
    }

    public func end(now: Date = Date()) {
        transportBindings.removeAll()
        state = .ended
        lastActivityAt = now
        diagnosticHistory.append(.stateChanged(.ended))
    }

    public func queueForDelivery(_ envelope: BeakrNetEnvelope) {
        guard envelope.sessionID == id,
              envelope.sourceNodeID == localNodeID,
              envelope.destinationNodeID == remoteNodeID else { return }
        guard pendingDeliveries[envelope.messageID] == nil else { return }

        pendingDeliveries[envelope.messageID] = PendingDelivery(envelope: envelope)
        diagnosticHistory.append(
            .deliveryQueued(
                messageID: envelope.messageID,
                sequenceNumber: envelope.sequenceNumber
            )
        )
    }

    public func recordDeliveryAttempt(
        for messageID: MessageID,
        now: Date = Date()
    ) {
        guard var pending = pendingDeliveries[messageID] else { return }
        pending.recordAttempt(at: now)
        pendingDeliveries[messageID] = pending
        diagnosticHistory.append(
            .deliveryAttempted(messageID: messageID, attempt: pending.attemptCount)
        )
        lastActivityAt = now
    }

    @discardableResult
    public func acknowledge(_ acknowledgement: DeliveryAcknowledgement) -> Bool {
        guard acknowledgement.sessionID == id,
              pendingDeliveries.removeValue(forKey: acknowledgement.messageID) != nil else {
            return false
        }
        diagnosticHistory.append(.deliveryAcknowledged(messageID: acknowledgement.messageID))
        return true
    }

    public func pendingDelivery(for messageID: MessageID) -> PendingDelivery? {
        pendingDeliveries[messageID]
    }

    public func allPendingDeliveries() -> [PendingDelivery] {
        pendingDeliveries.values.sorted {
            $0.envelope.sequenceNumber < $1.envelope.sequenceNumber
        }
    }

    public func accept(_ envelope: BeakrNetEnvelope, now: Date = Date()) -> SessionAcceptance {
        guard envelope.sessionID == id else { return .wrongSession }
        guard envelope.destinationNodeID == localNodeID else { return .wrongDestination }
        guard receivedMessageIDs.insert(envelope.messageID).inserted else {
            diagnosticHistory.append(.duplicateRejected(messageID: envelope.messageID))
            return .duplicate
        }

        lastActivityAt = now
        diagnosticHistory.append(
            .envelopeAccepted(
                messageID: envelope.messageID,
                sequenceNumber: envelope.sequenceNumber
            )
        )
        return .accepted
    }
}
