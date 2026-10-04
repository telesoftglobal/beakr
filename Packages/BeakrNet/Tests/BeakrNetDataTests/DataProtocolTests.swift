import Foundation
import Testing
import BeakrNetCore
import BeakrNetData

@Suite("Application Data protocol")
struct DataProtocolTests {
    private let source = NodeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private let destination = NodeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    private let session = SessionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    private let messageID = MessageID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
    private let correlation = DataCorrelationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
    private let idempotency = DataIdempotencyKey(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!)
    private let now = Date(timeIntervalSince1970: 1_000)
    private let operation = DataOperation(namespace: "com.example.lighting", name: "set-state", version: 1)

    @Test("Canonical request has a stable golden encoding")
    func goldenEncoding() throws {
        let request = DataMessage(
            kind: .request,
            operation: operation,
            correlationID: correlation,
            idempotencyKey: idempotency,
            deadline: Date(timeIntervalSince1970: 1_030),
            body: Data("on".utf8)
        )
        let expected = #"{"body":"b24=","correlationID":{"rawValue":"00000000-0000-0000-0000-000000000005"},"deadline":1030000,"idempotencyKey":{"rawValue":"00000000-0000-0000-0000-000000000006"},"kind":"request","operation":{"name":"set-state","namespace":"com.example.lighting","version":1},"version":1}"#
        #expect(String(decoding: try DataCodec().encode(request), as: UTF8.self) == expected)
    }

    @Test("All message kinds round-trip through Data envelopes")
    func vocabularyRoundTrips() throws {
        let messages = [
            DataMessage(kind: .message, operation: operation, correlationID: correlation, body: Data("event".utf8)),
            DataMessage(kind: .request, operation: operation, correlationID: correlation, idempotencyKey: idempotency),
            DataMessage(kind: .response, operation: operation, correlationID: correlation, body: Data("ok".utf8)),
            DataMessage(kind: .cancellation, operation: operation, correlationID: correlation),
            DataMessage(kind: .applicationError, operation: operation, correlationID: correlation, errorCode: .conflict)
        ]
        let codec = DataCodec()
        for (index, message) in messages.enumerated() {
            let envelope = try makeEnvelope(message, sequence: UInt64(index))
            #expect(try codec.decode(envelope: envelope) == message)
        }
    }

    @Test("Versions, discriminators, channels, metadata, and resource bounds fail closed")
    func strictValidation() throws {
        let codec = DataCodec(limits: DataProtocolLimits(maximumPayloadBytes: 1_024, maximumBodyBytes: 4, maximumResponseBodyBytes: 2))
        #expect(throws: DataCodecError.unsupportedVersion(2)) {
            try codec.encode(DataMessage(version: 2, kind: .message, operation: operation, correlationID: correlation))
        }
        #expect(throws: DataCodecError.bodyTooLarge(maximumBytes: 4, actualBytes: 5)) {
            try codec.encode(DataMessage(kind: .message, operation: operation, correlationID: correlation, body: Data(repeating: 1, count: 5)))
        }
        #expect(throws: DataCodecError.invalidMetadata) {
            try codec.encode(DataMessage(kind: .cancellation, operation: operation, correlationID: correlation, body: Data([1])))
        }
        let valid = try makeEnvelope(DataMessage(kind: .message, operation: operation, correlationID: correlation))
        #expect(throws: DataCodecError.wrongChannel) { try codec.decode(envelope: replace(valid, channel: .blackboard)) }
        #expect(throws: DataCodecError.discriminatorMismatch) { try codec.decode(envelope: replace(valid, payloadType: "com.example.raw")) }
        #expect(throws: DataCodecError.noncanonical) {
            try codec.decode(envelope: replace(valid, payload: valid.payload + Data("\n".utf8)))
        }
    }

    @Test("Authorization, support, and deadlines run before the handler")
    func predispatchValidation() async throws {
        let handler = RecordingDataHandler()
        let dispatcher = DataDispatcher(
            authorization: DataAuthorizationPolicy { _, _, _ in false },
            supportedOperations: [operation],
            handler: handler,
            clock: { now }
        )
        let request = DataMessage(kind: .request, operation: operation, correlationID: correlation)
        guard case .rejected(.unauthorized, let response) = await dispatcher.dispatch(try makeEnvelope(request)) else {
            Issue.record("Expected authorization rejection"); return
        }
        #expect(response?.errorCode == .unauthorized)
        #expect(await handler.count == 0)

        let unsupported = DataMessage(kind: .request, operation: .init(namespace: "com.example", name: "unknown", version: 1), correlationID: correlation)
        guard case .rejected(.unsupportedOperation, _) = await dispatcher.dispatch(try makeEnvelope(unsupported, id: MessageID())) else {
            Issue.record("Expected unsupported operation rejection"); return
        }
        #expect(await handler.count == 0)
    }

    @Test("Idempotency keys isolate one mutation from envelope retries")
    func idempotentMutation() async throws {
        let response = DataMessage(kind: .response, operation: operation, correlationID: correlation, body: Data("ok".utf8))
        let handler = RecordingDataHandler(response: response)
        let dispatcher = DataDispatcher(supportedOperations: [operation], handler: handler, clock: { now })
        let request = DataMessage(kind: .request, operation: operation, correlationID: correlation, idempotencyKey: idempotency)

        #expect(await dispatcher.dispatch(try makeEnvelope(request)) == .handled(response: response))
        #expect(await dispatcher.dispatch(try makeEnvelope(request, id: MessageID(), sequence: 2)) == .handled(response: response))
        #expect(await handler.count == 1)
    }

    @Test("An exact Message ID replay never reaches the handler")
    func messageReplay() async throws {
        let handler = RecordingDataHandler()
        let dispatcher = DataDispatcher(supportedOperations: [operation], handler: handler, clock: { now })
        let envelope = try makeEnvelope(DataMessage(kind: .message, operation: operation, correlationID: correlation))
        #expect(await dispatcher.dispatch(envelope) == .handled(response: nil))
        #expect(await dispatcher.dispatch(envelope) == .rejected(.duplicate, response: nil))
        #expect(await handler.count == 1)
    }

    @Test("Cancellation prevents later correlated request dispatch")
    func cancellationState() async throws {
        let handler = RecordingDataHandler()
        let dispatcher = DataDispatcher(supportedOperations: [operation], handler: handler, clock: { now })
        let cancellation = DataMessage(kind: .cancellation, operation: operation, correlationID: correlation)
        #expect(await dispatcher.dispatch(try makeEnvelope(cancellation)) == .handled(response: nil))
        let request = DataMessage(kind: .request, operation: operation, correlationID: correlation)
        guard case .rejected(.cancelled, let response) = await dispatcher.dispatch(try makeEnvelope(request, id: MessageID())) else {
            Issue.record("Expected cancelled request rejection"); return
        }
        #expect(response?.errorCode == .cancelled)
        #expect(await handler.count == 1)
    }

    @Test("Handlers cannot substitute an unrelated correlated response")
    func responseBinding() async throws {
        let unrelated = DataMessage(
            kind: .response, operation: operation, correlationID: DataCorrelationID(), body: Data("wrong".utf8)
        )
        let handler = RecordingDataHandler(response: unrelated)
        let dispatcher = DataDispatcher(supportedOperations: [operation], handler: handler, clock: { now })
        let request = DataMessage(kind: .request, operation: operation, correlationID: correlation)
        guard case .rejected(.handlerFailure, let response) = await dispatcher.dispatch(try makeEnvelope(request)) else {
            Issue.record("Expected response-binding rejection"); return
        }
        #expect(response?.correlationID == correlation)
        #expect(response?.errorCode == .handlerFailure)
    }

    private func makeEnvelope(_ message: DataMessage, id: MessageID? = nil, sequence: UInt64 = 1) throws -> BeakrNetEnvelope {
        try DataCodec().makeEnvelope(
            for: message,
            sessionID: session,
            sourceNodeID: source,
            destinationNodeID: destination,
            messageID: id ?? messageID,
            sequenceNumber: sequence,
            createdAt: now,
            deliveryPolicy: .init(durability: .durable, expiresAt: now.addingTimeInterval(60))
        )
    }

    private func replace(
        _ envelope: BeakrNetEnvelope,
        channel: BeakrNetChannel? = nil,
        payloadType: String? = nil,
        payload: Data? = nil
    ) -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            messageID: envelope.messageID, sessionID: envelope.sessionID,
            sourceNodeID: envelope.sourceNodeID, destinationNodeID: envelope.destinationNodeID,
            sequenceNumber: envelope.sequenceNumber, channel: channel ?? envelope.channel,
            representation: envelope.representation, deliveryPolicy: envelope.deliveryPolicy,
            payloadType: payloadType ?? envelope.payloadType, payload: payload ?? envelope.payload,
            createdAt: envelope.createdAt
        )
    }
}

private actor RecordingDataHandler: DataMessageHandler {
    private(set) var count = 0
    private let response: DataMessage?

    init(response: DataMessage? = nil) { self.response = response }

    func handle(_ message: DataMessage, envelope: BeakrNetEnvelope) async throws -> DataMessage? {
        count += 1
        return response
    }
}
