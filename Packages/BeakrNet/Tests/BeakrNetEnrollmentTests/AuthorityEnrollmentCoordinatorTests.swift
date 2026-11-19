import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetEnrollment
import BeakrNetSecurity

@Suite("Authority enrollment coordinator")
struct AuthorityEnrollmentCoordinatorTests {
    @Test("Duplicate request submission is idempotent")
    func duplicateRequest() async throws {
        let fixture = try AuthorityFixture()
        let request = try await fixture.makeRequest()

        #expect(try await fixture.coordinator.submit(request) == .accepted)
        #expect(try await fixture.coordinator.submit(request) == .duplicate)
    }

    @Test("Creating a new invitation invalidates the previous QR code")
    func newInvitationInvalidatesPreviousInvitation() async throws {
        let fixture = try AuthorityFixture(maximumPendingInvitations: 1)
        let previous = try await fixture.coordinator.createInvitation(
            networkDisplayName: "Family",
            controlPlaneURL: nil
        )
        _ = try await fixture.coordinator.createInvitation(
            networkDisplayName: "Family",
            controlPlaneURL: nil
        )
        let staleRequest = try EnrollmentWireSigner.request(
            invitation: previous,
            identity: NodeIdentity(),
            requestNonce: Data(repeating: 4, count: 32)
        )

        await #expect(throws: AuthorityEnrollmentError.invitationConsumed) {
            try await fixture.coordinator.submit(staleRequest)
        }
    }

    @Test("Expired invitations release pending invitation capacity")
    func expiredInvitationCapacity() async throws {
        let clock = AuthorityTestClock()
        let fixture = try AuthorityFixture(maximumPendingInvitations: 1, clock: clock)
        _ = try await fixture.coordinator.createInvitation(
            networkDisplayName: "Family",
            controlPlaneURL: nil
        )

        clock.advance(by: 601)

        _ = try await fixture.coordinator.createInvitation(
            networkDisplayName: "Family",
            controlPlaneURL: nil
        )
    }

    @Test("Expired pending requests become durable signed rejections")
    func expiredPendingRequest() async throws {
        let clock = AuthorityTestClock()
        let fixture = try AuthorityFixture(clock: clock)
        let request = try await fixture.makeRequest()
        _ = try await fixture.coordinator.submit(request)

        clock.advance(by: 24 * 60 * 60 + 601)
        #expect(await fixture.coordinator.pendingRequests().isEmpty)

        let rejection = try #require(
            await fixture.coordinator.rejection(requestID: request.requestID)
        )
        #expect(rejection.reason == .expiredInvitation)
        try EnrollmentWireVerifier.verifyRejection(rejection, for: request)
        let auditRecord = try #require(await fixture.coordinator.auditRecords().first)
        #expect(auditRecord.status == .expired)
    }

    @Test("Approval requires a fresh matching local-authorization grant")
    func localAuthorization() async throws {
        let fixture = try AuthorityFixture()
        let request = try await fixture.makeRequest()
        _ = try await fixture.coordinator.submit(request)
        let invalidGrant = LocalAuthorizationGrant(
            requestID: UUID(),
            issuedAtMilliseconds: fixture.nowMilliseconds,
            expiresAtMilliseconds: fixture.nowMilliseconds + 60_000,
            opaqueToken: Data([1])
        )

        await #expect(throws: AuthorityEnrollmentError.invalidLocalAuthorization) {
            try await fixture.coordinator.approve(
                requestID: request.requestID,
                localAuthorization: invalidGrant
            )
        }
    }

    @Test("Approval consumes the invitation and publishes one membership generation")
    func approvalConsumesInvitation() async throws {
        let fixture = try AuthorityFixture()
        let request = try await fixture.makeRequest()
        _ = try await fixture.coordinator.submit(request)

        let approval = try await fixture.coordinator.approve(
            requestID: request.requestID,
            localAuthorization: fixture.grant(for: request.requestID)
        )
        let duplicate = try await fixture.coordinator.approve(
            requestID: request.requestID,
            localAuthorization: fixture.grant(for: request.requestID)
        )

        #expect(duplicate == approval)
        #expect(approval.membership.claims.generation == 1)
        #expect(approval.membership.claims.records.contains {
            $0.credential.claims.nodeID == request.nodeID
        })

        let replayIdentity = NodeIdentity()
        let replay = try EnrollmentWireSigner.request(
            invitation: request.invitation,
            identity: replayIdentity,
            requestNonce: Data(repeating: 8, count: 32)
        )
        await #expect(throws: AuthorityEnrollmentError.invitationConsumed) {
            try await fixture.coordinator.submit(replay)
        }
    }

    @Test("Re-enrolling an existing node refreshes its credential without duplicating membership")
    func existingNodeReenrollment() async throws {
        let fixture = try AuthorityFixture()
        let identity = NodeIdentity()
        let firstRequest = try await fixture.makeRequest(identity: identity)
        _ = try await fixture.coordinator.submit(firstRequest)
        let firstApproval = try await fixture.coordinator.approve(
            requestID: firstRequest.requestID,
            localAuthorization: fixture.grant(for: firstRequest.requestID)
        )
        let firstRecord = try #require(firstApproval.membership.claims.records.first {
            $0.credential.claims.nodeID == identity.nodeID
        })

        let secondRequest = try await fixture.makeRequest(identity: identity)
        _ = try await fixture.coordinator.submit(secondRequest)
        let secondApproval = try await fixture.coordinator.approve(
            requestID: secondRequest.requestID,
            localAuthorization: fixture.grant(for: secondRequest.requestID)
        )
        let matchingRecords = secondApproval.membership.claims.records.filter {
            $0.credential.claims.nodeID == identity.nodeID
        }

        #expect(matchingRecords.count == 1)
        #expect(secondApproval.membership.claims.records.count == firstApproval.membership.claims.records.count)
        #expect(matchingRecords[0].sessionID == firstRecord.sessionID)
        #expect(matchingRecords[0].credential.claims.credentialID != firstRecord.credential.claims.credentialID)
    }

    @Test("Creating a new invitation retires all pending requests")
    func newInvitationRetiresPendingRequests() async throws {
        let fixture = try AuthorityFixture()
        let request = try await fixture.makeRequest()
        _ = try await fixture.coordinator.submit(request)

        _ = try await fixture.coordinator.createInvitation(
            networkDisplayName: "Family",
            controlPlaneURL: nil
        )

        #expect(await fixture.coordinator.pendingRequests().isEmpty)
        let rejection = try #require(
            await fixture.coordinator.rejection(requestID: request.requestID)
        )
        #expect(rejection.reason == .invitationSuperseded)
        try EnrollmentWireVerifier.verifyRejection(rejection, for: request)
        let auditRecord = try #require(
            await fixture.coordinator.auditRecords().first { $0.id == request.requestID }
        )
        #expect(auditRecord.status == .rejected)
        #expect(auditRecord.rejectionReason == .invitationSuperseded)
    }

    @Test("Publication failure retains the signed decision for restart recovery")
    func approvalRecovery() async throws {
        let fixture = try AuthorityFixture(failActivationOnce: true)
        let request = try await fixture.makeRequest()
        _ = try await fixture.coordinator.submit(request)

        await #expect(throws: AuthorityTestError.activationFailed) {
            try await fixture.coordinator.approve(
                requestID: request.requestID,
                localAuthorization: fixture.grant(for: request.requestID)
            )
        }
        #expect(await fixture.stateStore.pendingApprovals().count == 1)

        let recovered = try await fixture.coordinator.resumePendingApprovals()
        #expect(recovered.count == 1)
        #expect(recovered[0].requestID == request.requestID)
        #expect(await fixture.publisher.activeGeneration == 1)
        #expect(await fixture.stateStore.pendingApprovals().isEmpty)
    }

    @Test("Expired pending approvals preserve their decision and do not block other requests")
    func expirationPreservesPendingApproval() async throws {
        let fixture = try AuthorityFixture(failActivationOnce: true)
        let request = try await fixture.makeRequest()
        _ = try await fixture.coordinator.submit(request)
        await #expect(throws: AuthorityTestError.activationFailed) {
            try await fixture.coordinator.approve(
                requestID: request.requestID,
                localAuthorization: fixture.grant(for: request.requestID)
            )
        }
        let pending = try #require(await fixture.stateStore.pendingApproval(requestID: request.requestID))
        fixture.clock.advance(by: 25 * 60 * 60)
        let freshRequest = try await fixture.makeRequest()
        let client = EnrollmentRequestHTTPClient(transport: EnrollmentEndpointTransport(
            endpoint: EnrollmentRequestHTTPEndpoint(coordinator: fixture.coordinator)
        ))
        #expect(try await client.submit(freshRequest) == .pending(requestID: freshRequest.requestID))
        #expect(try await client.status(requestID: request.requestID) == .pending(requestID: request.requestID))
        #expect(await fixture.stateStore.rejection(requestID: request.requestID) == nil)
        #expect(await fixture.stateStore.pendingApproval(requestID: request.requestID)?.transactionID == pending.transactionID)
        let recovered = try await fixture.coordinator.resumePendingApprovals()
        #expect(recovered == [pending.approval])
        #expect(try await client.status(requestID: request.requestID) == .approved(pending.approval))
    }

    @Test("HTTP submission stays pending until explicit approval and then returns the signed approval")
    func httpRequestLifecycle() async throws {
        let fixture = try AuthorityFixture()
        let request = try await fixture.makeRequest()
        let endpoint = EnrollmentRequestHTTPEndpoint(coordinator: fixture.coordinator)
        let client = EnrollmentRequestHTTPClient(
            transport: EnrollmentEndpointTransport(endpoint: endpoint)
        )

        #expect(try await client.submit(request) == .pending(requestID: request.requestID))
        #expect(try await client.submit(request) == .pending(requestID: request.requestID))

        let approval = try await fixture.coordinator.approve(
            requestID: request.requestID,
            localAuthorization: fixture.grant(for: request.requestID)
        )

        #expect(try await client.status(requestID: request.requestID) == .approved(approval))
        try EnrollmentWireVerifier.verifyApproval(
            approval,
            for: request,
            now: fixture.now,
            allowedClockSkew: 60
        )
    }

    @Test("Recovery finds an approved request after its submission response was lost")
    func recoverLostSubmissionResponse() async throws {
        let fixture = try AuthorityFixture()
        let request = try await fixture.makeRequest()
        let transport = RecoveryEnrollmentTransport(
            endpoint: EnrollmentRequestHTTPEndpoint(coordinator: fixture.coordinator),
            loseSubmissionResponse: true
        )
        let client = EnrollmentRequestHTTPClient(transport: transport)
        await #expect(throws: URLError.self) { try await client.submit(request) }
        let approval = try await fixture.coordinator.approve(
            requestID: request.requestID,
            localAuthorization: fixture.grant(for: request.requestID)
        )
        #expect(try await client.resume(request) == .approved(approval))
        #expect(await transport.methods == ["POST", "GET"])
    }

    @Test("Recovery submits an unknown saved request exactly once")
    func recoverUnknownSubmission() async throws {
        let fixture = try AuthorityFixture()
        let request = try await fixture.makeRequest()
        let transport = RecoveryEnrollmentTransport(
            endpoint: EnrollmentRequestHTTPEndpoint(coordinator: fixture.coordinator)
        )
        let client = EnrollmentRequestHTTPClient(transport: transport)
        #expect(try await client.resume(request) == .pending(requestID: request.requestID))
        #expect(try await client.resume(request) == .pending(requestID: request.requestID))
        #expect(await transport.methods == ["GET", "POST", "GET"])
        #expect(await fixture.coordinator.pendingRequests().count == 1)
    }

    @Test("HTTP errors remain visible and do not cause blind resubmission",
          arguments: [403, 409, 429, 503])
    func recoveryHTTPFailure(statusCode: Int) async throws {
        let fixture = try AuthorityFixture()
        let request = try await fixture.makeRequest()
        let transport = RecoveryEnrollmentTransport(
            endpoint: EnrollmentRequestHTTPEndpoint(coordinator: fixture.coordinator),
            forcedStatus: statusCode
        )
        let client = EnrollmentRequestHTTPClient(transport: transport)
        let error = EnrollmentRequestHTTPError(statusCode: statusCode)
        await #expect(throws: error) { try await client.resume(request) }
        #expect(await transport.methods == ["GET"])
        #expect(error.localizedDescription.contains("HTTP \(statusCode)"))
        #expect(error.isRetryable == (statusCode == 429 || statusCode == 503))
    }

    @Test("A signed installation confirmation is verified and durably recorded")
    func installationConfirmation() async throws {
        let fixture = try AuthorityFixture()
        let identity = NodeIdentity()
        let request = try await fixture.makeRequest(identity: identity)
        let endpoint = EnrollmentRequestHTTPEndpoint(coordinator: fixture.coordinator)
        let client = EnrollmentRequestHTTPClient(
            transport: EnrollmentEndpointTransport(endpoint: endpoint)
        )
        _ = try await client.submit(request)
        let approval = try await fixture.coordinator.approve(
            requestID: request.requestID,
            localAuthorization: fixture.grant(for: request.requestID)
        )
        let confirmation = try EnrollmentWireSigner.confirmation(
            approval: approval,
            identity: identity
        )

        try await client.confirm(confirmation)

        #expect(
            await fixture.coordinator.confirmation(requestID: request.requestID) == confirmation
        )
        let auditRecord = try #require(await fixture.coordinator.auditRecords().first)
        #expect(auditRecord.status == .confirmed)

        let exportData = try EnrollmentAuditExport(
            records: [auditRecord],
            exportedAt: fixture.now
        ).encoded()
        let exportJSON = String(decoding: exportData, as: UTF8.self)
        #expect(exportJSON.contains("\"status\":\"confirmed\""))
        #expect(!exportJSON.contains("invitationSecret"))
        #expect(!exportJSON.contains("requestNonce"))
        #expect(!exportJSON.contains("nodePublicKey"))
        #expect(!exportJSON.contains("authoritySignature"))
        #expect(!exportJSON.contains(Data(repeating: 5, count: 32).base64EncodedString()))
        #expect(!exportJSON.contains(Data(repeating: 6, count: 32).base64EncodedString()))

        let signedExport = try SignedEnrollmentAuditExport.signed(
            records: [auditRecord],
            authority: fixture.authority,
            exportedAt: fixture.now
        )
        let decoded = try JSONDecoder().decode(
            SignedEnrollmentAuditExport.self,
            from: signedExport.encoded()
        )
        let verified = try decoded.verify(
            trustedAuthorityPublicKey: fixture.authority.publicKeyRepresentation
        )
        #expect(verified.records.first?.status == .confirmed)
        let verifiedFromData = try SignedEnrollmentAuditExport.decodeAndVerify(
            signedExport.encoded(),
            trustedAuthorityPublicKey: fixture.authority.publicKeyRepresentation
        )
        #expect(verifiedFromData == verified)
        #expect(throws: EnrollmentAuditExportVerificationError.invalidSignature) {
            try decoded.verify(trustedAuthorityPublicKey: CredentialAuthority().publicKeyRepresentation)
        }
        let prettyPrinted = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: signedExport.encoded()),
            options: [.prettyPrinted, .sortedKeys]
        )
        #expect(throws: EnrollmentAuditExportVerificationError.nonCanonicalDocument) {
            try SignedEnrollmentAuditExport.decodeAndVerify(
                prettyPrinted,
                trustedAuthorityPublicKey: fixture.authority.publicKeyRepresentation
            )
        }
        #expect(throws: EnrollmentAuditExportVerificationError.fileTooLarge) {
            try SignedEnrollmentAuditExport.decodeAndVerify(
                Data(repeating: 0, count: SignedEnrollmentAuditExport.maximumEncodedBytes + 1),
                trustedAuthorityPublicKey: fixture.authority.publicKeyRepresentation
            )
        }

        let replacementAuthority = CredentialAuthority()
        let keyring = try EnrollmentAuditVerificationKeyring(
            currentPublicKey: replacementAuthority.publicKeyRepresentation,
            historicalEntries: [
                .init(
                    publicKey: fixture.authority.publicKeyRepresentation,
                    retiredAtMilliseconds: fixture.nowMilliseconds
                )
            ]
        )
        let historicalKey = try #require(keyring.publicKey(for: signedExport.authorityID))
        #expect(try signedExport.verify(trustedAuthorityPublicKey: historicalKey) == verified)

        let initialKeyring = try EnrollmentAuditVerificationKeyring(
            currentPublicKey: fixture.authority.publicKeyRepresentation
        )
        let rotation = try AuthorityKeyRotationStatement.signed(
            networkID: fixture.networkID,
            retiringAuthority: fixture.authority,
            replacementAuthority: replacementAuthority,
            effectiveAt: fixture.now
        )
        let rotatedKeyring = try initialKeyring.applyingVerifiedRotation(
            rotation,
            networkID: fixture.networkID
        )
        #expect(rotatedKeyring.publicKey(for: fixture.authority.authorityID) != nil)
        #expect(rotatedKeyring.publicKey(for: replacementAuthority.authorityID) != nil)
        let retainedKey = try #require(rotatedKeyring.publicKey(for: signedExport.authorityID))
        #expect(try signedExport.verify(trustedAuthorityPublicKey: retainedKey) == verified)
        #expect(throws: EnrollmentAuditExportVerificationError.invalidRotationStatement) {
            try rotation.verify(networkID: NetworkID())
        }
    }

    @Test("A node-signed cancellation removes the request from the authority queue")
    func nodeCancellation() async throws {
        let fixture = try AuthorityFixture()
        let identity = NodeIdentity()
        let request = try await fixture.makeRequest(identity: identity)
        let endpoint = EnrollmentRequestHTTPEndpoint(coordinator: fixture.coordinator)
        let client = EnrollmentRequestHTTPClient(
            transport: EnrollmentEndpointTransport(endpoint: endpoint)
        )
        #expect(try await client.submit(request) == .pending(requestID: request.requestID))

        let cancellation = try EnrollmentWireSigner.cancellation(
            request: request,
            identity: identity,
            issuedAt: fixture.now
        )
        try await client.cancel(cancellation)

        #expect(await fixture.coordinator.pendingRequests().isEmpty)
        #expect(await fixture.coordinator.cancellation(requestID: request.requestID) == cancellation)
        let auditRecord = try #require(await fixture.coordinator.auditRecords().first)
        #expect(auditRecord.status == .cancelled)
    }

    @Test("A valid signed invitation missing from the authority store reports its specific rejection")
    func unknownInvitationReason() async throws {
        let fixture = try AuthorityFixture()
        let invitation = try EnrollmentWireSigner.invitation(
            authority: fixture.authority,
            networkID: fixture.networkID,
            networkDisplayName: "Family",
            environment: "test",
            controlPlaneURL: nil,
            invitationSecret: Data(repeating: 7, count: 32),
            issuedAt: fixture.now,
            validity: 600
        )
        let request = try EnrollmentWireSigner.request(
            invitation: invitation, identity: NodeIdentity(),
            requestNonce: Data(repeating: 8, count: 32)
        )
        let client = EnrollmentRequestHTTPClient(transport: EnrollmentEndpointTransport(
            endpoint: EnrollmentRequestHTTPEndpoint(coordinator: fixture.coordinator)
        ))
        await #expect(throws: EnrollmentRequestHTTPError(statusCode: 403, reason: .invitationUnknown)) {
            try await client.resume(request)
        }
        #expect(await fixture.coordinator.pendingRequests().isEmpty)
    }

    @Test("Expired submission reports expiration rather than an unspecified HTTP 400")
    func expiredInvitationReason() async throws {
        let fixture = try AuthorityFixture()
        let request = try await fixture.makeRequest()
        fixture.clock.advance(by: 700)
        let client = EnrollmentRequestHTTPClient(transport: EnrollmentEndpointTransport(
            endpoint: EnrollmentRequestHTTPEndpoint(coordinator: fixture.coordinator)
        ))
        await #expect(throws: EnrollmentRequestHTTPError(statusCode: 400, reason: .invitationExpired)) {
            try await client.resume(request)
        }
    }

    @Test("Cancellation permits local cleanup when the authority has no request")
    func cancelUnknownRequest() async throws {
        let fixture = try AuthorityFixture()
        let identity = NodeIdentity()
        let request = try await fixture.makeRequest(identity: identity)
        let client = EnrollmentRequestHTTPClient(
            transport: EnrollmentEndpointTransport(
                endpoint: EnrollmentRequestHTTPEndpoint(coordinator: fixture.coordinator)
            )
        )
        let cancellation = try EnrollmentWireSigner.cancellation(
            request: request, identity: identity, issuedAt: fixture.now
        )
        try await client.cancel(cancellation)
        #expect(await fixture.coordinator.pendingRequests().isEmpty)
    }

    @Test("Cancellation preserves failures that do not establish an absent request",
          arguments: [400, 403, 409, 503])
    func cancelFailure(statusCode: Int) async throws {
        let fixture = try AuthorityFixture()
        let identity = NodeIdentity()
        let request = try await fixture.makeRequest(identity: identity)
        let client = EnrollmentRequestHTTPClient(
            transport: RecoveryEnrollmentTransport(
                endpoint: EnrollmentRequestHTTPEndpoint(coordinator: fixture.coordinator),
                forcedStatus: statusCode
            )
        )
        let cancellation = try EnrollmentWireSigner.cancellation(
            request: request, identity: identity, issuedAt: fixture.now
        )
        await #expect(throws: EnrollmentRequestHTTPError(statusCode: statusCode)) {
            try await client.cancel(cancellation)
        }
    }

    @Test("Local authorization grants are short-lived and bound to one request")
    func boundedLocalAuthorizationGrant() async throws {
        let issuedAt = Date(timeIntervalSince1970: 40_000)
        let requestID = UUID()
        let authority = LocalAuthorizationGrantAuthority(maximumValidity: 60)
        let grant = try await authority.issue(
            requestID: requestID,
            validity: 30,
            now: issuedAt
        )

        try await authority.verifyApprovalGrant(
            grant,
            requestID: requestID,
            now: issuedAt.addingTimeInterval(15)
        )
        await #expect(throws: LocalAuthorizationGrantError.invalidGrant) {
            try await authority.verifyApprovalGrant(
                grant,
                requestID: UUID(),
                now: issuedAt.addingTimeInterval(15)
            )
        }
        await #expect(throws: LocalAuthorizationGrantError.invalidGrant) {
            try await authority.verifyApprovalGrant(
                grant,
                requestID: requestID,
                now: issuedAt.addingTimeInterval(31)
            )
        }
    }

    @Test("A locally authorized rejection is durable and returned by status polling")
    func durableRejection() async throws {
        let fixture = try AuthorityFixture()
        let request = try await fixture.makeRequest()
        let endpoint = EnrollmentRequestHTTPEndpoint(coordinator: fixture.coordinator)
        let client = EnrollmentRequestHTTPClient(
            transport: EnrollmentEndpointTransport(endpoint: endpoint)
        )
        #expect(try await client.submit(request) == .pending(requestID: request.requestID))

        let rejection = try await fixture.coordinator.reject(
            requestID: request.requestID,
            reason: .declined,
            localAuthorization: fixture.grant(for: request.requestID)
        )

        #expect(try await client.status(requestID: request.requestID) == .rejected(rejection))
        #expect(await fixture.coordinator.pendingRequests().isEmpty)
        try EnrollmentWireVerifier.verifyRejection(rejection, for: request)
    }
}

private actor RecoveryEnrollmentTransport: CertificateEnrollmentHTTPTransport {
    let endpoint: EnrollmentRequestHTTPEndpoint
    var loseSubmissionResponse: Bool
    let forcedStatus: Int?
    private(set) var methods: [String] = []

    init(
        endpoint: EnrollmentRequestHTTPEndpoint,
        loseSubmissionResponse: Bool = false,
        forcedStatus: Int? = nil
    ) {
        self.endpoint = endpoint
        self.loseSubmissionResponse = loseSubmissionResponse
        self.forcedStatus = forcedStatus
    }

    func send(_ request: CertificateEnrollmentHTTPRequest) async throws
        -> CertificateEnrollmentHTTPResponse {
        methods.append(request.method)
        if let forcedStatus {
            return .init(statusCode: forcedStatus, headers: [:], body: Data())
        }
        let response = await endpoint.handle(request)
        if request.method == "POST", loseSubmissionResponse {
            loseSubmissionResponse = false
            throw URLError(.networkConnectionLost)
        }
        return response
    }
}

private struct EnrollmentEndpointTransport: CertificateEnrollmentHTTPTransport {
    let endpoint: EnrollmentRequestHTTPEndpoint

    func send(_ request: CertificateEnrollmentHTTPRequest) async throws
        -> CertificateEnrollmentHTTPResponse {
        await endpoint.handle(request)
    }
}

private enum AuthorityTestError: Error {
    case activationFailed
    case invalidGrant
}

private struct TestLocalAuthorizationVerifier: LocalAuthorizationVerifying {
    func verifyApprovalGrant(_ grant: LocalAuthorizationGrant, requestID: UUID, now: Date) throws {
        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        guard grant.requestID == requestID,
              !grant.opaqueToken.isEmpty,
              grant.issuedAtMilliseconds <= nowMilliseconds,
              grant.expiresAtMilliseconds > nowMilliseconds else {
            throw AuthorityTestError.invalidGrant
        }
    }
}

private actor TestMembershipPublisher: AuthorityMembershipPublishing {
    private var membership: ProfileMembershipSnapshot
    private let revocations: CredentialRevocationSnapshot
    private var staged: [UUID: ProfileMembershipSnapshot] = [:]
    private var failActivationOnce: Bool

    var activeGeneration: UInt64 { membership.claims.generation }

    init(
        membership: ProfileMembershipSnapshot,
        revocations: CredentialRevocationSnapshot,
        failActivationOnce: Bool
    ) {
        self.membership = membership
        self.revocations = revocations
        self.failActivationOnce = failActivationOnce
    }

    func currentMembership() -> ProfileMembershipSnapshot { membership }
    func currentRevocations() -> CredentialRevocationSnapshot { revocations }

    func stageMembership(_ membership: ProfileMembershipSnapshot, transactionID: UUID) {
        staged[transactionID] = membership
    }

    func activateMembership(transactionID: UUID) throws {
        if failActivationOnce {
            failActivationOnce = false
            throw AuthorityTestError.activationFailed
        }
        if let proposed = staged.removeValue(forKey: transactionID) {
            membership = proposed
        }
    }

    func discardStagedMembership(transactionID: UUID) {
        staged.removeValue(forKey: transactionID)
    }
}

private final class AuthorityTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = Date(timeIntervalSince1970: 20_000)) {
        self.value = value
    }

    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private struct AuthorityFixture {
    let clock: AuthorityTestClock
    var now: Date { clock.read() }
    var nowMilliseconds: Int64 { Int64(now.timeIntervalSince1970 * 1_000) }
    let authority = CredentialAuthority()
    let networkID = NetworkID(rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!)
    let stateStore: InMemoryAuthorityEnrollmentStateStore
    let publisher: TestMembershipPublisher
    let coordinator: AuthorityEnrollmentCoordinator

    init(
        maximumPendingInvitations: Int = 8,
        failActivationOnce: Bool = false,
        clock: AuthorityTestClock = AuthorityTestClock()
    ) throws {
        self.clock = clock
        let now = clock.read()
        let initialMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        let creator = NodeIdentity()
        let creatorCredential = try authority.issue(
            nodeID: creator.nodeID,
            nodePublicKey: creator.publicKeyRepresentation,
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
            generation: 0,
            generatedAtMilliseconds: initialMilliseconds,
            records: [ProfileMembershipRecord(
                credential: creatorCredential,
                certificatePublicKey: creator.publicKeyRepresentation,
                sessionID: SessionID()
            )]
        ))
        let revocations = try authority.issueRevocationSnapshot(revocations: [], now: now)
        stateStore = InMemoryAuthorityEnrollmentStateStore()
        publisher = TestMembershipPublisher(
            membership: membership,
            revocations: revocations,
            failActivationOnce: failActivationOnce
        )
        let policy = try AuthorityPolicy(
            credentialValidity: 30 * 24 * 60 * 60,
            certificateValidity: 30 * 24 * 60 * 60,
            invitationValidity: 10 * 60,
            pendingRequestValidity: 24 * 60 * 60,
            allowedClockSkew: 60,
            maximumPendingInvitations: maximumPendingInvitations,
            maximumPendingRequests: 8,
            maximumEnrolledDevices: 16,
            maximumPayloadBytes: 64 * 1_024,
            credentialServiceScopes: ["lan.connect", "relay.connect"]
        )
        coordinator = AuthorityEnrollmentCoordinator(
            authority: authority,
            networkID: networkID,
            environment: "test",
            policy: policy,
            stateStore: stateStore,
            membershipPublisher: publisher,
            localAuthorizationVerifier: TestLocalAuthorizationVerifier(),
            now: { clock.read() },
            makeSecret: { Data(repeating: 5, count: 32) }
        )
    }

    func makeRequest(identity: NodeIdentity = NodeIdentity()) async throws -> EnrollmentRequest {
        let invitation = try await coordinator.createInvitation(
            networkDisplayName: "Family",
            controlPlaneURL: nil
        )
        return try EnrollmentWireSigner.request(
            invitation: invitation,
            identity: identity,
            requestNonce: Data(repeating: 6, count: 32)
        )
    }

    func grant(for requestID: UUID) -> LocalAuthorizationGrant {
        LocalAuthorizationGrant(
            requestID: requestID,
            issuedAtMilliseconds: nowMilliseconds,
            expiresAtMilliseconds: nowMilliseconds + 60_000,
            opaqueToken: Data([1])
        )
    }
}
