import Foundation
import Testing
import BeakrNetCore
import BeakrNetData
import BeakrNetHost

@Suite("Persistent host messaging")
struct PersistentHostMessagingServiceTests {
    @Test("Offline send persists a durable envelope and retry preserves its identity")
    func offlineQueueAndRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = try await PersistentDataState.open(fileURL: directory.appendingPathComponent("data.json"))
        let destination = NodeID()
        let source = NodeID()
        let session = SessionID()
        let submissions = SubmissionRecorder()
        let now = Date(timeIntervalSince1970: 1_000)
        let service = PersistentHostMessagingService(
            state: state,
            clock: { now },
            contextProvider: { requestedDestination in
                #expect(requestedDestination == destination)
                return HostDeliveryContext(sessionID: session, sourceNodeID: source, sequenceNumber: 9)
            },
            submit: { envelope in await submissions.record(envelope); return .routeUnavailable }
        )

        try await service.send(.text(destination: destination, body: "Hello"))
        let queued = try await state.pending(now: now)
        #expect(queued.count == 1)
        #expect(queued[0].deliveryPolicy.durability == .durable)
        #expect(queued[0].destinationNodeID == destination)

        let reopenedState = try await PersistentDataState.open(fileURL: directory.appendingPathComponent("data.json"),
                                                               now: now)
        let restartedService = PersistentHostMessagingService(
            state: reopenedState,
            clock: { now },
            contextProvider: { _ in
                Issue.record("Retrying persisted work must not create a new delivery context")
                return HostDeliveryContext(sessionID: SessionID(), sourceNodeID: NodeID(), sequenceNumber: 10)
            },
            submit: { envelope in await submissions.record(envelope); return .routeUnavailable }
        )
        try await restartedService.retryPending()
        let attempted = await submissions.envelopes
        try #require(attempted.count == 2)
        #expect(attempted[0] == attempted[1])
    }

    @Test("Cancellation removes only the matching correlated message")
    func cancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = try await PersistentDataState.open(fileURL: directory.appendingPathComponent("data.json"))
        let destination = NodeID()
        let correlationID = DataCorrelationID()
        let service = PersistentHostMessagingService(
            state: state,
            contextProvider: { _ in HostDeliveryContext(sessionID: SessionID(), sourceNodeID: NodeID(), sequenceNumber: 1) },
            submit: { _ in .routeUnavailable }
        )
        let message = DataMessage(kind: .message,
                                  operation: DataOperation(namespace: "beakr", name: "text-message", version: 1),
                                  correlationID: correlationID, body: Data("Hello".utf8))
        try await service.send(HostMessageRequest(destination: destination, message: message))

        try await service.cancel(correlationID: correlationID)
        #expect(try await state.pending().isEmpty)
    }
}

private actor SubmissionRecorder {
    private(set) var envelopes: [BeakrNetEnvelope] = []
    func record(_ envelope: BeakrNetEnvelope) { envelopes.append(envelope) }
}
