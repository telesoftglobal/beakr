import Foundation

public struct OperationalRolloutState: Equatable, Sendable {
    public let activeGeneration: UInt64
    public let candidateGeneration: UInt64?
    public let healthyNodes: Int
    public let requiredHealthyNodes: Int
}

public enum OperationalRolloutResult: Equatable, Sendable {
    case activated(UInt64)
    case retained(UInt64)
}

public protocol OperationalKeyCustodyAvailability: Sendable {
    func isAvailable() async -> Bool
}

public enum OperationalReadinessResult: Equatable, Sendable {
    case ready
    case blocked(OperationalAuditReason)
}

public struct OperationalReadinessCoordinator: Sendable {
    private let keyCustody: any OperationalKeyCustodyAvailability

    public init(keyCustody: any OperationalKeyCustodyAvailability) {
        self.keyCustody = keyCustody
    }

    public func evaluate(revocationStateFresh: Bool) async -> OperationalReadinessResult {
        guard await keyCustody.isAvailable() else { return .blocked(.keyUnavailable) }
        guard revocationStateFresh else { return .blocked(.staleRevocation) }
        return .ready
    }
}

public actor OperationalRolloutCoordinator {
    private(set) var activeGeneration: UInt64
    public init(activeGeneration: UInt64) { self.activeGeneration = activeGeneration }

    public func evaluate(candidateGeneration: UInt64, healthyNodes: Int,
                         requiredHealthyNodes: Int, revocationStateFresh: Bool,
                         maximumClockDisagreement: TimeInterval, observedClockDisagreement: TimeInterval) -> OperationalRolloutResult {
        guard candidateGeneration == activeGeneration + 1, requiredHealthyNodes > 0,
              healthyNodes >= requiredHealthyNodes, revocationStateFresh,
              observedClockDisagreement >= 0,
              observedClockDisagreement <= maximumClockDisagreement else { return .retained(activeGeneration) }
        activeGeneration = candidateGeneration
        return .activated(candidateGeneration)
    }
}
