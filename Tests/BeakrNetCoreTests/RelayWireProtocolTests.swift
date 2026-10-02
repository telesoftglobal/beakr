import Foundation
import Testing
@testable import BeakrNetCore
import BeakrNetSecurity

@Suite("Relay wire protocol")
struct RelayWireProtocolTests {
    @Test("A registration frame round trips")
    func registrationRoundTrip() throws {
        let identity = NodeIdentity()
        let message = RelayWireMessage.clientHello(
            nodeID: identity.nodeID,
            publicKey: identity.publicKeyRepresentation
        )
        let frame = try RelayWireCodec.encode(message)
        let header = frame.prefix(4)
        let body = frame.dropFirst(4)

        #expect(try RelayWireCodec.bodyLength(from: Data(header)) == body.count)
        #expect(try RelayWireCodec.decodeBody(Data(body)) == message)
    }

    @Test("An envelope frame round trips")
    func envelopeRoundTrip() throws {
        let envelope = BeakrNetEnvelope(
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
