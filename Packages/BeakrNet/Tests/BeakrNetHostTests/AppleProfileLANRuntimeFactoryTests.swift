#if canImport(Network)
import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetHost

@Suite("Apple profile LAN runtime construction")
struct AppleProfileLANRuntimeFactoryTests {
    @Test("Invalid Bonjour construction inputs fail before Keychain access")
    func invalidConstructionInputs() async throws {
        let profile = try NetworkProfile(
            networkID: NetworkID(),
            localNodeID: NodeID(),
            displayName: "Red"
        )
        let registry = ProfileConnectionRegistry(
            networkID: profile.networkID,
            localNodeID: profile.localNodeID,
            revocations: RevocationSnapshotDistributor(verifier: { _, _ in }),
            routePolicy: ProfileRoutePolicyController()
        )
        let snapshot = CredentialRevocationSnapshot(
            claims: CredentialRevocationClaims(
                issuerID: AuthorityID(rawValue: UUID()),
                generatedAtMilliseconds: 1_000,
                revocations: []
            ),
            issuerSignature: Data([1])
        )

        #expect(throws: AppleProfileLANRuntimeFactoryError.invalidAdvertisementNonce) {
            _ = try AppleProfileLANRuntimeFactory.make(
                profile: profile,
                keychainBaseService: "net.beakr.test",
                environment: "test",
                trustedAuthorityPublicKey: Data([1]),
                revocationSnapshot: snapshot,
                registry: registry,
                advertisementNonce: Data(),
                sessionID: { _ in SessionID() },
                acceptedPeer: { _ in nil }
            )
        }
        #expect(throws: AppleProfileLANRuntimeFactoryError.invalidServiceType) {
            _ = try AppleProfileLANRuntimeFactory.make(
                profile: profile,
                keychainBaseService: "net.beakr.test",
                environment: "test",
                trustedAuthorityPublicKey: Data([1]),
                revocationSnapshot: snapshot,
                registry: registry,
                serviceType: "beakrnet",
                advertisementNonce: Data(repeating: 1, count: 32),
                sessionID: { _ in SessionID() },
                acceptedPeer: { _ in nil }
            )
        }
    }
}
#endif
