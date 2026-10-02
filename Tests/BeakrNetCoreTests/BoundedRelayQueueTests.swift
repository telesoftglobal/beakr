import Foundation
import Testing
@testable import BeakrNetCore

@Suite("Bounded relay queue")
struct BoundedRelayQueueTests {
    @Test("The per-node limit evicts the oldest envelope")
    func perNodeLimit() async {
        let destination = NodeID()
        let queue = BoundedRelayQueue(
            policy: RelayQueuePolicy(
                maximumMessagesPerNode: 2,
                maximumTotalMessages: 4,
                messageTimeToLive: 60
            )
        )
        let envelopes = makeEnvelopes(count: 3, destination: destination)

        for envelope in envelopes {
            await queue.enqueue(envelope, for: destination)
        }

        #expect(await queue.drain(for: destination).map(\.sequenceNumber) == [2, 3])
    }

    @Test("The global limit evicts the oldest envelope")
    func globalLimit() async {
        let firstDestination = NodeID()
        let secondDestination = NodeID()
        let queue = BoundedRelayQueue(
            policy: RelayQueuePolicy(
                maximumMessagesPerNode: 2,
                maximumTotalMessages: 2,
                messageTimeToLive: 60
            )
        )
        let first = makeEnvelopes(count: 1, destination: firstDestination)[0]
        let second = makeEnvelopes(count: 2, destination: secondDestination)

        await queue.enqueue(first, for: firstDestination, now: Date(timeIntervalSince1970: 1))
        await queue.enqueue(second[0], for: secondDestination, now: Date(timeIntervalSince1970: 2))
        await queue.enqueue(second[1], for: secondDestination, now: Date(timeIntervalSince1970: 3))

        #expect(await queue.count(for: firstDestination, now: Date(timeIntervalSince1970: 3)) == 0)
        #expect(await queue.countAll(now: Date(timeIntervalSince1970: 3)) == 2)
    }

    @Test("Expired envelopes are not delivered")
    func expiration() async {
        let destination = NodeID()
        let queue = BoundedRelayQueue(
            policy: RelayQueuePolicy(
                maximumMessagesPerNode: 2,
                maximumTotalMessages: 2,
                messageTimeToLive: 10
            )
        )
        let envelope = makeEnvelopes(count: 1, destination: destination)[0]
        await queue.enqueue(envelope, for: destination, now: Date(timeIntervalSince1970: 1))

        #expect(await queue.drain(for: destination, now: Date(timeIntervalSince1970: 11)).isEmpty)
    }

    private func makeEnvelopes(count: Int, destination: NodeID) -> [BeakrNetEnvelope] {
        let sessionID = SessionID()
        let source = NodeID()
        return (1...count).map { sequence in
            BeakrNetEnvelope(
                sessionID: sessionID,
                sourceNodeID: source,
                destinationNodeID: destination,
                sequenceNumber: UInt64(sequence),
                payloadType: "ping",
                payload: Data()
            )
        }
    }
}
