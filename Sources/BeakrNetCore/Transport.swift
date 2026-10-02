import Foundation

public enum TransportKind: String, Codable, CaseIterable, Sendable {
    case local
    case relay
    case watchConnectivity
    case inMemory
}

public struct TransportCapabilities: Codable, Equatable, Sendable {
    public let preservesOrder: Bool
    public let supportsImmediateDelivery: Bool
    public let supportsQueuedDelivery: Bool
    public let supportsBackgroundDelivery: Bool

    public init(
        preservesOrder: Bool,
        supportsImmediateDelivery: Bool,
        supportsQueuedDelivery: Bool,
        supportsBackgroundDelivery: Bool
    ) {
        self.preservesOrder = preservesOrder
        self.supportsImmediateDelivery = supportsImmediateDelivery
        self.supportsQueuedDelivery = supportsQueuedDelivery
        self.supportsBackgroundDelivery = supportsBackgroundDelivery
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
