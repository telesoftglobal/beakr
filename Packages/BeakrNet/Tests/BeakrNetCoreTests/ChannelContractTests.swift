import Foundation
import Testing
@testable import BeakrNetCore

@Suite("Versioned channel contract")
struct ChannelContractTests {
    private let sessionID = SessionID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    private let sourceNodeID = NodeID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    private let destinationNodeID = NodeID(rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
    private let messageID = MessageID(rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)

    @Test("Every channel survives encoding", arguments: BeakrNetChannel.allCases)
    func channelRoundTrip(channel: BeakrNetChannel) throws {
        let envelope = makeEnvelope(channel: channel)
        let decoded = try JSONDecoder().decode(BeakrNetEnvelope.self, from: JSONEncoder().encode(envelope))

        #expect(decoded == envelope)
        #expect(decoded.channel == channel)
    }

    @Test("Schema version 2 has a stable encoded fixture")
    func goldenVersion2Fixture() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(makeEnvelope(channel: .data))
        let fixture = #"{"channel":"data","createdAt":0,"deliveryPolicy":{"durability":"queued","priority":0},"destinationNodeID":{"rawValue":"33333333-3333-3333-3333-333333333333"},"messageID":{"rawValue":"44444444-4444-4444-4444-444444444444"},"payload":"aGVsbG8=","payloadType":"com.example.message","representation":"full","schemaVersion":2,"sequenceNumber":42,"sessionID":{"rawValue":"11111111-1111-1111-1111-111111111111"},"sourceNodeID":{"rawValue":"22222222-2222-2222-2222-222222222222"}}"#

        #expect(String(decoding: encoded, as: UTF8.self) == fixture)
    }

    @Test("Version 1 and future versions are rejected", arguments: [1, 3])
    func unsupportedVersion(version: Int) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(makeEnvelope())) as? [String: Any])
        object["schemaVersion"] = version
        let encoded = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: EnvelopeValidationError.unsupportedSchemaVersion(version)) {
            try JSONDecoder().decode(BeakrNetEnvelope.self, from: encoded)
        }
    }

    @Test("Application payloads cannot use Control")
    func applicationPayloadOnControl() {
        let envelope = makeEnvelope(channel: .control)
        #expect(throws: EnvelopeValidationError.applicationPayloadOnControlChannel) {
            try envelope.validate()
        }
    }

    @Test("Control payloads have a strict size limit")
    func oversizedControlPayload() {
        let envelope = makeEnvelope(
            channel: .control,
            payloadType: ControlPayloadType.keepalive.rawValue,
            payload: Data(count: BeakrNetEnvelope.maximumControlPayloadBytes + 1)
        )
        #expect(throws: EnvelopeValidationError.controlPayloadTooLarge(
            maximumBytes: BeakrNetEnvelope.maximumControlPayloadBytes,
            actualBytes: BeakrNetEnvelope.maximumControlPayloadBytes + 1
        )) {
            try envelope.validate()
        }
    }

    @Test("Compact profiles do not change channel semantics", arguments: [BeakrNetChannel.data, .blackboard])
    func compactChannelIsPreserved(channel: BeakrNetChannel) throws {
        let envelope = makeEnvelope(channel: channel, representation: .compact)
        let decoded = try JSONDecoder().decode(BeakrNetEnvelope.self, from: JSONEncoder().encode(envelope))

        #expect(decoded.channel == channel)
        #expect(decoded.representation == .compact)
    }

    @Test("Expired messages are rejected by sessions")
    func expiredMessage() async throws {
        let session = BeakrNetSession(id: sessionID, localNodeID: sourceNodeID, remoteNodeID: destinationNodeID)
        let envelope = makeEnvelope(deliveryPolicy: DeliveryPolicy(
            durability: .queued,
            expiresAt: Date(timeIntervalSince1970: 10)
        ))

        await #expect(throws: EnvelopeValidationError.expired) {
            try await session.queueForDelivery(envelope, now: Date(timeIntervalSince1970: 11))
        }
        #expect(await session.pendingDelivery(for: envelope.messageID) == nil)
    }

    @Test("Replacement keys require queued delivery")
    func replacementPolicy() {
        let invalid = makeEnvelope(deliveryPolicy: DeliveryPolicy(durability: .durable, replacementKey: "status"))
        #expect(throws: EnvelopeValidationError.invalidDeliveryPolicy) {
            try invalid.validate()
        }

        let valid = makeEnvelope(deliveryPolicy: DeliveryPolicy(durability: .queued, replacementKey: "status"))
        #expect(throws: Never.self) {
            try valid.validate()
        }
    }

    @Test("Queued Control must be brief and durable Control is forbidden")
    func controlDeliveryPolicy() {
        for durability in [DeliveryDurability.queued, .durable] {
            let envelope = makeEnvelope(
                channel: .control,
                deliveryPolicy: DeliveryPolicy(durability: durability),
                payloadType: ControlPayloadType.keepalive.rawValue
            )
            #expect(throws: EnvelopeValidationError.invalidDeliveryPolicy) {
                try envelope.validate(now: Date(timeIntervalSinceReferenceDate: 0))
            }
        }

        let brieflyQueued = makeEnvelope(
            channel: .control,
            deliveryPolicy: DeliveryPolicy(
                durability: .queued,
                expiresAt: Date(timeIntervalSinceReferenceDate: 60)
            ),
            payloadType: ControlPayloadType.keepalive.rawValue
        )
        #expect(throws: Never.self) {
            try brieflyQueued.validate(now: Date(timeIntervalSinceReferenceDate: 0))
        }
    }

    private func makeEnvelope(
        channel: BeakrNetChannel = .data,
        representation: RepresentationProfile = .full,
        deliveryPolicy: DeliveryPolicy = .standard,
        payloadType: String = "com.example.message",
        payload: Data = Data("hello".utf8)
    ) -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            messageID: messageID,
            sessionID: sessionID,
            sourceNodeID: sourceNodeID,
            destinationNodeID: destinationNodeID,
            sequenceNumber: 42,
            channel: channel,
            representation: representation,
            deliveryPolicy: deliveryPolicy,
            payloadType: payloadType,
            payload: payload,
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }
}
