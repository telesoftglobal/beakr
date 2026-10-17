import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity
@testable import BeakrNetHost

@Suite("Profile trust maintenance")
struct ProfileTrustMaintenanceTests {
    @Test("Revocation is propagated before membership activation")
    func revocationPrecedesMembership() async throws {
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
        let revocation = try authority.issueRevocationSnapshot(
            revocations: [.init(
                credentialID: credential.claims.credentialID,
                revokedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
                reason: "test"
            )],
            now: now
        )
        let membership = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        ).sign(.init(
            networkID: networkID,
            generation: 1,
            generatedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            records: [.init(
                credential: credential,
                certificatePublicKey: identity.publicKeyRepresentation,
                sessionID: SessionID()
            )]
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakr-trust-maintenance-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let distributor = RevocationSnapshotDistributor(
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            now: { now }
        )
        let directory = try await ProfileMembershipDirectory.open(
            fileURL: root.appendingPathComponent("membership.json"),
            networkID: networkID,
            environment: "test",
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            revokedCredentialIDs: [],
            now: { now }
        )
        let revocationRefresh = RevocationRefreshController(
            distributor: distributor,
            requester: TrustRevocationRequester(snapshot: revocation),
            store: FileRevocationSnapshotStore(fileURL: root.appendingPathComponent("revocations.json")),
            policy: try .init(refreshInterval: 60, initialRetryDelay: 5, maximumRetryDelay: 10),
            now: { now }
        )
        let membershipRefresh = ProfileMembershipRefreshController(
            directory: directory,
            requester: TrustMembershipRequester(snapshot: membership),
            policy: try .init(refreshInterval: 60, initialRetryDelay: 5, maximumRetryDelay: 10),
            now: { now }
        )
        let controller = ProfileTrustMaintenanceController(
            revocationRefresh: revocationRefresh,
            revocations: distributor,
            membershipDirectory: directory,
            membershipRefresh: membershipRefresh
        )

        let report = await controller.refreshNow(
            revocationTrigger: .scheduled,
            membershipTrigger: .scheduled
        )

        #expect(report.revokedCredentialCount == 1)
        #expect(await directory.generation() == nil)
        #expect(await directory.resolve(certificatePublicKey: identity.publicKeyRepresentation) == nil)
        guard case .failed = report.membership else {
            Issue.record("Membership containing the newly revoked credential must fail")
            return
        }
    }
}

private actor TrustRevocationRequester: RevocationSnapshotRequesting {
    let snapshot: CredentialRevocationSnapshot
    init(snapshot: CredentialRevocationSnapshot) { self.snapshot = snapshot }
    func fetchSnapshot(after generatedAtMilliseconds: Int64?) async throws -> CredentialRevocationSnapshot? {
        snapshot
    }
}

private actor TrustMembershipRequester: ProfileMembershipSnapshotRequesting {
    let snapshot: ProfileMembershipSnapshot
    init(snapshot: ProfileMembershipSnapshot) { self.snapshot = snapshot }
    func fetchSnapshot(after generation: UInt64?) async throws -> ProfileMembershipSnapshot? {
        snapshot
    }
}
