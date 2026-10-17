import Foundation
import Testing
@testable import BeakrNetCore

@Suite("Persistent relay queue")
struct PersistentRelayQueueTests {
    @Test("Queued envelopes survive reopening and retain fair scheduling")
    func restartAndFairScheduling() async throws {
        let fileURL = temporaryFileURL()
        let destination = NodeID()
        let policy = policy(controlBurst: 2)
        let first = try await PersistentRelayQueue.open(networkID: .test, policy: policy, fileURL: fileURL)

        try await first.enqueue(control(sequence: 1, destination: destination), for: destination, now: date(1))
        try await first.enqueue(control(sequence: 2, destination: destination), for: destination, now: date(2))
        try await first.enqueue(control(sequence: 3, destination: destination), for: destination, now: date(3))
        try await first.enqueue(application(sequence: 4, destination: destination), for: destination, now: date(4))

        let reopened = try await PersistentRelayQueue.open(networkID: .test, policy: policy, fileURL: fileURL, now: date(5))
        let drained = try await reopened.drain(for: destination, now: date(5))

        #expect(drained.map(\.channel) == [.control, .control, .data, .control])
        #expect(try await PersistentRelayQueue.open(networkID: .test, policy: policy, fileURL: fileURL, now: date(5)).countAll(now: date(5)) == 0)
    }

    @Test("Persistent admission preserves reserved Control capacity")
    func reservedControlCapacity() async throws {
        let fileURL = temporaryFileURL()
        let destination = NodeID()
        let policy = RelayQueuePolicy(
            maximumMessagesPerNode: 4,
            maximumTotalMessages: 4,
            reservedControlMessagesPerNode: 1,
            reservedControlMessagesTotal: 1,
            messageTimeToLive: 60
        )
        let queue = try await PersistentRelayQueue.open(networkID: .test, policy: policy, fileURL: fileURL)
        for sequence in 1...4 {
            try await queue.enqueue(application(sequence: UInt64(sequence), destination: destination), for: destination, now: date(sequence))
        }
        try await queue.enqueue(control(sequence: 5, destination: destination), for: destination, now: date(5))

        let reopened = try await PersistentRelayQueue.open(networkID: .test, policy: policy, fileURL: fileURL, now: date(5))
        let drained = try await reopened.drain(for: destination, now: date(5))
        #expect(drained.count == 4)
        #expect(drained.first?.channel == .control)
        #expect(Set(drained.dropFirst().map(\.sequenceNumber)) == [2, 3, 4])
    }

    @Test("Expired persisted envelopes are removed when reopened")
    func expirationOnRestart() async throws {
        let fileURL = temporaryFileURL()
        let destination = NodeID()
        let policy = policy(controlBurst: 2, timeToLive: 10)
        let queue = try await PersistentRelayQueue.open(networkID: .test, policy: policy, fileURL: fileURL)
        try await queue.enqueue(application(sequence: 1, destination: destination), for: destination, now: date(1))

        let reopened = try await PersistentRelayQueue.open(networkID: .test, policy: policy, fileURL: fileURL, now: date(11))
        #expect(await reopened.countAll(now: date(11)) == 0)
        #expect(try await reopened.drain(for: destination, now: date(11)).isEmpty)
    }

    private func policy(controlBurst: Int, timeToLive: TimeInterval = 60) -> RelayQueuePolicy {
        RelayQueuePolicy(
            maximumMessagesPerNode: 10,
            maximumTotalMessages: 10,
            reservedControlMessagesPerNode: 2,
            reservedControlMessagesTotal: 2,
            maximumConsecutiveControlMessages: controlBurst,
            messageTimeToLive: timeToLive
        )
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BeakrNetTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("queue.json")
    }

    private func date(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private func application(sequence: UInt64, destination: NodeID) -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            networkID: .test,
            sessionID: SessionID(),
            sourceNodeID: NodeID(),
            destinationNodeID: destination,
            sequenceNumber: sequence,
            payloadType: "test.data",
            payload: Data()
        )
    }

    private func control(sequence: UInt64, destination: NodeID) -> BeakrNetEnvelope {
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
                expiresAt: Date.distantFuture
            ),
            payloadType: ControlPayloadType.keepalive.rawValue,
            payload: Data()
        )
    }
}
