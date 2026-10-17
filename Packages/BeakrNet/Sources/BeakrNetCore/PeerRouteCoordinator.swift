import Foundation

public struct RouteSnapshot: Equatable, Sendable {
    public let remoteNodeID: NodeID
    public let transportID: TransportID
    public let transportKind: TransportKind
    public let capabilities: TransportCapabilities
    public let generation: UInt64

    public init(candidate: RouteCandidate) {
        self.remoteNodeID = candidate.remoteNodeID
        self.transportID = candidate.transportID
        self.transportKind = candidate.transportKind
        self.capabilities = candidate.capabilities
        self.generation = candidate.generation
    }
}

public enum RouteCandidateState: String, Codable, Equatable, Sendable {
    case probing
    case authenticated
    case ready
}

public enum RouteRemovalReason: String, Codable, Equatable, Sendable {
    case connectionFailed
    case authenticationRejected
    case capabilityChanged
    case withdrawn
}

public enum RouteCoordinatorDiagnosticEvent: Equatable, Sendable {
    case candidateUpdated(transportID: TransportID, generation: UInt64, state: RouteCandidateState)
    case candidateRemoved(transportID: TransportID, generation: UInt64, reason: RouteRemovalReason)
    case staleCallbackIgnored(
        transportID: TransportID,
        callbackGeneration: UInt64,
        currentGeneration: UInt64?
    )
    case routeSelected(transportID: TransportID, generation: UInt64)
    case handoffStarted(fromTransportID: TransportID, toTransportID: TransportID, generation: UInt64)
    case handoffCompleted(fromTransportID: TransportID, toTransportID: TransportID, generation: UInt64)
    case fallbackSelected(transportID: TransportID, generation: UInt64)
    case fallbackUnavailable(remoteNodeID: NodeID)
}

/// Serializes route-candidate lifecycles for one authenticated peer.
///
/// This actor deliberately has no reference to a session or its pending deliveries.
public actor PeerRouteCoordinator {
    public typealias EventSink = @Sendable (RouteCoordinatorDiagnosticEvent) -> Void

    public let networkID: NetworkID
    public let remoteNodeID: NodeID

    private let selector: RouteSelector
    private let eventSink: EventSink
    private var candidates: [TransportID: RouteCandidate]
    private var nextGeneration: UInt64
    private var selectedSnapshot: RouteSnapshot?

    public private(set) var diagnosticHistory: [RouteCoordinatorDiagnosticEvent]

    public init(
        networkID: NetworkID,
        remoteNodeID: NodeID,
        selector: RouteSelector = RouteSelector(),
        eventSink: @escaping EventSink = { _ in }
    ) {
        self.networkID = networkID
        self.remoteNodeID = remoteNodeID
        self.selector = selector
        self.eventSink = eventSink
        self.candidates = [:]
        self.nextGeneration = 1
        self.selectedSnapshot = nil
        self.diagnosticHistory = []
    }

    /// Starts a new candidate lifecycle and returns the token required by its callbacks.
    @discardableResult
    public func beginCandidate(
        transportID: TransportID,
        kind: TransportKind,
        capabilities: TransportCapabilities
    ) -> UInt64 {
        let generation = allocateGeneration()
        candidates[transportID] = RouteCandidate(
            remoteNodeID: remoteNodeID,
            transportID: transportID,
            transportKind: kind,
            capabilities: capabilities,
            generation: generation,
            isAuthenticated: false,
            isReady: false
        )
        emit(.candidateUpdated(transportID: transportID, generation: generation, state: .probing))
        return generation
    }

    @discardableResult
    public func candidateAuthenticated(
        transportID: TransportID,
        generation: UInt64,
        capabilities: TransportCapabilities? = nil
    ) -> Bool {
        updateCandidate(
            transportID: transportID,
            generation: generation,
            capabilities: capabilities,
            isAuthenticated: true,
            isReady: false,
            state: .authenticated
        )
    }

    @discardableResult
    public func candidateReady(
        transportID: TransportID,
        generation: UInt64,
        capabilities: TransportCapabilities? = nil
    ) -> Bool {
        updateCandidate(
            transportID: transportID,
            generation: generation,
            capabilities: capabilities,
            isAuthenticated: true,
            isReady: true,
            state: .ready
        )
    }

    @discardableResult
    public func removeCandidate(
        transportID: TransportID,
        generation: UInt64,
        reason: RouteRemovalReason
    ) -> Bool {
        guard let candidate = candidates[transportID], candidate.generation == generation else {
            rejectStaleCallback(transportID: transportID, generation: generation)
            return false
        }

        candidates.removeValue(forKey: transportID)
        emit(.candidateRemoved(transportID: transportID, generation: generation, reason: reason))
        return true
    }

    /// Returns an immutable route snapshot. Selection never sends, retries, or mutates an envelope.
    public func route(for envelope: BeakrNetEnvelope, envelopeSizeBytes: Int) -> RouteSnapshot? {
        guard envelope.networkID == networkID,
              envelope.destinationNodeID == remoteNodeID else {
            emit(.fallbackUnavailable(remoteNodeID: remoteNodeID))
            selectedSnapshot = nil
            return nil
        }

        let result = selector.select(
            for: envelope,
            envelopeSizeBytes: envelopeSizeBytes,
            from: Array(candidates.values)
        )
        let nextSnapshot = result.selected.map(RouteSnapshot.init(candidate:))
        recordTransition(to: nextSnapshot)
        selectedSnapshot = nextSnapshot
        return nextSnapshot
    }

    public func candidate(transportID: TransportID) -> RouteCandidate? {
        candidates[transportID]
    }

    public func currentRoute() -> RouteSnapshot? {
        selectedSnapshot
    }

    public func isAuthenticatedRoute(transportID: TransportID, generation: UInt64) -> Bool {
        guard let candidate = candidates[transportID] else { return false }
        return candidate.generation == generation && candidate.isAuthenticated
    }

    @discardableResult
    public func markRouteUnhealthy(_ snapshot: RouteSnapshot) -> Bool {
        removeCandidate(
            transportID: snapshot.transportID,
            generation: snapshot.generation,
            reason: .connectionFailed
        )
    }

    private func updateCandidate(
        transportID: TransportID,
        generation: UInt64,
        capabilities: TransportCapabilities?,
        isAuthenticated: Bool,
        isReady: Bool,
        state: RouteCandidateState
    ) -> Bool {
        guard let existing = candidates[transportID], existing.generation == generation else {
            rejectStaleCallback(transportID: transportID, generation: generation)
            return false
        }

        candidates[transportID] = RouteCandidate(
            remoteNodeID: remoteNodeID,
            transportID: transportID,
            transportKind: existing.transportKind,
            capabilities: capabilities ?? existing.capabilities,
            generation: generation,
            isAuthenticated: isAuthenticated,
            isReady: isReady
        )
        emit(.candidateUpdated(transportID: transportID, generation: generation, state: state))
        return true
    }

    private func allocateGeneration() -> UInt64 {
        let generation = nextGeneration
        precondition(generation < UInt64.max, "Route generation exhausted")
        nextGeneration += 1
        return generation
    }

    private func rejectStaleCallback(transportID: TransportID, generation: UInt64) {
        emit(.staleCallbackIgnored(
            transportID: transportID,
            callbackGeneration: generation,
            currentGeneration: candidates[transportID]?.generation
        ))
    }

    private func recordTransition(to next: RouteSnapshot?) {
        guard let next else {
            if selectedSnapshot != nil {
                emit(.fallbackUnavailable(remoteNodeID: remoteNodeID))
            }
            return
        }

        guard let previous = selectedSnapshot else {
            emit(.routeSelected(transportID: next.transportID, generation: next.generation))
            return
        }
        guard previous != next else { return }

        emit(.handoffStarted(
            fromTransportID: previous.transportID,
            toTransportID: next.transportID,
            generation: next.generation
        ))
        if previous.transportKind == .local && next.transportKind == .relay {
            emit(.fallbackSelected(transportID: next.transportID, generation: next.generation))
        }
        emit(.handoffCompleted(
            fromTransportID: previous.transportID,
            toTransportID: next.transportID,
            generation: next.generation
        ))
    }

    private func emit(_ event: RouteCoordinatorDiagnosticEvent) {
        diagnosticHistory.append(event)
        eventSink(event)
    }
}
