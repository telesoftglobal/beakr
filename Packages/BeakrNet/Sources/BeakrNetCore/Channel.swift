import Foundation

public enum BeakrNetChannel: String, Codable, CaseIterable, Sendable {
    case control
    case data
    case blackboard
}

public enum RepresentationProfile: String, Codable, Sendable {
    case full
    case compact
}

public enum DeliveryDurability: String, Codable, Sendable {
    case ephemeral
    case queued
    case durable
}

public struct DeliveryPolicy: Codable, Equatable, Sendable {
    public let durability: DeliveryDurability
    public let priority: UInt8
    public let expiresAt: Date?
    public let replacementKey: String?

    public init(durability: DeliveryDurability, priority: UInt8 = 0, expiresAt: Date? = nil, replacementKey: String? = nil) {
        self.durability = durability
        self.priority = priority
        self.expiresAt = expiresAt
        self.replacementKey = replacementKey
    }

    public static let standard = DeliveryPolicy(durability: .queued)
}

public enum ControlPayloadType: String, Codable, CaseIterable, Sendable {
    case deliveryAcknowledgement = "beakrnet.delivery-acknowledgement"
    case capabilities = "beakrnet.capabilities"
    case protocolVersion = "beakrnet.protocol-version"
    case routeAvailability = "beakrnet.route-availability"
    case keepalive = "beakrnet.keepalive"
    case queuePressure = "beakrnet.queue-pressure"
}

public enum EnvelopeValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case applicationPayloadOnControlChannel
    case reservedPayloadOutsideControlChannel
    case controlPayloadTooLarge(maximumBytes: Int, actualBytes: Int)
    case invalidDeliveryPolicy
    case expired
}
