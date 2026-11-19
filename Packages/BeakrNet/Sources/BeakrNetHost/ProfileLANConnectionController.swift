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
    case connectionEnded(UUID)
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
    private var addressConnections: [UUID: any BonjourConnection] = [:]
    private var pendingConnectionIDs: Set<UUID> = []
    private var endedConnectionIDs: Set<UUID> = []

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
            let snapshot = try await registry.currentRevocationSnapshot()
            let currentConfiguration = LANTransportConfiguration(
                identity: configuration.identity,
                credential: configuration.credential,
                trustedAuthorityPublicKey: configuration.trustedAuthorityPublicKey,
                networkID: configuration.networkID,
                environment: configuration.environment,
                revocationSnapshot: snapshot,
                localCertificateDER: configuration.localCertificateDER,
                localCertificatePublicKey: configuration.localCertificatePublicKey,
                capabilities: configuration.capabilities,
                now: configuration.now
            )
            return try await LANTransport.authenticate(
                connection: connection,
                role: role,
                expectedPeerNodeID: expectedPeerNodeID,
                advertisementNonce: advertisementNonce,
                configuration: currentConfiguration,
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
        guard pendingConnectionIDs.insert(connection.id).inserted else {
            throw ProfileLANConnectionError.duplicateConnection(connection.id)
        }
        defer {
            pendingConnectionIDs.remove(connection.id)
            endedConnectionIDs.remove(connection.id)
        }
        let replacesExistingPeer = transports.values.contains {
            $0.peerNodeID == expectedPeerNodeID
        }
        guard transports.count < maximumConnections || replacesExistingPeer else {
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
        guard !endedConnectionIDs.contains(connection.id) else {
            await transport.close()
            throw ProfileLANConnectionError.connectionEnded(connection.id)
        }
        guard transport.peerNodeID == expectedPeerNodeID else {
            await transport.close()
            throw ProfileLANConnectionError.authenticatedPeerMismatch
        }
        let superseded = transports.filter { _, existing in
            existing.peerNodeID == transport.peerNodeID
        }
        do {
            // Admit the replacement before retiring the old route. The registry
            // can own multiple transports for one peer, so this preserves logical
            // peer presence throughout a same-session connection handoff.
            let peer = try await registry.admit(
                transport: transport,
                remoteNodeID: transport.peerNodeID,
                sessionID: sessionID
            )
            guard !endedConnectionIDs.contains(connection.id) else {
                await registry.remove(transport: transport)
                throw ProfileLANConnectionError.connectionEnded(connection.id)
            }
            transports[connection.id] = transport
            addressConnections[connection.id] = connection
            for (connectionID, existing) in superseded {
                transports.removeValue(forKey: connectionID)
                addressConnections.removeValue(forKey: connectionID)
                await registry.remove(transport: existing)
            }
            return peer
        } catch {
            await transport.close()
            throw error
        }
    }

    public func connectionEnded(_ connectionID: UUID) async {
        addressConnections.removeValue(forKey: connectionID)
        if let transport = transports.removeValue(forKey: connectionID) {
            await registry.remove(transport: transport)
        } else if pendingConnectionIDs.contains(connectionID) {
            endedConnectionIDs.insert(connectionID)
        }
    }

    public func stopAll() async {
        let active = transports
        transports.removeAll(keepingCapacity: true)
        addressConnections.removeAll(keepingCapacity: true)
        for transport in active.values { await registry.remove(transport: transport) }
    }

    /// Addresses are diagnostic observations of currently admitted connections only.
    public func peerIPAddresses() -> [NodeID: String] {
        var result: [NodeID: String] = [:]
        for (id, transport) in transports {
            if let address = addressConnections[id]?.remoteIPAddress {
                result[transport.peerNodeID] = address
            }
        }
        return result
    }

    public func connectionCount() -> Int { transports.count }

    public struct ResourceSnapshot: Sendable, Equatable {
        public let activeTransports: Int
        public let pendingHandshakes: Int
    }

    public func resourceSnapshot() -> ResourceSnapshot {
        ResourceSnapshot(
            activeTransports: transports.count,
            pendingHandshakes: pendingConnectionIDs.count
        )
    }
}
