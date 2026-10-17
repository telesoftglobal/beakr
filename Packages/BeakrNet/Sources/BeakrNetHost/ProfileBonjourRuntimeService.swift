import Foundation
import BeakrNetCore
import BeakrNetSecurity

public struct ProfileAcceptedPeerContext: Sendable, Equatable {
    public let expectedPeerNodeID: NodeID
    public let sessionID: SessionID

    public init(expectedPeerNodeID: NodeID, sessionID: SessionID) {
        self.expectedPeerNodeID = expectedPeerNodeID
        self.sessionID = sessionID
    }
}

public enum ProfileBonjourRuntimeDiagnostic: Sendable, Equatable {
    case started
    case stopped
    case acceptedConnectionRejected(connectionID: UUID)
    case authenticationFailed(connectionID: UUID, role: LANHandshakeRole)
}

public typealias ProfileAcceptedPeerResolver = @Sendable (
    any BonjourConnection
) async -> ProfileAcceptedPeerContext?

/// Owns the Bonjour browser and listener for one active profile. Discovery
/// metadata selects who initiates, but successful authenticated admission is
/// the only operation that creates a usable route.
public actor ProfileBonjourRuntimeService {
    private let discovery: BonjourDiscoveryCoordinator
    private let listener: BonjourListenerCoordinator
    private let connections: ProfileLANConnectionController
    private let diagnosticSink: @Sendable (ProfileBonjourRuntimeDiagnostic) -> Void
    private var isRunning = false

    public init(
        discovery: BonjourDiscoveryCoordinator,
        listener: BonjourListenerCoordinator,
        connections: ProfileLANConnectionController,
        diagnosticSink: @escaping @Sendable (ProfileBonjourRuntimeDiagnostic) -> Void = { _ in }
    ) {
        self.discovery = discovery
        self.listener = listener
        self.connections = connections
        self.diagnosticSink = diagnosticSink
    }

    public static func make(
        localNodeID: NodeID,
        localAdvertisementNonce: Data,
        browser: any BonjourBrowsing,
        connectionFactory: any BonjourConnectionFactory,
        listener: any BonjourListening,
        connections: ProfileLANConnectionController,
        sessionID: @escaping @Sendable (NodeID) async -> SessionID?,
        acceptedPeer: @escaping ProfileAcceptedPeerResolver,
        bonjourDiagnosticSink: @escaping BonjourDiagnosticSink = { _ in },
        diagnosticSink: @escaping @Sendable (ProfileBonjourRuntimeDiagnostic) -> Void = { _ in }
    ) -> ProfileBonjourRuntimeService {
        precondition(localAdvertisementNonce.count == 32)
        let discovery = BonjourDiscoveryCoordinator(
            localNodeID: localNodeID,
            browser: browser,
            connectionFactory: connectionFactory,
            diagnosticSink: bonjourDiagnosticSink,
            connectionHandler: { candidate, connection in
                Task {
                    guard let peerSessionID = await sessionID(candidate.nodeIDHint) else {
                        connection.cancel()
                        diagnosticSink(.acceptedConnectionRejected(connectionID: connection.id))
                        return
                    }
                    do {
                        _ = try await connections.authenticateAndAdmit(
                            connection: connection,
                            role: .initiator,
                            expectedPeerNodeID: candidate.nodeIDHint,
                            advertisementNonce: candidate.key.advertisementNonce,
                            sessionID: peerSessionID
                        )
                    } catch {
                        diagnosticSink(.authenticationFailed(
                            connectionID: connection.id,
                            role: .initiator
                        ))
                    }
                }
            },
            connectionEndedHandler: { connectionID in
                Task { await connections.connectionEnded(connectionID) }
            }
        )
        let listener = BonjourListenerCoordinator(
            listener: listener,
            diagnosticSink: bonjourDiagnosticSink,
            connectionHandler: { connection in
                Task {
                    guard let peer = await acceptedPeer(connection),
                          let connectionSessionID = await sessionID(peer.expectedPeerNodeID) else {
                        connection.cancel()
                        diagnosticSink(.acceptedConnectionRejected(connectionID: connection.id))
                        return
                    }
                    do {
                        _ = try await connections.authenticateAndAdmit(
                            connection: connection,
                            role: .acceptor,
                            expectedPeerNodeID: peer.expectedPeerNodeID,
                            advertisementNonce: localAdvertisementNonce,
                            sessionID: connectionSessionID
                        )
                    } catch {
                        diagnosticSink(.authenticationFailed(
                            connectionID: connection.id,
                            role: .acceptor
                        ))
                    }
                }
            }
        )
        return ProfileBonjourRuntimeService(
            discovery: discovery,
            listener: listener,
            connections: connections,
            diagnosticSink: diagnosticSink
        )
    }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        await listener.start()
        await discovery.start()
        diagnosticSink(.started)
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        await discovery.stop()
        await listener.stop()
        await connections.stopAll()
        diagnosticSink(.stopped)
    }

    public func running() -> Bool { isRunning }

    public func discoveredDisplayNames() async -> [NodeID: String] {
        var names: [NodeID: String] = [:]
        for candidate in await discovery.discoveredCandidates() {
            if let displayName = candidate.displayName {
                names[candidate.nodeIDHint] = displayName
            }
        }
        return names
    }
}
