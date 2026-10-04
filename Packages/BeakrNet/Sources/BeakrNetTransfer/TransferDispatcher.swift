import Foundation
import BeakrNetCore

public struct TransferAuthorizationPolicy: Sendable {
    public typealias Decision = @Sendable (NodeID, TransferID, TransferMessageKind) -> Bool
    private let decision: Decision
    public init(_ decision: @escaping Decision) { self.decision = decision }
    public func permits(source: NodeID, transferID: TransferID, kind: TransferMessageKind) -> Bool { decision(source, transferID, kind) }
    public static let allowAuthenticatedPeer = TransferAuthorizationPolicy { _, _, _ in true }
}

public enum TransferDispatchResult: Equatable, Sendable {
    case handled(response: TransferWireMessage?)
    case rejected(TransferProtocolErrorCode, response: TransferWireMessage?)
}

public actor TransferDispatcher {
    public typealias Publication = @Sendable (TransferManifest, URL) async throws -> Void
    private let codec: TransferCodec
    private let store: TransferStagingStore
    private let authorization: TransferAuthorizationPolicy
    private let clock: @Sendable () -> Date
    private let publication: Publication

    public init(codec: TransferCodec = TransferCodec(), store: TransferStagingStore,
                authorization: TransferAuthorizationPolicy = .allowAuthenticatedPeer,
                clock: @escaping @Sendable () -> Date = Date.init,
                publication: @escaping Publication = { _, _ in }) {
        self.codec = codec; self.store = store; self.authorization = authorization
        self.clock = clock; self.publication = publication
    }

    public func dispatch(_ envelope: BeakrNetEnvelope) async -> TransferDispatchResult {
        let message: TransferWireMessage
        do { message = try codec.decode(envelope: envelope) }
        catch let error as TransferCodecError { return reject(nil, id: TransferID(), code: map(error), respond: false) }
        catch { return reject(nil, id: TransferID(), code: .malformed, respond: false) }
        guard authorization.permits(source: envelope.sourceNodeID, transferID: message.transferID, kind: message.kind) else {
            return reject(message, id: message.transferID, code: .unauthorized, respond: message.kind != .protocolError)
        }
        do {
            switch message.kind {
            case .manifest:
                try await store.admit(message.manifest!, now: clock())
                return .handled(response: .init(kind: .resumeResponse, transferID: message.transferID,
                                                missingRanges: try await store.missingRanges(for: message.transferID)))
            case .chunk:
                _ = try await store.receive(message.chunk!, now: clock())
                return .handled(response: nil)
            case .resumeRequest:
                return .handled(response: .init(kind: .resumeResponse, transferID: message.transferID,
                                                missingRanges: try await store.missingRanges(for: message.transferID)))
            case .cancellation:
                try await store.cancel(message.transferID); return .handled(response: nil)
            case .completion:
                let manifest = try await store.manifest(for: message.transferID)
                let url = try await store.finalize(message.transferID)
                try await publication(manifest, url)
                return .handled(response: nil)
            case .resumeResponse: return .handled(response: nil)
            case .protocolError: return .handled(response: nil)
            }
        } catch let error as TransferStagingError {
            return reject(message, id: message.transferID, code: map(error), respond: message.kind != .protocolError)
        } catch { return reject(message, id: message.transferID, code: .malformed, respond: false) }
    }

    private func reject(_ message: TransferWireMessage?, id: TransferID, code: TransferProtocolErrorCode, respond: Bool) -> TransferDispatchResult {
        guard respond else { return .rejected(code, response: nil) }
        return .rejected(code, response: .init(kind: .protocolError, transferID: id, errorCode: code))
    }
    private func map(_ error: TransferCodecError) -> TransferProtocolErrorCode {
        switch error { case .resourceLimit: .resourceLimit; default: .malformed }
    }
    private func map(_ error: TransferStagingError) -> TransferProtocolErrorCode {
        switch error {
        case .unknownTransfer: .unknownTransfer
        case .storageLimit: .resourceLimit
        case .expired: .expired
        case .integrityFailure, .invalidChunk, .conflictingChunk: .integrityFailure
        default: .malformed
        }
    }
}
