import Foundation
import Testing
import BeakrNetCore
import BeakrNetData

@Suite("Durable application Data state")
struct DataPersistenceTests {
    @Test("Failed admission never becomes pending or leaks into a later successful save")
    func failedEnqueueIsNotAccepted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("store")
        let url = directory.appendingPathComponent("state.json")
        let backup = root.appendingPathComponent("preserved-store")
        let state = try await PersistentDataState.open(fileURL: url)
        let accepted = makeEnvelope()
        let rejected = makeEnvelope()
        try await state.enqueue(accepted)

        // Preserve the original file, then obstruct its parent with a regular file.
        // This reliably fails writes without depending on filesystem permissions.
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data("blocked".utf8).write(to: directory)
        await #expect(throws: (any Error).self) { try await state.enqueue(rejected) }
        #expect(try await state.pending() == [accepted])
        await #expect(throws: (any Error).self) { try await state.enqueue(rejected) }

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        let later = makeEnvelope()
        try await state.enqueue(later)
        let reopened = try await PersistentDataState.open(fileURL: url)
        #expect(try await reopened.pending() == [accepted, later])

        // Explicit retry after storage recovers accepts the same identity exactly once.
        try await state.enqueue(rejected)
        try await state.enqueue(rejected)
        let retried = try await PersistentDataState.open(fileURL: url)
        #expect(try await retried.pending() == [accepted, later, rejected])
    }

    @Test("Failed incoming persistence restores results, eviction order and idempotency indexes")
    func failedIncomingWriteIsRetryable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("store")
        let url = directory.appendingPathComponent("state.json")
        let backup = root.appendingPathComponent("backup")
        let state = try await PersistentDataState.open(fileURL: url, maximumIncoming: 1)
        let accepted = StoredDataResult(messageID: MessageID(), idempotencyKey: DataIdempotencyKey(),
                                       response: nil, completedAt: Date(timeIntervalSince1970: 1_000))
        let retried = StoredDataResult(messageID: MessageID(), idempotencyKey: DataIdempotencyKey(),
                                      response: nil, completedAt: Date(timeIntervalSince1970: 1_001))
        let acceptedKey = try #require(accepted.idempotencyKey)
        let retriedKey = try #require(retried.idempotencyKey)
        try await state.record(accepted)
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data("blocked".utf8).write(to: directory)
        for _ in 0..<2 {
            await #expect(throws: (any Error).self) { try await state.record(retried) }
            #expect(await state.recordedResults() == [accepted])
            #expect(await state.result(for: acceptedKey) == accepted)
            #expect(await state.result(for: retriedKey) == nil)
        }
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        let untouched = try await PersistentDataState.open(fileURL: url)
        #expect(await untouched.recordedResults() == [accepted])
        try await state.record(retried)
        try await state.record(retried)
        let recovered = try await PersistentDataState.open(fileURL: url, maximumIncoming: 1)
        #expect(await recovered.recordedResults() == [retried])
        #expect(await recovered.result(for: acceptedKey) == nil)
        #expect(await recovered.result(for: retriedKey) == retried)
    }

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
        #expect(try await restored.removeRecordedResult(envelope.messageID))

        let afterDeletion = try await PersistentDataState.open(fileURL: url, now: now)
        #expect(await afterDeletion.result(for: envelope.messageID) == nil)
        #expect(await afterDeletion.result(for: key) == nil)
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

    @Test("Read-only result access does not rewrite runtime state")
    func readOnlyResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data-state.json")
        let now = Date(timeIntervalSince1970: 1_000)
        let state = try await PersistentDataState.open(fileURL: url, now: now)
        let result = StoredDataResult(
            messageID: MessageID(),
            idempotencyKey: DataIdempotencyKey(),
            response: DataMessage(
                kind: .response,
                operation: .init(namespace: "com.example", name: "read", version: 1),
                correlationID: DataCorrelationID(),
                body: Data("preserved".utf8)
            ),
            completedAt: now
        )
        try await state.record(result)
        let dataBeforeRead = try Data(contentsOf: url)

        let results = try PersistentDataState.readRecordedResults(fileURL: url)

        #expect(results == [result])
        #expect(try Data(contentsOf: url) == dataBeforeRead)
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
            networkID: .test,
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
            for: message, networkID: .test, sessionID: SessionID(), sourceNodeID: NodeID(), destinationNodeID: NodeID(),
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
