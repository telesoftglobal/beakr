import Foundation
import Testing
import BeakrNetCore
@testable import BeakrNetSecurity

@Suite("Node identity")
struct NodeIdentityTests {
    @Test("A valid identity proves possession of its private key")
    func validProof() throws {
        let identity = NodeIdentity()
        let challenge = Data(repeating: 0x42, count: 32)
        let signature = try identity.signature(forRegistrationChallenge: challenge)

        #expect(
            NodeIdentity.verifyRegistrationProof(
                nodeID: identity.nodeID,
                publicKeyRepresentation: identity.publicKeyRepresentation,
                challenge: challenge,
                signature: signature
            )
        )
    }

    @Test("A proof cannot claim another Node ID")
    func wrongNodeID() throws {
        let identity = NodeIdentity()
        let otherIdentity = NodeIdentity()
        let challenge = Data(repeating: 0x42, count: 32)
        let signature = try identity.signature(forRegistrationChallenge: challenge)

        #expect(
            !NodeIdentity.verifyRegistrationProof(
                nodeID: otherIdentity.nodeID,
                publicKeyRepresentation: identity.publicKeyRepresentation,
                challenge: challenge,
                signature: signature
            )
        )
    }

    @Test("A proof cannot be replayed for a different challenge")
    func wrongChallenge() throws {
        let identity = NodeIdentity()
        let signature = try identity.signature(
            forRegistrationChallenge: Data(repeating: 0x42, count: 32)
        )

        #expect(
            !NodeIdentity.verifyRegistrationProof(
                nodeID: identity.nodeID,
                publicKeyRepresentation: identity.publicKeyRepresentation,
                challenge: Data(repeating: 0x43, count: 32),
                signature: signature
            )
        )
    }
}
