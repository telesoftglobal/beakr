import Foundation
import Testing
import BeakrNetCore
import BeakrNetTestSupport

@Suite("In-memory transport")
struct InMemoryTransportTests {
    @Test("A paired transport delivers an envelope")
    func delivery() async throws {
        let (sender, receiver) = await InMemoryTransport.makePair()
        let envelope = BeakrNetEnvelope(
            sessionID: SessionID(),
            sourceNodeID: NodeID(),
            destinationNodeID: NodeID(),
            sequenceNumber: 1,
            payloadType: "ping",
            payload: Data("ping".utf8)
        )

        try await sender.send(envelope)

        #expect(await receiver.receive() == envelope)
    }

    @Test("Closing a transport completes a waiting receive")
    func closeCompletesReceive() async {
        let transport = InMemoryTransport()

        await transport.close()

        #expect(await transport.receive() == nil)
    }
}
