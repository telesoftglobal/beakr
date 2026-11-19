import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetEnrollment
import BeakrNetSecurity

@Suite("Persistent enrollment stores")
struct PersistentEnrollmentStoreTests {
    @Test("Lifecycle records survive reopen and reject noncanonical storage")
    func lifecyclePersistence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("lifecycle.json")
        let fixture = try PersistentFixture()
        let store = try PersistentEnrollmentLifecycleStore.open(fileURL: fileURL)
        try await store.save(fixture.identityReadyRecord, condition: .create)

        let reopened = try PersistentEnrollmentLifecycleStore.open(fileURL: fileURL)
        #expect(await reopened.load() == fixture.identityReadyRecord)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(fixture.identityReadyRecord).write(to: fileURL, options: .atomic)
        #expect(throws: EnrollmentPersistenceError.nonCanonicalSnapshot) {
            try PersistentEnrollmentLifecycleStore.open(fileURL: fileURL)
        }
    }

    @Test("Authority invitation, request, and pending approval survive process recreation")
    func authorityStatePersistence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("authority-enrollment.json")
        let fixture = try PersistentFixture()
        var store = try PersistentAuthorityEnrollmentStateStore.open(fileURL: fileURL)
        try await store.registerInvitation(fixture.invitation, maximumPending: 8)
        #expect(try await store.submit(fixture.request, maximumPending: 8) == .accepted)
        let pending = PendingAuthorityApproval(
            transactionID: fixture.transactionID,
            request: fixture.request,
            approval: fixture.approval
        )
        try await store.stageApproval(pending)

        store = try PersistentAuthorityEnrollmentStateStore.open(fileURL: fileURL)
        #expect(await store.pendingApproval(requestID: fixture.request.requestID) == pending)
        try await store.finalizeApproval(
            requestID: fixture.request.requestID,
            transactionID: fixture.transactionID
        )

        store = try PersistentAuthorityEnrollmentStateStore.open(fileURL: fileURL)
        #expect(await store.approval(requestID: fixture.request.requestID) == fixture.approval)
        await #expect(throws: AuthorityEnrollmentError.invitationConsumed) {
            try await store.submit(fixture.request, maximumPending: 8)
        }

        try await store.pruneTerminalRecords(keepingMostRecent: 0)
        // Approval is recoverable work until the joining node confirms installation.
        #expect(await store.auditRecords().map(\.status) == [.approved])
        store = try PersistentAuthorityEnrollmentStateStore.open(fileURL: fileURL)
        #expect(await store.request(id: fixture.request.requestID) == fixture.request)
        #expect(await store.approval(requestID: fixture.request.requestID) == fixture.approval)

        let confirmation = try EnrollmentWireSigner.confirmation(
            approval: fixture.approval,
            identity: fixture.joiningIdentity
        )
        try await store.finalizeConfirmation(confirmation)
        store = try PersistentAuthorityEnrollmentStateStore.open(fileURL: fileURL)
        #expect(await store.confirmation(requestID: fixture.request.requestID) == confirmation)
        #expect(await store.auditRecords().map(\.status) == [.confirmed])

        try await store.pruneTerminalRecords(keepingMostRecent: 0)
        #expect(await store.auditRecords().isEmpty)

        store = try PersistentAuthorityEnrollmentStateStore.open(fileURL: fileURL)
        #expect(await store.auditRecords().isEmpty)
        #expect(await store.request(id: fixture.request.requestID) == nil)
    }

    @Test("Joining requests and staged approvals remain recoverable after reopen")
    func joiningStatePersistence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("joining-enrollment.json")
        let fixture = try PersistentFixture()
        var store = try PersistentJoiningEnrollmentStore.open(fileURL: fileURL)
        try await store.stageRequest(fixture.request)
        try await store.stageApproval(fixture.approval, transactionID: fixture.transactionID)

        store = try PersistentJoiningEnrollmentStore.open(fileURL: fileURL)
        #expect(await store.request(id: fixture.request.requestID) == fixture.request)
        #expect(await store.stagedApproval(transactionID: fixture.transactionID) == fixture.approval)
        try await store.activateApproval(transactionID: fixture.transactionID)

        store = try PersistentJoiningEnrollmentStore.open(fileURL: fileURL)
        #expect(await store.stagedApproval(transactionID: fixture.transactionID) == fixture.approval)
        try await store.activateApproval(transactionID: fixture.transactionID)
    }

    @Test("Membership publication resumes a staged generation after reopen")
    func membershipPublicationPersistence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("membership.json")
        let fixture = try PersistentFixture()
        var publisher = try PersistentAuthorityMembershipPublisher.open(
            fileURL: fileURL,
            initialMembership: fixture.initialMembership,
            initialRevocations: fixture.revocations
        )
        try await publisher.stageMembership(
            fixture.approval.membership,
            transactionID: fixture.transactionID
        )

        publisher = try PersistentAuthorityMembershipPublisher.open(fileURL: fileURL)
        try await publisher.activateMembership(transactionID: fixture.transactionID)
        #expect(await publisher.currentMembership().claims.generation == 1)

        publisher = try PersistentAuthorityMembershipPublisher.open(fileURL: fileURL)
        try await publisher.activateMembership(transactionID: fixture.transactionID)
        #expect(await publisher.currentMembership() == fixture.approval.membership)
    }

    @Test("Oversized and malformed durable snapshots fail closed")
    func invalidPersistence() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("lifecycle.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fileURL)
        #expect(throws: EnrollmentPersistenceError.malformedSnapshot) {
            try PersistentEnrollmentLifecycleStore.open(fileURL: fileURL)
        }
        try Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1).write(to: fileURL)
        #expect(throws: EnrollmentPersistenceError.fileTooLarge) {
            try PersistentEnrollmentLifecycleStore.open(fileURL: fileURL)
        }
    }
}

@Suite("Enrollment cold-start planning")
struct EnrollmentColdStartPlannerTests {
    @Test("Durable transaction kind selects the only permitted recovery path")
    func transactionRecovery() throws {
        let fixture = try PersistentFixture()
        let creation = try fixture.installingRecord(kind: .createNetwork)
        let joining = try fixture.installingRecord(kind: .joinNetwork)

        #expect(EnrollmentColdStartPlanner.action(for: creation) ==
                .resumeNetworkCreation(transactionID: fixture.transactionID))
        #expect(EnrollmentColdStartPlanner.action(for: joining) ==
                .resumeMembershipInstallation(transactionID: fixture.transactionID))
        #expect(EnrollmentColdStartPlanner.action(for: nil) == .showUnconfigured)
    }

    @Test("Joining waits for its exact durable request")
    func joiningRecovery() throws {
        let fixture = try PersistentFixture()
        let joining = try fixture.joiningRecord()
        #expect(EnrollmentColdStartPlanner.action(for: joining) ==
                .waitForAdministrator(requestID: fixture.request.requestID))
    }
}

private struct PersistentFixture {
    let now = Date(timeIntervalSince1970: 50_000)
    let authority = CredentialAuthority()
    let creator = NodeIdentity()
    let joiningIdentity = NodeIdentity()
    let networkID = NetworkID(rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!)
    let transactionID = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
    let invitation: EnrollmentInvitation
    let request: EnrollmentRequest
    let initialMembership: ProfileMembershipSnapshot
    let revocations: CredentialRevocationSnapshot
    let approval: EnrollmentApproval
    let identityReadyRecord: EnrollmentLifecycleRecord

    init() throws {
        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        invitation = try EnrollmentWireSigner.invitation(
            authority: authority,
            networkID: networkID,
            networkDisplayName: "Family",
            environment: "test",
            controlPlaneURL: nil,
            invitationSecret: Data(repeating: 1, count: 32),
            issuedAt: now,
            validity: 600
        )
        request = try EnrollmentWireSigner.request(
            invitation: invitation,
            identity: joiningIdentity,
            requestNonce: Data(repeating: 2, count: 32)
        )
        let creatorCredential = try authority.issue(
            nodeID: creator.nodeID,
            nodePublicKey: creator.publicKeyRepresentation,
            networkID: networkID,
            environment: "test",
            validity: 30 * 24 * 60 * 60,
            now: now
        )
        initialMembership = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        ).sign(ProfileMembershipClaims(
            networkID: networkID,
            networkDisplayName: "Family",
            generation: 0,
            generatedAtMilliseconds: nowMilliseconds,
            records: [ProfileMembershipRecord(
                credential: creatorCredential,
                certificatePublicKey: creator.publicKeyRepresentation,
                sessionID: SessionID()
            )]
        ))
        revocations = try authority.issueRevocationSnapshot(revocations: [], now: now)
        let joiningCredential = try authority.issue(
            nodeID: joiningIdentity.nodeID,
            nodePublicKey: joiningIdentity.publicKeyRepresentation,
            networkID: networkID,
            environment: "test",
            validity: 30 * 24 * 60 * 60,
            now: now
        )
        var records = initialMembership.claims.records
        records.append(ProfileMembershipRecord(
            credential: joiningCredential,
            certificatePublicKey: joiningIdentity.publicKeyRepresentation,
            sessionID: SessionID()
        ))
        let nextMembership = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        ).sign(ProfileMembershipClaims(
            networkID: networkID,
            networkDisplayName: "Family",
            generation: 1,
            generatedAtMilliseconds: nowMilliseconds + 1,
            records: records
        ))
        approval = try EnrollmentWireSigner.approval(
            request: request,
            credential: joiningCredential,
            membership: nextMembership,
            revocations: revocations,
            authority: authority,
            issuedAt: now
        )
        identityReadyRecord = try EnrollmentLifecycleRecord(
            installationID: UUID(),
            phase: .identityReady,
            nodeID: joiningIdentity.nodeID,
            createdAtMilliseconds: nowMilliseconds,
            updatedAtMilliseconds: nowMilliseconds
        )
    }

    func joiningRecord() throws -> EnrollmentLifecycleRecord {
        let network = NetworkBinding(
            networkID: networkID,
            displayName: "Family",
            environment: "test",
            authorityID: authority.authorityID,
            authorityPublicKey: authority.publicKeyRepresentation
        )
        let pending = PendingEnrollment(
            invitationID: invitation.invitationID,
            requestID: request.requestID,
            networkID: networkID,
            expectedAuthorityID: authority.authorityID,
            localNodeID: joiningIdentity.nodeID,
            createdAtMilliseconds: invitation.issuedAtMilliseconds,
            expiresAtMilliseconds: invitation.expiresAtMilliseconds,
            status: .submitted
        )
        return try identityReadyRecord.transitioning(
            to: .joining,
            at: identityReadyRecord.updatedAtMilliseconds,
            nodeID: joiningIdentity.nodeID,
            network: network,
            pendingEnrollment: pending
        )
    }

    func installingRecord(kind: EnrollmentTransactionKind) throws -> EnrollmentLifecycleRecord {
        let joining = try joiningRecord()
        let network = NetworkBinding(
            networkID: networkID,
            displayName: "Family",
            environment: "test",
            authorityID: authority.authorityID,
            authorityPublicKey: authority.publicKeyRepresentation,
            activeCredentialID: approval.credential.claims.credentialID,
            membershipGeneration: 1
        )
        let pending = PendingEnrollment(
            invitationID: invitation.invitationID,
            requestID: request.requestID,
            networkID: networkID,
            expectedAuthorityID: authority.authorityID,
            localNodeID: joiningIdentity.nodeID,
            createdAtMilliseconds: invitation.issuedAtMilliseconds,
            expiresAtMilliseconds: invitation.expiresAtMilliseconds,
            status: .approved
        )
        if kind == .createNetwork {
            return try identityReadyRecord.transitioning(
                to: .installingMembership,
                at: identityReadyRecord.updatedAtMilliseconds,
                nodeID: joiningIdentity.nodeID,
                network: network,
                transaction: EnrollmentTransaction(id: transactionID, kind: kind)
            )
        }
        return try joining.transitioning(
            to: .installingMembership,
            at: joining.updatedAtMilliseconds,
            nodeID: joiningIdentity.nodeID,
            network: network,
            pendingEnrollment: pending,
            transaction: EnrollmentTransaction(id: transactionID, kind: kind)
        )
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("BeakrNetEnrollmentTests-\(UUID().uuidString)", isDirectory: true)
}
