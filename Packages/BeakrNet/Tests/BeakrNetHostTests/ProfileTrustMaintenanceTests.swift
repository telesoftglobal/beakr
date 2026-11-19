import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity
@testable import BeakrNetHost

@Suite("Profile trust maintenance")
struct ProfileTrustMaintenanceTests {
    @Test("Authority removal propagates to member directories and survives reopening")
    func removalPropagatesAndRejectsReentry() async throws {
        let now = Date()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = CredentialAuthority()
        let network = NetworkID()
        let identities = [NodeIdentity(), NodeIdentity(), NodeIdentity()]
        let trust = try await AuthorityTrustStateCoordinator.open(
            authority: authority, networkID: network, environment: "test",
            ledgerURL: root.appendingPathComponent("trust.json"), now: now
        )
        let credentials = try identities.map { identity in
            try authority.issue(nodeID: identity.nodeID, nodePublicKey: identity.publicKeyRepresentation,
                                networkID: network, environment: "test", validity: 3600,
                                serviceScopes: ["lan"], now: now)
        }
        for index in identities.indices {
            try await trust.approve(credential: credentials[index],
                                    certificatePublicKey: identities[index].publicKeyRepresentation, now: now)
        }
        var directories: [ProfileMembershipDirectory] = []
        var controllers: [ProfileTrustMaintenanceController] = []
        for index in 0..<2 {
            let directory = try await ProfileMembershipDirectory.open(
                fileURL: root.appendingPathComponent("member-\(index).json"),
                networkID: network, environment: "test",
                trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                revokedCredentialIDs: [], now: { now }
            )
            let distributor = RevocationSnapshotDistributor(
                trustedAuthorityPublicKey: authority.publicKeyRepresentation, now: { now }
            )
            let controller = ProfileTrustMaintenanceController(
                revocationRefresh: RevocationRefreshController(
                    distributor: distributor, requester: LiveTrustRevocations(trust: trust),
                    store: FileRevocationSnapshotStore(fileURL: root.appendingPathComponent("revocations-\(index).json")),
                    policy: try .init(), now: { now }
                ),
                revocations: distributor, membershipDirectory: directory,
                membershipRefresh: ProfileMembershipRefreshController(
                    directory: directory, requester: LiveTrustMembership(trust: trust),
                    policy: try .init(), now: { now }
                )
            )
            _ = await controller.refreshNow(revocationTrigger: .startup, membershipTrigger: .startup)
            #expect(await directory.memberNodeIDs().count == 3)
            directories.append(directory)
            controllers.append(controller)
        }
        let removed = identities[2]
        try await trust.removeAndRevoke(nodeID: removed.nodeID, reason: "Regression removal", now: now)
        for index in 0..<2 {
            let report = await controllers[index].refreshNow(revocationTrigger: .manual, membershipTrigger: .manual)
            #expect(report.revokedCredentialCount == 1)
            #expect(await directories[index].memberNodeIDs().count == 2)
            #expect(await directories[index].resolve(certificatePublicKey: removed.publicKeyRepresentation) == nil)
            #expect(await controllers[index].connectionSessionID(localNodeID: identities[index].nodeID,
                                                                peerNodeID: removed.nodeID) == nil)
            let persistedRevocations = try CredentialFiles.loadRevocationSnapshot(
                from: root.appendingPathComponent("revocations-\(index).json")
            )
            let revoked = try RevocationVerifier.verify(persistedRevocations,
                trustedAuthorityPublicKey: authority.publicKeyRepresentation)
            let reopened = try await ProfileMembershipDirectory.open(
                fileURL: root.appendingPathComponent("member-\(index).json"),
                networkID: network, environment: "test",
                trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                revokedCredentialIDs: revoked, now: { now }
            )
            #expect(await reopened.sessionID(for: removed.nodeID) == nil)
            #expect(await reopened.sessionID(for: identities[index].nodeID) != nil)
        }
        await #expect(throws: (any Error).self) {
            try await trust.approve(credential: credentials[2],
                                    certificatePublicKey: removed.publicKeyRepresentation, now: now)
        }
    }

    @Test("Revocation is enforced even when membership refresh is offline", arguments: [false, true])
    func revocationPrecedesMembership(membershipOffline: Bool) async throws {
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
            requester: TrustMembershipRequester(snapshot: membership, offline: membershipOffline),
            policy: try .init(refreshInterval: 60, initialRetryDelay: 5, maximumRetryDelay: 10),
            now: { now }
        )
        let controller = ProfileTrustMaintenanceController(
            revocationRefresh: revocationRefresh,
            revocations: distributor,
            membershipDirectory: directory,
            membershipRefresh: membershipRefresh
        )

        if membershipOffline {
            try await directory.activate(membership)
            #expect(await directory.resolve(certificatePublicKey: identity.publicKeyRepresentation) != nil)
        }

        let report = await controller.refreshNow(
            revocationTrigger: .scheduled,
            membershipTrigger: .scheduled
        )

        #expect(report.revokedCredentialCount == 1)
        #expect(await directory.generation() == (membershipOffline ? 1 : nil))
        #expect(await directory.resolve(certificatePublicKey: identity.publicKeyRepresentation) == nil)
        guard case .failed = report.membership else {
            Issue.record("Membership containing the newly revoked credential must fail")
            return
        }
    }
    @Test("Unknown peers fail closed through an authority outage and recover signed membership",
          arguments: [false, true], [false, true])
    func unknownPeerRecovery(revoked: Bool, initiallyOffline: Bool) async throws {
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
            revocations: revoked ? [.init(
                credentialID: credential.claims.credentialID,
                revokedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
                reason: "test"
            )] : [],
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
        let revocationRequester = TrustRevocationRequester(snapshot: revocation, offline: initiallyOffline)
        let revocationRefresh = RevocationRefreshController(
            distributor: distributor,
            requester: revocationRequester,
            store: FileRevocationSnapshotStore(fileURL: root.appendingPathComponent("revocations.json")),
            policy: try .init(refreshInterval: 60, initialRetryDelay: 5, maximumRetryDelay: 10),
            now: { now }
        )
        let requester = TrustMembershipRequester(snapshot: membership, offline: initiallyOffline)
        let membershipRefresh = ProfileMembershipRefreshController(
            directory: directory,
            requester: requester,
            policy: try .init(refreshInterval: 60, initialRetryDelay: 5, maximumRetryDelay: 10),
            now: { now }
        )
        let controller = ProfileTrustMaintenanceController(
            revocationRefresh: revocationRefresh,
            revocations: distributor,
            membershipDirectory: directory,
            membershipRefresh: membershipRefresh
        )


        let resolver = directory.acceptedPeerResolver {
            await controller.recoverUnknownPeer()
        }
        let connection = MembershipRecoveryConnection(key: identity.publicKeyRepresentation)
        #expect(await directory.resolve(certificatePublicKey: identity.publicKeyRepresentation) == nil)
        if initiallyOffline {
            async let firstAttempt = resolver(connection)
            async let concurrentAttempt = resolver(connection)
            let rejected = await [firstAttempt, concurrentAttempt]
            #expect(rejected.allSatisfy { $0 == nil })
            #expect(await directory.generation() == nil)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("membership.json").path))
            #expect(await requester.calls == 1)
            #expect(await revocationRequester.calls == 1)
            // Repeated inbound attempts cannot turn an outage into a refresh storm.
            for _ in 0..<10 { #expect(await resolver(connection) == nil) }
            #expect(await requester.calls == 1)
            #expect(await revocationRequester.calls == 1)
            await requester.setOffline(false)
            await revocationRequester.setOffline(false)
            // Exercise the production miss-recovery retry deadline, without a
            // manual refresh, new controller, or cleared cache.
            try await Task.sleep(for: .milliseconds(2_100))
        }
        async let first = resolver(connection)
        async let second = resolver(connection)
        let peers = await [first, second]
        #expect(peers.allSatisfy { ($0 != nil) == !revoked })
        #expect(await requester.calls == (initiallyOffline ? 2 : 1))
        #expect(await revocationRequester.calls == (initiallyOffline ? 2 : 1))
        let session = await controller.connectionSessionID(localNodeID: identity.nodeID, peerNodeID: identity.nodeID)
        #expect((session != nil) == !revoked)
        // Another unknown identity cannot force an immediate second network fetch.
        #expect(await resolver(MembershipRecoveryConnection(key: Data([99]))) == nil)
        #expect(await requester.calls == (initiallyOffline ? 2 : 1))
    }

}

private actor TrustRevocationRequester: RevocationSnapshotRequesting {
    let snapshot: CredentialRevocationSnapshot
    private var offline: Bool
    private(set) var calls = 0
    init(snapshot: CredentialRevocationSnapshot, offline: Bool = false) {
        self.snapshot = snapshot
        self.offline = offline
    }
    func setOffline(_ offline: Bool) { self.offline = offline }
    func fetchSnapshot(after generatedAtMilliseconds: Int64?) async throws -> CredentialRevocationSnapshot? {
        calls += 1
        if offline { throw URLError(.notConnectedToInternet) }
        return snapshot
    }
}

private actor TrustMembershipRequester: ProfileMembershipSnapshotRequesting {
    private(set) var calls = 0
    let snapshot: ProfileMembershipSnapshot
    private var offline: Bool
    init(snapshot: ProfileMembershipSnapshot, offline: Bool = false) {
        self.snapshot = snapshot
        self.offline = offline
    }
    func setOffline(_ offline: Bool) { self.offline = offline }
    func fetchSnapshot(after generation: UInt64?) async throws -> ProfileMembershipSnapshot? {
        calls += 1
        if offline { throw URLError(.notConnectedToInternet) }
        return snapshot
    }
}

private struct LiveTrustRevocations: RevocationSnapshotRequesting {
    let trust: AuthorityTrustStateCoordinator
    func fetchSnapshot(after generatedAtMilliseconds: Int64?) async throws -> CredentialRevocationSnapshot? {
        await trust.revocationSnapshot()
    }
}

private struct LiveTrustMembership: ProfileMembershipSnapshotRequesting {
    let trust: AuthorityTrustStateCoordinator
    func fetchSnapshot(after generation: UInt64?) async throws -> ProfileMembershipSnapshot? {
        await trust.membershipSnapshot()
    }
}

private final class MembershipRecoveryConnection: BonjourConnection, Sendable {
    let id = UUID()
    let key: Data
    init(key: Data) { self.key = key }
    func start(stateHandler: @escaping @Sendable (BonjourConnectionState) -> Void) {}
    func cancel() {}
    func sendFrame(_ data: Data) async throws {}
    func receiveFrame(maximumBytes: Int) async throws -> Data { Data() }
    func peerCertificate() throws -> BonjourPeerCertificate {
        BonjourPeerCertificate(derRepresentation: Data(), publicKeyRepresentation: key)
    }
}
