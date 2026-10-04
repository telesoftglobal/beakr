import Foundation
import Testing
import BeakrNetCore
import BeakrNetSecurity
@testable import BeakrNetAuthority
@testable import BeakrNetRelayTransport

@Suite("Revocation snapshot distribution")
struct RevocationDistributionTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("A verified snapshot reaches every active route")
    func distributesToActiveRoutes() async throws {
        let authority = CredentialAuthority()
        let distributor = RevocationSnapshotDistributor(
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            now: { now }
        )
        let lan = RecordingConsumer()
        let relay = RecordingConsumer()
        await distributor.register(lan)
        await distributor.register(relay)
        let snapshot = try authority.issueRevocationSnapshot(revocations: [], now: now)

        let report = try await distributor.publish(snapshot)

        #expect(report.outcomes.count == 2)
        #expect(report.outcomes.values.allSatisfy { $0 == .installed })
        #expect(await lan.snapshots == [snapshot])
        #expect(await relay.snapshots == [snapshot])
    }

    @Test("A late route receives the current snapshot during registration")
    func catchesUpLateRoute() async throws {
        let authority = CredentialAuthority()
        let distributor = RevocationSnapshotDistributor(
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            now: { now }
        )
        let snapshot = try authority.issueRevocationSnapshot(revocations: [], now: now)
        _ = try await distributor.publish(snapshot)
        let consumer = RecordingConsumer()

        let outcome = await distributor.register(consumer)

        #expect(outcome == .installed)
        #expect(await consumer.snapshots == [snapshot])
    }

    @Test("Rollback and conflicting snapshots are rejected before distribution")
    func rejectsRollbackAndConflict() async throws {
        let authority = CredentialAuthority()
        let distributor = RevocationSnapshotDistributor(
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            now: { now }
        )
        let consumer = RecordingConsumer()
        await distributor.register(consumer)
        let current = try authority.issueRevocationSnapshot(revocations: [], now: now)
        _ = try await distributor.publish(current)
        let stale = try authority.issueRevocationSnapshot(
            revocations: [],
            now: now.addingTimeInterval(-1)
        )
        let conflict = try authority.issueRevocationSnapshot(
            revocations: [revocation()],
            now: now
        )

        await #expect(throws: RevocationDistributionError.staleSnapshot) {
            try await distributor.publish(stale)
        }
        await #expect(throws: RevocationDistributionError.conflictingSnapshot) {
            try await distributor.publish(conflict)
        }
        #expect(await consumer.snapshots == [current])
    }

    @Test("Consumer failure is isolated and reported")
    func isolatesConsumerFailure() async throws {
        let authority = CredentialAuthority()
        let distributor = RevocationSnapshotDistributor(
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            now: { now }
        )
        let healthy = RecordingConsumer()
        let failing = RecordingConsumer(shouldFail: true)
        await distributor.register(healthy)
        await distributor.register(failing)
        let snapshot = try authority.issueRevocationSnapshot(revocations: [], now: now)

        let report = try await distributor.publish(snapshot)

        #expect(report.outcomes[healthy.revocationConsumerID] == .installed)
        guard case .failed = report.outcomes[failing.revocationConsumerID] else {
            Issue.record("Expected the failing route to be reported")
            return
        }
        #expect(await healthy.snapshots == [snapshot])
    }

    @Test("A relay closes when its own credential is revoked")
    func revokedRelayCredentialClosesTransport() async throws {
        let authority = CredentialAuthority()
        let identity = NodeIdentity()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            environment: "test",
            validity: 60,
            now: now
        )
        let configuration = try RelayTransportConfiguration(
            host: "127.0.0.1",
            port: 7878,
            preSharedKey: Data(repeating: 0x42, count: 32),
            identity: identity,
            credential: credential,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            now: { now }
        )
        let relay = RelayTransport(configuration: configuration)
        let snapshot = try authority.issueRevocationSnapshot(
            revocations: [revocation(credential.claims.credentialID)],
            now: now
        )

        await #expect(throws: RelayTransportError.localCredentialRevoked) {
            try await relay.installRevocationSnapshot(snapshot)
        }
        #expect(await relay.state == .closed)
    }

    private func revocation(_ id: UUID = UUID()) -> CredentialRevocation {
        CredentialRevocation(
            credentialID: id,
            revokedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            reason: "test"
        )
    }
}

private enum RecordingConsumerError: Error {
    case rejected
}

private actor RecordingConsumer: RevocationSnapshotConsumer {
    nonisolated let revocationConsumerID = TransportID()
    let shouldFail: Bool
    private(set) var snapshots: [CredentialRevocationSnapshot] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func installRevocationSnapshot(
        _ snapshot: CredentialRevocationSnapshot
    ) async throws {
        if shouldFail { throw RecordingConsumerError.rejected }
        snapshots.append(snapshot)
    }
}
