import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetEnrollment
import BeakrNetSecurity

@Suite("Joining-device enrollment coordinator")
struct JoiningEnrollmentCoordinatorTests {
    @Test("Importing an invitation persists the exact request and joining lifecycle")
    func beginsJoining() async throws {
        let fixture = try JoinFixture()
        let request = try await fixture.coordinator.beginJoining(
            invitation: fixture.invitation,
            identity: fixture.identity
        )

        #expect(try await fixture.coordinator.pendingRequest() == request)
        #expect(await fixture.lifecycleStore.load()?.phase == .joining)
        #expect(await fixture.lifecycleStore.load()?.pendingEnrollment?.requestID == request.requestID)
    }

    @Test("A fresh invitation replaces a failed pending request only after safe cancellation",
          arguments: [204, 404, 409, 500])
    func replacesPendingInvitation(cancellationStatus: Int) async throws {
        let fixture = try JoinFixture()
        let old = try await fixture.coordinator.beginJoining(
            invitation: fixture.invitation, identity: fixture.identity
        )
        let replacement = try EnrollmentWireSigner.invitation(
            authority: fixture.authority, networkID: fixture.networkID,
            networkDisplayName: "Family", environment: "test", controlPlaneURL: nil,
            invitationSecret: Data(repeating: 9, count: 32), issuedAt: fixture.now, validity: 600
        )
        let client = EnrollmentRequestHTTPClient(
            transport: ReplacementCancellationTransport(status: cancellationStatus)
        )
        do {
            let replaced = try await fixture.coordinator.prepareReplacementInvitation(
                replacement, identity: fixture.identity,
                cancelRequest: { cancellation in
                    #expect(cancellation.requestID == old.requestID)
                    try await client.cancel(cancellation)
                }
            )
            #expect(cancellationStatus == 204 || cancellationStatus == 404)
            #expect(replaced)
            #expect(try await fixture.coordinator.pendingRequest() == nil)
            let fresh = try await fixture.coordinator.beginJoining(
                invitation: replacement, identity: fixture.identity
            )
            #expect(fresh.requestID != old.requestID)
            #expect(fresh.invitation == replacement)
            #expect(fresh.nodeID == old.nodeID)
            let joined = try await fixture.coordinator.receiveApproval(
                fixture.approval(for: fresh), identity: fixture.identity
            )
            #expect(joined.lifecycle.phase == .member)
        } catch let error as EnrollmentRequestHTTPError {
            #expect(cancellationStatus == 409 || cancellationStatus == 500)
            #expect(error.statusCode == cancellationStatus)
            #expect(try await fixture.coordinator.pendingRequest() == old)
            #expect(await fixture.lifecycleStore.load()?.phase == .joining)
        }
    }

    @Test("Reimporting the same invitation preserves its request without cancellation")
    func sameInvitationResumes() async throws {
        let fixture = try JoinFixture()
        let old = try await fixture.coordinator.beginJoining(
            invitation: fixture.invitation, identity: fixture.identity
        )
        let replaced = try await fixture.coordinator.prepareReplacementInvitation(
            fixture.invitation, identity: fixture.identity,
            cancelRequest: { _ in Issue.record("Same invitation must not cancel its request") }
        )
        #expect(!replaced)
        #expect(try await fixture.coordinator.pendingRequest() == old)
    }

    @Test("A different authority cannot replace a pending invitation for the same network")
    func replacementAuthorityMismatch() async throws {
        let fixture = try JoinFixture()
        let old = try await fixture.coordinator.beginJoining(
            invitation: fixture.invitation, identity: fixture.identity
        )
        let replacement = try EnrollmentWireSigner.invitation(
            authority: CredentialAuthority(), networkID: fixture.networkID,
            networkDisplayName: "Family", environment: "test", controlPlaneURL: nil,
            invitationSecret: Data(repeating: 9, count: 32), issuedAt: fixture.now, validity: 600
        )
        await #expect(throws: JoiningEnrollmentError.requestMismatch) {
            try await fixture.coordinator.prepareReplacementInvitation(
                replacement, identity: fixture.identity,
                cancelRequest: { _ in Issue.record("Authority mismatch must not cancel") }
            )
        }
        #expect(try await fixture.coordinator.pendingRequest() == old)
    }

    @Test("A verified approval installs membership and produces a signed confirmation")
    func completesJoining() async throws {
        let fixture = try JoinFixture()
        let request = try await fixture.coordinator.beginJoining(
            invitation: fixture.invitation,
            identity: fixture.identity
        )
        let approval = try fixture.approval(for: request)

        let joined = try await fixture.coordinator.receiveApproval(
            approval,
            identity: fixture.identity
        )

        #expect(joined.lifecycle.phase == .member)
        #expect(joined.lifecycle.network?.activeCredentialID == approval.credential.claims.credentialID)
        try EnrollmentWireVerifier.verifyConfirmation(
            joined.confirmation,
            for: approval,
            nodePublicKey: fixture.identity.publicKeyRepresentation
        )
        #expect(try await fixture.coordinator.pendingRequest() == nil)
        #expect(await fixture.coordinator.pendingConfirmations() == [joined.confirmation])
        try await fixture.coordinator.acknowledgeConfirmation(
            requestID: joined.confirmation.requestID
        )
        #expect(await fixture.coordinator.pendingConfirmations().isEmpty)
    }

    @Test("A signed rejection returns to identity-ready without replacing the identity")
    func handlesRejection() async throws {
        let fixture = try JoinFixture()
        let request = try await fixture.coordinator.beginJoining(
            invitation: fixture.invitation,
            identity: fixture.identity
        )
        let rejection = try EnrollmentWireSigner.rejection(
            request: request,
            reason: .declined,
            authority: fixture.authority,
            issuedAt: fixture.now
        )

        try await fixture.coordinator.receiveRejection(rejection)

        let record = try #require(await fixture.lifecycleStore.load())
        #expect(record.phase == .identityReady)
        #expect(record.nodeID == fixture.identity.nodeID)
        #expect(record.network == nil)
    }

    @Test("Cancelling a pending request durably returns to identity-ready")
    func cancelsJoining() async throws {
        let fixture = try JoinFixture()
        _ = try await fixture.coordinator.beginJoining(
            invitation: fixture.invitation,
            identity: fixture.identity
        )

        try await fixture.coordinator.cancelJoining()

        let record = try #require(await fixture.lifecycleStore.load())
        #expect(record.phase == .identityReady)
        #expect(record.nodeID == fixture.identity.nodeID)
        #expect(record.network == nil)
        #expect(try await fixture.coordinator.pendingRequest() == nil)
    }

    @Test("Interrupted approval activation resumes from the same joining transaction")
    func resumesInstallation() async throws {
        let fixture = try JoinFixture(failActivationOnce: true)
        let request = try await fixture.coordinator.beginJoining(
            invitation: fixture.invitation,
            identity: fixture.identity
        )
        let approval = try fixture.approval(for: request)

        await #expect(throws: JoinTestError.activationFailed) {
            try await fixture.coordinator.receiveApproval(approval, identity: fixture.identity)
        }
        let checkpoint = try #require(await fixture.lifecycleStore.load())
        #expect(checkpoint.phase == .installingMembership)
        #expect(checkpoint.transaction?.kind == .joinNetwork)

        let joined = try await fixture.coordinator.resumeMembershipInstallation(identity: fixture.identity)
        #expect(joined.lifecycle.phase == .member)
        #expect(joined.approval == approval)
    }

    @Test("Interrupted secure installation replays before approval activation")
    func resumesSecureInstallation() async throws {
        let fixture = try JoinFixture(failInstallationOnce: true)
        let request = try await fixture.coordinator.beginJoining(
            invitation: fixture.invitation,
            identity: fixture.identity
        )
        let approval = try fixture.approval(for: request)

        await #expect(throws: JoinTestError.installationFailed) {
            try await fixture.coordinator.receiveApproval(approval, identity: fixture.identity)
        }
        #expect(await fixture.lifecycleStore.load()?.phase == .installingMembership)

        let joined = try await fixture.coordinator.resumeMembershipInstallation(
            identity: fixture.identity
        )
        #expect(joined.lifecycle.phase == .member)
        #expect(await fixture.membershipInstaller.installedApprovalIDs == [approval.approvalID])
    }

    @Test("An approval for another request cannot mutate joining state")
    func rejectsMismatchedApproval() async throws {
        let fixture = try JoinFixture()
        let request = try await fixture.coordinator.beginJoining(
            invitation: fixture.invitation,
            identity: fixture.identity
        )
        let approval = try fixture.approval(for: request)
        let mismatched = EnrollmentApproval(
            approvalID: approval.approvalID,
            invitationID: approval.invitationID,
            requestID: UUID(),
            networkID: approval.networkID,
            authorityID: approval.authorityID,
            nodeID: approval.nodeID,
            requestNonce: approval.requestNonce,
            credential: approval.credential,
            membership: approval.membership,
            revocations: approval.revocations,
            issuedAtMilliseconds: approval.issuedAtMilliseconds,
            authoritySignature: approval.authoritySignature
        )

        await #expect(throws: EnrollmentWireError.wrongRequest) {
            try await fixture.coordinator.receiveApproval(mismatched, identity: fixture.identity)
        }
        #expect(await fixture.lifecycleStore.load()?.phase == .joining)
    }
}

private enum JoinTestError: Error {
    case activationFailed
    case installationFailed
}

private actor TestMembershipInstaller: JoiningMembershipInstalling {
    private(set) var installedApprovalIDs: [UUID] = []
    private var failOnce: Bool

    init(failOnce: Bool = false) {
        self.failOnce = failOnce
    }

    func installMembership(from approval: EnrollmentApproval, identity: NodeIdentity) throws {
        if failOnce {
            failOnce = false
            throw JoinTestError.installationFailed
        }
        if !installedApprovalIDs.contains(approval.approvalID) {
            installedApprovalIDs.append(approval.approvalID)
        }
    }
}

private actor TestJoiningStore: JoiningEnrollmentStore {
    private var requests: [UUID: EnrollmentRequest] = [:]
    private var staged: [UUID: EnrollmentApproval] = [:]
    private var active: [UUID: EnrollmentApproval] = [:]
    private var confirmations: [UUID: EnrollmentConfirmation] = [:]
    private var failActivationOnce: Bool

    init(failActivationOnce: Bool) {
        self.failActivationOnce = failActivationOnce
    }

    func stageRequest(_ request: EnrollmentRequest) { requests[request.requestID] = request }
    func request(id: UUID) -> EnrollmentRequest? { requests[id] }
    func discardRequest(id: UUID) { requests.removeValue(forKey: id) }
    func stageApproval(_ approval: EnrollmentApproval, transactionID: UUID) { staged[transactionID] = approval }
    func stagedApproval(transactionID: UUID) -> EnrollmentApproval? { staged[transactionID] ?? active[transactionID] }

    func activateApproval(transactionID: UUID) throws {
        if failActivationOnce {
            failActivationOnce = false
            throw JoinTestError.activationFailed
        }
        if let approval = staged.removeValue(forKey: transactionID) { active[transactionID] = approval }
    }

    func discardStagedApproval(transactionID: UUID) { staged.removeValue(forKey: transactionID) }
    func stageConfirmation(_ confirmation: EnrollmentConfirmation) {
        confirmations[confirmation.requestID] = confirmation
    }
    func pendingConfirmations() -> [EnrollmentConfirmation] { Array(confirmations.values) }
    func discardConfirmation(requestID: UUID) { confirmations.removeValue(forKey: requestID) }
}

private struct JoinFixture {
    let now = Date(timeIntervalSince1970: 30_000)
    let authority = CredentialAuthority()
    let identity = NodeIdentity()
    let networkID = NetworkID(rawValue: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!)
    let invitation: EnrollmentInvitation
    let lifecycleStore: InMemoryEnrollmentLifecycleStore
    let enrollmentStore: TestJoiningStore
    let membershipInstaller: TestMembershipInstaller
    let coordinator: JoiningEnrollmentCoordinator

    init(failActivationOnce: Bool = false, failInstallationOnce: Bool = false) throws {
        invitation = try EnrollmentWireSigner.invitation(
            authority: authority,
            networkID: networkID,
            networkDisplayName: "Family",
            environment: "test",
            controlPlaneURL: nil,
            invitationSecret: Data(repeating: 3, count: 32),
            issuedAt: now,
            validity: 600
        )
        let milliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        lifecycleStore = InMemoryEnrollmentLifecycleStore(record: try EnrollmentLifecycleRecord(
            installationID: UUID(),
            phase: .identityReady,
            nodeID: identity.nodeID,
            createdAtMilliseconds: milliseconds,
            updatedAtMilliseconds: milliseconds
        ))
        enrollmentStore = TestJoiningStore(failActivationOnce: failActivationOnce)
        membershipInstaller = TestMembershipInstaller(failOnce: failInstallationOnce)
        coordinator = JoiningEnrollmentCoordinator(
            lifecycleStore: lifecycleStore,
            enrollmentStore: enrollmentStore,
            membershipInstaller: membershipInstaller,
            allowedClockSkew: 60,
            now: { Date(timeIntervalSince1970: 30_000) },
            makeNonce: { Data(repeating: 4, count: 32) }
        )
    }

    func approval(for request: EnrollmentRequest) throws -> EnrollmentApproval {
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "test",
            validity: 30 * 24 * 60 * 60,
            serviceScopes: ["lan.connect", "relay.connect"],
            now: now
        )
        let membership = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        ).sign(ProfileMembershipClaims(
            networkID: networkID,
            networkDisplayName: "Family",
            generation: 1,
            generatedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            records: [ProfileMembershipRecord(
                credential: credential,
                certificatePublicKey: identity.publicKeyRepresentation,
                sessionID: SessionID()
            )]
        ))
        return try EnrollmentWireSigner.approval(
            request: request,
            credential: credential,
            membership: membership,
            revocations: try authority.issueRevocationSnapshot(revocations: [], now: now),
            authority: authority,
            issuedAt: now
        )
    }
}

private struct ReplacementCancellationTransport: CertificateEnrollmentHTTPTransport {
    let status: Int

    func send(_ request: CertificateEnrollmentHTTPRequest) async throws -> CertificateEnrollmentHTTPResponse {
        #expect(request.method == "DELETE")
        return CertificateEnrollmentHTTPResponse(statusCode: status)
    }
}
