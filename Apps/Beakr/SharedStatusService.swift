import Foundation
import BeakrNetCore
import BeakrNetData
import BeakrNetHost

/// Product schema. No addresses, peer identities, history or authority state are shared.
nonisolated struct SharedStatusSnapshot: Codable, Equatable, Sendable {
    enum RuntimeState: String, Codable, Sendable {
        case starting, running, stopping, stopped, failed
    }

    let schemaVersion: Int
    let sampledAt: Date
    let applicationVersion: String
    let runtimeState: RuntimeState
    let authenticatedPeerCount: Int

    func validate() throws {
        guard schemaVersion == 1, sampledAt.timeIntervalSince1970.isFinite,
              !applicationVersion.isEmpty, applicationVersion.utf8.count <= 128,
              authenticatedPeerCount >= 0 else { throw SharedStatusError.invalidResponse }
    }
}

/// Supplied only by trusted composition after admission. IDs are bindings, not credentials.
/// One instance represents one peer session in one selected runtime generation.
nonisolated struct SharedStatusBinding: Equatable, Sendable {
    let runtimeID: UUID
    let networkID: NetworkID
    let localNodeID: NodeID
    let peerNodeID: NodeID
    let sessionID: SessionID

    func accepts(_ envelope: BeakrNetEnvelope, authenticatedPeer: NodeID) -> Bool {
        authenticatedPeer == peerNodeID && envelope.sourceNodeID == authenticatedPeer
            && envelope.networkID == networkID && envelope.destinationNodeID == localNodeID
            && envelope.sessionID == sessionID
    }
}

nonisolated enum SharedStatusError: Error, Equatable, Sendable {
    case unauthorized, unavailable, busy, timedOut, cancelled, invalidated, invalidResponse
    case remote(DataApplicationErrorCode)
}

nonisolated struct SharedStatusEvent: Equatable, Sendable {
    enum Stage: String, Sendable { case request, authorization, reply, completion }
    enum Outcome: String, Sendable {
        case began, allowed, denied, completed, ignored, failed, timedOut, cancelled, invalidated
    }
    let runtimeID: UUID
    let correlationID: DataCorrelationID?
    let stage: Stage
    let outcome: Outcome
    let elapsed: Duration?
    var failure: SharedStatusError? = nil
}

nonisolated enum SharedStatusProtocol {
    static let operation = DataOperation(namespace: "beakr.status", name: "read", version: 1)
    static let timeout: Duration = .seconds(10)
    static let lifetime: TimeInterval = 10
    static let codec = DataCodec(limits: DataProtocolLimits(
        maximumPayloadBytes: 8 * 1_024, maximumBodyBytes: 4 * 1_024,
        maximumResponseBodyBytes: 4 * 1_024
    ))

    static func encode(_ snapshot: SharedStatusSnapshot) throws -> Data {
        try snapshot.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let body = try encoder.encode(snapshot)
        guard body.count <= 4 * 1_024 else { throw SharedStatusError.invalidResponse }
        return body
    }

    static func decode(_ body: Data) throws -> SharedStatusSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(SharedStatusSnapshot.self, from: body)
        try snapshot.validate()
        return snapshot
    }

    static func envelope(_ message: DataMessage, binding: SharedStatusBinding,
                         sequence: UInt64, now: Date, expiresAt: Date) throws -> BeakrNetEnvelope {
        try codec.makeEnvelope(
            for: message, networkID: binding.networkID, sessionID: binding.sessionID,
            sourceNodeID: binding.localNodeID, destinationNodeID: binding.peerNodeID,
            sequenceNumber: sequence, createdAt: now,
            deliveryPolicy: DeliveryPolicy(durability: .ephemeral, expiresAt: expiresAt)
        )
    }
}

private actor SharedStatusHandler: DataMessageHandler {
    let sample: @Sendable () async throws -> SharedStatusSnapshot

    init(sample: @escaping @Sendable () async throws -> SharedStatusSnapshot) { self.sample = sample }

    func handle(_ message: DataMessage, envelope: BeakrNetEnvelope) async throws -> DataMessage? {
        DataMessage(kind: .response, operation: SharedStatusProtocol.operation,
                    correlationID: message.correlationID,
                    body: try SharedStatusProtocol.encode(await sample()))
    }
}

/// Restricted responder used behind the selected runtime's authenticated receive path.
/// The provider is read-only and receives no requester-selected resource or path.
actor SharedStatusResponder {
    private let binding: SharedStatusBinding
    private let dispatcher: DataDispatcher
    private let clock: @Sendable () -> Date
    private let eventSink: @Sendable (SharedStatusEvent) -> Void
    private var enabled: Bool
    private var active = true
    private var revision: UInt64 = 0
    private var busy = false

    init(binding: SharedStatusBinding, enabled: Bool = false,
         clock: @escaping @Sendable () -> Date = Date.init,
         eventSink: @escaping @Sendable (SharedStatusEvent) -> Void = { _ in },
         sample: @escaping @Sendable () async throws -> SharedStatusSnapshot) {
        self.binding = binding
        self.enabled = enabled
        self.clock = clock
        self.eventSink = eventSink
        dispatcher = DataDispatcher(
            codec: SharedStatusProtocol.codec,
            authorization: DataAuthorizationPolicy { source, operation, kind in
                source == binding.peerNodeID && operation == SharedStatusProtocol.operation && kind == .request
            },
            supportedOperations: [SharedStatusProtocol.operation], maximumTrackedMessages: 64,
            handler: SharedStatusHandler(sample: sample), clock: clock
        )
    }

    func setEnabled(_ enabled: Bool) {
        revision &+= 1
        self.enabled = enabled
    }

    func invalidate() {
        active = false
        revision &+= 1
    }

    /// Call only after authenticated transport/session acceptance. This is not a TLS verifier.
    func receive(_ envelope: BeakrNetEnvelope, authenticatedPeer: NodeID) async -> DataMessage? {
        guard active, binding.accepts(envelope, authenticatedPeer: authenticatedPeer) else { return nil }
        guard (try? envelope.validate(now: clock())) != nil,
              envelope.deliveryPolicy.durability == .ephemeral,
              let message = try? SharedStatusProtocol.codec.decode(envelope: envelope),
              message.kind == .request else { return nil }
        func error(_ code: DataApplicationErrorCode) -> DataMessage {
            DataMessage(kind: .applicationError, operation: message.operation,
                        correlationID: message.correlationID, errorCode: code)
        }
        eventSink(SharedStatusEvent(runtimeID: binding.runtimeID, correlationID: message.correlationID,
                                   stage: .authorization, outcome: enabled ? .allowed : .denied, elapsed: nil))
        guard enabled else { return error(.unauthorized) }
        guard message.operation == SharedStatusProtocol.operation else { return error(.unsupportedOperation) }
        guard message.body.isEmpty, message.idempotencyKey == nil,
              let deadline = message.deadline, let expiry = envelope.deliveryPolicy.expiresAt,
              // Data deadlines are encoded in milliseconds; an envelope may still
              // hold the original higher-precision Date before transport encoding.
              expiry.timeIntervalSince(deadline) <= 0.001, deadline > clock(),
              deadline.timeIntervalSince(clock()) <= SharedStatusProtocol.lifetime else {
            return error(.invalidRequest)
        }
        guard !busy else { return error(.resourceLimit) }
        busy = true
        let admittedRevision = revision
        defer { busy = false }
        let result = await dispatcher.dispatch(envelope)
        // Permission withdrawal or runtime replacement during an await suppresses disclosure.
        guard active, enabled, revision == admittedRevision else { return nil }
        guard clock() < deadline, clock() < expiry else { return error(.deadlineExceeded) }
        switch result {
        case .handled(let response), .rejected(_, let response): return response
        }
    }
}

nonisolated struct SharedStatusResult: Equatable, Sendable {
    let snapshot: SharedStatusSnapshot
    let binding: SharedStatusBinding
    let correlationID: DataCorrelationID
    let receivedAt: Date
    let elapsed: Duration
}

/// One pending request per bound peer; no durable enqueue, replay or offline restart recovery.
actor SharedStatusClient {
    typealias Send = @Sendable (BeakrNetEnvelope) async throws -> HostDeliveryAttempt
    private struct Pending {
        let id: DataCorrelationID
        let began: Duration
        let continuation: CheckedContinuation<SharedStatusResult, any Error>
        var sending: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }

    private let binding: SharedStatusBinding
    private let clock: @Sendable () -> Date
    private let elapsed: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let eventSink: @Sendable (SharedStatusEvent) -> Void
    private var pending: Pending?
    private var active = true
    private var enabled: Bool

    init(binding: SharedStatusBinding, enabled: Bool = false,
         clock: @escaping @Sendable () -> Date = Date.init,
         elapsed: (@Sendable () -> Duration)? = nil,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         eventSink: @escaping @Sendable (SharedStatusEvent) -> Void = { _ in }) {
        self.binding = binding
        self.enabled = enabled
        self.clock = clock
        let origin = ContinuousClock.now
        self.elapsed = elapsed ?? { origin.duration(to: .now) }
        self.sleep = sleep
        self.eventSink = eventSink
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { finish(.failure(.unauthorized)) }
    }

    func invalidate() {
        active = false
        finish(.failure(.invalidated))
    }

    func disconnected() { finish(.failure(.unavailable)) }

    /// The trusted runtime supplies its sequence number and an immediate, admitted route.
    func request(sequence: UInt64, send: @escaping Send) async throws -> SharedStatusResult {
        guard active else { throw SharedStatusError.invalidated }
        guard enabled else { throw SharedStatusError.unauthorized }
        guard pending == nil else { throw SharedStatusError.busy }
        guard !Task.isCancelled else { throw SharedStatusError.cancelled }
        let id = DataCorrelationID()
        let now = clock()
        let deadline = now.addingTimeInterval(SharedStatusProtocol.lifetime)
        let envelope = try SharedStatusProtocol.envelope(
            DataMessage(kind: .request, operation: SharedStatusProtocol.operation,
                        correlationID: id, deadline: deadline),
            binding: binding, sequence: sequence, now: now, expiresAt: deadline
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = Pending(id: id, began: elapsed(), continuation: continuation)
                eventSink(SharedStatusEvent(runtimeID: binding.runtimeID, correlationID: id,
                                           stage: .request, outcome: .began, elapsed: nil))
                pending?.timer = Task { [sleep] in
                    do {
                        try await sleep(SharedStatusProtocol.timeout)
                        self.timeout(id)
                    } catch {
                        if !Task.isCancelled { self.fail(id, error: .unavailable) }
                    }
                }
                pending?.sending = Task {
                    do {
                        guard !Task.isCancelled else { return }
                        if try await send(envelope) == .routeUnavailable { self.fail(id, error: .unavailable) }
                    } catch { self.fail(id, error: .unavailable) }
                }
            }
        } onCancel: {
            Task { await self.fail(id, error: .cancelled) }
        }
    }

    /// A matching reply is required; a delivery acknowledgement never completes a request.
    func receive(_ envelope: BeakrNetEnvelope, authenticatedPeer: NodeID) {
        guard let pending else { return }
        guard active, enabled, binding.accepts(envelope, authenticatedPeer: authenticatedPeer),
              (try? envelope.validate(now: clock())) != nil,
              envelope.deliveryPolicy.durability == .ephemeral,
              let message = try? SharedStatusProtocol.codec.decode(envelope: envelope),
              message.operation == SharedStatusProtocol.operation,
              message.correlationID == pending.id,
              message.kind == .response || message.kind == .applicationError else {
            eventSink(SharedStatusEvent(runtimeID: binding.runtimeID, correlationID: pending.id,
                                       stage: .reply, outcome: .ignored, elapsed: nil))
            return
        }
        let duration = elapsed() - pending.began
        guard duration < SharedStatusProtocol.timeout else { timeout(pending.id); return }
        if let code = message.errorCode { finish(.failure(.remote(code))); return }
        do {
            let snapshot = try SharedStatusProtocol.decode(message.body)
            finish(.success(SharedStatusResult(snapshot: snapshot, binding: binding,
                                               correlationID: pending.id, receivedAt: clock(), elapsed: duration)))
        } catch { finish(.failure(.invalidResponse)) }
    }

    private func timeout(_ id: DataCorrelationID) { fail(id, error: .timedOut) }

    private func fail(_ id: DataCorrelationID, error: SharedStatusError) {
        guard pending?.id == id else { return }
        finish(.failure(error))
    }

    private func finish(_ result: Result<SharedStatusResult, SharedStatusError>) {
        guard let current = pending else { return }
        pending = nil
        current.timer?.cancel()
        current.sending?.cancel()
        let outcome: SharedStatusEvent.Outcome
        switch result {
        case .success: outcome = .completed
        case .failure(.timedOut): outcome = .timedOut
        case .failure(.cancelled): outcome = .cancelled
        case .failure(.invalidated): outcome = .invalidated
        case .failure: outcome = .failed
        }
        let failure: SharedStatusError?
        if case .failure(let error) = result { failure = error } else { failure = nil }
        eventSink(SharedStatusEvent(runtimeID: binding.runtimeID, correlationID: current.id,
                                   stage: .completion, outcome: outcome, elapsed: elapsed() - current.began,
                                   failure: failure))
        current.continuation.resume(with: result.mapError { $0 as any Error })
    }
}
