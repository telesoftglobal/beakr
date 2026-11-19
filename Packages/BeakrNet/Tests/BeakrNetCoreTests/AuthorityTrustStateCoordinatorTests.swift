import Foundation
import Testing
import BeakrNetCore
import BeakrNetSecurity
@testable import BeakrNetAuthority

@Suite("Authority trust-state transactions")
struct AuthorityTrustStateCoordinatorTests {
    @Test("An idle authority renews stale signed revocations on conditional GET without changing membership")
    func idleAuthorityRenewsOnRequest() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledgerURL = root.appendingPathComponent("trust.json")
        let coordinator = try await AuthorityTrustStateCoordinator.open(
            authority: authority, networkID: networkID, environment: "test",
            ledgerURL: ledgerURL, now: now
        )
        let identity = NodeIdentity()
        let credential = try authority.issue(
            nodeID: identity.nodeID, nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID, environment: "test", validity: 7 * 86_400,
            serviceScopes: ["lan"], now: now
        )
        try await coordinator.approve(
            credential: credential, certificatePublicKey: identity.publicKeyRepresentation, now: now
        )
        let remainingIdentity = NodeIdentity()
        let remainingCredential = try authority.issue(
            nodeID: remainingIdentity.nodeID, nodePublicKey: remainingIdentity.publicKeyRepresentation,
            networkID: networkID, environment: "test", validity: 7 * 86_400,
            serviceScopes: ["lan"], now: now
        )
        try await coordinator.approve(
            credential: remainingCredential,
            certificatePublicKey: remainingIdentity.publicKeyRepresentation, now: now
        )
        try await coordinator.removeAndRevoke(nodeID: identity.nodeID, reason: "fixture", now: now)
        let membership = await coordinator.membershipSnapshot()
        let old = await coordinator.revocationSnapshot()
        let later = now.addingTimeInterval(90_000)
        #expect(throws: LANHandshakeError.staleRevocationSnapshot) {
            try LANHandshakeAuthenticator.validatedRevokedCredentialIDs(
                in: old, trustedAuthorityPublicKey: authority.publicKeyRepresentation, now: later
            )
        }
        let endpoint = await coordinator.revocationEndpoint
        let request = CertificateEnrollmentHTTPRequest(
            method: "GET", path: RevocationSnapshotHTTPEndpoint.path,
            headers: ["if-none-match": RevocationSnapshotHTTPEndpoint.etag(for: old)]
        )
        let response = await endpoint.handle(request, now: later)
        #expect(response.statusCode == 200)
        let fresh = try RevocationSnapshotWireCodec.decode(response.body)
        #expect(fresh.claims.generatedAtMilliseconds > old.claims.generatedAtMilliseconds)
        #expect(fresh.claims.revocations == old.claims.revocations)
        let revoked = try LANHandshakeAuthenticator.validatedRevokedCredentialIDs(
            in: fresh, trustedAuthorityPublicKey: authority.publicKeyRepresentation, now: later
        )
        #expect(revoked.contains(credential.claims.credentialID))
        #expect(await coordinator.membershipSnapshot() == membership)
        let reopened = try await AuthorityTrustStateCoordinator.open(
            authority: authority, networkID: networkID, environment: "test",
            ledgerURL: ledgerURL, now: later
        )
        #expect(await reopened.revocationSnapshot() == fresh)
        #expect(await reopened.membershipSnapshot() == membership)
        let unchanged = await endpoint.handle(.init(
            method: "GET", path: RevocationSnapshotHTTPEndpoint.path,
            headers: ["if-none-match": RevocationSnapshotHTTPEndpoint.etag(for: fresh)]
        ), now: later.addingTimeInterval(60))
        #expect(unchanged.statusCode == 304)
    }

    @Test("Concurrent refresh requests renew once and invalid requests do not renew")
    func concurrentRevocationRenewal() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try await AuthorityTrustStateCoordinator.open(
            authority: CredentialAuthority(), networkID: NetworkID(), environment: "test",
            ledgerURL: root.appendingPathComponent("trust.json"), now: now
        )
        let old = await coordinator.revocationSnapshot()
        let endpoint = await coordinator.revocationEndpoint
        let later = now.addingTimeInterval(90_000)
        #expect(await endpoint.handle(.init(method: "POST", path: RevocationSnapshotHTTPEndpoint.path),
                                      now: later).statusCode == 405)
        #expect(await coordinator.revocationSnapshot() == old)
        let snapshots = try await withThrowingTaskGroup(of: CredentialRevocationSnapshot.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let response = await endpoint.handle(.init(
                        method: "GET", path: RevocationSnapshotHTTPEndpoint.path
                    ), now: later)
                    #expect(response.statusCode == 200)
                    return try RevocationSnapshotWireCodec.decode(response.body)
                }
            }
            var results: [CredentialRevocationSnapshot] = []
            for try await snapshot in group { results.append(snapshot) }
            return results
        }
        let current = await coordinator.revocationSnapshot()
        #expect(current.claims.generatedAtMilliseconds == Int64(later.timeIntervalSince1970 * 1_000))
        #expect(snapshots.allSatisfy { $0 == current })
    }

    @Test("Failed durable renewal returns unavailable rather than stale success")
    func renewalPersistenceFailure() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try await AuthorityTrustStateCoordinator.open(
            authority: CredentialAuthority(), networkID: NetworkID(), environment: "test",
            ledgerURL: root.appendingPathComponent("trust.json"), now: now
        )
        let old = await coordinator.revocationSnapshot()
        // Replace only this disposable fixture directory with a file to deny writes.
        try FileManager.default.removeItem(at: root)
        try Data([1]).write(to: root)
        let response = await coordinator.revocationEndpoint.handle(.init(
            method: "GET", path: RevocationSnapshotHTTPEndpoint.path,
            headers: ["if-none-match": RevocationSnapshotHTTPEndpoint.etag(for: old)]
        ), now: now.addingTimeInterval(90_000))
        #expect(response.statusCode == 503)
        #expect(response.body.isEmpty)
        #expect(await coordinator.revocationSnapshot() == old)
    }

    @Test("Approval and removal atomically advance membership and accumulated revocations")
    func approveThenRemove() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let identity = NodeIdentity()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "test",
            validity: 3_600,
            serviceScopes: ["lan"],
            now: now
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakr-trust-ledger-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledgerURL = root.appendingPathComponent("trust.json")
        let coordinator = try await AuthorityTrustStateCoordinator.open(
            authority: authority,
            networkID: networkID,
            environment: "test",
            ledgerURL: ledgerURL,
            now: now
        )

        try await coordinator.approve(
            credential: credential,
            certificatePublicKey: identity.publicKeyRepresentation,
            now: now
        )
        #expect(await coordinator.membershipSnapshot().claims.generation == 1)
        #expect(await coordinator.membershipSnapshot().claims.records.count == 1)

        try await coordinator.removeAndRevoke(
            nodeID: identity.nodeID,
            reason: "operator removal",
            now: now
        )
        #expect(await coordinator.membershipSnapshot().claims.generation == 2)
        #expect(await coordinator.membershipSnapshot().claims.records.isEmpty)
        #expect(await coordinator.revocationSnapshot().claims.revocations.map(\.credentialID) == [
            credential.claims.credentialID
        ])

        let reopened = try await AuthorityTrustStateCoordinator.open(
            authority: authority,
            networkID: networkID,
            environment: "test",
            ledgerURL: ledgerURL,
            now: now
        )
        #expect(await reopened.membershipSnapshot() == coordinator.membershipSnapshot())
        #expect(await reopened.revocationSnapshot() == coordinator.revocationSnapshot())
    }

    @Test("A failed removal leaves both generations unchanged")
    func failedMutationIsAtomic() async throws {
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakr-trust-ledger-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try await AuthorityTrustStateCoordinator.open(
            authority: authority,
            networkID: networkID,
            environment: "test",
            ledgerURL: root.appendingPathComponent("trust.json")
        )
        let beforeMembership = await coordinator.membershipSnapshot()
        let beforeRevocations = await coordinator.revocationSnapshot()

        await #expect(throws: AuthorityTrustStateError.nodeNotFound) {
            try await coordinator.removeAndRevoke(nodeID: NodeID(), reason: "missing")
        }
        #expect(await coordinator.membershipSnapshot() == beforeMembership)
        #expect(await coordinator.revocationSnapshot() == beforeRevocations)
    }

    @Test("Renaming advances signed metadata without changing network identity or membership")
    func renamePreservesIdentityAndMembership() async throws {
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakr-trust-rename-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try await AuthorityTrustStateCoordinator.open(
            authority: authority,
            networkID: networkID,
            environment: "test",
            networkDisplayName: "Green",
            ledgerURL: root.appendingPathComponent("trust.json")
        )
        let before = await coordinator.membershipSnapshot()

        try await coordinator.renameNetwork(to: "Home")

        let after = await coordinator.membershipSnapshot()
        #expect(after.claims.networkID == networkID)
        #expect(after.claims.networkDisplayName == "Home")
        #expect(after.claims.records == before.claims.records)
        #expect(after.claims.generation == before.claims.generation + 1)
    }
}
