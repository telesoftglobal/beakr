import Foundation
import Testing
import BeakrNetCore
import BeakrNetOperations

@Suite("Operational admission and audit")
struct OperationalAdmissionTests {
    @Test("Source overload is deterministic and refills with the injected clock")
    func sourceOverload() async throws {
        let clock = OperationsClock(Date(timeIntervalSince1970: 1_000))
        let controller = try OperationalAdmissionController(profile: profile(sourceCapacity: 1),
                                                             operationLimit: .init(capacity: 10, refillPerSecond: 10),
                                                             clock: { clock.now })
        let context = OperationalAdmissionContext(source: "source-a", identity: nil, endpoint: .enrollment)
        #expect(await controller.admit(context) == .admitted)
        guard case .rejected(.source, let retry) = await controller.admit(context) else {
            Issue.record("Expected source rejection"); return
        }
        #expect(retry == 1)
        clock.now = Date(timeIntervalSince1970: 1_001)
        #expect(await controller.admit(context) == .admitted)
    }

    @Test("Unauthenticated failures consume capacity and principal state stays bounded")
    func abuseBounds() async throws {
        let controller = try OperationalAdmissionController(profile: profile(sourceCapacity: 10, tracked: 2),
                                                             operationLimit: .init(capacity: 100, refillPerSecond: 100))
        for index in 0..<10 {
            _ = await controller.admit(.init(source: "source-\(index)", identity: NodeID(), endpoint: .enrollmentChallenge))
        }
        #expect(await controller.trackedPrincipalCount() <= 2)
    }

    @Test("Global, identity, and operation limits reject at their own layer")
    func layeredOverload() async throws {
        let identity = NodeID()
        let identityController = try OperationalAdmissionController(
            profile: profile(sourceCapacity: 10, identityCapacity: 1),
            operationLimit: .init(capacity: 10, refillPerSecond: 1)
        )
        let identityContext = OperationalAdmissionContext(source: "source-a", identity: identity,
                                                          endpoint: .enrollment)
        #expect(await identityController.admit(identityContext) == .admitted)
        guard case .rejected(.identity, _) = await identityController.admit(identityContext) else {
            Issue.record("Expected identity rejection"); return
        }

        let globalController = try OperationalAdmissionController(
            profile: profile(sourceCapacity: 10, globalCapacity: 1),
            operationLimit: .init(capacity: 10, refillPerSecond: 1)
        )
        #expect(await globalController.admit(.init(source: "source-a", identity: nil,
                                                  endpoint: .enrollment)) == .admitted)
        guard case .rejected(.global, _) = await globalController.admit(
            .init(source: "source-b", identity: nil, endpoint: .revocationRead)
        ) else { Issue.record("Expected global rejection"); return }

        let operationController = try OperationalAdmissionController(
            profile: profile(sourceCapacity: 10), operationLimit: .init(capacity: 1, refillPerSecond: 1)
        )
        #expect(await operationController.admit(.init(source: "source-a", identity: nil,
                                                     endpoint: .enrollment)) == .admitted)
        guard case .rejected(.operation, _) = await operationController.admit(
            .init(source: "source-b", identity: nil, endpoint: .enrollment)
        ) else { Issue.record("Expected operation rejection"); return }
    }

    @Test("Audit retention is bounded and contains no free-form request fields")
    func auditRetention() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let journal = OperationalAuditJournal(maximumEvents: 2, retention: 10)
        await journal.record(.init(timestamp: now.addingTimeInterval(-20), endpoint: .enrollment,
                                   outcome: .failed, reason: .malformed, correlationID: UUID()), now: now)
        await journal.record(.init(timestamp: now, endpoint: .enrollment, outcome: .accepted,
                                   reason: .authorized, correlationID: UUID()), now: now)
        await journal.record(.init(timestamp: now, endpoint: .revocationRead, outcome: .accepted,
                                   reason: .authorized, correlationID: UUID()), now: now)
        #expect(await journal.snapshot(now: now).count == 2)
    }

    private func profile(sourceCapacity: Int, identityCapacity: Int = 100,
                         globalCapacity: Int = 1_000, tracked: Int = 100) -> BeakrNetProductionProfile {
        .init(environment: "production", enrollmentURL: URL(string: "https://a.example/e")!,
              revocationURL: URL(string: "https://a.example/r")!,
              keyCustody: .externalKMS(provider: "kms", keyIdentifier: "key"), serviceAuthentication: .mutualTLS,
              perSourceLimit: .init(capacity: sourceCapacity, refillPerSecond: 1),
              perIdentityLimit: .init(capacity: identityCapacity, refillPerSecond: 1),
              globalLimit: .init(capacity: globalCapacity, refillPerSecond: 1), maximumTrackedLimiters: tracked,
              offlineRevocationGrace: 60, auditRetention: 60, maximumAuditEvents: 100,
              backup: .init(retentionCount: 1, maximumAge: 60, encryptionProvider: "kms"))
    }
}

private final class OperationsClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
