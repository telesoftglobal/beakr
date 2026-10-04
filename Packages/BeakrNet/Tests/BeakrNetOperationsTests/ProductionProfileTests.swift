import Foundation
import Testing
import BeakrNetOperations

@Suite("Production deployment profile")
struct ProductionProfileTests {
    @Test("A complete secure production profile validates")
    func validProfile() throws { try profile().validate() }

    @Test("Development environment and non-HTTPS endpoints fail closed")
    func unsafeDeployment() {
        #expect(throws: ProductionProfileError.invalidEnvironment) { try profile(environment: "development").validate() }
        #expect(throws: ProductionProfileError.insecureEndpoint) {
            try profile(enrollmentURL: URL(string: "http://authority.example/enroll")!).validate()
        }
    }

    @Test("Revocation grace and operational bounds require explicit safe values")
    func boundedPolicy() {
        #expect(throws: ProductionProfileError.invalidRevocationGrace) { try profile(grace: 0).validate() }
        #expect(throws: ProductionProfileError.invalidRevocationGrace) { try profile(grace: 8 * 24 * 60 * 60).validate() }
    }

    private func profile(environment: String = "production",
                         enrollmentURL: URL = URL(string: "https://authority.example/enroll")!,
                         grace: TimeInterval = 24 * 60 * 60) -> BeakrNetProductionProfile {
        .init(environment: environment, enrollmentURL: enrollmentURL,
              revocationURL: URL(string: "https://authority.example/revocations")!,
              keyCustody: .externalKMS(provider: "managed-kms", keyIdentifier: "authority-generation-7"),
              serviceAuthentication: .mutualTLS,
              perSourceLimit: .init(capacity: 20, refillPerSecond: 2),
              perIdentityLimit: .init(capacity: 50, refillPerSecond: 5),
              globalLimit: .init(capacity: 1_000, refillPerSecond: 100), maximumTrackedLimiters: 10_000,
              offlineRevocationGrace: grace, auditRetention: 30 * 24 * 60 * 60, maximumAuditEvents: 100_000,
              backup: .init(retentionCount: 30, maximumAge: 90 * 24 * 60 * 60, encryptionProvider: "backup-kms"))
    }
}
