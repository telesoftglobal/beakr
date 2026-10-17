import Foundation
import Testing
import BeakrNetCore
import BeakrNetTestSupport

@Suite("In-memory transport")
struct InMemoryTransportTests {
    @Test("A transport preserves channel metadata")
    func channelPreservation() async throws {
        let (sender, receiver) = await InMemoryTransport.makePair()
        let envelope = BeakrNetEnvelope(
            networkID: .test,
            sessionID: SessionID(),
            sourceNodeID: NodeID(),
            destinationNodeID: NodeID(),
            sequenceNumber: 1,
            channel: .blackboard,
            representation: .compact,
            deliveryPolicy: DeliveryPolicy(durability: .queued, replacementKey: "dashboard"),
            payloadType: "com.example.dashboard",
            payload: Data()
        )

        try await sender.send(envelope)
        let received = await receiver.receive()

        #expect(received?.channel == .blackboard)
        #expect(received?.representation == .compact)
    }

    @Test("A paired transport delivers an envelope")
    func delivery() async throws {
        let (sender, receiver) = await InMemoryTransport.makePair()
        let envelope = BeakrNetEnvelope(
            networkID: .test,
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
