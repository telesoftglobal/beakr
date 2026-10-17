import Foundation
import Testing
import BeakrNetCore
import BeakrNetSecurity
@testable import BeakrNetAuthority

extension NetworkID {
    static let test = NetworkID(
        rawValue: UUID(uuidString: "7E570000-0000-4000-8000-000000000001")!
    )
}

@Suite("Credential authority")
struct CredentialAuthorityTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("Network-scoped credential claims have canonical JSON")
    func canonicalClaimsJSON() throws {
        let claims = NodeCredentialClaims(
            credentialID: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
            issuerID: AuthorityID(
                rawValue: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
            ),
            networkID: NetworkID(
                rawValue: UUID(uuidString: "66666666-7777-4888-8999-AAAAAAAAAAAA")!
            ),
            nodeID: NodeID(
                rawValue: UUID(uuidString: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF")!
            ),
            nodePublicKey: Data([1, 2, 3]),
            environment: "development",
            issuedAtMilliseconds: 2_000_000_000_000,
            expiresAtMilliseconds: 2_000_003_600_000,
            serviceScopes: ["relay", "admin"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(claims)
        let fixture = #"{"credentialID":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE","environment":"development","expiresAtMilliseconds":2000003600000,"issuedAtMilliseconds":2000000000000,"issuerID":{"rawValue":"11111111-2222-4333-8444-555555555555"},"networkID":{"rawValue":"66666666-7777-4888-8999-AAAAAAAAAAAA"},"nodeID":{"rawValue":"BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF"},"nodePublicKey":"AQID","serviceScopes":["admin","relay"],"version":2}"#

        #expect(String(decoding: encoded, as: UTF8.self) == fixture)
        #expect(try JSONDecoder().decode(NodeCredentialClaims.self, from: encoded) == claims)
    }

    @Test("An enrolled node credential verifies")
    func validCredential() throws {
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

        try CredentialVerifier.verify(
            credential,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: .test,
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
            networkID: .test,
            environment: "development",
            validity: 3_600,
            now: now
        )

        #expect(throws: CredentialVerificationError.wrongIssuer) {
            try CredentialVerifier.verify(
                credential,
                trustedAuthorityPublicKey: trustedAuthority.publicKeyRepresentation,
                networkID: .test,
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
            networkID: .test,
            environment: "development",
            validity: 60,
            now: now
        )

        #expect(throws: CredentialVerificationError.expired) {
            try CredentialVerifier.verify(
                credential,
                trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                networkID: .test,
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
            networkID: .test,
            environment: "development",
            validity: 3_600,
            now: now
        )

        #expect(throws: CredentialVerificationError.wrongEnvironment) {
            try CredentialVerifier.verify(
                credential,
                trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                networkID: .test,
                environment: "production",
                now: now
            )
        }
    }

    @Test("A credential for another network is rejected")
    func wrongNetwork() throws {
        let authority = CredentialAuthority()
        let identity = NodeIdentity()
        let issuedNetwork = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: issuedNetwork,
            environment: "development",
            validity: 3_600,
            now: now
        )

        #expect(credential.claims.networkID == issuedNetwork)
        #expect(throws: CredentialVerificationError.wrongNetwork) {
            try CredentialVerifier.verify(
                credential,
                trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                networkID: NetworkID(),
                environment: "development",
                now: now
            )
        }
    }

    @Test("The signed transcript binds the network")
    func tamperedNetwork() throws {
        let authority = CredentialAuthority()
        let identity = NodeIdentity()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: NetworkID(),
            environment: "development",
            validity: 3_600,
            now: now
        )
        let changedClaims = NodeCredentialClaims(
            credentialID: credential.claims.credentialID,
            issuerID: credential.claims.issuerID,
            networkID: NetworkID(),
            nodeID: credential.claims.nodeID,
            nodePublicKey: credential.claims.nodePublicKey,
            environment: credential.claims.environment,
            issuedAtMilliseconds: credential.claims.issuedAtMilliseconds,
            expiresAtMilliseconds: credential.claims.expiresAtMilliseconds,
            serviceScopes: credential.claims.serviceScopes
        )
        let tampered = NodeCredential(
            claims: changedClaims,
            issuerSignature: credential.issuerSignature
        )

        #expect(throws: CredentialVerificationError.invalidSignature) {
            try CredentialVerifier.verify(
                tampered,
                trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                networkID: changedClaims.networkID,
                environment: "development",
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
            networkID: .test,
            environment: "development",
            validity: 3_600,
            now: now
        )
        let changedClaims = NodeCredentialClaims(
            credentialID: credential.claims.credentialID,
            issuerID: credential.claims.issuerID,
            networkID: credential.claims.networkID,
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
                networkID: .test,
                environment: "development",
                now: now
            )
        }
    }
}
