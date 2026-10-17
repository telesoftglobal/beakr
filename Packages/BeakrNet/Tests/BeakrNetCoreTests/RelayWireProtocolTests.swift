import Foundation
import Testing
@testable import BeakrNetCore
import BeakrNetSecurity
import BeakrNetAuthority

@Suite("Relay wire protocol")
struct RelayWireProtocolTests {
    @Test("A registration frame round trips")
    func registrationRoundTrip() throws {
        let identity = NodeIdentity()
        let credential = try CredentialAuthority().issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: .test,
            environment: "test",
            validity: 60
        )
        let message = RelayWireMessage.clientHello(credential: credential)
        let frame = try RelayWireCodec.encode(message)
        let header = frame.prefix(4)
        let body = frame.dropFirst(4)

        #expect(try RelayWireCodec.bodyLength(from: Data(header)) == body.count)
        #expect(try RelayWireCodec.decodeBody(Data(body)) == message)
    }

    @Test("An envelope frame round trips")
    func envelopeRoundTrip() throws {
        let envelope = BeakrNetEnvelope(
            networkID: .test,
            sessionID: SessionID(),
            sourceNodeID: NodeID(),
            destinationNodeID: NodeID(),
            sequenceNumber: 42,
            payloadType: "ping",
            payload: Data("hello".utf8)
        )
        let message = RelayWireMessage.envelope(envelope)
        let frame = try RelayWireCodec.encode(message)

        #expect(try RelayWireCodec.decodeBody(Data(frame.dropFirst(4))) == message)
    }
}
