import Foundation
import Testing
import BeakrNetCore
import BeakrNetSecurity
@testable import BeakrNetAuthority

@Suite("Credential authority")
struct CredentialAuthorityTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("An enrolled node credential verifies")
    func validCredential() throws {
        let authority = CredentialAuthority()
        let identity = NodeIdentity()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            environment: "development",
            validity: 3_600,
            now: now
        )

        try CredentialVerifier.verify(
            credential,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            environment: "development",
            now: now
        )
    }

    @Test("A credential from another authority is rejected")
    func wrongAuthority() throws {
        let issuer = CredentialAuthority()
        let trustedAuthority = CredentialAuthority()
        let identity = NodeIdentity()
        let credential = try issuer.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            environment: "development",
            validity: 3_600,
            now: now
        )

        #expect(throws: CredentialVerificationError.wrongIssuer) {
            try CredentialVerifier.verify(
                credential,
                trustedAuthorityPublicKey: trustedAuthority.publicKeyRepresentation,
                environment: "development",
                now: now
            )
        }
    }

    @Test("An expired credential is rejected")
    func expiredCredential() throws {
        let authority = CredentialAuthority()
        let identity = NodeIdentity()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            environment: "development",
            validity: 60,
            now: now
        )

        #expect(throws: CredentialVerificationError.expired) {
            try CredentialVerifier.verify(
                credential,
                trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                environment: "development",
                now: now.addingTimeInterval(121),
                allowedClockSkew: 0
            )
        }
    }

    @Test("A credential for another environment is rejected")
    func wrongEnvironment() throws {
        let authority = CredentialAuthority()
        let identity = NodeIdentity()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            environment: "development",
            validity: 3_600,
            now: now
        )

        #expect(throws: CredentialVerificationError.wrongEnvironment) {
            try CredentialVerifier.verify(
                credential,
                trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                environment: "production",
                now: now
            )
        }
    }

    @Test("Changing signed claims invalidates the signature")
    func tamperedCredential() throws {
        let authority = CredentialAuthority()
        let identity = NodeIdentity()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            environment: "development",
            validity: 3_600,
            now: now
        )
        let changedClaims = NodeCredentialClaims(
            credentialID: credential.claims.credentialID,
            issuerID: credential.claims.issuerID,
            nodeID: credential.claims.nodeID,
            nodePublicKey: credential.claims.nodePublicKey,
            environment: credential.claims.environment,
            issuedAtMilliseconds: credential.claims.issuedAtMilliseconds,
            expiresAtMilliseconds: credential.claims.expiresAtMilliseconds,
            serviceScopes: ["admin"]
        )
        let tampered = NodeCredential(
            claims: changedClaims,
            issuerSignature: credential.issuerSignature
        )

        #expect(throws: CredentialVerificationError.invalidSignature) {
            try CredentialVerifier.verify(
                tampered,
                trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                environment: "development",
                now: now
            )
        }
    }
}
