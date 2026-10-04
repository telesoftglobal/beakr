import Foundation

public enum TransportKind: String, Codable, CaseIterable, Sendable {
    case local
    case relay
    case watchConnectivity
    case inMemory
}

public struct TransportCapabilities: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let supportedChannels: Set<BeakrNetChannel>
    public let supportedRepresentations: Set<RepresentationProfile>
    public let maximumEnvelopeBytes: Int
    public let preservesOrder: Bool
    public let supportsImmediateDelivery: Bool
    public let supportsQueuedDelivery: Bool
    public let supportsBackgroundDelivery: Bool

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        supportedChannels: Set<BeakrNetChannel> = Set(BeakrNetChannel.allCases),
        supportedRepresentations: Set<RepresentationProfile> = Set(RepresentationProfile.allCases),
        maximumEnvelopeBytes: Int = 1_048_576,
        preservesOrder: Bool,
        supportsImmediateDelivery: Bool,
        supportsQueuedDelivery: Bool,
        supportsBackgroundDelivery: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.supportedChannels = supportedChannels
        self.supportedRepresentations = supportedRepresentations
        self.maximumEnvelopeBytes = maximumEnvelopeBytes
        self.preservesOrder = preservesOrder
        self.supportsImmediateDelivery = supportsImmediateDelivery
        self.supportsQueuedDelivery = supportsQueuedDelivery
        self.supportsBackgroundDelivery = supportsBackgroundDelivery
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case supportedChannels
        case supportedRepresentations
        case maximumEnvelopeBytes
        case preservesOrder
        case supportsImmediateDelivery
        case supportsQueuedDelivery
        case supportsBackgroundDelivery
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        supportedChannels = Set(try container.decode([BeakrNetChannel].self, forKey: .supportedChannels))
        supportedRepresentations = Set(
            try container.decode([RepresentationProfile].self, forKey: .supportedRepresentations)
        )
        maximumEnvelopeBytes = try container.decode(Int.self, forKey: .maximumEnvelopeBytes)
        preservesOrder = try container.decode(Bool.self, forKey: .preservesOrder)
        supportsImmediateDelivery = try container.decode(Bool.self, forKey: .supportsImmediateDelivery)
        supportsQueuedDelivery = try container.decode(Bool.self, forKey: .supportsQueuedDelivery)
        supportsBackgroundDelivery = try container.decode(Bool.self, forKey: .supportsBackgroundDelivery)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(supportedChannels.sorted { $0.rawValue < $1.rawValue }, forKey: .supportedChannels)
        try container.encode(
            supportedRepresentations.sorted { $0.rawValue < $1.rawValue },
            forKey: .supportedRepresentations
        )
        try container.encode(maximumEnvelopeBytes, forKey: .maximumEnvelopeBytes)
        try container.encode(preservesOrder, forKey: .preservesOrder)
        try container.encode(supportsImmediateDelivery, forKey: .supportsImmediateDelivery)
        try container.encode(supportsQueuedDelivery, forKey: .supportsQueuedDelivery)
        try container.encode(supportsBackgroundDelivery, forKey: .supportsBackgroundDelivery)
    }

    public func supports(
        _ envelope: BeakrNetEnvelope,
        envelopeSizeBytes: Int,
        requiredProtocolVersion: Int = Self.currentProtocolVersion
    ) -> Bool {
        guard protocolVersion == requiredProtocolVersion,
              supportedChannels.contains(envelope.channel),
              supportedRepresentations.contains(envelope.representation),
              envelopeSizeBytes >= 0,
              envelopeSizeBytes <= maximumEnvelopeBytes else {
            return false
        }

        switch envelope.deliveryPolicy.durability {
        case .ephemeral:
            return supportsImmediateDelivery
        case .queued, .durable:
            return supportsQueuedDelivery
        }
    }

    public static let inMemory = TransportCapabilities(
        preservesOrder: true,
        supportsImmediateDelivery: true,
        supportsQueuedDelivery: false,
        supportsBackgroundDelivery: false
    )
}

public protocol BeakrNetTransport: Actor {
    var id: TransportID { get }
    var kind: TransportKind { get }
    var capabilities: TransportCapabilities { get }

    func send(_ envelope: BeakrNetEnvelope) async throws
    func receive() async -> BeakrNetEnvelope?
    func close() async
}
