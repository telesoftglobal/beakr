import Foundation
import Testing
import BeakrNetCore
import BeakrNetSecurity
@testable import BeakrNetAuthority

@Suite("Credential revocation")
struct CredentialRevocationTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("A signed revocation snapshot is accepted")
    func validSnapshot() throws {
        let authority = CredentialAuthority()
        let credentialID = UUID()
        let snapshot = try authority.issueRevocationSnapshot(
            revocations: [revocation(credentialID: credentialID)],
            now: now
        )

        let identifiers = try RevocationVerifier.verify(
            snapshot,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            now: now
        )
        #expect(identifiers == [credentialID])
    }

    @Test("A revoked credential is rejected")
    func revokedCredential() throws {
        let authority = CredentialAuthority()
        let identity = NodeIdentity()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: .test,
            environment: "development",
            validity: 3_600,
            now: now
        )

        #expect(throws: CredentialVerificationError.revoked) {
            try CredentialVerifier.verify(
                credential,
                trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                networkID: .test,
                environment: "development",
                revokedCredentialIDs: [credential.claims.credentialID],
                now: now
            )
        }
    }

    @Test("A snapshot from another authority is rejected")
    func wrongAuthority() throws {
        let issuer = CredentialAuthority()
        let trusted = CredentialAuthority()
        let snapshot = try issuer.issueRevocationSnapshot(
            revocations: [revocation(credentialID: UUID())],
            now: now
        )

        #expect(throws: RevocationVerificationError.wrongIssuer) {
            try RevocationVerifier.verify(
                snapshot,
                trustedAuthorityPublicKey: trusted.publicKeyRepresentation,
                now: now
            )
        }
    }

    private func revocation(credentialID: UUID) -> CredentialRevocation {
        CredentialRevocation(
            credentialID: credentialID,
            revokedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            reason: "test"
        )
    }
}
