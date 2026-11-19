import Foundation

/// Diagnostic context only. It never grants admission or controls a runtime.
public struct RuntimeTraceContext: Codable, Equatable, Sendable {
    public let runID: UUID
    public let operationID: UUID
    public let parentOperationID: UUID?
    public let profileID: UUID?
    public let networkID: UUID?
    public let generation: Int

    public init(runID: UUID, operationID: UUID = UUID(), parentOperationID: UUID? = nil,
                profileID: UUID?, networkID: UUID?, generation: Int) {
        self.runID = runID
        self.operationID = operationID
        self.parentOperationID = parentOperationID
        self.profileID = profileID
        self.networkID = networkID
        self.generation = generation
    }
}

public enum RuntimeTraceStage: String, Codable, Sendable {
    case transitionWait, transition, startup, trustPreparation, discoveryStart
    case browser, listener, authentication, admission, peerLoss, peerRecovery, firstPeer
    case retryScheduled, connectionAttempt, connectivity, pendingRetry, resources, observation
    case membershipRefresh, revocationRefresh
}

public enum RuntimeTraceOutcome: String, Codable, Sendable {
    case began, completed, failed, cancelled, timedOut, alreadyRunning
    case ready, waiting, denied, stopped, notObserved, stale, changed
}

public enum RuntimeTraceReason: String, Codable, Sendable {
    case missingTrust, membershipRemoved, startupError, permissionDenied
    case authenticationRejected, connectionFailed, deadline, cancellation, capacity
    case trustRefreshFailed
}

public struct RuntimeTraceEvent: Codable, Equatable, Sendable {
    public let context: RuntimeTraceContext
    public let sequence: UInt64
    public let elapsedMilliseconds: Double
    public let stage: RuntimeTraceStage
    public let outcome: RuntimeTraceOutcome
    public let durationMilliseconds: Double?
    public let subjectID: UUID?
    public let count: Int?
    public let previousState: String?
    public let state: String?
    public let reason: RuntimeTraceReason?
    public let scheduledDelayMilliseconds: Double?
}

/// Reuses the host diagnostic retention policy without adding per-event tasks or
/// disk writes. Callers may export a bounded snapshot for developer inspection.
public final class RuntimeTraceJournal: @unchecked Sendable {
    public struct Snapshot: Codable, Sendable {
        public let events: [RuntimeTraceEvent]
        public let droppedEvents: UInt64
    }

    public let policy: HostDiagnosticPolicy
    private let lock = NSLock()
    private var events: [RuntimeTraceEvent] = []
    private var droppedEvents: UInt64 = 0
    private let sink: @Sendable (RuntimeTraceEvent) -> Void

    public init(policy: HostDiagnosticPolicy = HostDiagnosticPolicy(),
                sink: @escaping @Sendable (RuntimeTraceEvent) -> Void = { _ in }) {
        self.policy = policy
        self.sink = sink
    }

    public func record(_ event: RuntimeTraceEvent) {
        lock.withLock {
            if events.count == policy.maximumEvents {
                events.removeFirst()
                droppedEvents &+= 1
            }
            events.append(event)
        }
        // No user callback while holding the journal lock.
        sink(event)
    }

    public func snapshot() -> Snapshot {
        lock.withLock { Snapshot(events: events, droppedEvents: droppedEvents) }
    }

    public func export() throws -> Data {
        let snapshot = snapshot()
        var retained = snapshot.events
        var dropped = snapshot.droppedEvents
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        while true {
            let data = try encoder.encode(Snapshot(events: retained, droppedEvents: dropped))
            if data.count <= policy.maximumExportBytes { return data }
            guard !retained.isEmpty else { throw CocoaError(.fileWriteOutOfSpace) }
            retained.removeFirst()
            dropped &+= 1
        }
    }
}

/// One immutable runtime binding, with bounded peer observation state. All mutable
/// fields are protected by the lock; the clock must be monotonic and non-reentrant.
public final class RuntimeLifecycleTrace: @unchecked Sendable {
    public let context: RuntimeTraceContext
    private let journal: RuntimeTraceJournal
    private let now: @Sendable () -> Duration
    private let began: Duration
    private let maximumPeers: Int
    private let observesPeers: Bool
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var closed = false
    private var sawFirstPeer = false
    private var peers: Set<UUID> = []
    private var losses: [UUID: Duration] = [:]
    private var reportedOverflow = false

    public init(context: RuntimeTraceContext, journal: RuntimeTraceJournal,
                maximumPeers: Int = 64, observesPeers: Bool = true,
                now: (@Sendable () -> Duration)? = nil) {
        precondition(maximumPeers > 0)
        let origin = ContinuousClock.now
        let clock = now ?? { origin.duration(to: .now) }
        self.context = context
        self.journal = journal
        self.maximumPeers = maximumPeers
        self.observesPeers = observesPeers
        self.now = clock
        began = clock()
    }

    public func instant() -> Duration { now() }

    public func record(_ stage: RuntimeTraceStage, _ outcome: RuntimeTraceOutcome,
                       since: Duration? = nil, subjectID: UUID? = nil, count: Int? = nil,
                       previousState: String? = nil, state: String? = nil,
                       reason: RuntimeTraceReason? = nil, scheduledDelay: Duration? = nil) {
        let event = lock.withLock { () -> RuntimeTraceEvent? in
            guard !closed else { return nil }
            return event(stage, outcome, since: since, subjectID: subjectID, count: count,
                         previousState: previousState, state: state,
                         reason: reason, scheduledDelay: scheduledDelay)
        }
        if let event { journal.record(event) }
    }

    /// Called from the registry's admission/removal publication, not TLS readiness.
    /// Repeated address reports and transport handoffs do not create false recovery.
    public func observePeers(_ current: Set<UUID>) {
        let events = lock.withLock { () -> [RuntimeTraceEvent] in
            guard !closed, observesPeers else { return [] }
            var result: [RuntimeTraceEvent] = []
            let timestamp = now()
            for peer in peers.subtracting(current).sorted(by: { $0.uuidString < $1.uuidString }) {
                if losses.count < maximumPeers { losses[peer] = timestamp }
                else if !reportedOverflow {
                    reportedOverflow = true
                    result.append(event(.observation, .notObserved, state: "peer-capacity"))
                }
                result.append(event(.peerLoss, .changed, subjectID: peer))
            }
            // Cap retained identifiers even if a caller supplies an oversized set.
            let selected = Set(current.sorted { $0.uuidString < $1.uuidString }.prefix(maximumPeers))
            if current.count > maximumPeers && !reportedOverflow {
                reportedOverflow = true
                result.append(event(.observation, .notObserved, state: "peer-capacity"))
            }
            for peer in selected.subtracting(peers).sorted(by: { $0.uuidString < $1.uuidString }) {
                result.append(event(.admission, .completed, subjectID: peer, count: current.count))
                if let lost = losses.removeValue(forKey: peer) {
                    result.append(event(.peerRecovery, .completed, since: lost, subjectID: peer))
                }
            }
            if !current.isEmpty && !sawFirstPeer {
                sawFirstPeer = true
                result.append(event(.firstPeer, .completed, since: began, count: current.count))
            }
            peers = selected
            return result
        }
        for event in events { journal.record(event) }
    }

    /// Closing cancels observation, not networking. Missing measurements remain nil.
    public func close(_ outcome: RuntimeTraceOutcome) {
        let events = lock.withLock { () -> [RuntimeTraceEvent] in
            guard !closed else { return [] }
            var result: [RuntimeTraceEvent] = []
            if observesPeers && !sawFirstPeer { result.append(event(.firstPeer, .notObserved)) }
            for peer in losses.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                result.append(event(.peerRecovery, .notObserved, subjectID: peer))
            }
            result.append(event(.observation, outcome, since: began))
            closed = true
            peers.removeAll()
            losses.removeAll()
            return result
        }
        for event in events { journal.record(event) }
    }

    private func event(_ stage: RuntimeTraceStage, _ outcome: RuntimeTraceOutcome,
                       since: Duration? = nil, subjectID: UUID? = nil, count: Int? = nil,
                       previousState: String? = nil, state: String? = nil,
                       reason: RuntimeTraceReason? = nil,
                       scheduledDelay: Duration? = nil) -> RuntimeTraceEvent {
        sequence &+= 1
        let timestamp = now()
        return RuntimeTraceEvent(context: context, sequence: sequence,
                                 elapsedMilliseconds: Self.milliseconds(timestamp - began),
                                 stage: stage, outcome: outcome,
                                 durationMilliseconds: since.map { Self.milliseconds(timestamp - $0) },
                                 subjectID: subjectID, count: count,
                                 previousState: previousState.map { String($0.prefix(96)) },
                                 state: state.map { String($0.prefix(96)) }, reason: reason,
                                 scheduledDelayMilliseconds: scheduledDelay.map(Self.milliseconds))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}

/// Propagates diagnostics through existing start APIs and structured child tasks.
/// Runtime callbacks capture the value, so later UI selection cannot rebind it.
public enum RuntimeLifecycleDiagnostics {
    @TaskLocal public static var current: RuntimeLifecycleTrace?
    @TaskLocal public static var transitionID: UUID?
}
