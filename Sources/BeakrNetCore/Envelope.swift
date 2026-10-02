import Foundation

public struct BeakrNetEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let messageID: MessageID
    public let sessionID: SessionID
    public let sourceNodeID: NodeID
    public let destinationNodeID: NodeID
    public let sequenceNumber: UInt64
    public let payloadType: String
    public let payload: Data
    public let createdAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        messageID: MessageID = MessageID(),
        sessionID: SessionID,
        sourceNodeID: NodeID,
        destinationNodeID: NodeID,
        sequenceNumber: UInt64,
        payloadType: String,
        payload: Data,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.messageID = messageID
        self.sessionID = sessionID
        self.sourceNodeID = sourceNodeID
        self.destinationNodeID = destinationNodeID
        self.sequenceNumber = sequenceNumber
        self.payloadType = payloadType
        self.payload = payload
        self.createdAt = createdAt
    }
}
