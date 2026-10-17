import Foundation
import Testing
@testable import BeakrNetCore

@Suite("Bounded relay queue")
struct BoundedRelayQueueTests {
    @Test("The per-node limit evicts the oldest envelope")
    func perNodeLimit() async throws {
        let destination = NodeID()
        let queue = BoundedRelayQueue(
            networkID: .test,
            policy: RelayQueuePolicy(
                maximumMessagesPerNode: 2,
                maximumTotalMessages: 4,
                messageTimeToLive: 60
            )
        )
        let envelopes = makeEnvelopes(count: 3, destination: destination)

        for envelope in envelopes {
            try await queue.enqueue(envelope, for: destination)
        }

        #expect(await queue.drain(for: destination).map(\.sequenceNumber) == [2, 3])
    }

    @Test("The global limit evicts the oldest envelope")
    func globalLimit() async throws {
        let firstDestination = NodeID()
        let secondDestination = NodeID()
        let queue = BoundedRelayQueue(
            networkID: .test,
            policy: RelayQueuePolicy(
                maximumMessagesPerNode: 2,
                maximumTotalMessages: 2,
                messageTimeToLive: 60
            )
        )
        let first = makeEnvelopes(count: 1, destination: firstDestination)[0]
        let second = makeEnvelopes(count: 2, destination: secondDestination)

        try await queue.enqueue(first, for: firstDestination, now: Date(timeIntervalSince1970: 1))
        try await queue.enqueue(second[0], for: secondDestination, now: Date(timeIntervalSince1970: 2))
        try await queue.enqueue(second[1], for: secondDestination, now: Date(timeIntervalSince1970: 3))

        #expect(await queue.count(for: firstDestination, now: Date(timeIntervalSince1970: 3)) == 0)
        #expect(await queue.countAll(now: Date(timeIntervalSince1970: 3)) == 2)
    }

    @Test("Expired envelopes are not delivered")
    func expiration() async throws {
        let destination = NodeID()
        let queue = BoundedRelayQueue(
            networkID: .test,
            policy: RelayQueuePolicy(
                maximumMessagesPerNode: 2,
                maximumTotalMessages: 2,
                messageTimeToLive: 10
            )
        )
        let envelope = makeEnvelopes(count: 1, destination: destination)[0]
        try await queue.enqueue(envelope, for: destination, now: Date(timeIntervalSince1970: 1))

        #expect(await queue.drain(for: destination, now: Date(timeIntervalSince1970: 11)).isEmpty)
    }

    @Test("Application traffic cannot consume reserved Control capacity")
    func reservedControlCapacity() async throws {
        let destination = NodeID()
        let queue = BoundedRelayQueue(
            networkID: .test,
            policy: RelayQueuePolicy(
                maximumMessagesPerNode: 4,
                maximumTotalMessages: 4,
                reservedControlMessagesPerNode: 1,
                reservedControlMessagesTotal: 1,
                messageTimeToLive: 60
            )
        )
        let application = makeEnvelopes(count: 4, destination: destination)
        for envelope in application {
            try await queue.enqueue(envelope, for: destination)
        }

        let control = makeControlEnvelope(sequence: 5, destination: destination)
        let admission = try await queue.enqueue(control, for: destination)
        let drained = await queue.drain(for: destination)

        #expect(admission.evictions.isEmpty)
        #expect(drained.count == 4)
        #expect(drained.first?.channel == .control)
        #expect(Set(drained.dropFirst().map(\.sequenceNumber)) == [2, 3, 4])
    }

    @Test("Control preference has a bounded burst so application traffic progresses")
    func controlBurstFairness() async throws {
        let destination = NodeID()
        let queue = BoundedRelayQueue(
            networkID: .test,
            policy: RelayQueuePolicy(
                maximumMessagesPerNode: 10,
                maximumTotalMessages: 10,
                reservedControlMessagesPerNode: 2,
                reservedControlMessagesTotal: 2,
                maximumConsecutiveControlMessages: 2,
                messageTimeToLive: 60
            )
        )
        try await queue.enqueue(makeControlEnvelope(sequence: 1, destination: destination), for: destination)
        try await queue.enqueue(makeControlEnvelope(sequence: 2, destination: destination), for: destination)
        try await queue.enqueue(makeControlEnvelope(sequence: 3, destination: destination), for: destination)
        try await queue.enqueue(makeEnvelopes(count: 1, destination: destination)[0], for: destination)

        let drained = await queue.drain(for: destination)

        #expect(drained.map(\.channel) == [.control, .control, .data, .control])
    }

    @Test("Diagnostics report admission, eviction, expiry, and queue partition")
    func diagnostics() async throws {
        let destination = NodeID()
        let queue = BoundedRelayQueue(
            networkID: .test,
            policy: RelayQueuePolicy(
                maximumMessagesPerNode: 2,
                maximumTotalMessages: 2,
                reservedControlMessagesPerNode: 1,
                reservedControlMessagesTotal: 1,
                messageTimeToLive: 10
            )
        )
        let application = makeEnvelopes(count: 2, destination: destination)
        try await queue.enqueue(application[0], for: destination, now: Date(timeIntervalSince1970: 1))
        try await queue.enqueue(application[1], for: destination, now: Date(timeIntervalSince1970: 2))
        try await queue.enqueue(
            makeControlEnvelope(sequence: 3, destination: destination),
            for: destination,
            now: Date(timeIntervalSince1970: 2)
        )

        let beforeExpiry = await queue.diagnostics(now: Date(timeIntervalSince1970: 2))
        #expect(beforeExpiry.controlMessages == 1)
        #expect(beforeExpiry.applicationMessages == 1)
        #expect(beforeExpiry.admittedMessages == 3)
        #expect(beforeExpiry.evictedMessages == 1)

        let afterExpiry = await queue.diagnostics(now: Date(timeIntervalSince1970: 12))
        #expect(afterExpiry.totalMessages == 0)
        #expect(afterExpiry.expiredMessages == 2)
    }

    @Test("A queue rejects envelopes belonging to another network")
    func crossNetworkAdmission() async {
        let otherNetwork = NetworkID(rawValue: UUID(uuidString: "B10E0000-0000-4000-8000-000000000001")!)
        let destination = NodeID()
        let queue = BoundedRelayQueue(networkID: .test, policy: .development)
        let envelope = BeakrNetEnvelope(
            networkID: otherNetwork,
            sessionID: SessionID(),
            sourceNodeID: NodeID(),
            destinationNodeID: destination,
            sequenceNumber: 1,
            payloadType: "ping",
            payload: Data()
        )

        await #expect(throws: RelayQueueError.wrongNetwork(expected: .test, actual: otherNetwork)) {
            try await queue.enqueue(envelope, for: destination)
        }
        #expect(await queue.countAll() == 0)
    }

    private func makeEnvelopes(count: Int, destination: NodeID) -> [BeakrNetEnvelope] {
        let sessionID = SessionID()
        let source = NodeID()
        return (1...count).map { sequence in
            BeakrNetEnvelope(
                networkID: .test,
                sessionID: sessionID,
                sourceNodeID: source,
                destinationNodeID: destination,
                sequenceNumber: UInt64(sequence),
                payloadType: "ping",
                payload: Data()
            )
        }
    }

    private func makeControlEnvelope(sequence: UInt64, destination: NodeID) -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            networkID: .test,
            sessionID: SessionID(),
            sourceNodeID: NodeID(),
            destinationNodeID: destination,
            sequenceNumber: sequence,
            channel: .control,
            representation: .compact,
            deliveryPolicy: DeliveryPolicy(
                durability: .queued,
                expiresAt: Date().addingTimeInterval(60)
            ),
            payloadType: ControlPayloadType.keepalive.rawValue,
            payload: Data()
        )
    }
}
