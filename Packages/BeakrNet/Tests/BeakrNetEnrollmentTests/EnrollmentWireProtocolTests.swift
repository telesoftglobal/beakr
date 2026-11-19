import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetEnrollment
import BeakrNetSecurity

@Suite("Enrollment wire protocol")
struct EnrollmentWireProtocolTests {
    @Test("Every enrollment message has a bounded canonical round trip")
    func canonicalRoundTrips() throws {
        let fixture = try WireFixture()

        try roundTrip(fixture.invitation)
        try roundTrip(fixture.request)
        try roundTrip(fixture.approval)
        try roundTrip(fixture.rejection)
        try roundTrip(fixture.confirmation)
    }

    @Test("Invitation verification rejects expiry and authority substitution")
    func invitationValidation() throws {
        let fixture = try WireFixture()
        try EnrollmentWireVerifier.verifyInvitation(fixture.invitation, now: fixture.now, allowedClockSkew: 0)

        #expect(throws: EnrollmentWireError.expired) {
            try EnrollmentWireVerifier.verifyInvitation(
                fixture.invitation,
                now: fixture.now.addingTimeInterval(601),
                allowedClockSkew: 0
            )
        }

        let substituted = EnrollmentInvitation(
            invitationID: fixture.invitation.invitationID,
            networkID: fixture.invitation.networkID,
            authorityID: AuthorityID(rawValue: UUID()),
            authorityPublicKey: fixture.invitation.authorityPublicKey,
            networkDisplayName: fixture.invitation.networkDisplayName,
            environment: fixture.invitation.environment,
            controlPlaneURL: fixture.invitation.controlPlaneURL,
            invitationSecret: fixture.invitation.invitationSecret,
            issuedAtMilliseconds: fixture.invitation.issuedAtMilliseconds,
            expiresAtMilliseconds: fixture.invitation.expiresAtMilliseconds,
            authoritySignature: fixture.invitation.authoritySignature
        )
        #expect(throws: EnrollmentWireError.wrongAuthority) {
            try EnrollmentWireVerifier.verifyInvitation(substituted, now: fixture.now, allowedClockSkew: 0)
        }
    }

    @Test("Request signature binds its nonce, node identity, network, and authority")
    func requestBindings() throws {
        let fixture = try WireFixture()
        try EnrollmentWireVerifier.verifyRequest(
            fixture.request,
            expectedNetworkID: fixture.networkID,
            expectedAuthorityID: fixture.authority.authorityID,
            now: fixture.now,
            allowedClockSkew: 0
        )

        let modified = EnrollmentRequest(
            requestID: fixture.request.requestID,
            invitation: fixture.request.invitation,
            nodeID: fixture.request.nodeID,
            nodePublicKey: fixture.request.nodePublicKey,
            requestNonce: Data(repeating: 9, count: 32),
            nodeSignature: fixture.request.nodeSignature
        )
        #expect(throws: EnrollmentWireError.invalidSignature) {
            try EnrollmentWireVerifier.verifyRequest(
                modified,
                expectedNetworkID: fixture.networkID,
                expectedAuthorityID: fixture.authority.authorityID,
                now: fixture.now,
                allowedClockSkew: 0
            )
        }
        let renamed = EnrollmentRequest(
            requestID: fixture.request.requestID,
            invitation: fixture.request.invitation,
            nodeID: fixture.request.nodeID,
            deviceDisplayName: "Impostor Device",
            nodePublicKey: fixture.request.nodePublicKey,
            requestNonce: fixture.request.requestNonce,
            nodeSignature: fixture.request.nodeSignature
        )
        #expect(throws: EnrollmentWireError.invalidSignature) {
            try EnrollmentWireVerifier.verifyRequest(
                renamed,
                expectedNetworkID: fixture.networkID,
                expectedAuthorityID: fixture.authority.authorityID,
                now: fixture.now,
                allowedClockSkew: 0
            )
        }
        #expect(throws: EnrollmentWireError.wrongNetwork) {
            try EnrollmentWireVerifier.verifyRequest(
                fixture.request,
                expectedNetworkID: NetworkID(),
                expectedAuthorityID: fixture.authority.authorityID,
                now: fixture.now,
                allowedClockSkew: 0
            )
        }
    }

    @Test("Approval, rejection, and confirmation are bound to the original request")
    func decisionBindings() throws {
        let fixture = try WireFixture()
        try EnrollmentWireVerifier.verifyApproval(
            fixture.approval,
            for: fixture.request,
            now: fixture.now,
            allowedClockSkew: 0
        )
        try EnrollmentWireVerifier.verifyRejection(fixture.rejection, for: fixture.request)
        try EnrollmentWireVerifier.verifyConfirmation(
            fixture.confirmation,
            for: fixture.approval,
            nodePublicKey: fixture.identity.publicKeyRepresentation
        )

        let replayedForAnotherRequest = EnrollmentRequest(
            requestID: UUID(),
            invitation: fixture.request.invitation,
            nodeID: fixture.request.nodeID,
            nodePublicKey: fixture.request.nodePublicKey,
            requestNonce: fixture.request.requestNonce,
            nodeSignature: fixture.request.nodeSignature
        )
        #expect(throws: EnrollmentWireError.wrongRequest) {
            try EnrollmentWireVerifier.verifyApproval(
                fixture.approval,
                for: replayedForAnotherRequest,
                now: fixture.now,
                allowedClockSkew: 0
            )
        }
    }

    @Test("Oversized and noncanonical payloads fail before use")
    func boundedCanonicalCodec() throws {
        let fixture = try WireFixture()
        let canonical = try EnrollmentWireCodec.encode(fixture.invitation)
        let noncanonical = Data(" \n".utf8) + canonical

        #expect(throws: EnrollmentWireError.nonCanonicalPayload) {
            try EnrollmentWireCodec.decode(EnrollmentInvitation.self, from: noncanonical)
        }
        #expect(throws: EnrollmentWireError.payloadTooLarge) {
            try EnrollmentWireCodec.decode(
                EnrollmentInvitation.self,
                from: Data(repeating: 0, count: EnrollmentWireCodec.maximumPayloadBytes + 1)
            )
        }
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try EnrollmentWireCodec.encode(value)
        #expect(try EnrollmentWireCodec.decode(T.self, from: data) == value)
    }
}

private struct WireFixture {
    let now = Date(timeIntervalSince1970: 10_000)
    let authority = CredentialAuthority()
    let identity = NodeIdentity()
    let networkID = NetworkID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!)
    let invitation: EnrollmentInvitation
    let request: EnrollmentRequest
    let approval: EnrollmentApproval
    let rejection: EnrollmentRejection
    let confirmation: EnrollmentConfirmation

    init() throws {
        invitation = try EnrollmentWireSigner.invitation(
            authority: authority,
            invitationID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            networkID: networkID,
            networkDisplayName: "Family",
            environment: "test",
            controlPlaneURL: URL(string: "https://authority.example/enroll")!,
            invitationSecret: Data(repeating: 1, count: 32),
            issuedAt: now,
            validity: 600
        )
        request = try EnrollmentWireSigner.request(
            invitation: invitation,
            identity: identity,
            requestID: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
            requestNonce: Data(repeating: 2, count: 32)
        )
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
            generatedAtMilliseconds: 10_000_000,
            records: [ProfileMembershipRecord(
                credential: credential,
                certificatePublicKey: identity.publicKeyRepresentation,
                sessionID: SessionID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000004")!)
            )]
        ))
        let revocations = try authority.issueRevocationSnapshot(revocations: [], now: now)
        approval = try EnrollmentWireSigner.approval(
            request: request,
            approvalID: UUID(uuidString: "20000000-0000-0000-0000-000000000005")!,
            credential: credential,
            membership: membership,
            revocations: revocations,
            authority: authority,
            issuedAt: now
        )
        rejection = try EnrollmentWireSigner.rejection(
            request: request,
            rejectionID: UUID(uuidString: "20000000-0000-0000-0000-000000000006")!,
            reason: .declined,
            authority: authority,
            issuedAt: now
        )
        confirmation = try EnrollmentWireSigner.confirmation(
            approval: approval,
            identity: identity,
            confirmationID: UUID(uuidString: "20000000-0000-0000-0000-000000000007")!
        )
    }
}
