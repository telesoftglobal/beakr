import Foundation
import BeakrNetCore

public enum OperationalEndpoint: String, Codable, Sendable {
    case enrollmentChallenge = "enrollment-challenge"
    case enrollment
    case membershipRead = "membership-read"
    case revocationRead = "revocation-read"
    case revocationPublish = "revocation-publish"
    case administration
}

public struct OperationalAdmissionContext: Sendable {
    public let source: String
    public let identity: NodeID?
    public let endpoint: OperationalEndpoint
    public init(source: String, identity: NodeID?, endpoint: OperationalEndpoint) {
        self.source = source; self.identity = identity; self.endpoint = endpoint
    }
}

public enum OperationalLimitLayer: String, Codable, Sendable { case global, source, identity, operation }
public enum OperationalAdmissionResult: Equatable, Sendable {
    case admitted
    case rejected(layer: OperationalLimitLayer, retryAfter: TimeInterval)
}

public actor OperationalAdmissionController {
    public typealias Clock = @Sendable () -> Date
    private struct Bucket: Sendable { var tokens: Double; var updatedAt: Date; var lastUsedAt: Date }
    private let profile: BeakrNetProductionProfile
    private let operationLimit: ProductionRateLimit
    private let clock: Clock
    private var global: Bucket
    private var sources: [String: Bucket] = [:]
    private var identities: [NodeID: Bucket] = [:]
    private var operations: [OperationalEndpoint: Bucket] = [:]

    public init(profile: BeakrNetProductionProfile, operationLimit: ProductionRateLimit,
                clock: @escaping Clock = Date.init) throws {
        try profile.validate()
        guard operationLimit.capacity > 0, operationLimit.refillPerSecond > 0 else {
            throw ProductionProfileError.invalidRateLimit
        }
        self.profile = profile; self.operationLimit = operationLimit; self.clock = clock
        let now = clock(); global = Bucket(tokens: Double(profile.globalLimit.capacity), updatedAt: now, lastUsedAt: now)
    }

    public func admit(_ context: OperationalAdmissionContext) -> OperationalAdmissionResult {
        let now = clock()
        if let rejection = consume(&global, limit: profile.globalLimit, now: now) { return .rejected(layer: .global, retryAfter: rejection) }
        evictIfNeeded(now: now)
        var source = sources[context.source] ?? fresh(profile.perSourceLimit, now)
        if let rejection = consume(&source, limit: profile.perSourceLimit, now: now) {
            sources[context.source] = source; return .rejected(layer: .source, retryAfter: rejection)
        }
        sources[context.source] = source
        if let identity = context.identity {
            evictIfNeeded(now: now)
            var bucket = identities[identity] ?? fresh(profile.perIdentityLimit, now)
            if let rejection = consume(&bucket, limit: profile.perIdentityLimit, now: now) {
                identities[identity] = bucket; return .rejected(layer: .identity, retryAfter: rejection)
            }
            identities[identity] = bucket
        }
        var operation = operations[context.endpoint] ?? fresh(operationLimit, now)
        if let rejection = consume(&operation, limit: operationLimit, now: now) {
            operations[context.endpoint] = operation; return .rejected(layer: .operation, retryAfter: rejection)
        }
        operations[context.endpoint] = operation
        return .admitted
    }

    public func trackedPrincipalCount() -> Int { sources.count + identities.count }

    private func fresh(_ limit: ProductionRateLimit, _ now: Date) -> Bucket {
        Bucket(tokens: Double(limit.capacity), updatedAt: now, lastUsedAt: now)
    }
    private func consume(_ bucket: inout Bucket, limit: ProductionRateLimit, now: Date) -> TimeInterval? {
        let elapsed = max(0, now.timeIntervalSince(bucket.updatedAt))
        bucket.tokens = min(Double(limit.capacity), bucket.tokens + elapsed * limit.refillPerSecond)
        bucket.updatedAt = now; bucket.lastUsedAt = now
        guard bucket.tokens >= 1 else { return (1 - bucket.tokens) / limit.refillPerSecond }
        bucket.tokens -= 1; return nil
    }
    private func evictIfNeeded(now: Date) {
        while sources.count + identities.count >= profile.maximumTrackedLimiters {
            let sourceOldest = sources.min { $0.value.lastUsedAt < $1.value.lastUsedAt }
            let identityOldest = identities.min { $0.value.lastUsedAt < $1.value.lastUsedAt }
            if let sourceOldest, identityOldest == nil || sourceOldest.value.lastUsedAt <= identityOldest!.value.lastUsedAt {
                sources.removeValue(forKey: sourceOldest.key)
            } else if let identityOldest { identities.removeValue(forKey: identityOldest.key) } else { break }
        }
    }
}
