import Foundation

public struct BeakrNetEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let maximumControlPayloadBytes = 16 * 1_024
    public static let maximumControlQueueDuration: TimeInterval = 5 * 60

    public let schemaVersion: Int
    public let messageID: MessageID
    public let sessionID: SessionID
    public let sourceNodeID: NodeID
    public let destinationNodeID: NodeID
    public let sequenceNumber: UInt64
    public let channel: BeakrNetChannel
    public let representation: RepresentationProfile
    public let deliveryPolicy: DeliveryPolicy
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
        channel: BeakrNetChannel = .data,
        representation: RepresentationProfile = .full,
        deliveryPolicy: DeliveryPolicy = .standard,
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
        self.channel = channel
        self.representation = representation
        self.deliveryPolicy = deliveryPolicy
        self.payloadType = payloadType
        self.payload = payload
        self.createdAt = createdAt
    }

    public func validate(now: Date = Date()) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw EnvelopeValidationError.unsupportedSchemaVersion(schemaVersion)
        }

        let isReservedPayload = payloadType.hasPrefix("beakrnet.")
        if channel == .control {
            guard isReservedPayload else {
                throw EnvelopeValidationError.applicationPayloadOnControlChannel
            }
            guard payload.count <= Self.maximumControlPayloadBytes else {
                throw EnvelopeValidationError.controlPayloadTooLarge(maximumBytes: Self.maximumControlPayloadBytes, actualBytes: payload.count)
            }
            guard deliveryPolicy.durability != .durable else {
                throw EnvelopeValidationError.invalidDeliveryPolicy
            }
            if deliveryPolicy.durability == .queued {
                guard let expiresAt = deliveryPolicy.expiresAt,
                      expiresAt <= createdAt.addingTimeInterval(Self.maximumControlQueueDuration) else {
                    throw EnvelopeValidationError.invalidDeliveryPolicy
                }
            }
        } else if isReservedPayload {
            throw EnvelopeValidationError.reservedPayloadOutsideControlChannel
        }

        if let expiresAt = deliveryPolicy.expiresAt, expiresAt <= now {
            throw EnvelopeValidationError.expired
        }
        if let replacementKey = deliveryPolicy.replacementKey,
           (replacementKey.isEmpty || deliveryPolicy.durability != .queued) {
            throw EnvelopeValidationError.invalidDeliveryPolicy
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, messageID, sessionID, sourceNodeID, destinationNodeID
        case sequenceNumber, channel, representation, deliveryPolicy
        case payloadType, payload, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw EnvelopeValidationError.unsupportedSchemaVersion(schemaVersion)
        }

        self.schemaVersion = schemaVersion
        messageID = try container.decode(MessageID.self, forKey: .messageID)
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        sourceNodeID = try container.decode(NodeID.self, forKey: .sourceNodeID)
        destinationNodeID = try container.decode(NodeID.self, forKey: .destinationNodeID)
        sequenceNumber = try container.decode(UInt64.self, forKey: .sequenceNumber)
        channel = try container.decode(BeakrNetChannel.self, forKey: .channel)
        representation = try container.decode(RepresentationProfile.self, forKey: .representation)
        deliveryPolicy = try container.decode(DeliveryPolicy.self, forKey: .deliveryPolicy)
        payloadType = try container.decode(String.self, forKey: .payloadType)
        payload = try container.decode(Data.self, forKey: .payload)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
