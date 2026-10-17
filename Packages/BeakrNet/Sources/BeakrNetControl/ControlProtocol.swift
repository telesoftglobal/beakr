import Foundation
import BeakrNetCore

public enum ControlMessageType: String, CaseIterable, Codable, Sendable {
    case deliveryAcknowledgement = "beakrnet.delivery-acknowledgement"
    case sessionLiveness = "beakrnet.session-liveness"
    case queuePressure = "beakrnet.queue-pressure"
    case synchronizationHint = "beakrnet.synchronization-hint"
    case protocolError = "beakrnet.protocol-error"
}

public struct ControlContext: Codable, Equatable, Sendable {
    public let networkID: NetworkID
    public let sourceNodeID: NodeID
    public let destinationNodeID: NodeID
    public let sessionID: SessionID

    public init(networkID: NetworkID, sourceNodeID: NodeID, destinationNodeID: NodeID, sessionID: SessionID) {
        self.networkID = networkID
        self.sourceNodeID = sourceNodeID
        self.destinationNodeID = destinationNodeID
        self.sessionID = sessionID
    }
}

public struct ControlHeader: Codable, Equatable, Sendable {
    public let type: ControlMessageType
    public let version: Int
    public let context: ControlContext

    public init(type: ControlMessageType, version: Int = 1, context: ControlContext) {
        self.type = type
        self.version = version
        self.context = context
    }
}

public struct ControlDeliveryAcknowledgement: Codable, Equatable, Sendable {
    public let acknowledgedMessageID: MessageID

    public init(acknowledgedMessageID: MessageID) {
        self.acknowledgedMessageID = acknowledgedMessageID
    }
}

public enum LivenessKind: String, Codable, Sendable { case probe, response }

public struct SessionLiveness: Codable, Equatable, Sendable {
    public let kind: LivenessKind
    public let nonce: UInt64

    public init(kind: LivenessKind, nonce: UInt64) {
        self.kind = kind
        self.nonce = nonce
    }
}

public enum QueuePressureLevel: String, Codable, Sendable { case normal, elevated, critical }

public struct QueuePressure: Codable, Equatable, Sendable {
    public let level: QueuePressureLevel
    public let availableSlots: UInt32
    public let retryAfterMilliseconds: UInt32?

    public init(level: QueuePressureLevel, availableSlots: UInt32, retryAfterMilliseconds: UInt32? = nil) {
        self.level = level
        self.availableSlots = availableSlots
        self.retryAfterMilliseconds = retryAfterMilliseconds
    }
}

public enum SynchronizationScope: String, Codable, Sendable { case data, blackboard }

public struct SynchronizationHint: Codable, Equatable, Sendable {
    public let scope: SynchronizationScope
    public let cursor: String?

    public init(scope: SynchronizationScope, cursor: String? = nil) {
        self.scope = scope
        self.cursor = cursor
    }
}

public enum ControlProtocolErrorCode: String, Codable, Sendable {
    case malformed
    case unsupportedMessage
    case unsupportedVersion
    case unauthorized
    case replayed
    case resourceLimit
}

public struct ControlProtocolError: Codable, Equatable, Sendable {
    public let code: ControlProtocolErrorCode
    public let relatedMessageID: MessageID?

    public init(code: ControlProtocolErrorCode, relatedMessageID: MessageID? = nil) {
        self.code = code
        self.relatedMessageID = relatedMessageID
    }
}

public enum ControlMessage: Equatable, Sendable {
    case deliveryAcknowledgement(ControlHeader, ControlDeliveryAcknowledgement)
    case sessionLiveness(ControlHeader, SessionLiveness)
    case queuePressure(ControlHeader, QueuePressure)
    case synchronizationHint(ControlHeader, SynchronizationHint)
    case protocolError(ControlHeader, ControlProtocolError)

    public var header: ControlHeader {
        switch self {
        case .deliveryAcknowledgement(let header, _), .sessionLiveness(let header, _),
             .queuePressure(let header, _), .synchronizationHint(let header, _),
             .protocolError(let header, _): header
        }
    }

    public var type: ControlMessageType { header.type }
}

private struct WirePayload<Body: Codable & Sendable>: Codable, Sendable {
    let type: String
    let version: Int
    let networkID: NetworkID
    let sourceNodeID: NodeID
    let destinationNodeID: NodeID
    let sessionID: SessionID
    let body: Body
}

private struct WireHeader: Decodable {
    let type: String
    let version: Int
}

public enum ControlCodecError: Error, Equatable, Sendable {
    case payloadTooLarge(maximumBytes: Int, actualBytes: Int)
    case malformed
    case unsupportedMessage(String)
    case unsupportedVersion(type: String, version: Int)
    case discriminatorMismatch(expected: String, actual: String)
    case envelopeMismatch
    case invalidValue
}

public struct ControlCodec: Sendable {
    public static let maximumPayloadBytes = 4 * 1_024
    public static let maximumCursorBytes = 256
    public static let maximumRetryAfterMilliseconds: UInt32 = 300_000

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    public func encode(_ message: ControlMessage) throws -> Data {
        let data: Data
        switch message {
        case .deliveryAcknowledgement(let h, let body): data = try encode(h, body)
        case .sessionLiveness(let h, let body): data = try encode(h, body)
        case .queuePressure(let h, let body): data = try encode(h, body)
        case .synchronizationHint(let h, let body):
            if let cursor = body.cursor, cursor.utf8.count > Self.maximumCursorBytes { throw ControlCodecError.invalidValue }
            data = try encode(h, body)
        case .protocolError(let h, let body): data = try encode(h, body)
        }
        guard data.count <= Self.maximumPayloadBytes else {
            throw ControlCodecError.payloadTooLarge(maximumBytes: Self.maximumPayloadBytes, actualBytes: data.count)
        }
        return data
    }

    public func decode(envelope: BeakrNetEnvelope) throws -> ControlMessage {
        guard envelope.channel == .control else { throw ControlCodecError.envelopeMismatch }
        guard envelope.payload.count <= Self.maximumPayloadBytes else {
            throw ControlCodecError.payloadTooLarge(maximumBytes: Self.maximumPayloadBytes, actualBytes: envelope.payload.count)
        }
        let header: WireHeader
        do { header = try decoder.decode(WireHeader.self, from: envelope.payload) }
        catch { throw ControlCodecError.malformed }
        guard let type = ControlMessageType(rawValue: header.type) else {
            throw ControlCodecError.unsupportedMessage(header.type)
        }
        guard envelope.payloadType == type.rawValue else {
            throw ControlCodecError.discriminatorMismatch(expected: envelope.payloadType, actual: type.rawValue)
        }
        guard header.version == 1 else {
            throw ControlCodecError.unsupportedVersion(type: type.rawValue, version: header.version)
        }
        let message: ControlMessage
        do {
            switch type {
            case .deliveryAcknowledgement:
                let wire: WirePayload<ControlDeliveryAcknowledgement> = try decode(envelope.payload)
                message = .deliveryAcknowledgement(makeHeader(wire, type), wire.body)
            case .sessionLiveness:
                let wire: WirePayload<SessionLiveness> = try decode(envelope.payload)
                message = .sessionLiveness(makeHeader(wire, type), wire.body)
            case .queuePressure:
                let wire: WirePayload<QueuePressure> = try decode(envelope.payload)
                guard wire.body.retryAfterMilliseconds.map({ $0 <= Self.maximumRetryAfterMilliseconds }) ?? true else { throw ControlCodecError.invalidValue }
                message = .queuePressure(makeHeader(wire, type), wire.body)
            case .synchronizationHint:
                let wire: WirePayload<SynchronizationHint> = try decode(envelope.payload)
                guard wire.body.cursor.map({ $0.utf8.count <= Self.maximumCursorBytes }) ?? true else { throw ControlCodecError.invalidValue }
                message = .synchronizationHint(makeHeader(wire, type), wire.body)
            case .protocolError:
                let wire: WirePayload<ControlProtocolError> = try decode(envelope.payload)
                message = .protocolError(makeHeader(wire, type), wire.body)
            }
        } catch let error as ControlCodecError { throw error }
        catch { throw ControlCodecError.malformed }
        guard try encode(message) == envelope.payload else { throw ControlCodecError.malformed }
        return message
    }

    public func makeEnvelope(
        for message: ControlMessage,
        messageID: MessageID = MessageID(),
        sequenceNumber: UInt64,
        createdAt: Date,
        deliveryPolicy: DeliveryPolicy = DeliveryPolicy(durability: .ephemeral)
    ) throws -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            messageID: messageID,
            networkID: message.header.context.networkID,
            sessionID: message.header.context.sessionID,
            sourceNodeID: message.header.context.sourceNodeID,
            destinationNodeID: message.header.context.destinationNodeID,
            sequenceNumber: sequenceNumber,
            channel: .control,
            representation: .full,
            deliveryPolicy: deliveryPolicy,
            payloadType: message.type.rawValue,
            payload: try encode(message),
            createdAt: createdAt
        )
    }

    private func encode<Body: Codable & Sendable>(_ header: ControlHeader, _ body: Body) throws -> Data {
        guard header.version == 1 else { throw ControlCodecError.unsupportedVersion(type: header.type.rawValue, version: header.version) }
        return try encoder.encode(WirePayload(
            type: header.type.rawValue,
            version: header.version,
            networkID: header.context.networkID,
            sourceNodeID: header.context.sourceNodeID,
            destinationNodeID: header.context.destinationNodeID,
            sessionID: header.context.sessionID,
            body: body
        ))
    }

    private func decode<Body: Codable & Sendable>(_ data: Data) throws -> WirePayload<Body> {
        try decoder.decode(WirePayload<Body>.self, from: data)
    }

    private func makeHeader<Body>(_ wire: WirePayload<Body>, _ type: ControlMessageType) -> ControlHeader {
        ControlHeader(type: type, version: wire.version, context: ControlContext(
            networkID: wire.networkID,
            sourceNodeID: wire.sourceNodeID,
            destinationNodeID: wire.destinationNodeID,
            sessionID: wire.sessionID
        ))
    }
}

public struct ControlAuthorizationPolicy: Sendable {
    public typealias Decision = @Sendable (NodeID, ControlMessageType) -> Bool
    private let decision: Decision

    public init(_ decision: @escaping Decision) { self.decision = decision }
    public func permits(source: NodeID, type: ControlMessageType) -> Bool { decision(source, type) }
    public static let allowAuthenticatedPeer = ControlAuthorizationPolicy { _, _ in true }
}

public struct ControlResourcePolicy: Equatable, Sendable {
    public let maximumTrackedReplayIDs: Int
    public let maximumMessagesPerWindow: Int
    public let rateWindow: TimeInterval

    public init(maximumTrackedReplayIDs: Int = 1_024, maximumMessagesPerWindow: Int = 128, rateWindow: TimeInterval = 60) {
        precondition(maximumTrackedReplayIDs > 0 && maximumMessagesPerWindow > 0 && rateWindow > 0)
        self.maximumTrackedReplayIDs = maximumTrackedReplayIDs
        self.maximumMessagesPerWindow = maximumMessagesPerWindow
        self.rateWindow = rateWindow
    }
}

public enum ControlDiagnosticEvent: Equatable, Sendable {
    case accepted(messageID: MessageID, type: ControlMessageType)
    case rejected(messageID: MessageID, reason: ControlProtocolErrorCode)
    case handlerFailed(messageID: MessageID, type: ControlMessageType)
}

public protocol ControlMessageHandler: Sendable {
    func handle(_ message: ControlMessage, envelope: BeakrNetEnvelope) async throws
}

public enum ControlDispatchResult: Equatable, Sendable {
    case handled(ControlMessage)
    case rejected(ControlProtocolErrorCode, response: ControlMessage?)
}

public actor ControlDispatcher {
    public typealias Clock = @Sendable () -> Date
    public typealias EventSink = @Sendable (ControlDiagnosticEvent) -> Void

    private let codec: ControlCodec
    private let authorization: ControlAuthorizationPolicy
    private let resources: ControlResourcePolicy
    private let handler: any ControlMessageHandler
    private let clock: Clock
    private let eventSink: EventSink
    private var replayOrder: [MessageID] = []
    private var replaySet: Set<MessageID> = []
    private var rateWindows: [NodeID: (start: Date, count: Int)] = [:]

    public init(
        codec: ControlCodec = ControlCodec(),
        authorization: ControlAuthorizationPolicy = .allowAuthenticatedPeer,
        resources: ControlResourcePolicy = ControlResourcePolicy(),
        handler: any ControlMessageHandler,
        clock: @escaping Clock = Date.init,
        eventSink: @escaping EventSink = { _ in }
    ) {
        self.codec = codec
        self.authorization = authorization
        self.resources = resources
        self.handler = handler
        self.clock = clock
        self.eventSink = eventSink
    }

    public func dispatch(_ envelope: BeakrNetEnvelope) async -> ControlDispatchResult {
        let message: ControlMessage
        do { message = try codec.decode(envelope: envelope) }
        catch let error as ControlCodecError {
            return reject(envelope, reason: map(error), mayRespond: responseAllowed(for: envelope.payloadType))
        } catch { return reject(envelope, reason: .malformed, mayRespond: false) }

        guard message.header.context == ControlContext(networkID: envelope.networkID, sourceNodeID: envelope.sourceNodeID, destinationNodeID: envelope.destinationNodeID, sessionID: envelope.sessionID) else {
            return reject(envelope, reason: .malformed, mayRespond: mayRespond(to: message))
        }
        guard authorization.permits(source: envelope.sourceNodeID, type: message.type) else {
            return reject(envelope, reason: .unauthorized, mayRespond: mayRespond(to: message))
        }
        guard admitRate(source: envelope.sourceNodeID, now: clock()) else {
            return reject(envelope, reason: .resourceLimit, mayRespond: false)
        }
        guard !replaySet.contains(envelope.messageID) else {
            return reject(envelope, reason: .replayed, mayRespond: false)
        }
        remember(envelope.messageID)

        do { try await handler.handle(message, envelope: envelope) }
        catch {
            eventSink(.handlerFailed(messageID: envelope.messageID, type: message.type))
            return .rejected(.resourceLimit, response: nil)
        }
        eventSink(.accepted(messageID: envelope.messageID, type: message.type))
        return .handled(message)
    }

    private func admitRate(source: NodeID, now: Date) -> Bool {
        var window = rateWindows[source] ?? (now, 0)
        if now.timeIntervalSince(window.start) >= resources.rateWindow { window = (now, 0) }
        guard window.count < resources.maximumMessagesPerWindow else { return false }
        window.count += 1
        rateWindows[source] = window
        return true
    }

    private func remember(_ id: MessageID) {
        replaySet.insert(id); replayOrder.append(id)
        if replayOrder.count > resources.maximumTrackedReplayIDs {
            replaySet.remove(replayOrder.removeFirst())
        }
    }

    private func map(_ error: ControlCodecError) -> ControlProtocolErrorCode {
        switch error {
        case .unsupportedMessage: .unsupportedMessage
        case .unsupportedVersion: .unsupportedVersion
        case .payloadTooLarge, .invalidValue: .resourceLimit
        default: .malformed
        }
    }

    private func responseAllowed(for payloadType: String) -> Bool {
        payloadType != ControlMessageType.deliveryAcknowledgement.rawValue && payloadType != ControlMessageType.protocolError.rawValue
    }

    private func mayRespond(to message: ControlMessage) -> Bool {
        message.type != .deliveryAcknowledgement && message.type != .protocolError
    }

    private func reject(_ envelope: BeakrNetEnvelope, reason: ControlProtocolErrorCode, mayRespond: Bool) -> ControlDispatchResult {
        eventSink(.rejected(messageID: envelope.messageID, reason: reason))
        guard mayRespond else { return .rejected(reason, response: nil) }
        let context = ControlContext(networkID: envelope.networkID, sourceNodeID: envelope.destinationNodeID, destinationNodeID: envelope.sourceNodeID, sessionID: envelope.sessionID)
        return .rejected(reason, response: .protocolError(
            ControlHeader(type: .protocolError, context: context),
            ControlProtocolError(code: reason, relatedMessageID: envelope.messageID)
        ))
    }
}

public extension ControlMessage {
    var coreAcknowledgement: DeliveryAcknowledgement? {
        guard case .deliveryAcknowledgement(let header, let body) = self else { return nil }
        return DeliveryAcknowledgement(networkID: header.context.networkID, sessionID: header.context.sessionID, messageID: body.acknowledgedMessageID)
    }
}
