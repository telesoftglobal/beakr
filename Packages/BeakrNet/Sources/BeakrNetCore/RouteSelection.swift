import Foundation

public struct RouteCandidate: Equatable, Sendable {
    public let remoteNodeID: NodeID
    public let transportID: TransportID
    public let transportKind: TransportKind
    public let capabilities: TransportCapabilities
    public let generation: UInt64
    public let isAuthenticated: Bool
    public let isReady: Bool

    public init(
        remoteNodeID: NodeID,
        transportID: TransportID,
        transportKind: TransportKind,
        capabilities: TransportCapabilities,
        generation: UInt64,
        isAuthenticated: Bool,
        isReady: Bool
    ) {
        self.remoteNodeID = remoteNodeID
        self.transportID = transportID
        self.transportKind = transportKind
        self.capabilities = capabilities
        self.generation = generation
        self.isAuthenticated = isAuthenticated
        self.isReady = isReady
    }
}

public enum RouteRejectionReason: String, Codable, Equatable, Sendable {
    case peerMismatch
    case unauthenticated
    case notReady
    case incompatibleCapabilities
}

public enum RouteDiagnosticEvent: Equatable, Sendable {
    case candidateRejected(transportID: TransportID, reason: RouteRejectionReason)
    case routeSelected(transportID: TransportID, generation: UInt64)
    case routeUnavailable(remoteNodeID: NodeID)
}

public struct RouteSelectionResult: Equatable, Sendable {
    public let selected: RouteCandidate?
    public let diagnostics: [RouteDiagnosticEvent]

    public init(selected: RouteCandidate?, diagnostics: [RouteDiagnosticEvent]) {
        self.selected = selected
        self.diagnostics = diagnostics
    }
}

public struct RouteSelector: Sendable {
    public init() {}

    public func select(
        for envelope: BeakrNetEnvelope,
        envelopeSizeBytes: Int,
        from candidates: [RouteCandidate]
    ) -> RouteSelectionResult {
        var eligible: [RouteCandidate] = []
        var diagnostics: [RouteDiagnosticEvent] = []

        for candidate in candidates {
            let rejection: RouteRejectionReason?
            if candidate.remoteNodeID != envelope.destinationNodeID {
                rejection = .peerMismatch
            } else if !candidate.isAuthenticated {
                rejection = .unauthenticated
            } else if !candidate.isReady {
                rejection = .notReady
            } else if !candidate.capabilities.supports(envelope, envelopeSizeBytes: envelopeSizeBytes) {
                rejection = .incompatibleCapabilities
            } else {
                rejection = nil
            }

            if let rejection {
                diagnostics.append(.candidateRejected(transportID: candidate.transportID, reason: rejection))
            } else {
                eligible.append(candidate)
            }
        }

        let selected = eligible.min(by: precedes)
        if let selected {
            diagnostics.append(.routeSelected(transportID: selected.transportID, generation: selected.generation))
        } else {
            diagnostics.append(.routeUnavailable(remoteNodeID: envelope.destinationNodeID))
        }
        return RouteSelectionResult(selected: selected, diagnostics: diagnostics)
    }

    private func precedes(_ lhs: RouteCandidate, _ rhs: RouteCandidate) -> Bool {
        let lhsPreference = preference(for: lhs.transportKind)
        let rhsPreference = preference(for: rhs.transportKind)
        if lhsPreference != rhsPreference {
            return lhsPreference < rhsPreference
        }
        return lhs.transportID.rawValue.uuidString < rhs.transportID.rawValue.uuidString
    }

    private func preference(for kind: TransportKind) -> Int {
        switch kind {
        case .local: 0
        case .relay: 1
        case .watchConnectivity: 2
        case .inMemory: 3
        }
    }
}
