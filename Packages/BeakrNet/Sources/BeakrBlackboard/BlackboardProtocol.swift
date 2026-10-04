import Foundation
import BeakrNetCore

public enum BlackboardMessageKind: String, Codable, CaseIterable, Sendable {
    case snapshotRequest = "snapshot-request"
    case snapshotResponse = "snapshot-response"
    case incrementalRequest = "incremental-request"
    case incrementalResponse = "incremental-response"
    case operationBatch = "operation-batch"
    case subscriptionRequest = "subscription-request"
    case subscriptionCancellation = "subscription-cancellation"
    case protocolError = "protocol-error"
}

public enum BlackboardProtocolErrorCode: String, Codable, Sendable {
    case malformed
    case unsupportedVersion = "unsupported-version"
    case unauthorized
    case invalidCausality = "invalid-causality"
    case compactionBoundaryMismatch = "compaction-boundary-mismatch"
    case resourceLimit = "resource-limit"
}

public struct BlackboardWireMessage: Codable, Equatable, Sendable {
    public static let payloadType = "application/vnd.beakrnet.blackboard+json"
    public static let currentVersion: UInt16 = 1

    public let version: UInt16
    public let kind: BlackboardMessageKind
    public let spaceID: BlackboardSpaceID
    public let cursor: BlackboardCursor?
    public let limit: UInt32?
    public let operations: [BlackboardOperation]
    public let snapshot: BlackboardSpaceSnapshot?
    public let subscriptionID: BlackboardSubscriptionID?
    public let errorCode: BlackboardProtocolErrorCode?

    public init(
        version: UInt16 = Self.currentVersion,
        kind: BlackboardMessageKind,
        spaceID: BlackboardSpaceID,
        cursor: BlackboardCursor? = nil,
        limit: UInt32? = nil,
        operations: [BlackboardOperation] = [],
        snapshot: BlackboardSpaceSnapshot? = nil,
        subscriptionID: BlackboardSubscriptionID? = nil,
        errorCode: BlackboardProtocolErrorCode? = nil
    ) {
        self.version = version
        self.kind = kind
        self.spaceID = spaceID
        self.cursor = cursor
        self.limit = limit
        self.operations = operations
        self.snapshot = snapshot
        self.subscriptionID = subscriptionID
        self.errorCode = errorCode
    }
}

public struct BlackboardProtocolLimits: Equatable, Sendable {
    public let maximumPayloadBytes: Int
    public let maximumOperationsPerBatch: Int
    public let maximumIncrementalLimit: UInt32

    public init(
        maximumPayloadBytes: Int = 512 * 1_024,
        maximumOperationsPerBatch: Int = 256,
        maximumIncrementalLimit: UInt32 = 256
    ) {
        precondition(maximumPayloadBytes > 0 && maximumOperationsPerBatch > 0 && maximumIncrementalLimit > 0)
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumOperationsPerBatch = maximumOperationsPerBatch
        self.maximumIncrementalLimit = maximumIncrementalLimit
    }
}

public enum BlackboardCodecError: Error, Equatable, Sendable {
    case wrongChannel
    case discriminatorMismatch
    case unsupportedVersion(UInt16)
    case invalidMessage
    case payloadTooLarge(maximumBytes: Int, actualBytes: Int)
    case resourceLimit
    case malformed
    case noncanonical
}

public struct BlackboardCodec: Sendable {
    public let limits: BlackboardProtocolLimits
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(limits: BlackboardProtocolLimits = BlackboardProtocolLimits()) {
        self.limits = limits
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public func encode(_ message: BlackboardWireMessage) throws -> Data {
        try validate(message)
        let data: Data
        do { data = try encoder.encode(message) }
        catch { throw BlackboardCodecError.malformed }
        guard data.count <= limits.maximumPayloadBytes else {
            throw BlackboardCodecError.payloadTooLarge(maximumBytes: limits.maximumPayloadBytes, actualBytes: data.count)
        }
        return data
    }

    public func decode(envelope: BeakrNetEnvelope) throws -> BlackboardWireMessage {
        guard envelope.channel == .blackboard else { throw BlackboardCodecError.wrongChannel }
        guard envelope.payloadType == BlackboardWireMessage.payloadType else { throw BlackboardCodecError.discriminatorMismatch }
        guard envelope.payload.count <= limits.maximumPayloadBytes else {
            throw BlackboardCodecError.payloadTooLarge(maximumBytes: limits.maximumPayloadBytes, actualBytes: envelope.payload.count)
        }
        let message: BlackboardWireMessage
        do { message = try decoder.decode(BlackboardWireMessage.self, from: envelope.payload) }
        catch { throw BlackboardCodecError.malformed }
        try validate(message)
        guard try encode(message) == envelope.payload else { throw BlackboardCodecError.noncanonical }
        return message
    }

    public func makeEnvelope(
        for message: BlackboardWireMessage,
        sessionID: SessionID,
        sourceNodeID: NodeID,
        destinationNodeID: NodeID,
        messageID: MessageID = MessageID(),
        sequenceNumber: UInt64,
        createdAt: Date,
        deliveryPolicy: DeliveryPolicy
    ) throws -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            messageID: messageID, sessionID: sessionID,
            sourceNodeID: sourceNodeID, destinationNodeID: destinationNodeID,
            sequenceNumber: sequenceNumber, channel: .blackboard,
            representation: .full, deliveryPolicy: deliveryPolicy,
            payloadType: BlackboardWireMessage.payloadType,
            payload: try encode(message), createdAt: createdAt
        )
    }

    private func validate(_ message: BlackboardWireMessage) throws {
        guard message.version == BlackboardWireMessage.currentVersion else {
            throw BlackboardCodecError.unsupportedVersion(message.version)
        }
        guard message.operations.count <= limits.maximumOperationsPerBatch else { throw BlackboardCodecError.resourceLimit }
        if let limit = message.limit, limit == 0 || limit > limits.maximumIncrementalLimit {
            throw BlackboardCodecError.resourceLimit
        }
        let valid: Bool = switch message.kind {
        case .snapshotRequest:
            message.cursor == nil && message.limit == nil && message.operations.isEmpty && message.snapshot == nil && message.subscriptionID == nil && message.errorCode == nil
        case .snapshotResponse:
            message.snapshot?.spaceID == message.spaceID && message.cursor == nil && message.limit == nil && message.operations.isEmpty && message.subscriptionID == nil && message.errorCode == nil
        case .incrementalRequest:
            message.cursor != nil && message.limit != nil && message.operations.isEmpty && message.snapshot == nil && message.subscriptionID == nil && message.errorCode == nil
        case .incrementalResponse:
            message.cursor != nil && message.limit == nil && message.snapshot == nil && message.subscriptionID == nil && message.errorCode == nil && message.operations.allSatisfy { $0.spaceID == message.spaceID }
        case .operationBatch:
            !message.operations.isEmpty && message.cursor == nil && message.limit == nil && message.snapshot == nil && message.subscriptionID == nil && message.errorCode == nil && message.operations.allSatisfy { $0.spaceID == message.spaceID }
        case .subscriptionRequest, .subscriptionCancellation:
            message.subscriptionID != nil && message.cursor == nil && message.limit == nil && message.operations.isEmpty && message.snapshot == nil && message.errorCode == nil
        case .protocolError:
            message.errorCode != nil && message.limit == nil && message.operations.isEmpty && message.snapshot == nil && message.subscriptionID == nil
        }
        guard valid else { throw BlackboardCodecError.invalidMessage }
    }
}
