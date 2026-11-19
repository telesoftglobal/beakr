import Foundation
import Testing
import BeakrNetCore
import BeakrNetControl
import BeakrNetTestSupport

@Suite("Typed Control protocol")
struct ControlProtocolTests {
    private let source = NodeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private let destination = NodeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    private let session = SessionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    private let acknowledged = MessageID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
    private let envelopeID = MessageID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test("All approved payloads encode canonically and round-trip")
    func vocabularyRoundTrips() throws {
        let context = context()
        let messages: [ControlMessage] = [
            .deliveryAcknowledgement(ControlHeader(type: .deliveryAcknowledgement, context: context), .init(acknowledgedMessageID: acknowledged)),
            .sessionLiveness(ControlHeader(type: .sessionLiveness, context: context), .init(kind: .probe, nonce: 42)),
            .queuePressure(ControlHeader(type: .queuePressure, context: context), .init(level: .elevated, availableSlots: 7, retryAfterMilliseconds: 500)),
            .synchronizationHint(ControlHeader(type: .synchronizationHint, context: context), .init(scope: .blackboard, cursor: "cursor-7")),
            .peerLifecycle(ControlHeader(type: .peerLifecycle, context: context), .init(reason: .applicationBackgrounded)),
            .peerNetworkInfo(ControlHeader(type: .peerNetworkInfo, context: context), .init(ipv4Address: "192.0.2.10")),
            .protocolError(ControlHeader(type: .protocolError, context: context), .init(code: .unsupportedVersion, relatedMessageID: envelopeID))
        ]
        let codec = ControlCodec()

        for (index, message) in messages.enumerated() {
            let envelope = try codec.makeEnvelope(for: message, messageID: envelopeID, sequenceNumber: UInt64(index), createdAt: now)
            #expect(try codec.decode(envelope: envelope) == message)
            #expect(try codec.encode(message) == codec.encode(message))
            #expect(envelope.payloadType == message.type.rawValue)
        }
    }

    @Test("Acknowledgement encoding matches the golden fixture")
    func acknowledgementGoldenFixture() throws {
        let message = ControlMessage.deliveryAcknowledgement(
            ControlHeader(type: .deliveryAcknowledgement, context: context()),
            ControlDeliveryAcknowledgement(acknowledgedMessageID: acknowledged)
        )
        let expected = #"{"body":{"acknowledgedMessageID":{"rawValue":"00000000-0000-0000-0000-000000000004"}},"destinationNodeID":{"rawValue":"00000000-0000-0000-0000-000000000002"},"networkID":{"rawValue":"7E570000-0000-4000-8000-000000000001"},"sessionID":{"rawValue":"00000000-0000-0000-0000-000000000003"},"sourceNodeID":{"rawValue":"00000000-0000-0000-0000-000000000001"},"type":"beakrnet.delivery-acknowledgement","version":1}"#

        #expect(String(decoding: try ControlCodec().encode(message), as: UTF8.self) == expected)
    }

    @Test("Discriminator, version, envelope context, and size failures close")
    func strictValidation() throws {
        let codec = ControlCodec()
        let valid = try envelope(.sessionLiveness(ControlHeader(type: .sessionLiveness, context: context()), .init(kind: .probe, nonce: 1)))
        let wrongType = replace(valid, payloadType: ControlMessageType.queuePressure.rawValue)
        #expect(throws: ControlCodecError.discriminatorMismatch(expected: wrongType.payloadType, actual: ControlMessageType.sessionLiveness.rawValue)) {
            try codec.decode(envelope: wrongType)
        }

        let future = replacePayload(valid, from: #""version":1"#, to: #""version":2"#)
        #expect(throws: ControlCodecError.unsupportedVersion(type: ControlMessageType.sessionLiveness.rawValue, version: 2)) {
            try codec.decode(envelope: future)
        }

        let unknown = replacePayload(valid, from: ControlMessageType.sessionLiveness.rawValue, to: "beakrnet.future")
        #expect(throws: ControlCodecError.unsupportedMessage("beakrnet.future")) { try codec.decode(envelope: unknown) }

        let oversized = replace(valid, payload: Data(repeating: 0, count: ControlCodec.maximumPayloadBytes + 1))
        #expect(throws: ControlCodecError.payloadTooLarge(maximumBytes: ControlCodec.maximumPayloadBytes, actualBytes: oversized.payload.count)) {
            try codec.decode(envelope: oversized)
        }

        let noncanonical = replace(valid, payload: Data((String(decoding: valid.payload, as: UTF8.self) + "\n").utf8))
        #expect(throws: ControlCodecError.malformed) { try codec.decode(envelope: noncanonical) }
    }

    @Test("Dispatcher validates context before isolated handler invocation")
    func contextAndHandlerIsolation() async throws {
        let handler = RecordingHandler()
        let dispatcher = ControlDispatcher(handler: handler, clock: { now })
        let good = try envelope(.sessionLiveness(ControlHeader(type: .sessionLiveness, context: context()), .init(kind: .probe, nonce: 1)))
        #expect(await dispatcher.dispatch(good) == .handled(try ControlCodec().decode(envelope: good)))
        #expect(await handler.count == 1)

        let badPayload = try envelope(.sessionLiveness(ControlHeader(type: .sessionLiveness, context: context()), .init(kind: .probe, nonce: 2)))
        let bad = replaceContext(badPayload, source: NodeID())
        guard case .rejected(.malformed, let response) = await dispatcher.dispatch(bad) else {
            Issue.record("Expected context rejection"); return
        }
        #expect(response?.type == .protocolError)
        #expect(await handler.count == 1)
    }

    @Test("Authorization, replay, and per-source rate bounds run before handlers")
    func dispatchBounds() async throws {
        let handler = RecordingHandler()
        let dispatcher = ControlDispatcher(
            authorization: ControlAuthorizationPolicy { _, type in type == .sessionLiveness },
            resources: ControlResourcePolicy(maximumTrackedReplayIDs: 2, maximumMessagesPerWindow: 2, rateWindow: 10),
            handler: handler,
            clock: { now }
        )
        let denied = try envelope(.queuePressure(ControlHeader(type: .queuePressure, context: context()), .init(level: .normal, availableSlots: 1)))
        guard case .rejected(.unauthorized, _) = await dispatcher.dispatch(denied) else { Issue.record("Expected authorization rejection"); return }

        let first = try envelope(.sessionLiveness(ControlHeader(type: .sessionLiveness, context: context()), .init(kind: .probe, nonce: 1)))
        #expect(await dispatcher.dispatch(first) == .handled(try ControlCodec().decode(envelope: first)))
        guard case .rejected(.replayed, nil) = await dispatcher.dispatch(first) else { Issue.record("Expected replay rejection"); return }

        let second = try envelope(.sessionLiveness(ControlHeader(type: .sessionLiveness, context: context()), .init(kind: .probe, nonce: 2)), id: MessageID())
        guard case .rejected(.resourceLimit, nil) = await dispatcher.dispatch(second) else { Issue.record("Expected rate rejection"); return }
        #expect(await handler.count == 1)
    }

    @Test("Acknowledgements and errors never receive protocol-error responses")
    func loopPrevention() async throws {
        let handler = RecordingHandler()
        let dispatcher = ControlDispatcher(authorization: ControlAuthorizationPolicy { _, _ in false }, handler: handler)
        let acknowledgement = try envelope(.deliveryAcknowledgement(ControlHeader(type: .deliveryAcknowledgement, context: context()), .init(acknowledgedMessageID: acknowledged)))
        let protocolError = try envelope(.protocolError(ControlHeader(type: .protocolError, context: context()), .init(code: .malformed)))
        guard case .rejected(.unauthorized, nil) = await dispatcher.dispatch(acknowledgement) else { Issue.record("Acknowledgement loop risk"); return }
        guard case .rejected(.unauthorized, nil) = await dispatcher.dispatch(protocolError) else { Issue.record("Error loop risk"); return }
    }

    @Test("Typed acknowledgement completes Core pending delivery")
    func acknowledgementIntegration() async throws {
        let coreSession = BeakrNetSession(id: session, networkID: .test, localNodeID: source, remoteNodeID: destination, state: .active, now: now)
        let pending = BeakrNetEnvelope(
            messageID: acknowledged, networkID: .test, sessionID: session, sourceNodeID: source, destinationNodeID: destination,
            sequenceNumber: 1, payloadType: "com.example.data", payload: Data(), createdAt: now
        )
        try await coreSession.queueForDelivery(pending, now: now)
        let typed = ControlMessage.deliveryAcknowledgement(
            ControlHeader(type: .deliveryAcknowledgement, context: ControlContext(networkID: .test, sourceNodeID: destination, destinationNodeID: source, sessionID: session)),
            .init(acknowledgedMessageID: acknowledged)
        )
        #expect(await coreSession.acknowledge(try #require(typed.coreAcknowledgement)))
        #expect(await coreSession.pendingDelivery(for: acknowledged) == nil)
    }

    @Test("Typed Control crosses transport and session boundaries")
    func endToEndTransportDelivery() async throws {
        let codec = ControlCodec()
        let message = ControlMessage.sessionLiveness(ControlHeader(type: .sessionLiveness, context: context()), .init(kind: .probe, nonce: 99))
        let outgoing = try codec.makeEnvelope(for: message, messageID: envelopeID, sequenceNumber: 8, createdAt: now)
        let (sender, receiver) = await InMemoryTransport.makePair()
        try await sender.send(outgoing)
        let incoming = try #require(await receiver.receive())
        let receivingSession = BeakrNetSession(id: session, networkID: .test, localNodeID: destination, remoteNodeID: source, state: .active, now: now)
        #expect(try await receivingSession.accept(incoming, now: now) == .accepted)
        #expect(try codec.decode(envelope: incoming) == message)
    }

    @Test("Mixed Control, Data, and Blackboard keep bounded relay fairness")
    func mixedFairness() async throws {
        let queue = BoundedRelayQueue(networkID: .test, policy: RelayQueuePolicy(
            maximumMessagesPerNode: 8, maximumTotalMessages: 8,
            reservedControlMessagesPerNode: 2, reservedControlMessagesTotal: 2,
            maximumConsecutiveControlMessages: 2, messageTimeToLive: 60
        ))
        for index in 0..<4 {
            let control = try envelope(.sessionLiveness(ControlHeader(type: .sessionLiveness, context: context()), .init(kind: .probe, nonce: UInt64(index))), id: MessageID())
            try await queue.enqueue(control, for: destination, now: now)
        }
        try await queue.enqueue(applicationEnvelope(.data, sequence: 10), for: destination, now: now)
        try await queue.enqueue(applicationEnvelope(.blackboard, sequence: 11), for: destination, now: now)

        let channels = await queue.drain(for: destination, now: now).map(\.channel)
        #expect(channels == [.control, .control, .data, .control, .control, .blackboard])
    }

    @Test("Peer network reports accept IPv4 or missing addresses, and reject IPv6 and malformed values")
    func peerNetworkInfoValidation() throws {
        let header = ControlHeader(type: .peerNetworkInfo, context: context())
        let codec = ControlCodec()
        for address in [nil, "192.168.1.157"] as [String?] {
            let message = ControlMessage.peerNetworkInfo(header, .init(ipv4Address: address))
            #expect(try codec.decode(envelope: envelope(message)) == message)
        }
        for address in ["fe80::1%en0", "256.1.1.1", "1.2.3", "192.168.1.1\\n", "0.0.0.0"] {
            #expect(throws: ControlCodecError.invalidValue) {
                try codec.encode(.peerNetworkInfo(header, .init(ipv4Address: address)))
            }
        }
    }

    private func context() -> ControlContext {
        ControlContext(networkID: .test, sourceNodeID: source, destinationNodeID: destination, sessionID: session)
    }

    private func envelope(_ message: ControlMessage, id: MessageID? = nil) throws -> BeakrNetEnvelope {
        try ControlCodec().makeEnvelope(for: message, messageID: id ?? envelopeID, sequenceNumber: 1, createdAt: now)
    }

    private func applicationEnvelope(_ channel: BeakrNetChannel, sequence: UInt64) -> BeakrNetEnvelope {
        BeakrNetEnvelope(networkID: .test, sessionID: session, sourceNodeID: source, destinationNodeID: destination, sequenceNumber: sequence,
                         channel: channel, deliveryPolicy: .init(durability: .queued, expiresAt: now.addingTimeInterval(30)),
                         payloadType: "com.example.payload", payload: Data(), createdAt: now)
    }

    private func replace(_ envelope: BeakrNetEnvelope, payloadType: String? = nil, payload: Data? = nil) -> BeakrNetEnvelope {
        BeakrNetEnvelope(messageID: envelope.messageID, networkID: envelope.networkID, sessionID: envelope.sessionID, sourceNodeID: envelope.sourceNodeID,
                         destinationNodeID: envelope.destinationNodeID, sequenceNumber: envelope.sequenceNumber,
                         channel: envelope.channel, representation: envelope.representation, deliveryPolicy: envelope.deliveryPolicy,
                         payloadType: payloadType ?? envelope.payloadType, payload: payload ?? envelope.payload, createdAt: envelope.createdAt)
    }

    private func replaceContext(_ envelope: BeakrNetEnvelope, source: NodeID) -> BeakrNetEnvelope {
        BeakrNetEnvelope(messageID: envelope.messageID, networkID: envelope.networkID, sessionID: envelope.sessionID, sourceNodeID: source,
                         destinationNodeID: envelope.destinationNodeID, sequenceNumber: envelope.sequenceNumber,
                         channel: envelope.channel, representation: envelope.representation, deliveryPolicy: envelope.deliveryPolicy,
                         payloadType: envelope.payloadType, payload: envelope.payload, createdAt: envelope.createdAt)
    }

    private func replacePayload(_ envelope: BeakrNetEnvelope, from: String, to: String) -> BeakrNetEnvelope {
        let changed = String(decoding: envelope.payload, as: UTF8.self).replacingOccurrences(of: from, with: to)
        return replace(envelope, payload: Data(changed.utf8))
    }
}

private actor RecordingHandler: ControlMessageHandler {
    private(set) var count = 0
    func handle(_ message: ControlMessage, envelope: BeakrNetEnvelope) async throws { count += 1 }
}
