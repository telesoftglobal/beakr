import CryptoKit
import Foundation
import Testing
import BeakrNetOperations

@Suite("Operational backup and recovery drills")
struct OperationalRecoveryTests {
    @Test("Restore activates only a complete integrity-verified backup")
    func verifiedRestore() async throws {
        let activator = RestoreRecorder()
        let coordinator = OperationalRestoreCoordinator(activator: activator)
        let components = ["authority": Data("generation-8".utf8), "revocations": Data("sequence-42".utf8)]
        let manifest = makeManifest(components: components)

        try await coordinator.restore(manifest: manifest, components: components,
                                      expectedEnvironment: "production", minimumAuthorityGeneration: 7,
                                      minimumSequence: 41)

        #expect(await activator.activationCount == 1)
    }

    @Test("Corruption, incompleteness, and rollback fail before activation",
          arguments: [RecoveryFailure.corruption, .missingComponent, .generationRollback, .sequenceRollback])
    func rejectedRestore(failure: RecoveryFailure) async {
        let activator = RestoreRecorder()
        let coordinator = OperationalRestoreCoordinator(activator: activator)
        let original = ["authority": Data("generation-8".utf8), "revocations": Data("sequence-42".utf8)]
        let manifest = makeManifest(components: original)
        var supplied = original
        var minimumGeneration: UInt64 = 7
        var minimumSequence: UInt64 = 41
        switch failure {
        case .corruption: supplied["authority"] = Data("corruption!".utf8)
        case .missingComponent: supplied.removeValue(forKey: "revocations")
        case .generationRollback: minimumGeneration = 9
        case .sequenceRollback: minimumSequence = 42
        }

        await #expect(throws: OperationalRestoreError.self) {
            try await coordinator.restore(manifest: manifest, components: supplied,
                                          expectedEnvironment: "production",
                                          minimumAuthorityGeneration: minimumGeneration,
                                          minimumSequence: minimumSequence)
        }
        #expect(await activator.activationCount == 0)
    }

    @Test("Rollout retains the trusted generation until every health gate passes")
    func rolloutGates() async {
        let coordinator = OperationalRolloutCoordinator(activeGeneration: 7)
        #expect(await coordinator.evaluate(candidateGeneration: 8, healthyNodes: 1, requiredHealthyNodes: 2,
                                           revocationStateFresh: true, maximumClockDisagreement: 5,
                                           observedClockDisagreement: 1) == .retained(7))
        #expect(await coordinator.evaluate(candidateGeneration: 8, healthyNodes: 2, requiredHealthyNodes: 2,
                                           revocationStateFresh: false, maximumClockDisagreement: 5,
                                           observedClockDisagreement: 1) == .retained(7))
        #expect(await coordinator.evaluate(candidateGeneration: 8, healthyNodes: 2, requiredHealthyNodes: 2,
                                           revocationStateFresh: true, maximumClockDisagreement: 5,
                                           observedClockDisagreement: 6) == .retained(7))
        #expect(await coordinator.evaluate(candidateGeneration: 8, healthyNodes: 2, requiredHealthyNodes: 2,
                                           revocationStateFresh: true, maximumClockDisagreement: 5,
                                           observedClockDisagreement: 1) == .activated(8))
    }

    @Test("Key-custody outage blocks readiness without exposing provider details")
    func custodyOutage() async {
        let coordinator = OperationalReadinessCoordinator(keyCustody: CustodyAvailability(available: false))
        #expect(await coordinator.evaluate(revocationStateFresh: true) == .blocked(.keyUnavailable))
    }

    @Test("Restore resource policy rejects oversized backup before activation")
    func restoreResourceLimit() async {
        let activator = RestoreRecorder()
        let verifier = OperationalBackupVerifier(maximumComponents: 1, maximumComponentBytes: 4,
                                                 maximumTotalBytes: 4)
        let coordinator = OperationalRestoreCoordinator(verifier: verifier, activator: activator)
        let components = ["authority": Data("generation-8".utf8)]
        await #expect(throws: OperationalRestoreError.resourceLimit) {
            try await coordinator.restore(manifest: makeManifest(components: components), components: components,
                                          expectedEnvironment: "production", minimumAuthorityGeneration: 7,
                                          minimumSequence: 41)
        }
        #expect(await activator.activationCount == 0)
    }

    @Test("Telemetry exposes bounded reason counters without dynamic labels")
    func privacySafeTelemetry() async {
        let telemetry = OperationalTelemetry()
        await telemetry.increment(.rejected)
        await telemetry.increment(.rejected, by: 2)
        #expect(await telemetry.snapshot() == [.rejected: 3])
    }

    private func makeManifest(components: [String: Data]) -> OperationalBackupManifest {
        OperationalBackupManifest(environment: "production", authorityGeneration: 8, sequence: 42,
                                  createdAt: Date(timeIntervalSince1970: 1_000),
                                  components: components.map {
            OperationalBackupComponent(name: $0.key, byteCount: UInt64($0.value.count),
                                       digest: Data(SHA256.hash(data: $0.value)))
        })
    }
}

enum RecoveryFailure: Sendable {
    case corruption
    case missingComponent
    case generationRollback
    case sequenceRollback
}

private actor RestoreRecorder: OperationalRestoreActivator {
    private(set) var activationCount = 0

    func activate(manifest: OperationalBackupManifest, verifiedComponents: [String: Data]) async throws {
        activationCount += 1
    }
}

private struct CustodyAvailability: OperationalKeyCustodyAvailability {
    let available: Bool
    func isAvailable() async -> Bool { available }
}
