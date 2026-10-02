import Foundation
import BeakrNetCore
import BeakrNetTestSupport

@main
struct BeakrNetHandoffLab {
    static func main() async throws {
        let nodeA = NodeID()
        let nodeB = NodeID()
        let sessionID = SessionID()
        let senderSession = BeakrNetSession(
            id: sessionID,
            localNodeID: nodeA,
            remoteNodeID: nodeB
        )
        let receiverSession = BeakrNetSession(
            id: sessionID,
            localNodeID: nodeB,
            remoteNodeID: nodeA
        )
        let (relayA, relayB) = await InMemoryTransport.makePair()
        let (localA, localB) = await InMemoryTransport.makePair()

        await senderSession.bind(transportID: relayA.id, kind: .relay)
        await receiverSession.bind(transportID: relayB.id, kind: .relay)

        var senderTransport = relayA
        var receiverTransport = relayB
        var acceptedCount = 0
        var duplicateCount = 0

        for sequenceNumber in UInt64(1)...100 {
            if sequenceNumber == 36 {
                await senderSession.bind(transportID: localA.id, kind: .local)
                await receiverSession.bind(transportID: localB.id, kind: .local)
                await senderSession.unbind(transportID: relayA.id)
                await receiverSession.unbind(transportID: relayB.id)
                senderTransport = localA
                receiverTransport = localB
                print("Route changed: relay → local at message 36")
            } else if sequenceNumber == 71 {
                await senderSession.bind(transportID: relayA.id, kind: .relay)
                await receiverSession.bind(transportID: relayB.id, kind: .relay)
                await senderSession.unbind(transportID: localA.id)
                await receiverSession.unbind(transportID: localB.id)
                senderTransport = relayA
                receiverTransport = relayB
                print("Route changed: local → relay at message 71")
            }

            let envelope = BeakrNetEnvelope(
                sessionID: sessionID,
                sourceNodeID: nodeA,
                destinationNodeID: nodeB,
                sequenceNumber: sequenceNumber,
                payloadType: "ping",
                payload: Data("ping-\(sequenceNumber)".utf8)
            )

            await senderSession.queueForDelivery(envelope)
            try await deliver(
                envelope,
                senderSession: senderSession,
                receiverSession: receiverSession,
                senderTransport: senderTransport,
                receiverTransport: receiverTransport,
                acknowledge: sequenceNumber != 50,
                acceptedCount: &acceptedCount,
                duplicateCount: &duplicateCount
            )

            if sequenceNumber == 50 {
                try await deliver(
                    envelope,
                    senderSession: senderSession,
                    receiverSession: receiverSession,
                    senderTransport: senderTransport,
                    receiverTransport: receiverTransport,
                    acknowledge: true,
                    acceptedCount: &acceptedCount,
                    duplicateCount: &duplicateCount
                )
            }
        }

        let pendingCount = await senderSession.allPendingDeliveries().count
        let senderState = await senderSession.state

        print("Accepted messages: \(acceptedCount)")
        print("Rejected duplicates: \(duplicateCount)")
        print("Pending deliveries: \(pendingCount)")
        print("Logical session state: \(senderState)")

        guard acceptedCount == 100,
              duplicateCount == 1,
              pendingCount == 0,
              senderState == .active else {
            throw LabError.verificationFailed
        }

        print("Transport handoff verified")
    }

    private static func deliver(
        _ envelope: BeakrNetEnvelope,
        senderSession: BeakrNetSession,
        receiverSession: BeakrNetSession,
        senderTransport: InMemoryTransport,
        receiverTransport: InMemoryTransport,
        acknowledge: Bool,
        acceptedCount: inout Int,
        duplicateCount: inout Int
    ) async throws {
        await senderSession.recordDeliveryAttempt(for: envelope.messageID)
        try await senderTransport.send(envelope)
        guard let received = await receiverTransport.receive() else {
            throw LabError.transportClosed
        }

        switch await receiverSession.accept(received) {
        case .accepted:
            acceptedCount += 1
        case .duplicate:
            duplicateCount += 1
        case .wrongSession, .wrongDestination:
            throw LabError.invalidEnvelope
        }

        if acknowledge {
            let acknowledgement = DeliveryAcknowledgement(
                sessionID: received.sessionID,
                messageID: received.messageID
            )
            guard await senderSession.acknowledge(acknowledgement) else {
                throw LabError.invalidAcknowledgement
            }
        }
    }
}

private enum LabError: Error {
    case transportClosed
    case invalidEnvelope
    case invalidAcknowledgement
    case verificationFailed
}
