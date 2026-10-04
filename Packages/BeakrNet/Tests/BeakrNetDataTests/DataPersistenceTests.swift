import Foundation
import Testing
import BeakrNetCore
import BeakrNetData

@Suite("Durable application Data state")
struct DataPersistenceTests {
    @Test("Outgoing envelopes and incoming idempotency results survive restart")
    func restartRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data-state.json")
        let now = Date(timeIntervalSince1970: 1_000)
        let envelope = makeEnvelope(expiresAt: now.addingTimeInterval(60))
        let key = DataIdempotencyKey()
        let response = DataMessage(
            kind: .response,
            operation: .init(namespace: "com.example", name: "write", version: 1),
            correlationID: DataCorrelationID(),
            body: Data("ok".utf8)
        )

        let first = try await PersistentDataState.open(fileURL: url, now: now)
        try await first.enqueue(envelope, now: now)
        try await first.record(.init(messageID: envelope.messageID, idempotencyKey: key, response: response, completedAt: now))

        let restored = try await PersistentDataState.open(fileURL: url, now: now)
        #expect(try await restored.pending(now: now) == [envelope])
        #expect(await restored.result(for: envelope.messageID)?.response == response)
        #expect(await restored.result(for: key)?.messageID == envelope.messageID)
        #expect(try await restored.acknowledge(envelope.messageID))
        #expect(try await restored.pending(now: now).isEmpty)
    }

    @Test("Expired outgoing work is removed during restart")
    func restartExpiry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data-state.json")
        let start = Date(timeIntervalSince1970: 1_000)
        let first = try await PersistentDataState.open(fileURL: url, now: start)
        try await first.enqueue(makeEnvelope(expiresAt: start.addingTimeInterval(1)), now: start)

        let restored = try await PersistentDataState.open(fileURL: url, now: start.addingTimeInterval(2))
        #expect(try await restored.pending(now: start.addingTimeInterval(2)).isEmpty)
    }

    @Test("Outgoing capacity is bounded without evicting durable work")
    func capacityBound() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = try await PersistentDataState.open(fileURL: directory.appendingPathComponent("state.json"), maximumOutgoing: 1)
        try await state.enqueue(makeEnvelope())
        await #expect(throws: DataPersistenceError.capacityExceeded) {
            try await state.enqueue(makeEnvelope(id: MessageID()))
        }
    }

    @Test("A mutation retry after dispatcher restart returns the durable response once")
    func dispatcherRestartDeduplication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let now = Date(timeIntervalSince1970: 1_000)
        let operation = DataOperation(namespace: "com.example", name: "write", version: 1)
        let correlation = DataCorrelationID()
        let key = DataIdempotencyKey()
        let request = DataMessage(kind: .request, operation: operation, correlationID: correlation, idempotencyKey: key)
        let response = DataMessage(kind: .response, operation: operation, correlationID: correlation, body: Data("ok".utf8))
        let firstHandler = PersistenceHandler(response: response)
        let firstState = try await PersistentDataState.open(fileURL: url, now: now)
        let firstDispatcher = DataDispatcher(
            supportedOperations: [operation], persistentState: firstState,
            handler: firstHandler, clock: { now }
        )
        let firstEnvelope = try makeTypedEnvelope(request, now: now)
        #expect(await firstDispatcher.dispatch(firstEnvelope) == .handled(response: response))
        #expect(await firstHandler.count == 1)

        let secondHandler = PersistenceHandler(response: response)
        let restored = try await PersistentDataState.open(fileURL: url, now: now)
        let secondDispatcher = DataDispatcher(
            supportedOperations: [operation], persistentState: restored,
            handler: secondHandler, clock: { now }
        )
        let retriedEnvelope = try makeTypedEnvelope(request, id: MessageID(), now: now)
        #expect(await secondDispatcher.dispatch(retriedEnvelope) == .handled(response: response))
        #expect(await secondHandler.count == 0)
    }

    private func makeEnvelope(id: MessageID = MessageID(), expiresAt: Date? = nil) -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            messageID: id,
            sessionID: SessionID(),
            sourceNodeID: NodeID(),
            destinationNodeID: NodeID(),
            sequenceNumber: 1,
            channel: .data,
            deliveryPolicy: .init(durability: .durable, expiresAt: expiresAt),
            payloadType: DataMessage.payloadType,
            payload: Data(),
            createdAt: expiresAt.map { $0.addingTimeInterval(-60) } ?? Date(timeIntervalSince1970: 1_000)
        )
    }

    private func makeTypedEnvelope(_ message: DataMessage, id: MessageID = MessageID(), now: Date) throws -> BeakrNetEnvelope {
        try DataCodec().makeEnvelope(
            for: message, sessionID: SessionID(), sourceNodeID: NodeID(), destinationNodeID: NodeID(),
            messageID: id, sequenceNumber: 1, createdAt: now,
            deliveryPolicy: .init(durability: .durable, expiresAt: now.addingTimeInterval(60))
        )
    }
}

private actor PersistenceHandler: DataMessageHandler {
    private(set) var count = 0
    let response: DataMessage?

    init(response: DataMessage?) { self.response = response }

    func handle(_ message: DataMessage, envelope: BeakrNetEnvelope) async throws -> DataMessage? {
        count += 1
        return response
    }
}
