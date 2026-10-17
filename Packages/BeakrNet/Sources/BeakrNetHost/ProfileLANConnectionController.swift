import Foundation
import BeakrNetCore
import BeakrNetSecurity

public protocol ProfileAuthenticatedPeerTransport: BeakrNetTransport, RevocationSnapshotConsumer {
    nonisolated var peerNodeID: NodeID { get }
}

extension LANTransport: ProfileAuthenticatedPeerTransport {}

public enum ProfileLANConnectionError: Error, Equatable, Sendable {
    case capacityExceeded(maximumConnections: Int)
    case duplicateConnection(UUID)
    case authenticatedPeerMismatch
}

/// Bridges Bonjour connections into the profile's authenticated connection
/// registry. The injected factory exists for deterministic protocol tests; the
/// production default is `LANTransport.authenticate`.
public actor ProfileLANConnectionController {
    public typealias Authenticate = @Sendable (
        any BonjourConnection,
        LANHandshakeRole,
        NodeID,
        Data
    ) async throws -> any ProfileAuthenticatedPeerTransport

    private let registry: ProfileConnectionRegistry
    private let maximumConnections: Int
    private let authenticate: Authenticate
    private var transports: [UUID: any ProfileAuthenticatedPeerTransport] = [:]

    public init(
        registry: ProfileConnectionRegistry,
        configuration: LANTransportConfiguration,
        maximumConnections: Int = 64,
        diagnosticSink: @escaping LANTransportDiagnosticSink = { _ in }
    ) {
        precondition(maximumConnections > 0)
        self.registry = registry
        self.maximumConnections = maximumConnections
        authenticate = { connection, role, expectedPeerNodeID, advertisementNonce in
            try await LANTransport.authenticate(
                connection: connection,
                role: role,
                expectedPeerNodeID: expectedPeerNodeID,
                advertisementNonce: advertisementNonce,
                configuration: configuration,
                diagnosticSink: diagnosticSink
            )
        }
    }

    public init(
        registry: ProfileConnectionRegistry,
        maximumConnections: Int = 64,
        authenticate: @escaping Authenticate
    ) {
        precondition(maximumConnections > 0)
        self.registry = registry
        self.maximumConnections = maximumConnections
        self.authenticate = authenticate
    }

    public func authenticateAndAdmit(
        connection: any BonjourConnection,
        role: LANHandshakeRole,
        expectedPeerNodeID: NodeID,
        advertisementNonce: Data,
        sessionID: SessionID
    ) async throws -> ProfilePeerConnection {
        guard transports[connection.id] == nil else {
            throw ProfileLANConnectionError.duplicateConnection(connection.id)
        }
        guard transports.count < maximumConnections else {
            connection.cancel()
            throw ProfileLANConnectionError.capacityExceeded(maximumConnections: maximumConnections)
        }

        let transport: any ProfileAuthenticatedPeerTransport
        do {
            transport = try await authenticate(
                connection,
                role,
                expectedPeerNodeID,
                advertisementNonce
            )
        } catch {
            connection.cancel()
            throw error
        }
        guard transport.peerNodeID == expectedPeerNodeID else {
            await transport.close()
            throw ProfileLANConnectionError.authenticatedPeerMismatch
        }
        do {
            let peer = try await registry.admit(
                transport: transport,
                remoteNodeID: transport.peerNodeID,
                sessionID: sessionID
            )
            transports[connection.id] = transport
            return peer
        } catch {
            await transport.close()
            throw error
        }
    }

    public func connectionEnded(_ connectionID: UUID) async {
        guard let transport = transports.removeValue(forKey: connectionID) else { return }
        await registry.remove(transport: transport)
    }

    public func stopAll() async {
        let active = transports
        transports.removeAll(keepingCapacity: true)
        for transport in active.values { await registry.remove(transport: transport) }
    }

    public func connectionCount() -> Int { transports.count }
}
