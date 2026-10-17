import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

@Suite("Authority administration")
struct AuthorityAdministrationTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("An administrator can create an invitation and cannot replay the request")
    func administratorInvitationAndReplayProtection() async throws {
        let fixture = try Fixture(scopes: ["admin", "relay"])
        let request = try AuthorityInvitationRequest.signed(
            credential: fixture.credential,
            identity: fixture.identity,
            validity: 600,
            now: now
        )

        let invitation = try await fixture.service.createInvitation(request, now: now)
        #expect(invitation.networkID == fixture.networkID)
        #expect(invitation.expiresAtMilliseconds - invitation.issuedAtMilliseconds == 600_000)

        do {
            _ = try await fixture.service.createInvitation(request, now: now)
            Issue.record("A replayed administration request was accepted")
        } catch let error as AuthorityAdministrationError {
            #expect(error == .replayedRequest)
        }
    }

    @Test("A valid credential without admin scope cannot create an invitation")
    func nonAdministratorIsRejected() async throws {
        let fixture = try Fixture(scopes: ["relay"])
        let request = try AuthorityInvitationRequest.signed(
            credential: fixture.credential,
            identity: fixture.identity,
            validity: 600,
            now: now
        )

        do {
            _ = try await fixture.service.createInvitation(request, now: now)
            Issue.record("A non-administrator created an invitation")
        } catch let error as AuthorityAdministrationError {
            #expect(error == .unauthorized)
        }
    }
}

private struct Fixture {
    let networkID = NetworkID()
    let identity = NodeIdentity()
    let credential: NodeCredential
    let service: AuthorityAdministrationService

    init(scopes: [String]) throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let authority = CredentialAuthority()
        let capturedNetworkID = networkID
        credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: capturedNetworkID,
            environment: "test",
            validity: 3_600,
            serviceScopes: scopes,
            now: now
        )
        service = AuthorityAdministrationService(
            authorityPublicKey: authority.publicKeyRepresentation,
            networkID: capturedNetworkID,
            environment: "test"
        ) { validity in
            try authority.issueNetworkInvitation(
                networkID: capturedNetworkID,
                environment: "test",
                controlPlaneURL: URL(string: "https://authority.example")!,
                authorityCertificateDER: Data([1, 2, 3]),
                serviceScopes: ["relay"],
                validity: validity,
                now: now
            )
        }
    }
}
