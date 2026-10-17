import Foundation
import Testing
@testable import BeakrNetCore

@Suite("BeakrNet session")
struct SessionTests {
    @Test("A logical session survives transport replacement")
    func transportReplacement() async {
        let localNodeID = NodeID()
        let remoteNodeID = NodeID()
        let session = BeakrNetSession(networkID: .test, localNodeID: localNodeID, remoteNodeID: remoteNodeID)
        let localTransportID = TransportID()
        let relayTransportID = TransportID()

        await session.bind(transportID: relayTransportID, kind: .relay)
        await session.bind(transportID: localTransportID, kind: .local)
        await session.unbind(transportID: relayTransportID)

        #expect(await session.state == .active)
        #expect(await session.transportBindings[localTransportID]?.kind == .local)
        #expect(await session.transportBindings[relayTransportID] == nil)
    }

    @Test("A repeated message is detected as a duplicate")
    func duplicateMessage() async throws {
        let localNodeID = NodeID()
        let remoteNodeID = NodeID()
        let sessionID = SessionID()
        let session = BeakrNetSession(
            id: sessionID,
            networkID: .test,
            localNodeID: localNodeID,
            remoteNodeID: remoteNodeID,
            state: .active
        )
        let envelope = BeakrNetEnvelope(
            networkID: .test,
            sessionID: sessionID,
            sourceNodeID: remoteNodeID,
            destinationNodeID: localNodeID,
            sequenceNumber: 1,
            payloadType: "ping",
            payload: Data()
        )

        #expect(try await session.accept(envelope) == .accepted)
        #expect(try await session.accept(envelope) == .duplicate)
    }

    @Test("An acknowledgement removes a pending delivery")
    func acknowledgementRemovesPendingDelivery() async throws {
        let localNodeID = NodeID()
        let remoteNodeID = NodeID()
        let sessionID = SessionID()
        let session = BeakrNetSession(
            id: sessionID,
            networkID: .test,
            localNodeID: localNodeID,
            remoteNodeID: remoteNodeID,
            state: .active
        )
        let envelope = BeakrNetEnvelope(
            networkID: .test,
            sessionID: sessionID,
            sourceNodeID: localNodeID,
            destinationNodeID: remoteNodeID,
            sequenceNumber: 1,
            payloadType: "ping",
            payload: Data()
        )

        try await session.queueForDelivery(envelope)
        await session.recordDeliveryAttempt(for: envelope.messageID)

        #expect(await session.pendingDelivery(for: envelope.messageID)?.attemptCount == 1)
        #expect(
            await session.acknowledge(
                DeliveryAcknowledgement(
                    networkID: .test,
                    sessionID: sessionID,
                    messageID: envelope.messageID
                )
            )
        )
        #expect(await session.pendingDelivery(for: envelope.messageID) == nil)
    }

    @Test("A session rejects another network before duplicate or acknowledgement state changes")
    func crossNetworkIsolation() async throws {
        let otherNetwork = NetworkID(rawValue: UUID(uuidString: "B10E0000-0000-4000-8000-000000000001")!)
        let local = NodeID()
        let remote = NodeID()
        let sessionID = SessionID()
        let session = BeakrNetSession(
            id: sessionID,
            networkID: .test,
            localNodeID: local,
            remoteNodeID: remote,
            state: .active
        )
        let incoming = BeakrNetEnvelope(
            networkID: otherNetwork,
            sessionID: sessionID,
            sourceNodeID: remote,
            destinationNodeID: local,
            sequenceNumber: 1,
            payloadType: "ping",
            payload: Data()
        )

        #expect(try await session.accept(incoming) == .wrongNetwork)

        let pending = BeakrNetEnvelope(
            networkID: .test,
            sessionID: sessionID,
            sourceNodeID: local,
            destinationNodeID: remote,
            sequenceNumber: 2,
            payloadType: "ping",
            payload: Data()
        )
        try await session.queueForDelivery(pending)
        #expect(await session.acknowledge(.init(networkID: otherNetwork, sessionID: sessionID, messageID: pending.messageID)) == false)
        #expect(await session.pendingDelivery(for: pending.messageID) != nil)
    }
}
