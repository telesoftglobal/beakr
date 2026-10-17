import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

@Suite("Profile Keychain namespace")
struct ProfileKeychainNamespaceTests {
    @Test("Profile IDs produce stable disjoint Keychain services")
    func disjointServices() {
        let redID = NetworkProfileID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let blueID = NetworkProfileID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let red = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: redID)
        let blue = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: blueID)

        #expect(red.service == "net.beakr.app.profile.00000000-0000-0000-0000-000000000001")
        #expect(red.service != blue.service)
        #expect(red.nodeSigningKeyAccount == blue.nodeSigningKeyAccount)
        #expect(red.nodeCredentialAccount == blue.nodeCredentialAccount)
    }

    @Test("Credential storage rejects another profile network or node")
    func credentialBinding() throws {
        let authority = CredentialAuthority()
        let identity = NodeIdentity()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "test",
            validity: 300,
            serviceScopes: ["lan"]
        )
        let valid = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Red"
        )
        try KeychainNodeCredentialStore.validate(credential, for: valid)

        let wrongNetwork = try NetworkProfile(
            networkID: NetworkID(),
            localNodeID: identity.nodeID,
            displayName: "Blue"
        )
        #expect(throws: ProfileKeychainCredentialError.profileNetworkMismatch) {
            try KeychainNodeCredentialStore.validate(credential, for: wrongNetwork)
        }
        let wrongNode = try NetworkProfile(
            networkID: networkID,
            localNodeID: NodeID(),
            displayName: "Other Node"
        )
        #expect(throws: ProfileKeychainCredentialError.profileNodeMismatch) {
            try KeychainNodeCredentialStore.validate(credential, for: wrongNode)
        }
    }
}
