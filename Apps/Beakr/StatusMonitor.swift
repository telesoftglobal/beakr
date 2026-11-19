import Foundation
import BeakrNetCore
import BeakrNetData
import BeakrNetHost

nonisolated enum MonitorAction: String, Codable, Sendable {
    case start, renew, stop, sample, ack, ended
    var operation: DataOperation { DataOperation(namespace: "beakr.status.monitor", name: rawValue, version: 1) }
}

nonisolated struct MonitorBody: Codable, Equatable, Sendable {
    let subscription: UUID
    var sequence: UInt64 = 0
    var snapshot: SharedStatusSnapshot?
    var reason: String?
}

nonisolated enum MonitorProtocol {
    static let namespace = "beakr.status.monitor"
    static func message(_ action: MonitorAction, kind: DataMessageKind = .message,
                        body: MonitorBody, correlation: DataCorrelationID = DataCorrelationID(),
                        error: DataApplicationErrorCode? = nil, now: Date) throws -> DataMessage {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let bytes = try encoder.encode(body)
        guard bytes.count <= 4096 else { throw SharedStatusError.invalidResponse }
        return DataMessage(kind: kind, operation: action.operation, correlationID: correlation,
                           deadline: now.addingTimeInterval(10), body: bytes, errorCode: error)
    }

    static func decode(_ message: DataMessage) throws -> (MonitorAction, MonitorBody) {
        guard message.operation.namespace == namespace, message.operation.version == 1,
              let action = MonitorAction(rawValue: message.operation.name),
              message.idempotencyKey == nil, message.body.count <= 4096 else { throw SharedStatusError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let body = try decoder.decode(MonitorBody.self, from: message.body)
        let control = action == .start || action == .renew
        guard control ? [.request, .response, .applicationError].contains(message.kind) : message.kind == .message,
              (message.kind == .applicationError) == (message.errorCode != nil),
              (action == .sample) == (body.snapshot != nil),
              action == .ended ? ["stopped", "permission-withdrawn"].contains(body.reason ?? "") : body.reason == nil,
              action != .start || body.sequence == 0,
              ![.renew, .sample, .ack].contains(action) || body.sequence > 0 else { throw SharedStatusError.invalidResponse }
        try body.snapshot?.validate()
        return (action, body)
    }
}

nonisolated struct MonitorViewState: Equatable, Sendable {
    enum Phase: Sendable { case stopped, starting, monitoring, stale, disconnected, denied, failed, permissionWithdrawn }
    var phase: Phase = .stopped
    var peer: NodeID?
    var owner: UUID?
    // Retain the initiating view identity after the active session ends, so a
    // newly opened details view does not replay another view's terminal notice.
    var presentationOwner: UUID?
    var snapshot: SharedStatusSnapshot?
    var ageSeconds: Int?
    var sequence: UInt64 = 0
}

/// One incoming and one outgoing ephemeral subscription in one selected runtime.
/// The injected monotonic clock and manual tick mode make ordering/deadline tests deterministic.
actor StatusMonitor {
    private struct Session {
        let id: UUID
        let peer: NodeID
        let route: ProfileApplicationRoute
        var lease: Duration
        var next: Duration
        var sequence: UInt64 = 0
        var outstanding: UInt64?
        var ackDeadline: Duration?
        var renewal: UInt64 = 0
        var permissionRevision: UUID?
    }
    private struct Pending {
        let correlation: DataCorrelationID
        let action: MonitorAction
        let generation: UInt64
        let began: Duration
    }
    private struct Cached {
        let peer: NodeID
        let route: ProfileApplicationRoute
        let request: DataMessage
        let response: DataMessage
        let until: Duration
    }
    private struct Ended {
        let id: UUID
        let peer: NodeID
        let route: ProfileApplicationRoute
        let until: Duration
    }

    private let profileID: UUID
    private let network: NetworkID
    private let local: NodeID
    private let permissions: SharedStatusPermissionStore?
    private let authorization: @Sendable () async -> ProfileServiceAuthorizationSnapshot?
    private let resolve: SharedStatusRuntime.Resolve
    private let submit: SharedStatusRuntime.Submit
    private let nextSequence: @Sendable (NodeID) async -> UInt64
    private let sample: @Sendable () async throws -> SharedStatusSnapshot
    private let elapsed: @Sendable () -> Duration
    private let wall: @Sendable () -> Date
    private let automaticTicks: Bool
    private let beforeCommit: (@Sendable () async -> Void)?
    private var incoming: Session?
    private var outgoing: Session?
    private var pending: Pending?
    private var cache: [DataCorrelationID: Cached] = [:]
    private var ended: [Ended] = []
    private var state = MonitorViewState()
    private var lastReceived: Duration?
    private var observers: [UUID: AsyncStream<MonitorViewState>.Continuation] = [:]
    private var timer: Task<Void, Never>?
    private var sampling: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var committedSamples: UInt64 = 0
    private var skippedTicks: UInt64 = 0
    private var permissionTask: Task<Void, Never>?
    private var active = true
    private var ticking = false

    init(profileID: UUID, network: NetworkID, local: NodeID,
         permissions: SharedStatusPermissionStore?,
         authorization: @escaping @Sendable () async -> ProfileServiceAuthorizationSnapshot?,
         resolve: @escaping SharedStatusRuntime.Resolve, submit: @escaping SharedStatusRuntime.Submit,
         nextSequence: @escaping @Sendable (NodeID) async -> UInt64,
         elapsed: (@Sendable () -> Duration)? = nil, wall: @escaping @Sendable () -> Date = Date.init,
         automaticTicks: Bool = true, beforeCommit: (@Sendable () async -> Void)? = nil,
         sample: @escaping @Sendable () async throws -> SharedStatusSnapshot) {
        self.profileID = profileID; self.network = network; self.local = local
        self.permissions = permissions; self.authorization = authorization
        self.resolve = resolve; self.submit = submit; self.nextSequence = nextSequence
        self.sample = sample; self.wall = wall; self.automaticTicks = automaticTicks
        self.beforeCommit = beforeCommit
        let origin = ContinuousClock.now
        self.elapsed = elapsed ?? { origin.duration(to: .now) }
    }

    func observePermissions() {
        guard permissionTask == nil, let permissions else { return }
        permissionTask = Task { [weak self, local] in
            for await _ in await permissions.updates(for: local) {
                guard !Task.isCancelled else { return }
                await self?.revalidate()
            }
        }
    }

    func updates() -> AsyncStream<MonitorViewState> {
        let (stream, continuation) = AsyncStream<MonitorViewState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard active, observers.count < 64 else { continuation.yield(state); continuation.finish(); return stream }
        let id = UUID()
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    func current() -> MonitorViewState { state }
    func diagnostics() -> (incoming: Bool, outgoing: Bool, retained: Int, timerActive: Bool, committedSamples: UInt64, skippedTicks: UInt64) {
        (incoming != nil, outgoing != nil, cache.count + ended.count, timer != nil, committedSamples, skippedTicks)
    }
    private func publish() { for observer in observers.values { observer.yield(state) } }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func identity(_ peer: NodeID) async -> SharedStatusPermissionIdentity? {
        guard active, peer != local, let permissions, permissions.operation == .monitor,
              permissions.profile.id.rawValue == profileID,
              permissions.profile.networkID == network, permissions.profile.localNodeID == local,
              let snapshot = await authorization(), active, snapshot.networkID == network else { return nil }
        await permissions.reconcile(snapshot)
        guard active, snapshot.eligibleSessions[local] != nil, snapshot.eligibleSessions[peer] != nil,
              let identity = SharedStatusPermissionIdentity(snapshot: snapshot, local: local, peer: peer),
              !snapshot.invalidatedCredentialIDs.contains(identity.localCredential),
              !snapshot.invalidatedCredentialIDs.contains(identity.remoteCredential) else { return nil }
        return identity
    }

    func setSharing(_ enabled: Bool, peer: NodeID, revision: UUID) async throws {
        guard let permissions else { throw SharedStatusPermissionError.unavailable }
        if !enabled {
            try await permissions.setSharing(false, peer: peer, identity: nil, expectedRevision: revision)
        } else {
            guard let identity = await identity(peer), active else { throw SharedStatusPermissionError.unavailable }
            try await permissions.setSharing(true, peer: peer, identity: identity, expectedRevision: revision)
        }
        await revalidate()
    }

    private func permission(_ peer: NodeID, route: ProfileApplicationRoute) async -> UUID? {
        guard let identity = await identity(peer), let permissions,
              await resolve(peer) == route, active else { return nil }
        return await permissions.authorization(for: peer, identity: identity)
    }

    func start(peer: NodeID, owner: UUID) async throws {
        guard active, outgoing == nil, peer != local else { throw SharedStatusError.busy }
        guard let route = await resolve(peer), active, !Task.isCancelled else { throw SharedStatusError.unavailable }
        guard outgoing == nil else { throw SharedStatusError.busy }
        let now = elapsed()
        let session = Session(id: UUID(), peer: peer, route: route, lease: now + .seconds(30), next: now + .seconds(10))
        outgoing = session
        trace("start", session: session)
        state = MonitorViewState(phase: .starting, peer: peer, owner: owner, presentationOwner: owner)
        lastReceived = nil
        publish()
        startTimer()
        await control(.start, session: session, generation: 0)
    }

    func stop(owner: UUID) async {
        guard state.owner == owner, let session = outgoing else { return }
        finishOutgoing(.stopped)
        _ = await send(.stop, body: MonitorBody(subscription: session.id), peer: session.peer, route: session.route)
    }

    private func control(_ action: MonitorAction, session: Session, generation: UInt64) async {
        guard outgoing?.id == session.id else { return }
        let correlation = DataCorrelationID()
        pending = Pending(correlation: correlation, action: action, generation: generation, began: elapsed())
        let result = await send(action, kind: .request,
                                body: MonitorBody(subscription: session.id, sequence: generation),
                                correlation: correlation, peer: session.peer, route: session.route)
        trace("control-submit-\(action.rawValue)-\(result)-correlation-\(correlation)", session: session)
        if result == .routeUnavailable, outgoing?.id == session.id { finishOutgoing(.disconnected) }
    }

    /// Returns false for this namespace even when malformed; never persist as chat or ACK durably.
    func receive(_ envelope: BeakrNetEnvelope, peer: NodeID, route: ProfileApplicationRoute) async -> Bool? {
        guard envelope.payloadType == DataMessage.payloadType,
              let message = try? DataCodec().decode(envelope: envelope),
              message.operation.namespace == MonitorProtocol.namespace else { return nil }
        func reject(_ reason: String) -> Bool {
            diagnostic("receive-rejected", message: message, detail: reason)
            return false
        }
        diagnostic("receive", message: message)
        guard active else { return reject("inactive") }
        guard peer != local, envelope.sourceNodeID == peer, envelope.destinationNodeID == local,
              envelope.networkID == network, envelope.sessionID == route.sessionID else { return reject("binding") }
        guard envelope.deliveryPolicy.durability == .ephemeral else { return reject("durability") }
        guard (try? envelope.validate(now: wall())) != nil else { return reject("envelope-validation") }
        guard let deadline = message.deadline, let expiry = envelope.deliveryPolicy.expiresAt else { return reject("missing-deadline") }
        guard deadline > wall() else { return reject("deadline-expired") }
        guard deadline.timeIntervalSince(wall()) <= 10.001 else { return reject("deadline-too-far-ahead") }
        guard expiry.timeIntervalSince(deadline) <= 0.001 else { return reject("expiry-after-deadline") }
        guard let bounded = try? SharedStatusProtocol.codec.decode(envelope: envelope) else { return reject("bounded-codec") }
        guard let (action, body) = try? MonitorProtocol.decode(bounded) else { return reject("monitor-protocol") }
        guard await resolve(peer) == route, active else { return reject("route-or-inactive") }
        prune()
        if action == .start || action == .renew {
            if message.kind == .request {
                await handleControl(action, body: body, message: message, peer: peer, route: route)
            } else {
                guard let session = outgoing else { return reject("control-no-session") }
                guard session.id == body.subscription, session.peer == peer, session.route == route else { return reject("control-session-binding") }
                guard let pending else { return reject("control-not-pending") }
                guard pending.correlation == message.correlationID else { return reject("control-correlation") }
                guard pending.action == action, pending.generation == body.sequence else { return reject("control-action-or-generation") }
                guard elapsed() < pending.began + .seconds(10) else { return reject("control-response-late") }
                guard elapsed() < session.lease else { return reject("control-lease-expired") }
                diagnostic("control-accepted", message: message)
                self.pending = nil
                if message.kind == .applicationError { finishOutgoing(.denied) }
                else {
                    outgoing?.lease = pending.began + .seconds(30)
                    outgoing?.next = pending.began + .seconds(10)
                    if state.phase == .starting { state.phase = .monitoring; publish() }
                }
            }
        } else if action == .stop {
            if incoming?.id == body.subscription, incoming?.peer == peer, incoming?.route == route { finishIncoming() }
            else if cache.count + ended.count < 63,
                    !ended.contains(where: { $0.id == body.subscription && $0.peer == peer && $0.route == route }) {
                // Stop may overtake a Start that is suspended on authorization or transport.
                ended.append(Ended(id: body.subscription, peer: peer, route: route, until: elapsed() + .seconds(30)))
            }
        } else if action == .ended {
            if outgoing?.id == body.subscription, outgoing?.peer == peer, outgoing?.route == route {
                finishOutgoing(body.reason == "permission-withdrawn" ? .permissionWithdrawn : .stopped)
            }
        } else if action == .ack {
            if incoming?.id == body.subscription, incoming?.peer == peer, incoming?.route == route,
               incoming?.outstanding == body.sequence,
               incoming?.ackDeadline.map({ elapsed() < $0 }) == true,
               incoming.map({ elapsed() < $0.lease }) == true {
                diagnostic("ack-accepted", message: message)
                incoming?.outstanding = nil; incoming?.ackDeadline = nil
            }
        } else if action == .sample {
            guard let session = outgoing, session.id == body.subscription, session.peer == peer,
                  session.route == route, state.phase != .starting, elapsed() < session.lease,
                  body.sequence >= session.sequence, let snapshot = body.snapshot else { return reject("sample-session-starting-sequence-or-lease") }
            if body.sequence > session.sequence {
                outgoing?.sequence = body.sequence; state.sequence = body.sequence
                state.snapshot = snapshot; state.phase = .monitoring; state.ageSeconds = 0
                lastReceived = elapsed(); publish()
            }
            _ = await send(.ack, body: MonitorBody(subscription: session.id, sequence: body.sequence), peer: peer, route: route)
        }
        return false
    }

    private func handleControl(_ action: MonitorAction, body: MonitorBody, message: DataMessage,
                               peer: NodeID, route: ProfileApplicationRoute) async {
        if let cached = cache[message.correlationID] {
            if cached.peer == peer, cached.route == route, cached.request == message {
                _ = await sendMessage(cached.response, peer: peer, route: route)
            }
            return
        }
        // Bound both retained responses and terminal subscription identities.
        guard cache.count + ended.count < 63 else {
            _ = await send(action, kind: .applicationError, body: body, correlation: message.correlationID,
                           error: .resourceLimit, peer: peer, route: route)
            return
        }
        let revision = await permission(peer, route: route)
        guard active, message.deadline.map({ $0 > wall() }) == true else { return }
        if let cached = cache[message.correlationID] {
            if cached.peer == peer, cached.route == route, cached.request == message {
                _ = await sendMessage(cached.response, peer: peer, route: route)
            }
            return
        }
        guard cache.count + ended.count < 63 else { return }
        // Recheck after suspension: concurrent controls cannot allocate a second session.
        var error: DataApplicationErrorCode?
        if revision == nil { error = .unauthorized }
        else if ended.contains(where: { $0.id == body.subscription && $0.peer == peer && $0.route == route }) { error = .conflict }
        else if action == .start {
            if incoming != nil { error = .resourceLimit }
            else {
                let now = elapsed()
                incoming = Session(id: body.subscription, peer: peer, route: route,
                                   lease: now + .seconds(30), next: now, permissionRevision: revision)
                startTimer()
            }
        } else {
            if let session = incoming, session.id == body.subscription, session.peer == peer,
               session.route == route, elapsed() < session.lease, body.sequence == session.renewal + 1 {
                incoming?.renewal = body.sequence
                incoming?.lease = elapsed() + .seconds(30)
            } else { error = .conflict }
        }
        guard let response = try? MonitorProtocol.message(action, kind: error == nil ? .response : .applicationError,
            body: body, correlation: message.correlationID, error: error, now: wall()) else { return }
        cache[message.correlationID] = Cached(peer: peer, route: route, request: message, response: response, until: elapsed() + .seconds(30))
        let result = await sendMessage(response, peer: peer, route: route)
        diagnostic("control-response-submit", message: response, detail: String(describing: result))
        if error == nil, incoming?.id == body.subscription {
            if result == .routeUnavailable { finishIncoming() }
            else if action == .start { scheduleSample() }
        }
    }

    private func scheduleSample() {
        guard sampling == nil, let session = incoming, session.outstanding == nil, elapsed() < session.lease else { return }
        incoming?.next = elapsed() + .seconds(2)
        sampling = Task { [weak self] in await self?.produce(session) }
    }

    private func produce(_ session: Session) async {
        defer { if incoming?.id == session.id { sampling = nil } }
        guard let revision = await permission(session.peer, route: session.route),
              revision == session.permissionRevision, incoming?.id == session.id, !Task.isCancelled else {
            if incoming?.id == session.id { await finishAfterPermissionChange(session) }
            return
        }
        do {
            let began = elapsed()
            let snapshot = try await sample()
            try snapshot.validate()
            guard incoming?.id == session.id, elapsed() < session.lease, !Task.isCancelled,
                  let current = await permission(session.peer, route: session.route), current == revision,
                  incoming?.id == session.id, !Task.isCancelled else { return }
            if let beforeCommit { await beforeCommit() }
            guard incoming?.id == session.id, !Task.isCancelled, let permissions else { return }
            let sequence = (incoming?.sequence ?? 0) + 1
            incoming?.sequence = sequence
            incoming?.outstanding = sequence
            incoming?.ackDeadline = elapsed() + .seconds(10)
            let body = MonitorBody(subscription: session.id, sequence: sequence, snapshot: snapshot)
            guard let committed = await permissions.commitDisclosure(for: session.peer, expectedRevision: revision, submit: { [weak self] in
                guard let self else { return .routeUnavailable }
                return await self.sendSample(body, session: session)
            }) else { if incoming?.id == session.id { await finishAfterPermissionChange(session) }; return }
            committedSamples &+= 1
            trace("sample-committed", session: session, duration: elapsed() - began)
            let result = await withTaskCancellationHandler { await committed.value } onCancel: { committed.cancel() }
            if result == .routeUnavailable, incoming?.id == session.id { finishIncoming() }
        } catch { if incoming?.id == session.id { finishIncoming() } }
    }

    private func sendSample(_ body: MonitorBody, session: Session) async -> HostDeliveryAttempt {
        guard incoming?.id == session.id, elapsed() < (incoming?.lease ?? .zero), !Task.isCancelled else { return .routeUnavailable }
        return await send(.sample, body: body, peer: session.peer, route: session.route)
    }

    /// Clock-driven maintenance; no network await can delay expiry or local Stop.
    func tick() async {
        guard active, !ticking else { return }
        ticking = true
        defer { ticking = false }
        let now = elapsed()
        prune()
        if let session = incoming {
            if now >= session.lease || session.ackDeadline.map({ now >= $0 }) == true {
                trace(now >= session.lease ? "incoming-lease-expired" : "sample-ack-timeout", session: session)
                finishIncoming()
            }
            else if now >= session.next {
                incoming?.next = now + .seconds(2)
                if session.outstanding == nil { scheduleSample() } else { skippedTicks &+= 1 }
            }
        }
        if let session = outgoing {
            if now >= session.lease || pending.map({ now >= $0.began + .seconds(10) }) == true {
                trace(now >= session.lease ? "outgoing-lease-expired" : "control-response-timeout", session: session)
                finishOutgoing(.failed)
            }
            else {
                if lastReceived == nil, now >= session.next - .seconds(4), state.phase == .monitoring {
                    state.phase = .stale; publish()
                }
                if let lastReceived {
                    state.ageSeconds = max(0, Int((now - lastReceived).components.seconds))
                    if now - lastReceived >= .seconds(6) { state.phase = .stale }
                    publish()
                }
                if pending == nil, now >= session.next {
                    outgoing?.renewal += 1
                    let generation = outgoing?.renewal ?? 1
                    // Do not block the timer on a slow transport.
                    renewalTask = Task { await self.control(.renew, session: session, generation: generation) }
                    outgoing?.next = now + .seconds(10)
                }
            }
        }
        stopTimerIfIdle()
    }

    func revalidate() async {
        if let session = incoming {
            let revision = await permission(session.peer, route: session.route)
            if incoming?.id == session.id, revision == nil || revision != session.permissionRevision { await finishAfterPermissionChange(session) }
        }
        if let session = outgoing {
            if await resolve(session.peer) != session.route, outgoing?.id == session.id { finishOutgoing(.disconnected) }
        }
    }

    func disconnected(peer: NodeID) {
        if incoming?.peer == peer { finishIncoming() }
        if outgoing?.peer == peer { finishOutgoing(.disconnected) }
    }

    func invalidate() {
        active = false
        finishIncoming(); finishOutgoing(.disconnected)
        permissionTask?.cancel(); permissionTask = nil
        timer?.cancel(); timer = nil
        for observer in observers.values { observer.finish() }
        observers.removeAll(); cache.removeAll(); ended.removeAll()
    }

    private func finishAfterPermissionChange(_ session: Session) async {
        let withdrawn: Bool
        if let revision = session.permissionRevision, let permissions {
            withdrawn = await permissions.wasExplicitlyWithdrawn(peer: session.peer, revision: revision)
        } else { withdrawn = false }
        guard incoming?.id == session.id else { return }
        finishIncoming(reason: withdrawn ? "permission-withdrawn" : "stopped")
    }

    private func finishIncoming(reason: String = "stopped") {
        guard let session = incoming else { return }
        incoming = nil
        trace("end-incoming", session: session)
        sampling?.cancel(); sampling = nil
        if active {
            Task { _ = await self.send(.ended, body: MonitorBody(subscription: session.id, reason: reason),
                                      peer: session.peer, route: session.route) }
        }
        // Capacity admission reserves room for this single active identity.
        ended.append(Ended(id: session.id, peer: session.peer, route: session.route, until: elapsed() + .seconds(30)))
        stopTimerIfIdle()
    }

    private func finishOutgoing(_ phase: MonitorViewState.Phase) {
        if let outgoing { trace("end-outgoing-\(phase)", session: outgoing) }
        outgoing = nil; pending = nil
        renewalTask?.cancel(); renewalTask = nil
        state.phase = phase; state.owner = nil
        publish(); stopTimerIfIdle()
    }

    private func trace(_ event: String, session: Session, duration: Duration = .zero) {
        BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [MONITOR] profile=\(profileID) subscription=\(session.id) event=\(event) committed=\(committedSamples) skipped=\(skippedTicks) duration=\(duration)",
                                level: .debug, logger: BeakrDiagnosticLog.runtime)
    }

    // No body, snapshot, credentials or arbitrary operation names in diagnostics.
    private func diagnostic(_ event: String, message: DataMessage, detail: String = "none") {
        let action = MonitorAction(rawValue: message.operation.name)?.rawValue ?? "unknown"
        BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [MONITOR] profile=\(profileID) correlation=\(message.correlationID) action=\(action) kind=\(message.kind) event=\(event) detail=\(detail)",
                                level: .debug, logger: BeakrDiagnosticLog.runtime)
    }

    private func prune() {
        let now = elapsed()
        cache = cache.filter { $0.value.until > now }
        ended.removeAll { $0.until <= now }
    }

    private func startTimer() {
        guard automaticTicks, timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await self?.tick()
            }
        }
    }

    private func stopTimerIfIdle() {
        if incoming == nil && outgoing == nil { timer?.cancel(); timer = nil }
    }

    private func send(_ action: MonitorAction, kind: DataMessageKind = .message, body: MonitorBody,
                      correlation: DataCorrelationID = DataCorrelationID(), error: DataApplicationErrorCode? = nil,
                      peer: NodeID, route: ProfileApplicationRoute) async -> HostDeliveryAttempt {
        guard let message = try? MonitorProtocol.message(action, kind: kind, body: body,
            correlation: correlation, error: error, now: wall()) else { return .routeUnavailable }
        return await sendMessage(message, peer: peer, route: route)
    }

    private func sendMessage(_ message: DataMessage, peer: NodeID, route: ProfileApplicationRoute) async -> HostDeliveryAttempt {
        guard active, !Task.isCancelled, await resolve(peer) == route, active else { return .routeUnavailable }
        let sequence = await nextSequence(peer)
        guard active, !Task.isCancelled, await resolve(peer) == route, active,
              let deadline = message.deadline, deadline > wall() else { return .routeUnavailable }
        let binding = SharedStatusBinding(runtimeID: UUID(), networkID: network, localNodeID: local,
                                         peerNodeID: peer, sessionID: route.sessionID)
        guard let envelope = try? SharedStatusProtocol.envelope(message, binding: binding, sequence: sequence,
                                                               now: wall(), expiresAt: deadline) else { return .routeUnavailable }
        return await submit(envelope, route.id)
    }
}
