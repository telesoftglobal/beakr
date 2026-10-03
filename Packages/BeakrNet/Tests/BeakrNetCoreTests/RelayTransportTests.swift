import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity
@testable import BeakrNetRelayTransport

@Suite("Relay transport")
struct RelayTransportTests {
    @Test("Configuration rejects a credential belonging to another identity")
    func credentialIdentityMismatch() throws {
        let authority = CredentialAuthority()
        let credentialIdentity = NodeIdentity()
        let transportIdentity = NodeIdentity()
        let credential = try authority.issue(
            nodeID: credentialIdentity.nodeID,
            nodePublicKey: credentialIdentity.publicKeyRepresentation,
            environment: "test",
            validity: 60
        )

        #expect(throws: RelayTransportError.credentialIdentityMismatch) {
            _ = try RelayTransportConfiguration(
                host: "127.0.0.1",
                port: 7878,
                preSharedKey: Data(repeating: 0x42, count: 32),
                identity: transportIdentity,
                credential: credential
            )
        }
    }

    @Test("Configuration rejects an empty reconnect policy")
    func invalidReconnectPolicy() throws {
        let authority = CredentialAuthority()
        let identity = NodeIdentity()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            environment: "test",
            validity: 60
        )

        #expect(throws: RelayTransportError.invalidReconnectPolicy) {
            _ = try RelayTransportConfiguration(
                host: "127.0.0.1",
                port: 7878,
                preSharedKey: Data(repeating: 0x42, count: 32),
                identity: identity,
                credential: credential,
                reconnectDelays: []
            )
        }
    }

    @Test("Closing completes a waiting receive")
    func closeCompletesReceive() async throws {
        let authority = CredentialAuthority()
        let identity = NodeIdentity()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            environment: "test",
            validity: 60
        )
        let configuration = try RelayTransportConfiguration(
            host: "127.0.0.1",
            port: 7878,
            preSharedKey: Data(repeating: 0x42, count: 32),
            identity: identity,
            credential: credential
        )
        let transport = RelayTransport(configuration: configuration)

        await transport.close()

        #expect(await transport.receive() == nil)
        #expect(await transport.state == .closed)
    }
}
