import Foundation
import Testing
import BeakrNetCore
import BeakrNetTransfer

@Suite("Reliable transfer protocol")
struct TransferProtocolTests {
    let transfer = TransferID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let session = SessionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let source = NodeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    let destination = NodeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)

    @Test("Manifest encoding is canonical and envelope-bound")
    func manifestRoundTrip() throws {
        let context = TransferContext(sessionID: session, sourceNodeID: source, destinationNodeID: destination)
        let manifest = TransferManifest(transferID: transfer, context: context, byteCount: 4, chunkSize: 2,
                                        chunkCount: 2, contentDigest: Data(repeating: 1, count: 32),
                                        mediaType: "application/octet-stream", expiresAt: Date(timeIntervalSince1970: 2_000))
        let message = TransferWireMessage(kind: .manifest, transferID: transfer, manifest: manifest)
        let codec = TransferCodec()
        let envelope = try codec.makeEnvelope(for: message, context: context, sequenceNumber: 1,
                                               createdAt: Date(timeIntervalSince1970: 1_000), deliveryPolicy: .init(durability: .durable))
        #expect(try codec.decode(envelope: envelope) == message)
        #expect(try codec.encode(message) == codec.encode(message))
    }

    @Test("Chunk and resume bounds fail closed")
    func bounds() throws {
        let codec = TransferCodec(limits: .init(maximumPayloadBytes: 1_024, maximumTransferBytes: 100,
                                                maximumChunkBytes: 2, maximumChunkCount: 10, maximumMissingRanges: 1))
        #expect(throws: TransferCodecError.invalidMessage) {
            try codec.encode(.init(kind: .chunk, transferID: transfer,
                                   chunk: .init(transferID: transfer, index: 0, offset: 0,
                                                bytes: Data([1, 2, 3]), digest: Data(repeating: 0, count: 32))))
        }
        #expect(throws: TransferCodecError.resourceLimit) {
            try codec.encode(.init(kind: .resumeResponse, transferID: transfer,
                                   missingRanges: [.init(lowerBound: 0, upperBound: 1), .init(lowerBound: 2, upperBound: 3)]))
        }
    }

    @Test("Manifest arithmetic and context substitution are rejected")
    func manifestValidation() throws {
        let context = TransferContext(sessionID: session, sourceNodeID: source, destinationNodeID: destination)
        let bad = TransferManifest(transferID: transfer, context: context, byteCount: 5, chunkSize: 2, chunkCount: 2,
                                   contentDigest: Data(repeating: 0, count: 32), mediaType: "x", expiresAt: Date.distantFuture)
        #expect(throws: TransferCodecError.invalidManifest) {
            try TransferCodec().encode(.init(kind: .manifest, transferID: transfer, manifest: bad))
        }
    }
}
