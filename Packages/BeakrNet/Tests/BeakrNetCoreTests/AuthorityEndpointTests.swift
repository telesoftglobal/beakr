import Foundation
import Testing
import BeakrNetCore
import BeakrNetAuthority

@Suite("Signed authority endpoint records")
struct AuthorityEndpointTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Signed endpoint roundtrip preserves trust identity across port changes")
    func portChange() throws {
        let authority = CredentialAuthority()
        let network = NetworkID()
        let first = try authority.issueAuthorityEndpoint(
            networkID: network, environment: "test", hostname: "test-host.local",
            port: 49_150, generation: 1, now: now
        )
        let second = try authority.issueAuthorityEndpoint(
            networkID: network, environment: "test", hostname: "test-host.local",
            port: 49_151, generation: 2, now: now
        )
        let decoded = try SignedAuthorityEndpoint.decode(second.encoded())
        let verified = try AuthorityEndpointVerifier.verify(
            decoded, trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: network, environment: "test", minimumGeneration: 1, now: now
        )
        #expect(verified.controlPlaneURL.absoluteString == "https://test-host.local:49151")
        #expect(verified.claims.authorityID == first.claims.authorityID)
        #expect(verified.claims.networkID == first.claims.networkID)
        #expect(throws: AuthorityEndpointError.staleGeneration) {
            try AuthorityEndpointVerifier.verify(
                first, trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                networkID: network, environment: "test", minimumGeneration: 2, now: now
            )
        }
    }

    @Test("Wrong authority, network and environment cannot redirect a client")
    func trustBinding() throws {
        let authority = CredentialAuthority()
        let network = NetworkID()
        let record = try authority.issueAuthorityEndpoint(
            networkID: network, environment: "test", hostname: "test.local",
            port: 49_150, generation: 1, now: now
        )
        #expect(throws: AuthorityEndpointError.wrongAuthority) {
            try AuthorityEndpointVerifier.verify(
                record, trustedAuthorityPublicKey: CredentialAuthority().publicKeyRepresentation,
                networkID: network, environment: "test", now: now
            )
        }
        #expect(throws: AuthorityEndpointError.wrongNetwork) {
            try AuthorityEndpointVerifier.verify(
                record, trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                networkID: NetworkID(), environment: "test", now: now
            )
        }
        #expect(throws: AuthorityEndpointError.wrongEnvironment) {
            try AuthorityEndpointVerifier.verify(
                record, trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                networkID: network, environment: "production", now: now
            )
        }
    }

    @Test("Endpoint substitution invalidates the signature")
    func tampering() throws {
        let authority = CredentialAuthority()
        let network = NetworkID()
        let record = try authority.issueAuthorityEndpoint(
            networkID: network, environment: "test", hostname: "test.local",
            port: 49_150, generation: 1, now: now
        )
        let claims = record.claims
        let changed = AuthorityEndpointClaims(
            authorityID: claims.authorityID, networkID: network, environment: "test",
            hostname: "other.local", port: claims.port, generation: claims.generation,
            issuedAtMilliseconds: claims.issuedAtMilliseconds,
            expiresAtMilliseconds: claims.expiresAtMilliseconds
        )
        #expect(throws: AuthorityEndpointError.invalidSignature) {
            try AuthorityEndpointVerifier.verify(
                SignedAuthorityEndpoint(claims: changed, signature: record.signature),
                trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                networkID: network, environment: "test", now: now
            )
        }
    }

    @Test("Expired and future records are rejected even with valid signatures")
    func freshness() throws {
        let authority = CredentialAuthority()
        let network = NetworkID()
        let record = try authority.issueAuthorityEndpoint(
            networkID: network, environment: "test", hostname: "test.local",
            port: 49_150, generation: 1, validity: 120, now: now
        )
        #expect(throws: AuthorityEndpointError.expired) {
            try AuthorityEndpointVerifier.verify(
                record, trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                networkID: network, environment: "test", now: now.addingTimeInterval(120)
            )
        }
        #expect(throws: AuthorityEndpointError.issuedInFuture) {
            try AuthorityEndpointVerifier.verify(
                record, trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                networkID: network, environment: "test", now: now.addingTimeInterval(-31)
            )
        }
    }

    @Test("Invalid hostnames, validity and oversized input fail safely")
    func invalidInput() throws {
        let authority = CredentialAuthority()
        for host in ["", "user@test.local", "test.local/path", "test..local", "-test.local", "Test.local"] {
            #expect(throws: AuthorityEndpointError.invalidRecord) {
                try authority.issueAuthorityEndpoint(
                    networkID: NetworkID(), environment: "test", hostname: host,
                    port: 49_150, generation: 1, now: now
                )
            }
        }
        for validity in [Double.nan, Double.infinity, -1, 0, 301] {
            #expect(throws: AuthorityEndpointError.invalidRecord) {
                try authority.issueAuthorityEndpoint(
                    networkID: NetworkID(), environment: "test", hostname: "test.local",
                    port: 49_150, generation: 1, validity: validity, now: now
                )
            }
        }
        #expect(throws: AuthorityEndpointError.invalidRecord) {
            try SignedAuthorityEndpoint.decode(Data(repeating: 0, count: 4_097))
        }
        #expect(throws: AuthorityEndpointError.invalidRecord) {
            try authority.issueAuthorityEndpoint(
                networkID: NetworkID(), environment: "test", hostname: "test.local",
                port: 0, generation: 0, now: now
            )
        }
    }
}
