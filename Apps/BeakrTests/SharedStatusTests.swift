import Foundation
import Testing
import BeakrNetCore
import BeakrNetData
import BeakrNetHost
@testable import Beakr

private nonisolated final class StatusTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero
    func read() -> Duration { lock.withLock { time } }
    func advance() { lock.withLock { time = .seconds(11) } }
}

private actor StatusSampleProbe {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    let entered: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let suspended: Bool

    init(suspended: Bool = false) {
        let stream = AsyncStream<Void>.makeStream()
        entered = stream.stream
        signal = stream.continuation
        self.suspended = suspended
    }

    func sample() async -> SharedStatusSnapshot {
        calls += 1
        if suspended {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                signal.yield(())
            }
        }
        return SharedStatusSnapshot(schemaVersion: 1, sampledAt: Date(timeIntervalSince1970: 1_000),
                                    applicationVersion: "1.0", runtimeState: .running, authenticatedPeerCount: 2)
    }

    func release() { continuation?.resume(); continuation = nil }
}

private actor StatusDataHandler: DataMessageHandler {
    private(set) var calls = 0
    var failOnce: Bool
    init(failOnce: Bool = false) { self.failOnce = failOnce }
    func handle(_ message: DataMessage, envelope: BeakrNetEnvelope) async throws -> DataMessage? {
        calls += 1
        if failOnce { failOnce = false; throw SharedStatusError.unavailable }
        return DataMessage(kind: .response, operation: message.operation, correlationID: message.correlationID,
                           body: Data("result".utf8))
    }
}

private actor SuspendedStatusDataHandler: DataMessageHandler {
    let probe: StatusSampleProbe
    init(probe: StatusSampleProbe) { self.probe = probe }
    func handle(_ message: DataMessage, envelope: BeakrNetEnvelope) async throws -> DataMessage? {
        _ = await probe.sample()
        return DataMessage(kind: .response, operation: message.operation, correlationID: message.correlationID)
    }
}

private nonisolated final class StatusEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SharedStatusEvent] = []
    func record(_ event: SharedStatusEvent) { lock.withLock { events.append(event) } }
    func snapshot() -> [SharedStatusEvent] { lock.withLock { events } }
}

@MainActor
@Suite("Restricted shared status proof")
struct SharedStatusTests {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let network = NetworkID()
    private let requester = NodeID()
    private let responder = NodeID()
    private let session = SessionID()
    private let runtime = UUID()

    private var clientBinding: SharedStatusBinding {
        SharedStatusBinding(runtimeID: runtime, networkID: network, localNodeID: requester,
                            peerNodeID: responder, sessionID: session)
    }
    private var serverBinding: SharedStatusBinding {
        SharedStatusBinding(runtimeID: runtime, networkID: network, localNodeID: responder,
                            peerNodeID: requester, sessionID: session)
    }

    private func request(body: Data = Data(), deadline: Date? = nil) throws -> BeakrNetEnvelope {
        let deadline = deadline ?? now.addingTimeInterval(10)
        return try SharedStatusProtocol.envelope(
            DataMessage(kind: .request, operation: SharedStatusProtocol.operation,
                        correlationID: DataCorrelationID(), deadline: deadline, body: body),
            binding: clientBinding, sequence: 1, now: now, expiresAt: deadline
        )
    }

    private func reply(to request: BeakrNetEnvelope, message: DataMessage? = nil) throws -> BeakrNetEnvelope {
        let incoming = try SharedStatusProtocol.codec.decode(envelope: request)
        let snapshot = SharedStatusSnapshot(schemaVersion: 1, sampledAt: now, applicationVersion: "1.0",
                                             runtimeState: .running, authenticatedPeerCount: 2)
        let response = try message ?? DataMessage(kind: .response, operation: SharedStatusProtocol.operation,
                                                  correlationID: incoming.correlationID,
                                                  body: SharedStatusProtocol.encode(snapshot))
        return try SharedStatusProtocol.envelope(response, binding: serverBinding, sequence: 2,
                                                now: now, expiresAt: now.addingTimeInterval(10))
    }

    private func replace(_ envelope: BeakrNetEnvelope, network: NetworkID? = nil, source: NodeID? = nil,
                         destination: NodeID? = nil, session: SessionID? = nil) -> BeakrNetEnvelope {
        BeakrNetEnvelope(messageID: envelope.messageID, networkID: network ?? envelope.networkID,
                         sessionID: session ?? envelope.sessionID, sourceNodeID: source ?? envelope.sourceNodeID,
                         destinationNodeID: destination ?? envelope.destinationNodeID,
                         sequenceNumber: envelope.sequenceNumber, deliveryPolicy: envelope.deliveryPolicy,
                         payloadType: envelope.payloadType, payload: envelope.payload, createdAt: envelope.createdAt)
    }

    @Test("Allowed request crosses the Data dispatcher and returns attributed bounded status")
    func roundTrip() async throws {
        let probe = StatusSampleProbe()
        let server = SharedStatusResponder(binding: serverBinding, enabled: true, clock: { now }, sample: { await probe.sample() })
        let client = SharedStatusClient(binding: clientBinding, enabled: true, clock: { now })
        let serverBinding = serverBinding
        let result = try await client.request(sequence: 1) { request in
            #expect(request.deliveryPolicy.durability == .ephemeral)
            #expect(request.deliveryPolicy.expiresAt == now.addingTimeInterval(10))
            let response = try #require(await server.receive(request, authenticatedPeer: requester))
            let wire = try SharedStatusProtocol.envelope(response, binding: serverBinding, sequence: 2,
                                                        now: now, expiresAt: now.addingTimeInterval(10))
            await client.receive(wire, authenticatedPeer: responder)
            return .submitted
        }
        #expect(result.binding == clientBinding)
        #expect(result.snapshot.authenticatedPeerCount == 2)
        #expect(result.snapshot.sampledAt == now)
        #expect(try SharedStatusProtocol.encode(result.snapshot).count <= 4_096)
        #expect(await probe.calls == 1)
    }

    @Test("Both service ends default to denied without invoking provider or transport")
    func defaultDenied() async throws {
        let probe = StatusSampleProbe()
        let server = SharedStatusResponder(binding: serverBinding, clock: { now }, sample: { await probe.sample() })
        #expect(await server.receive(try request(), authenticatedPeer: requester)?.errorCode == .unauthorized)
        #expect(await probe.calls == 0)
        let client = SharedStatusClient(binding: clientBinding)
        await #expect(throws: SharedStatusError.unauthorized) {
            try await client.request(sequence: 1) { _ in Issue.record("Denied send invoked"); return .submitted }
        }
    }

    @Test("Network, endpoint, session and authenticated identity must all match", arguments: 0..<5)
    func bindingDenials(_ variant: Int) async throws {
        let probe = StatusSampleProbe()
        let server = SharedStatusResponder(binding: serverBinding, enabled: true, clock: { now }, sample: { await probe.sample() })
        let original = try request()
        let envelope: BeakrNetEnvelope
        switch variant {
        case 0: envelope = replace(original, network: NetworkID())
        case 1: envelope = replace(original, source: NodeID())
        case 2: envelope = replace(original, destination: NodeID())
        case 3: envelope = replace(original, session: SessionID())
        default: envelope = original
        }
        #expect(await server.receive(envelope, authenticatedPeer: variant == 4 ? NodeID() : requester) == nil)
        #expect(await probe.calls == 0)
    }

    @Test("No request-selected fields, expired work, oversized body or distant deadline reaches provider", arguments: 0..<4)
    func invalidRequests(_ variant: Int) async throws {
        let probe = StatusSampleProbe()
        let server = SharedStatusResponder(binding: serverBinding, enabled: true, clock: { now }, sample: { await probe.sample() })
        let body = variant == 0 ? Data("{\"path\":\"/private\"}".utf8) : Data()
        if variant == 2 {
            #expect(throws: (any Error).self) { try request(body: Data(repeating: 1, count: 4_097)) }
        } else {
            let deadline = now.addingTimeInterval(variant == 1 ? -1 : variant == 3 ? 60 : 10)
            let response = await server.receive(try request(body: body, deadline: deadline), authenticatedPeer: requester)
            #expect(response == nil || response?.kind == .applicationError)
        }
        #expect(await probe.calls == 0)
    }

    @Test("Withdrawal or runtime replacement during sampling prevents a reply", arguments: [false, true])
    func responderInvalidation(_ stop: Bool) async throws {
        let probe = StatusSampleProbe(suspended: true)
        let server = SharedStatusResponder(binding: serverBinding, enabled: true, clock: { now }, sample: { await probe.sample() })
        let envelope = try request()
        let task = Task { await server.receive(envelope, authenticatedPeer: requester) }
        var entered = await probe.entered.makeAsyncIterator()
        _ = await entered.next()
        #expect(await server.receive(try request(), authenticatedPeer: requester)?.errorCode == .resourceLimit)
        if stop { await server.invalidate() } else { await server.setEnabled(false) }
        await probe.release()
        #expect(await task.value == nil)
        #expect(await probe.calls == 1)
    }

    @Test("Mismatched replies are ignored; one valid reply completes once")
    func replyMatching() async throws {
        let client = SharedStatusClient(binding: clientBinding, enabled: true, clock: { now })
        let (requests, sent) = AsyncStream<BeakrNetEnvelope>.makeStream()
        let task = Task { try await client.request(sequence: 1) { sent.yield($0); return .submitted } }
        var iterator = requests.makeAsyncIterator()
        let request = try #require(await iterator.next())
        let valid = try reply(to: request)
        for incorrect in [replace(valid, source: NodeID()), replace(valid, network: NetworkID()),
                          replace(valid, session: SessionID()), replace(valid, destination: NodeID())] {
            await client.receive(incorrect, authenticatedPeer: responder)
        }
        await client.receive(valid, authenticatedPeer: NodeID())
        let unrelated = DataMessage(kind: .response, operation: SharedStatusProtocol.operation,
                                     correlationID: DataCorrelationID(), body: Data())
        await client.receive(try reply(to: request, message: unrelated), authenticatedPeer: responder)
        await #expect(throws: SharedStatusError.busy) {
            try await client.request(sequence: 3) { _ in .submitted }
        }
        await client.receive(valid, authenticatedPeer: responder)
        await client.receive(valid, authenticatedPeer: responder)
        #expect(try await task.value.snapshot.authenticatedPeerCount == 2)
    }

    @Test("Terminal outcomes distinguish cancellation, unavailable, invalidation and withdrawal", arguments: 0..<4)
    func terminalOutcomes(_ variant: Int) async throws {
        let client = SharedStatusClient(binding: clientBinding, enabled: true, clock: { now })
        let (requests, sent) = AsyncStream<BeakrNetEnvelope>.makeStream()
        let task = Task { try await client.request(sequence: 1) { sent.yield($0); return .submitted } }
        var iterator = requests.makeAsyncIterator()
        let request = try #require(await iterator.next())
        let expected: SharedStatusError
        switch variant {
        case 0: task.cancel(); expected = .cancelled
        case 1: await client.disconnected(); expected = .unavailable
        case 2: await client.invalidate(); expected = .invalidated
        default: await client.setEnabled(false); expected = .unauthorized
        }
        await #expect(throws: expected) { try await task.value }
        await client.receive(try reply(to: request), authenticatedPeer: responder)
    }

    @Test("No route fails immediately; an absent reply times out without an offline queue")
    func offlineAndTimeout() async throws {
        let client = SharedStatusClient(binding: clientBinding, enabled: true, clock: { now })
        await #expect(throws: SharedStatusError.unavailable) {
            try await client.request(sequence: 1) { _ in .routeUnavailable }
        }
        let timed = SharedStatusClient(binding: clientBinding, enabled: true, clock: { now }, sleep: { _ in })
        await #expect(throws: SharedStatusError.timedOut) {
            try await timed.request(sequence: 1) { _ in .submitted }
        }
    }

    @Test("Monotonic deadline rejects a late reply even before the timeout task runs")
    func lateReply() async throws {
        let clock = StatusTestClock()
        let events = StatusEventRecorder()
        let client = SharedStatusClient(binding: clientBinding, enabled: true, clock: { now }, elapsed: { clock.read() },
                                        eventSink: { events.record($0) })
        let (requests, sent) = AsyncStream<BeakrNetEnvelope>.makeStream()
        let task = Task { try await client.request(sequence: 1) { sent.yield($0); return .submitted } }
        var iterator = requests.makeAsyncIterator()
        let request = try #require(await iterator.next())
        clock.advance()
        await client.receive(try reply(to: request), authenticatedPeer: responder)
        await #expect(throws: SharedStatusError.timedOut) { try await task.value }
        let terminal = events.snapshot().filter { $0.stage == .completion }
        #expect(terminal.count == 1)
        #expect(terminal.first?.failure == .timedOut)
        #expect(terminal.first?.elapsed == .seconds(11))
        #expect(terminal.first?.runtimeID == runtime)
    }

    @Test("Remote errors and invalid snapshots are distinct from successful status", arguments: [false, true])
    func invalidReplies(_ remoteError: Bool) async throws {
        let client = SharedStatusClient(binding: clientBinding, enabled: true, clock: { now })
        let (requests, sent) = AsyncStream<BeakrNetEnvelope>.makeStream()
        let task = Task { try await client.request(sequence: 1) { sent.yield($0); return .submitted } }
        var iterator = requests.makeAsyncIterator()
        let request = try #require(await iterator.next())
        let id = try SharedStatusProtocol.codec.decode(envelope: request).correlationID
        // Even a correct correlation cannot substitute another operation.
        let other = DataMessage(kind: .response, operation: DataOperation(namespace: "other", name: "read", version: 1),
                                correlationID: id)
        await client.receive(try reply(to: request, message: other), authenticatedPeer: responder)
        let message = DataMessage(kind: remoteError ? .applicationError : .response,
                                  operation: SharedStatusProtocol.operation, correlationID: id,
                                  body: remoteError ? Data() : Data("{}".utf8),
                                  errorCode: remoteError ? .unauthorized : nil)
        await client.receive(try reply(to: request, message: message), authenticatedPeer: responder)
        await #expect(throws: remoteError ? SharedStatusError.remote(.unauthorized) : .invalidResponse) {
            try await task.value
        }
    }

    @Test("Dispatcher serializes overlapping message and idempotency identities", arguments: [false, true])
    func dispatcherInFlight(_ sameKey: Bool) async throws {
        let probe = StatusSampleProbe(suspended: true)
        let handler = SuspendedStatusDataHandler(probe: probe)
        let dispatcher = DataDispatcher(supportedOperations: [SharedStatusProtocol.operation], handler: handler, clock: { now })
        let message = DataMessage(kind: .request, operation: SharedStatusProtocol.operation,
                                  correlationID: DataCorrelationID(), idempotencyKey: sameKey ? DataIdempotencyKey() : nil)
        let first = try SharedStatusProtocol.envelope(message, binding: clientBinding, sequence: 1,
                                                     now: now, expiresAt: now.addingTimeInterval(10))
        let second = try sameKey ? SharedStatusProtocol.envelope(message, binding: clientBinding, sequence: 2,
                                                                now: now, expiresAt: now.addingTimeInterval(10)) : first
        let task = Task { await dispatcher.dispatch(first) }
        var entered = await probe.entered.makeAsyncIterator()
        _ = await entered.next()
        guard case .rejected(.resourceLimit, _) = await dispatcher.dispatch(second) else {
            await probe.release()
            Issue.record("Concurrent dispatch was not bounded"); return
        }
        await probe.release()
        guard case .handled = await task.value else { Issue.record("Initial request failed"); return }
        let repeated = await dispatcher.dispatch(second)
        if sameKey {
            guard case .handled = repeated else { Issue.record("Completed idempotency result missing"); return }
        } else {
            #expect(repeated == .rejected(.duplicate, response: nil))
        }
        #expect(await probe.calls == 1)
    }

    @Test("Failed handler remains retryable with the same message identity")
    func failedHandlerRetry() async throws {
        let handler = StatusDataHandler(failOnce: true)
        let dispatcher = DataDispatcher(supportedOperations: [SharedStatusProtocol.operation], handler: handler, clock: { now })
        let envelope = try request()
        guard case .rejected(.handlerFailure, _) = await dispatcher.dispatch(envelope) else {
            Issue.record("Expected handler failure"); return
        }
        guard case .handled(let response) = await dispatcher.dispatch(envelope) else {
            Issue.record("Failed work was incorrectly remembered"); return
        }
        #expect(response?.kind == .response)
        #expect(await handler.calls == 2)
    }

    @Test("Failed result persistence cannot cache success and retry survives dispatcher restart")
    func failedPersistenceRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("store")
        let url = directory.appendingPathComponent("state.json")
        let backup = root.appendingPathComponent("saved")
        let state = try await PersistentDataState.open(fileURL: url, now: now)
        let handler = StatusDataHandler()
        let dispatcher = DataDispatcher(supportedOperations: [SharedStatusProtocol.operation], persistentState: state,
                                        handler: handler, clock: { now })
        let message = DataMessage(kind: .request, operation: SharedStatusProtocol.operation,
                                  correlationID: DataCorrelationID(), idempotencyKey: DataIdempotencyKey())
        let envelope = try SharedStatusProtocol.envelope(message, binding: clientBinding, sequence: 1,
                                                        now: now, expiresAt: now.addingTimeInterval(10))
        // Ensure the repository directory exists even when opening an empty state did not write it.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data("obstruction".utf8).write(to: directory)
        for _ in 0..<2 {
            guard case .rejected(.handlerFailure, _) = await dispatcher.dispatch(envelope) else {
                Issue.record("Persistence failure became success or duplicate"); return
            }
        }
        #expect(await state.recordedResults().isEmpty)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        guard case .handled(let response) = await dispatcher.dispatch(envelope) else {
            Issue.record("Same-envelope retry failed after storage recovery"); return
        }
        #expect(response?.body == Data("result".utf8))
        #expect(await handler.calls == 3)
        let restored = try await PersistentDataState.open(fileURL: url, now: now)
        let nextHandler = StatusDataHandler()
        let next = DataDispatcher(supportedOperations: [SharedStatusProtocol.operation], persistentState: restored,
                                  handler: nextHandler, clock: { now })
        #expect(await next.dispatch(envelope) == .handled(response: response))
        #expect(await nextHandler.calls == 0)
    }
}
