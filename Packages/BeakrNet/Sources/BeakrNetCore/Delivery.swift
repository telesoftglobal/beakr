import Foundation

public struct DeliveryAcknowledgement: Codable, Equatable, Sendable {
    public static let payloadType = ControlPayloadType.deliveryAcknowledgement.rawValue

    public let sessionID: SessionID
    public let messageID: MessageID

    public init(sessionID: SessionID, messageID: MessageID) {
        self.sessionID = sessionID
        self.messageID = messageID
    }
}

public struct PendingDelivery: Equatable, Sendable {
    public let envelope: BeakrNetEnvelope
    public private(set) var attemptCount: Int
    public private(set) var lastAttemptAt: Date?

    public init(envelope: BeakrNetEnvelope) {
        self.envelope = envelope
        self.attemptCount = 0
        self.lastAttemptAt = nil
    }

    public mutating func recordAttempt(at date: Date = Date()) {
        attemptCount += 1
        lastAttemptAt = date
    }
}

public enum PendingDeliveryRemovalReason: String, Codable, Equatable, Sendable {
    case expired
}

public enum SessionDiagnosticEvent: Equatable, Sendable {
    case transportBound(TransportBinding)
    case transportUnbound(transportID: TransportID)
    case stateChanged(SessionState)
    case deliveryQueued(messageID: MessageID, sequenceNumber: UInt64)
    case deliveryAttempted(messageID: MessageID, attempt: Int)
    case deliveryAcknowledged(messageID: MessageID)
    case deliveryRemoved(messageID: MessageID, reason: PendingDeliveryRemovalReason)
    case envelopeAccepted(messageID: MessageID, sequenceNumber: UInt64)
    case duplicateRejected(messageID: MessageID)
}
