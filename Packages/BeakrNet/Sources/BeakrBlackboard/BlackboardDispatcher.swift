import Foundation
import BeakrNetCore

public enum BlackboardDispatchResult: Equatable, Sendable {
    case handled(response: BlackboardWireMessage?)
    case rejected(BlackboardProtocolErrorCode, response: BlackboardWireMessage?)
}

public actor BlackboardDispatcher {
    private let codec: BlackboardCodec
    private let repository: BlackboardRepository
    private let maximumTrackedMessages: Int
    private var replayOrder: [MessageID] = []
    private var replaySet: Set<MessageID> = []

    public init(
        codec: BlackboardCodec = BlackboardCodec(),
        repository: BlackboardRepository,
        maximumTrackedMessages: Int = 4_096
    ) {
        precondition(maximumTrackedMessages > 0)
        self.codec = codec
        self.repository = repository
        self.maximumTrackedMessages = maximumTrackedMessages
    }

    public func dispatch(_ envelope: BeakrNetEnvelope) async -> BlackboardDispatchResult {
        let message: BlackboardWireMessage
        do { message = try codec.decode(envelope: envelope) }
        catch let error as BlackboardCodecError { return reject(envelope, code: map(error), mayRespond: true) }
        catch { return reject(envelope, code: .malformed, mayRespond: false) }
        guard !replaySet.contains(envelope.messageID) else { return .handled(response: nil) }
        remember(envelope.messageID)
        do {
            switch message.kind {
            case .snapshotRequest:
                let snapshot = try await repository.snapshot(spaceID: message.spaceID, authorizedNodeID: envelope.sourceNodeID)
                return .handled(response: .init(kind: .snapshotResponse, spaceID: message.spaceID, snapshot: snapshot))
            case .incrementalRequest:
                let incremental = try await repository.incremental(
                    spaceID: message.spaceID, after: message.cursor!, limit: Int(message.limit!),
                    authorizedNodeID: envelope.sourceNodeID
                )
                return .handled(response: .init(kind: .incrementalResponse, spaceID: message.spaceID,
                                                cursor: incremental.cursor, operations: incremental.operations))
            case .operationBatch:
                _ = try await repository.applyBatch(message.operations, authorizedNodeID: envelope.sourceNodeID)
                return .handled(response: nil)
            case .subscriptionRequest:
                _ = try await repository.subscribe(id: message.subscriptionID!, spaceID: message.spaceID,
                                                   authorizedNodeID: envelope.sourceNodeID) { _ in }
                return .handled(response: nil)
            case .subscriptionCancellation:
                await repository.cancelSubscription(message.subscriptionID!)
                return .handled(response: nil)
            case .snapshotResponse, .incrementalResponse:
                return .handled(response: nil)
            case .protocolError:
                return .handled(response: nil)
            }
        } catch let error as BlackboardRepositoryError {
            return reject(envelope, code: map(error), mayRespond: message.kind != .protocolError)
        } catch { return reject(envelope, code: .malformed, mayRespond: false) }
    }

    private func remember(_ id: MessageID) {
        replaySet.insert(id); replayOrder.append(id)
        if replayOrder.count > maximumTrackedMessages { replaySet.remove(replayOrder.removeFirst()) }
    }

    private func reject(_ envelope: BeakrNetEnvelope, code: BlackboardProtocolErrorCode, mayRespond: Bool) -> BlackboardDispatchResult {
        guard mayRespond, envelope.payloadType != BlackboardWireMessage.payloadType ||
                (try? codec.decode(envelope: envelope).kind) != .protocolError else {
            return .rejected(code, response: nil)
        }
        return .rejected(code, response: .init(kind: .protocolError,
                                               spaceID: (try? codec.decode(envelope: envelope).spaceID) ?? BlackboardSpaceID(),
                                               errorCode: code))
    }

    private func map(_ error: BlackboardCodecError) -> BlackboardProtocolErrorCode {
        switch error {
        case .unsupportedVersion: .unsupportedVersion
        case .payloadTooLarge, .resourceLimit: .resourceLimit
        default: .malformed
        }
    }

    private func map(_ error: BlackboardRepositoryError) -> BlackboardProtocolErrorCode {
        switch error {
        case .unauthorized, .unknownSpace: .unauthorized
        case .missingCausalDependency, .causalRollback, .conflictResolutionMismatch, .invalidOperation: .invalidCausality
        case .compactionBoundaryMismatch: .compactionBoundaryMismatch
        case .resourceLimit: .resourceLimit
        default: .malformed
        }
    }
}
