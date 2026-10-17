import Foundation
import Testing
import BeakrNetCore
import BeakrBlackboard

@Suite("Blackboard synchronization protocol")
struct BlackboardProtocolTests {
    private let space = BlackboardSpaceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    @Test("Snapshot request has stable canonical encoding")
    func goldenSnapshotRequest() throws {
        let message = BlackboardWireMessage(kind: .snapshotRequest, spaceID: space)
        let expected = #"{"kind":"snapshot-request","operations":[],"spaceID":{"rawValue":"00000000-0000-0000-0000-000000000001"},"version":1}"#
        #expect(String(decoding: try BlackboardCodec().encode(message), as: UTF8.self) == expected)
    }

    @Test("Every synchronization discriminator round-trips")
    func roundTrips() throws {
        let subscription = BlackboardSubscriptionID()
        let snapshot = BlackboardSpaceSnapshot(
            version: 1, spaceID: space, name: "Notes", membershipRevision: 1,
            members: [], compactionGeneration: 0, frontier: .init(), records: [], journalOffset: 0
        )
        let messages = [
            BlackboardWireMessage(kind: .snapshotRequest, spaceID: space),
            BlackboardWireMessage(kind: .snapshotResponse, spaceID: space, snapshot: snapshot),
            BlackboardWireMessage(kind: .incrementalRequest, spaceID: space, cursor: .init(compactionGeneration: 0, journalOffset: 0), limit: 10),
            BlackboardWireMessage(kind: .incrementalResponse, spaceID: space, cursor: .init(compactionGeneration: 0, journalOffset: 0)),
            BlackboardWireMessage(kind: .subscriptionRequest, spaceID: space, subscriptionID: subscription),
            BlackboardWireMessage(kind: .subscriptionCancellation, spaceID: space, subscriptionID: subscription),
            BlackboardWireMessage(kind: .protocolError, spaceID: space, errorCode: .invalidCausality)
        ]
        let codec = BlackboardCodec()
        for message in messages {
            let envelope = try codec.makeEnvelope(
                for: message, networkID: .test, sessionID: SessionID(), sourceNodeID: NodeID(), destinationNodeID: NodeID(),
                sequenceNumber: 1, createdAt: Date(timeIntervalSince1970: 1_000),
                deliveryPolicy: .init(durability: .durable)
            )
            #expect(try codec.decode(envelope: envelope) == message)
        }
    }

    @Test("Wrong channels, metadata combinations, versions, and bounds fail closed")
    func strictValidation() throws {
        let codec = BlackboardCodec(limits: .init(maximumPayloadBytes: 1_024, maximumOperationsPerBatch: 1, maximumIncrementalLimit: 2))
        #expect(throws: BlackboardCodecError.unsupportedVersion(2)) {
            try codec.encode(.init(version: 2, kind: .snapshotRequest, spaceID: space))
        }
        #expect(throws: BlackboardCodecError.invalidMessage) {
            try codec.encode(.init(kind: .snapshotRequest, spaceID: space, limit: 1))
        }
        #expect(throws: BlackboardCodecError.resourceLimit) {
            try codec.encode(.init(kind: .incrementalRequest, spaceID: space, cursor: .init(compactionGeneration: 0, journalOffset: 0), limit: 3))
        }
        let message = BlackboardWireMessage(kind: .snapshotRequest, spaceID: space)
        let good = try codec.makeEnvelope(
            for: message, networkID: .test, sessionID: SessionID(), sourceNodeID: NodeID(), destinationNodeID: NodeID(),
            sequenceNumber: 1, createdAt: Date(timeIntervalSince1970: 1_000), deliveryPolicy: .init(durability: .durable)
        )
        let wrong = BeakrNetEnvelope(
            messageID: good.messageID, networkID: good.networkID, sessionID: good.sessionID, sourceNodeID: good.sourceNodeID,
            destinationNodeID: good.destinationNodeID, sequenceNumber: good.sequenceNumber,
            channel: .data, deliveryPolicy: good.deliveryPolicy, payloadType: good.payloadType,
            payload: good.payload, createdAt: good.createdAt
        )
        #expect(throws: BlackboardCodecError.wrongChannel) { try codec.decode(envelope: wrong) }
    }
}
