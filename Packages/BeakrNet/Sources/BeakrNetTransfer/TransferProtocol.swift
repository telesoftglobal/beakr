import Foundation
import BeakrNetCore

public struct TransferID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
}

public struct TransferContext: Codable, Equatable, Sendable {
    public let networkID: NetworkID
    public let sessionID: SessionID
    public let sourceNodeID: NodeID
    public let destinationNodeID: NodeID

    public init(networkID: NetworkID, sessionID: SessionID, sourceNodeID: NodeID, destinationNodeID: NodeID) {
        self.networkID = networkID; self.sessionID = sessionID; self.sourceNodeID = sourceNodeID; self.destinationNodeID = destinationNodeID
    }
}

public struct TransferManifest: Codable, Equatable, Sendable {
    public static let currentVersion: UInt16 = 1
    public let version: UInt16
    public let transferID: TransferID
    public let context: TransferContext
    public let byteCount: UInt64
    public let chunkSize: UInt32
    public let chunkCount: UInt32
    public let contentDigest: Data
    public let mediaType: String
    public let filename: String?
    public let expiresAt: Date

    public init(version: UInt16 = Self.currentVersion, transferID: TransferID = TransferID(), context: TransferContext,
                byteCount: UInt64, chunkSize: UInt32, chunkCount: UInt32, contentDigest: Data,
                mediaType: String, filename: String? = nil, expiresAt: Date) {
        self.version = version; self.transferID = transferID; self.context = context; self.byteCount = byteCount
        self.chunkSize = chunkSize; self.chunkCount = chunkCount; self.contentDigest = contentDigest
        self.mediaType = mediaType; self.filename = filename; self.expiresAt = expiresAt
    }
}

public struct TransferChunk: Codable, Equatable, Sendable {
    public let transferID: TransferID
    public let index: UInt32
    public let offset: UInt64
    public let bytes: Data
    public let digest: Data

    public init(transferID: TransferID, index: UInt32, offset: UInt64, bytes: Data, digest: Data) {
        self.transferID = transferID; self.index = index; self.offset = offset; self.bytes = bytes; self.digest = digest
    }
}

public struct TransferChunkRange: Codable, Equatable, Sendable {
    public let lowerBound: UInt32
    public let upperBound: UInt32
    public init(lowerBound: UInt32, upperBound: UInt32) { self.lowerBound = lowerBound; self.upperBound = upperBound }
}

public enum TransferMessageKind: String, Codable, Sendable {
    case manifest, chunk, resumeRequest = "resume-request", resumeResponse = "resume-response"
    case cancellation, completion, protocolError = "protocol-error"
}

public enum TransferProtocolErrorCode: String, Codable, Sendable {
    case malformed, unauthorized, expired, integrityFailure = "integrity-failure"
    case resourceLimit = "resource-limit", unknownTransfer = "unknown-transfer"
}

public struct TransferWireMessage: Codable, Equatable, Sendable {
    public static let currentVersion: UInt16 = 1
    public static let payloadType = "application/vnd.beakrnet.transfer+json"
    public let version: UInt16
    public let kind: TransferMessageKind
    public let transferID: TransferID
    public let manifest: TransferManifest?
    public let chunk: TransferChunk?
    public let missingRanges: [TransferChunkRange]
    public let retryAfterMilliseconds: UInt32?
    public let errorCode: TransferProtocolErrorCode?

    public init(version: UInt16 = Self.currentVersion, kind: TransferMessageKind, transferID: TransferID,
                manifest: TransferManifest? = nil, chunk: TransferChunk? = nil,
                missingRanges: [TransferChunkRange] = [], retryAfterMilliseconds: UInt32? = nil,
                errorCode: TransferProtocolErrorCode? = nil) {
        self.version = version; self.kind = kind; self.transferID = transferID; self.manifest = manifest
        self.chunk = chunk; self.missingRanges = missingRanges; self.retryAfterMilliseconds = retryAfterMilliseconds
        self.errorCode = errorCode
    }
}

public struct TransferLimits: Equatable, Sendable {
    public let maximumPayloadBytes: Int
    public let maximumTransferBytes: UInt64
    public let maximumChunkBytes: Int
    public let maximumChunkCount: UInt32
    public let maximumMissingRanges: Int
    public init(maximumPayloadBytes: Int = 2 * 1_024 * 1_024, maximumTransferBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024,
                maximumChunkBytes: Int = 1 * 1_024 * 1_024, maximumChunkCount: UInt32 = 65_536, maximumMissingRanges: Int = 1_024) {
        self.maximumPayloadBytes = maximumPayloadBytes; self.maximumTransferBytes = maximumTransferBytes
        self.maximumChunkBytes = maximumChunkBytes; self.maximumChunkCount = maximumChunkCount
        self.maximumMissingRanges = maximumMissingRanges
    }
}

public enum TransferCodecError: Error, Equatable, Sendable {
    case wrongChannel, discriminatorMismatch, unsupportedVersion(UInt16), invalidMessage, invalidManifest
    case resourceLimit, contextMismatch, malformed, noncanonical
}

public struct TransferCodec: Sendable {
    public let limits: TransferLimits
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public init(limits: TransferLimits = TransferLimits()) {
        self.limits = limits; encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970; decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public func encode(_ message: TransferWireMessage) throws -> Data {
        try validate(message)
        let data = try encoder.encode(message)
        guard data.count <= limits.maximumPayloadBytes else { throw TransferCodecError.resourceLimit }
        return data
    }

    public func decode(envelope: BeakrNetEnvelope) throws -> TransferWireMessage {
        guard envelope.channel == .data else { throw TransferCodecError.wrongChannel }
        guard envelope.payloadType == TransferWireMessage.payloadType else { throw TransferCodecError.discriminatorMismatch }
        guard envelope.payload.count <= limits.maximumPayloadBytes else { throw TransferCodecError.resourceLimit }
        let message: TransferWireMessage
        do { message = try decoder.decode(TransferWireMessage.self, from: envelope.payload) } catch { throw TransferCodecError.malformed }
        try validate(message)
        if let context = message.manifest?.context {
            guard context == TransferContext(networkID: envelope.networkID, sessionID: envelope.sessionID, sourceNodeID: envelope.sourceNodeID,
                                             destinationNodeID: envelope.destinationNodeID) else { throw TransferCodecError.contextMismatch }
        }
        guard try encode(message) == envelope.payload else { throw TransferCodecError.noncanonical }
        return message
    }

    public func makeEnvelope(for message: TransferWireMessage, context: TransferContext, sequenceNumber: UInt64,
                             createdAt: Date, deliveryPolicy: DeliveryPolicy, messageID: MessageID = MessageID()) throws -> BeakrNetEnvelope {
        BeakrNetEnvelope(messageID: messageID, networkID: context.networkID, sessionID: context.sessionID, sourceNodeID: context.sourceNodeID,
                         destinationNodeID: context.destinationNodeID, sequenceNumber: sequenceNumber, channel: .data,
                         deliveryPolicy: deliveryPolicy, payloadType: TransferWireMessage.payloadType,
                         payload: try encode(message), createdAt: createdAt)
    }

    private func validate(_ message: TransferWireMessage) throws {
        guard message.version == TransferWireMessage.currentVersion else { throw TransferCodecError.unsupportedVersion(message.version) }
        guard message.missingRanges.count <= limits.maximumMissingRanges,
              message.missingRanges == message.missingRanges.sorted(by: { $0.lowerBound < $1.lowerBound }),
              message.missingRanges.allSatisfy({ $0.lowerBound < $0.upperBound }) else { throw TransferCodecError.resourceLimit }
        if let manifest = message.manifest {
            guard manifest.version == TransferManifest.currentVersion, manifest.transferID == message.transferID,
                  manifest.byteCount > 0, manifest.byteCount <= limits.maximumTransferBytes,
                  manifest.chunkSize > 0, manifest.chunkSize <= limits.maximumChunkBytes,
                  manifest.chunkCount > 0, manifest.chunkCount <= limits.maximumChunkCount,
                  UInt64(manifest.chunkCount) == (manifest.byteCount + UInt64(manifest.chunkSize) - 1) / UInt64(manifest.chunkSize),
                  manifest.contentDigest.count == 32, !manifest.mediaType.isEmpty, manifest.mediaType.utf8.count <= 128,
                  manifest.filename.map({ $0.utf8.count <= 255 }) ?? true else { throw TransferCodecError.invalidManifest }
        }
        if let chunk = message.chunk {
            guard chunk.transferID == message.transferID, chunk.bytes.count <= limits.maximumChunkBytes,
                  chunk.digest.count == 32 else { throw TransferCodecError.invalidMessage }
        }
        let valid = switch message.kind {
        case .manifest: message.manifest != nil && message.chunk == nil && message.missingRanges.isEmpty && message.errorCode == nil
        case .chunk: message.chunk != nil && message.manifest == nil && message.missingRanges.isEmpty && message.errorCode == nil
        case .resumeRequest, .cancellation, .completion: message.manifest == nil && message.chunk == nil && message.missingRanges.isEmpty && message.errorCode == nil
        case .resumeResponse: message.manifest == nil && message.chunk == nil && message.errorCode == nil
        case .protocolError: message.errorCode != nil && message.manifest == nil && message.chunk == nil && message.missingRanges.isEmpty
        }
        guard valid else { throw TransferCodecError.invalidMessage }
    }
}
