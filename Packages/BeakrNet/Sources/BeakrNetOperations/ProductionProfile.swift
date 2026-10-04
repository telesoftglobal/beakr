import Foundation

public enum ProductionKeyCustody: Codable, Equatable, Sendable {
    case secureHardware(provider: String, keyIdentifier: String)
    case externalKMS(provider: String, keyIdentifier: String)
}

public enum ProductionServiceAuthentication: String, Codable, Sendable {
    case mutualTLS = "mutual-tls"
    case signedWorkloadIdentity = "signed-workload-identity"
}

public struct ProductionRateLimit: Codable, Equatable, Sendable {
    public let capacity: Int
    public let refillPerSecond: Double
    public init(capacity: Int, refillPerSecond: Double) {
        self.capacity = capacity; self.refillPerSecond = refillPerSecond
    }
}

public struct ProductionBackupPolicy: Codable, Equatable, Sendable {
    public let retentionCount: Int
    public let maximumAge: TimeInterval
    public let encryptionProvider: String
    public init(retentionCount: Int, maximumAge: TimeInterval, encryptionProvider: String) {
        self.retentionCount = retentionCount; self.maximumAge = maximumAge
        self.encryptionProvider = encryptionProvider
    }
}

public struct BeakrNetProductionProfile: Codable, Equatable, Sendable {
    public let environment: String
    public let enrollmentURL: URL
    public let revocationURL: URL
    public let keyCustody: ProductionKeyCustody
    public let serviceAuthentication: ProductionServiceAuthentication
    public let perSourceLimit: ProductionRateLimit
    public let perIdentityLimit: ProductionRateLimit
    public let globalLimit: ProductionRateLimit
    public let maximumTrackedLimiters: Int
    public let offlineRevocationGrace: TimeInterval
    public let auditRetention: TimeInterval
    public let maximumAuditEvents: Int
    public let backup: ProductionBackupPolicy

    public init(environment: String, enrollmentURL: URL, revocationURL: URL,
                keyCustody: ProductionKeyCustody, serviceAuthentication: ProductionServiceAuthentication,
                perSourceLimit: ProductionRateLimit, perIdentityLimit: ProductionRateLimit,
                globalLimit: ProductionRateLimit, maximumTrackedLimiters: Int,
                offlineRevocationGrace: TimeInterval, auditRetention: TimeInterval,
                maximumAuditEvents: Int, backup: ProductionBackupPolicy) {
        self.environment = environment; self.enrollmentURL = enrollmentURL; self.revocationURL = revocationURL
        self.keyCustody = keyCustody; self.serviceAuthentication = serviceAuthentication
        self.perSourceLimit = perSourceLimit; self.perIdentityLimit = perIdentityLimit; self.globalLimit = globalLimit
        self.maximumTrackedLimiters = maximumTrackedLimiters; self.offlineRevocationGrace = offlineRevocationGrace
        self.auditRetention = auditRetention; self.maximumAuditEvents = maximumAuditEvents; self.backup = backup
    }
}

public enum ProductionProfileError: Error, Equatable, Sendable {
    case invalidEnvironment, insecureEndpoint, invalidKeyCustody, invalidRateLimit
    case invalidRevocationGrace, invalidAuditPolicy, invalidBackupPolicy
}

public extension BeakrNetProductionProfile {
    func validate(maximumOfflineRevocationGrace: TimeInterval = 7 * 24 * 60 * 60) throws {
        guard !environment.isEmpty, environment.utf8.count <= 64, environment != "development" else {
            throw ProductionProfileError.invalidEnvironment
        }
        guard enrollmentURL.scheme?.lowercased() == "https", revocationURL.scheme?.lowercased() == "https",
              enrollmentURL.host != nil, revocationURL.host != nil else { throw ProductionProfileError.insecureEndpoint }
        switch keyCustody {
        case .secureHardware(let provider, let id), .externalKMS(let provider, let id):
            guard !provider.isEmpty, !id.isEmpty, provider.utf8.count <= 128, id.utf8.count <= 256 else {
                throw ProductionProfileError.invalidKeyCustody
            }
        }
        let limits = [perSourceLimit, perIdentityLimit, globalLimit]
        guard limits.allSatisfy({ $0.capacity > 0 && $0.refillPerSecond > 0 && $0.refillPerSecond.isFinite }),
              maximumTrackedLimiters > 0 else { throw ProductionProfileError.invalidRateLimit }
        guard offlineRevocationGrace > 0, offlineRevocationGrace <= maximumOfflineRevocationGrace else {
            throw ProductionProfileError.invalidRevocationGrace
        }
        guard auditRetention > 0, maximumAuditEvents > 0 else { throw ProductionProfileError.invalidAuditPolicy }
        guard backup.retentionCount > 0, backup.maximumAge > 0, !backup.encryptionProvider.isEmpty else {
            throw ProductionProfileError.invalidBackupPolicy
        }
    }
}
