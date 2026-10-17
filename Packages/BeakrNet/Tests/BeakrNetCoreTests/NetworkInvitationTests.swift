import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

@Suite("Network invitations")
struct NetworkInvitationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A joining device proves key possession and receives its credential")
    func joinsOnce() async throws {
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let invitation = try authority.issueNetworkInvitation(
            networkID: networkID,
            environment: "production",
            controlPlaneURL: URL(string: "https://red-blue.local:8443")!,
            authorityCertificateDER: Data([1, 2, 3]),
            now: now
        )
        let identity = NodeIdentity()
        let request = try NetworkJoinRequest.signed(invitation: invitation, identity: identity)
        let service = try NetworkInvitationService(
            authority: authority,
            networkID: networkID,
            environment: "production"
        )

        let credential = try await service.join(request, now: now)

        #expect(credential.claims.nodeID == identity.nodeID)
        #expect(credential.claims.nodePublicKey == identity.publicKeyRepresentation)
        #expect(credential.claims.serviceScopes == ["lan"])
        try CredentialVerifier.verify(
            credential,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: networkID,
            environment: "production",
            now: now
        )
        await #expect(throws: NetworkInvitationError.alreadyConsumed) {
            try await service.join(request, now: now)
        }
    }

    @Test("Tampered trust material is rejected")
    func rejectsTampering() async throws {
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let invitation = try authority.issueNetworkInvitation(
            networkID: networkID,
            environment: "production",
            controlPlaneURL: URL(string: "https://red-blue.local:8443")!,
            authorityCertificateDER: Data([1, 2, 3]),
            now: now
        )
        let tampered = NetworkInvitation(
            invitationID: invitation.invitationID,
            authorityID: invitation.authorityID,
            networkID: invitation.networkID,
            networkDisplayName: invitation.networkDisplayName,
            environment: invitation.environment,
            controlPlaneURL: URL(string: "https://attacker.local:8443")!,
            authorityPublicKey: invitation.authorityPublicKey,
            authorityCertificateDER: invitation.authorityCertificateDER,
            serviceScopes: invitation.serviceScopes,
            issuedAtMilliseconds: invitation.issuedAtMilliseconds,
            expiresAtMilliseconds: invitation.expiresAtMilliseconds,
            authoritySignature: invitation.authoritySignature
        )
        let request = try NetworkJoinRequest.signed(invitation: tampered, identity: NodeIdentity())
        let service = try NetworkInvitationService(
            authority: authority,
            networkID: networkID,
            environment: "production"
        )

        await #expect(throws: NetworkInvitationError.invalidAuthoritySignature) {
            try await service.join(request, now: now)
        }
    }

    @Test("Expired invitations fail closed")
    func rejectsExpiredInvitation() async throws {
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let invitation = try authority.issueNetworkInvitation(
            networkID: networkID,
            environment: "production",
            controlPlaneURL: URL(string: "https://red-blue.local:8443")!,
            authorityCertificateDER: Data([1, 2, 3]),
            validity: 60,
            now: now
        )
        let request = try NetworkJoinRequest.signed(invitation: invitation, identity: NodeIdentity())
        let service = try NetworkInvitationService(
            authority: authority,
            networkID: networkID,
            environment: "production"
        )

        await #expect(throws: NetworkInvitationError.expired) {
            try await service.join(request, now: now.addingTimeInterval(121), allowedClockSkew: 60)
        }
    }

    @Test("Canonical invitation encoding round-trips")
    func canonicalWireRoundTrip() throws {
        let authority = CredentialAuthority()
        let invitation = try authority.issueNetworkInvitation(
            networkID: NetworkID(),
            environment: "production",
            controlPlaneURL: URL(string: "https://red-blue.local:8443")!,
            authorityCertificateDER: Data([1, 2, 3]),
            now: now
        )

        let encoded = try NetworkInvitationWireCodec.encode(invitation)
        #expect(try NetworkInvitationWireCodec.decode(encoded) == invitation)
    }

    @Test("Consumed invitations remain consumed after authority restart")
    func persistsConsumption() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledgerURL = directory.appendingPathComponent("invitations.json")
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let invitation = try authority.issueNetworkInvitation(
            networkID: networkID,
            environment: "production",
            controlPlaneURL: URL(string: "https://red-blue.local:8443")!,
            authorityCertificateDER: Data([1, 2, 3]),
            now: now
        )
        let request = try NetworkJoinRequest.signed(invitation: invitation, identity: NodeIdentity())
        let first = try NetworkInvitationService(
            authority: authority,
            networkID: networkID,
            environment: "production",
            consumptionLedgerURL: ledgerURL
        )
        _ = try await first.join(request, now: now)
        let restored = try NetworkInvitationService(
            authority: authority,
            networkID: networkID,
            environment: "production",
            consumptionLedgerURL: ledgerURL
        )

        await #expect(throws: NetworkInvitationError.alreadyConsumed) {
            try await restored.join(request, now: now)
        }
    }

    @Test("HTTPS join endpoint issues once and rejects replay")
    func httpJoinEndpoint() async throws {
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let invitation = try authority.issueNetworkInvitation(
            networkID: networkID,
            environment: "production",
            controlPlaneURL: URL(string: "https://red-blue.local:8443")!,
            authorityCertificateDER: Data([1, 2, 3]),
            now: now
        )
        let request = try NetworkJoinRequest.signed(
            invitation: invitation,
            identity: NodeIdentity()
        )
        let endpoint = NetworkInvitationHTTPEndpoint(
            service: try .init(
                authority: authority,
                networkID: networkID,
                environment: "production"
            ),
            now: { now }
        )
        let httpRequest = CertificateEnrollmentHTTPRequest(
            method: "POST",
            path: NetworkInvitationHTTPEndpoint.joinPath,
            headers: ["content-type": NetworkInvitationHTTPEndpoint.contentType],
            body: try NetworkJoinRequestWireCodec.encode(request)
        )

        let issued = await endpoint.handle(httpRequest)
        #expect(issued.statusCode == 200)
        let credential = try NetworkJoinCredentialWireCodec.decode(issued.body)
        #expect(credential.claims.nodeID == request.nodeID)
        let replay = await endpoint.handle(httpRequest)
        #expect(replay.statusCode == 403)
        #expect(replay.headers["x-beakr-invitation-error"] == "already-consumed")
    }
}
