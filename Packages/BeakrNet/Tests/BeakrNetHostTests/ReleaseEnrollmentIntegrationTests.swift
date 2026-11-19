import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetEnrollment
import BeakrNetHost
import BeakrNetSecurity

@Suite("Release 1 enrollment integration")
struct ReleaseEnrollmentIntegrationTests {
    @Test("Authority approval activates canonical trust and joining membership end to end")
    func authorityToJoiningDevice() async throws {
        let now = Date()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakr-release-enrollment-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let trust = try await AuthorityTrustStateCoordinator.open(
            authority: authority,
            networkID: networkID,
            environment: "test",
            networkDisplayName: "Family",
            ledgerURL: root.appendingPathComponent("authority/trust.json"),
            now: now
        )
        let authorityState = try PersistentAuthorityEnrollmentStateStore.open(
            fileURL: root.appendingPathComponent("authority/enrollment.json")
        )
        let publisher = try AuthorityTrustEnrollmentPublisher.open(
            fileURL: root.appendingPathComponent("authority/transactions.json"),
            trust: trust,
            now: { now }
        )
        let grants = LocalAuthorizationGrantAuthority()
        let authorityCoordinator = AuthorityEnrollmentCoordinator(
            authority: authority,
            networkID: networkID,
            environment: "test",
            policy: try AuthorityPolicy(
                credentialValidity: 3_600,
                certificateValidity: 3_600,
                invitationValidity: 600,
                pendingRequestValidity: 3_600,
                allowedClockSkew: 60,
                maximumPendingInvitations: 8,
                maximumPendingRequests: 8,
                maximumEnrolledDevices: 8,
                maximumPayloadBytes: EnrollmentWireCodec.maximumPayloadBytes,
                credentialServiceScopes: ["lan"]
            ),
            stateStore: authorityState,
            membershipPublisher: publisher,
            localAuthorizationVerifier: grants,
            now: { now },
            makeSecret: { Data(repeating: 7, count: 32) }
        )
        let invitation = try await authorityCoordinator.createInvitation(
            networkDisplayName: "Family",
            controlPlaneURL: URL(string: "https://authority.example")!,
            authorityCertificateDER: Data([1, 2, 3])
        )
        let endpoint = EnrollmentRequestHTTPEndpoint(coordinator: authorityCoordinator)
        let client = EnrollmentRequestHTTPClient(
            transport: ReleaseEnrollmentLoopbackTransport(endpoint: endpoint)
        )

        let identity = NodeIdentity()
        let lifecycleStore = try PersistentEnrollmentLifecycleStore.open(
            fileURL: root.appendingPathComponent("joining/lifecycle.json")
        )
        let milliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        try await lifecycleStore.save(
            EnrollmentLifecycleRecord(
                installationID: UUID(),
                phase: .identityReady,
                nodeID: identity.nodeID,
                createdAtMilliseconds: milliseconds,
                updatedAtMilliseconds: milliseconds
            ),
            condition: .create
        )
        let joiningStore = try PersistentJoiningEnrollmentStore.open(
            fileURL: root.appendingPathComponent("joining/transactions.json")
        )
        let installer = IntegrationMembershipInstaller()
        let joiningCoordinator = JoiningEnrollmentCoordinator(
            lifecycleStore: lifecycleStore,
            enrollmentStore: joiningStore,
            membershipInstaller: installer,
            allowedClockSkew: 60,
            now: { now },
            makeNonce: { Data(repeating: 8, count: 32) }
        )
        let request = try await joiningCoordinator.beginJoining(
            invitation: invitation,
            identity: identity
        )

        #expect(try await client.submit(request) == .pending(requestID: request.requestID))
        #expect(await lifecycleStore.load()?.phase == .joining)

        let grant = try await grants.issue(requestID: request.requestID, now: now)
        let approval = try await authorityCoordinator.approve(
            requestID: request.requestID,
            localAuthorization: grant
        )
        #expect(try await client.status(requestID: request.requestID) == .approved(approval))

        let joined = try await joiningCoordinator.receiveApproval(
            approval,
            identity: identity
        )
        #expect(joined.lifecycle.phase == .member)
        #expect(await installer.installedApprovalIDs == [approval.approvalID])
        #expect(await trust.membershipSnapshot() == approval.membership)
        #expect(await trust.membershipSnapshot().claims.records.contains {
            $0.credential.claims.nodeID == identity.nodeID
        })
        try EnrollmentWireVerifier.verifyConfirmation(
            joined.confirmation,
            for: approval,
            nodePublicKey: identity.publicKeyRepresentation
        )

        let reopenedLifecycle = try PersistentEnrollmentLifecycleStore.open(
            fileURL: root.appendingPathComponent("joining/lifecycle.json")
        )
        let reopenedAuthority = try PersistentAuthorityEnrollmentStateStore.open(
            fileURL: root.appendingPathComponent("authority/enrollment.json")
        )
        #expect(await reopenedLifecycle.load()?.phase == .member)
        #expect(await reopenedAuthority.approval(requestID: request.requestID) == approval)
    }
}

private struct ReleaseEnrollmentLoopbackTransport: CertificateEnrollmentHTTPTransport {
    let endpoint: EnrollmentRequestHTTPEndpoint

    func send(_ request: CertificateEnrollmentHTTPRequest) async throws
        -> CertificateEnrollmentHTTPResponse {
        await endpoint.handle(request)
    }
}

private actor IntegrationMembershipInstaller: JoiningMembershipInstalling {
    private(set) var installedApprovalIDs: [UUID] = []

    func installMembership(from approval: EnrollmentApproval, identity: NodeIdentity) {
        if !installedApprovalIDs.contains(approval.approvalID) {
            installedApprovalIDs.append(approval.approvalID)
        }
    }
}
