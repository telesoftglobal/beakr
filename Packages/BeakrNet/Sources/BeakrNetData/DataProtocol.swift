import Foundation
import BeakrNetCore

public struct DataCorrelationID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public struct DataIdempotencyKey: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public struct DataOperation: Codable, Equatable, Hashable, Sendable {
    public let namespace: String
    public let name: String
    public let version: UInt16

    public init(namespace: String, name: String, version: UInt16) {
        self.namespace = namespace
        self.name = name
        self.version = version
    }
}

public enum DataMessageKind: String, Codable, CaseIterable, Sendable {
    case message
    case request
    case response
    case cancellation
    case applicationError = "application-error"
}

public enum DataApplicationErrorCode: String, Codable, Sendable {
    case unsupportedOperation = "unsupported-operation"
    case unauthorized
    case invalidRequest = "invalid-request"
    case deadlineExceeded = "deadline-exceeded"
    case cancelled
    case conflict
    case resourceLimit = "resource-limit"
    case handlerFailure = "handler-failure"
}

public struct DataMessage: Codable, Equatable, Sendable {
    public static let payloadType = "application/vnd.beakrnet.data+json"
    public static let currentVersion: UInt16 = 1

    public let version: UInt16
    public let kind: DataMessageKind
    public let operation: DataOperation
    public let correlationID: DataCorrelationID
    public let idempotencyKey: DataIdempotencyKey?
    public let deadline: Date?
    public let body: Data
    public let errorCode: DataApplicationErrorCode?

    public init(
        version: UInt16 = Self.currentVersion,
        kind: DataMessageKind,
        operation: DataOperation,
        correlationID: DataCorrelationID,
        idempotencyKey: DataIdempotencyKey? = nil,
        deadline: Date? = nil,
        body: Data = Data(),
        errorCode: DataApplicationErrorCode? = nil
    ) {
        self.version = version
        self.kind = kind
        self.operation = operation
        self.correlationID = correlationID
        self.idempotencyKey = idempotencyKey
        self.deadline = deadline
        self.body = body
        self.errorCode = errorCode
    }
}

public enum DataCodecError: Error, Equatable, Sendable {
    case wrongChannel
    case discriminatorMismatch
    case unsupportedVersion(UInt16)
    case invalidOperation
    case invalidMetadata
    case payloadTooLarge(maximumBytes: Int, actualBytes: Int)
    case bodyTooLarge(maximumBytes: Int, actualBytes: Int)
    case malformed
    case noncanonical
}

public struct DataProtocolLimits: Equatable, Sendable {
    public let maximumPayloadBytes: Int
    public let maximumBodyBytes: Int
    public let maximumResponseBodyBytes: Int
    public let maximumOperationComponentBytes: Int

    public init(
        maximumPayloadBytes: Int = 256 * 1_024,
        maximumBodyBytes: Int = 192 * 1_024,
        maximumResponseBodyBytes: Int = 192 * 1_024,
        maximumOperationComponentBytes: Int = 128
    ) {
        precondition(maximumPayloadBytes > 0 && maximumBodyBytes >= 0 && maximumResponseBodyBytes >= 0)
        precondition(maximumOperationComponentBytes > 0)
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumResponseBodyBytes = maximumResponseBodyBytes
        self.maximumOperationComponentBytes = maximumOperationComponentBytes
    }
}

public struct DataCodec: Sendable {
    public let limits: DataProtocolLimits
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(limits: DataProtocolLimits = DataProtocolLimits()) {
        self.limits = limits
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public func encode(_ message: DataMessage) throws -> Data {
        try validate(message)
        let encoded: Data
        do { encoded = try encoder.encode(message) }
        catch { throw DataCodecError.malformed }
        guard encoded.count <= limits.maximumPayloadBytes else {
            throw DataCodecError.payloadTooLarge(maximumBytes: limits.maximumPayloadBytes, actualBytes: encoded.count)
        }
        return encoded
    }

    public func decode(envelope: BeakrNetEnvelope) throws -> DataMessage {
        guard envelope.channel == .data else { throw DataCodecError.wrongChannel }
        guard envelope.payloadType == DataMessage.payloadType else { throw DataCodecError.discriminatorMismatch }
        guard envelope.payload.count <= limits.maximumPayloadBytes else {
            throw DataCodecError.payloadTooLarge(maximumBytes: limits.maximumPayloadBytes, actualBytes: envelope.payload.count)
        }
        let message: DataMessage
        do { message = try decoder.decode(DataMessage.self, from: envelope.payload) }
        catch { throw DataCodecError.malformed }
        try validate(message)
        guard try encode(message) == envelope.payload else { throw DataCodecError.noncanonical }
        return message
    }

    public func makeEnvelope(
        for message: DataMessage,
        networkID: NetworkID,
        sessionID: SessionID,
        sourceNodeID: NodeID,
        destinationNodeID: NodeID,
        messageID: MessageID = MessageID(),
        sequenceNumber: UInt64,
        createdAt: Date,
        deliveryPolicy: DeliveryPolicy
    ) throws -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            messageID: messageID,
            networkID: networkID,
            sessionID: sessionID,
            sourceNodeID: sourceNodeID,
            destinationNodeID: destinationNodeID,
            sequenceNumber: sequenceNumber,
            channel: .data,
            representation: .full,
            deliveryPolicy: deliveryPolicy,
            payloadType: DataMessage.payloadType,
            payload: try encode(message),
            createdAt: createdAt
        )
    }

    private func validate(_ message: DataMessage) throws {
        guard message.version == DataMessage.currentVersion else { throw DataCodecError.unsupportedVersion(message.version) }
        guard validComponent(message.operation.namespace), validComponent(message.operation.name), message.operation.version > 0 else {
            throw DataCodecError.invalidOperation
        }
        let bodyLimit = message.kind == .response ? limits.maximumResponseBodyBytes : limits.maximumBodyBytes
        guard message.body.count <= bodyLimit else {
            throw DataCodecError.bodyTooLarge(maximumBytes: bodyLimit, actualBytes: message.body.count)
        }
        switch message.kind {
        case .message, .request:
            guard message.errorCode == nil else { throw DataCodecError.invalidMetadata }
        case .response:
            guard message.idempotencyKey == nil, message.errorCode == nil else { throw DataCodecError.invalidMetadata }
        case .cancellation:
            guard message.idempotencyKey == nil, message.errorCode == nil, message.body.isEmpty else { throw DataCodecError.invalidMetadata }
        case .applicationError:
            guard message.idempotencyKey == nil, message.errorCode != nil else { throw DataCodecError.invalidMetadata }
        }
    }

    private func validComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= limits.maximumOperationComponentBytes else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
        }
    }
}

public struct DataAuthorizationPolicy: Sendable {
    public typealias Decision = @Sendable (NodeID, DataOperation, DataMessageKind) -> Bool
    private let decision: Decision

    public init(_ decision: @escaping Decision) { self.decision = decision }
    public func permits(source: NodeID, operation: DataOperation, kind: DataMessageKind) -> Bool {
        decision(source, operation, kind)
    }
    public static let allowAuthenticatedPeer = DataAuthorizationPolicy { _, _, _ in true }
}

public protocol DataMessageHandler: Sendable {
    func handle(_ message: DataMessage, envelope: BeakrNetEnvelope) async throws -> DataMessage?
}

public enum DataDispatchRejection: String, Codable, Equatable, Sendable {
    case malformed
    case unsupportedVersion = "unsupported-version"
    case unsupportedOperation = "unsupported-operation"
    case unauthorized
    case expired
    case cancelled
    case duplicate
    case resourceLimit = "resource-limit"
    case handlerFailure = "handler-failure"
}

public enum DataDispatchResult: Equatable, Sendable {
    case handled(response: DataMessage?)
    case rejected(DataDispatchRejection, response: DataMessage?)
}

public enum DataDiagnosticEvent: Equatable, Sendable {
    case accepted(messageID: MessageID, operation: DataOperation, kind: DataMessageKind)
    case rejected(messageID: MessageID, reason: DataDispatchRejection)
    case handlerFailed(messageID: MessageID, operation: DataOperation)
}

public actor DataDispatcher {
    public typealias Clock = @Sendable () -> Date
    public typealias EventSink = @Sendable (DataDiagnosticEvent) -> Void

    private let codec: DataCodec
    private let authorization: DataAuthorizationPolicy
    private let supportedOperations: Set<DataOperation>
    private let maximumTrackedMessages: Int
    private let handler: any DataMessageHandler
    private let persistentState: PersistentDataState?
    private let cancellations: DataCancellationRegistry
    private let clock: Clock
    private let eventSink: EventSink
    private var seenOrder: [MessageID] = []
    private var seen: Set<MessageID> = []
    private enum StoredResult: Sendable {
        case noResponse
        case response(DataMessage)
    }

    private var mutationResults: [DataIdempotencyKey: StoredResult] = [:]

    public init(
        codec: DataCodec = DataCodec(),
        authorization: DataAuthorizationPolicy = .allowAuthenticatedPeer,
        supportedOperations: Set<DataOperation>,
        maximumTrackedMessages: Int = 4_096,
        persistentState: PersistentDataState? = nil,
        cancellations: DataCancellationRegistry = DataCancellationRegistry(),
        handler: any DataMessageHandler,
        clock: @escaping Clock = Date.init,
        eventSink: @escaping EventSink = { _ in }
    ) {
        precondition(maximumTrackedMessages > 0)
        self.codec = codec
        self.authorization = authorization
        self.supportedOperations = supportedOperations
        self.maximumTrackedMessages = maximumTrackedMessages
        self.handler = handler
        self.persistentState = persistentState
        self.cancellations = cancellations
        self.clock = clock
        self.eventSink = eventSink
    }

    public func dispatch(_ envelope: BeakrNetEnvelope) async -> DataDispatchResult {
        let message: DataMessage
        do { message = try codec.decode(envelope: envelope) }
        catch let error as DataCodecError {
            return reject(envelope.messageID, map(error), message: nil)
        } catch { return reject(envelope.messageID, .malformed, message: nil) }

        guard supportedOperations.contains(message.operation) else {
            return reject(envelope.messageID, .unsupportedOperation, message: message)
        }
        guard authorization.permits(source: envelope.sourceNodeID, operation: message.operation, kind: message.kind) else {
            return reject(envelope.messageID, .unauthorized, message: message)
        }
        if let deadline = message.deadline, deadline <= clock() {
            return reject(envelope.messageID, .expired, message: message)
        }
        if message.kind == .request, await cancellations.contains(message.correlationID) {
            return reject(envelope.messageID, .cancelled, message: message)
        }
        if let stored = await persistentState?.result(for: envelope.messageID) {
            return .handled(response: stored.response)
        }
        if let key = message.idempotencyKey, let stored = await persistentState?.result(for: key) {
            return .handled(response: stored.response)
        }
        guard !seen.contains(envelope.messageID) else {
            return reject(envelope.messageID, .duplicate, message: nil)
        }
        remember(envelope.messageID)

        if message.kind == .cancellation {
            await cancellations.insert(message.correlationID)
        }

        if let key = message.idempotencyKey, let stored = mutationResults[key] {
            switch stored {
            case .noResponse: return .handled(response: nil)
            case .response(let response): return .handled(response: response)
            }
        }
        do {
            let response = try await handler.handle(message, envelope: envelope)
            if let response {
                guard (response.kind == .response || response.kind == .applicationError),
                      response.operation == message.operation,
                      response.correlationID == message.correlationID else {
                    eventSink(.handlerFailed(messageID: envelope.messageID, operation: message.operation))
                    return reject(envelope.messageID, .handlerFailure, message: message)
                }
                do { _ = try codec.encode(response) }
                catch {
                    eventSink(.handlerFailed(messageID: envelope.messageID, operation: message.operation))
                    return reject(envelope.messageID, .resourceLimit, message: message)
                }
            }
            if let key = message.idempotencyKey {
                mutationResults[key] = response.map(StoredResult.response) ?? .noResponse
            }
            if let persistentState {
                do {
                    try await persistentState.record(StoredDataResult(
                        messageID: envelope.messageID,
                        idempotencyKey: message.idempotencyKey,
                        response: response,
                        completedAt: clock()
                    ))
                } catch {
                    eventSink(.handlerFailed(messageID: envelope.messageID, operation: message.operation))
                    return reject(envelope.messageID, .handlerFailure, message: message)
                }
            }
            eventSink(.accepted(messageID: envelope.messageID, operation: message.operation, kind: message.kind))
            return .handled(response: response)
        } catch {
            eventSink(.handlerFailed(messageID: envelope.messageID, operation: message.operation))
            return reject(envelope.messageID, .handlerFailure, message: message)
        }
    }

    private func remember(_ messageID: MessageID) {
        seen.insert(messageID)
        seenOrder.append(messageID)
        if seenOrder.count > maximumTrackedMessages { seen.remove(seenOrder.removeFirst()) }
    }

    private func map(_ error: DataCodecError) -> DataDispatchRejection {
        switch error {
        case .unsupportedVersion: .unsupportedVersion
        case .payloadTooLarge, .bodyTooLarge: .resourceLimit
        default: .malformed
        }
    }

    private func reject(_ id: MessageID, _ reason: DataDispatchRejection, message: DataMessage?) -> DataDispatchResult {
        eventSink(.rejected(messageID: id, reason: reason))
        guard let message, message.kind == .request else { return .rejected(reason, response: nil) }
        let code: DataApplicationErrorCode = switch reason {
        case .unsupportedOperation: .unsupportedOperation
        case .unauthorized: .unauthorized
        case .expired: .deadlineExceeded
        case .cancelled: .cancelled
        case .resourceLimit: .resourceLimit
        case .handlerFailure: .handlerFailure
        default: .invalidRequest
        }
        let response = DataMessage(
            kind: .applicationError,
            operation: message.operation,
            correlationID: message.correlationID,
            body: Data(),
            errorCode: code
        )
        return .rejected(reason, response: response)
    }
}

public actor DataCancellationRegistry {
    private let maximumEntries: Int
    private var order: [DataCorrelationID] = []
    private var entries: Set<DataCorrelationID> = []

    public init(maximumEntries: Int = 4_096) {
        precondition(maximumEntries > 0)
        self.maximumEntries = maximumEntries
    }

    public func insert(_ correlationID: DataCorrelationID) {
        guard entries.insert(correlationID).inserted else { return }
        order.append(correlationID)
        if order.count > maximumEntries { entries.remove(order.removeFirst()) }
    }

    public func contains(_ correlationID: DataCorrelationID) -> Bool { entries.contains(correlationID) }

    public func remove(_ correlationID: DataCorrelationID) {
        entries.remove(correlationID)
        order.removeAll { $0 == correlationID }
    }
}
