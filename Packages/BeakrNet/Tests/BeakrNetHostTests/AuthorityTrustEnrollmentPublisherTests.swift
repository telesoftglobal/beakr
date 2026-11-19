import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetHost
import BeakrNetSecurity

@Suite("Enrollment trust-ledger publisher")
struct AuthorityTrustEnrollmentPublisherTests {
    @Test("A staged membership commits to the canonical ledger and replay is idempotent")
    func commitsAndReplays() async throws {
        let now = Date()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakr-enrollment-publisher-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trust = try await AuthorityTrustStateCoordinator.open(
            authority: authority,
            networkID: networkID,
            environment: "test",
            ledgerURL: root.appendingPathComponent("trust.json"),
            now: now
        )
        let membership = try nextMembership(
            authority: authority,
            networkID: networkID,
            generation: 1,
            now: now
        )
        let stateURL = root.appendingPathComponent("transactions.json")
        let transactionID = UUID()
        let publisher = try AuthorityTrustEnrollmentPublisher.open(
            fileURL: stateURL,
            trust: trust,
            now: { now }
        )

        try await publisher.stageMembership(membership, transactionID: transactionID)
        try await publisher.activateMembership(transactionID: transactionID)
        #expect(await trust.membershipSnapshot() == membership)

        let reopened = try AuthorityTrustEnrollmentPublisher.open(
            fileURL: stateURL,
            trust: trust,
            now: { now }
        )
        try await reopened.activateMembership(transactionID: transactionID)
        #expect(await reopened.currentMembership() == membership)
    }

    private func nextMembership(
        authority: CredentialAuthority,
        networkID: NetworkID,
        generation: UInt64,
        now: Date
    ) throws -> ProfileMembershipSnapshot {
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
        return try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        ).sign(.init(
            networkID: networkID,
            networkDisplayName: "Family",
            generation: generation,
            generatedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            records: [.init(
                credential: credential,
                certificatePublicKey: identity.publicKeyRepresentation,
                sessionID: SessionID()
            )]
        ))
    }
}
