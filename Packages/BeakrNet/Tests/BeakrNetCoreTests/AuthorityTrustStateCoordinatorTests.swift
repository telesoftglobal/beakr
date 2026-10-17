import Foundation
import Testing
import BeakrNetCore
import BeakrNetSecurity
@testable import BeakrNetAuthority

@Suite("Authority trust-state transactions")
struct AuthorityTrustStateCoordinatorTests {
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
