import Foundation
import BeakrNetAuthority
import BeakrNetCore

public enum ProfileConnectionRegistryError: Error, Equatable, Sendable {
    case localPeer
    case duplicateTransport(TransportID)
    case sessionMismatch
    case missingRevocationSnapshot
    case revocationRejected
}

public struct ProfilePeerConnection: Sendable {
    public let session: BeakrNetSession
    public let coordinator: PeerRouteCoordinator
    public let driver: SessionDeliveryDriver
    public let routeOwner: AuthenticatedTransportRouteOwner
}

/// Owns authenticated connections for one profile. Transports must have
/// completed their own handshake before admission and must accept revocation
/// snapshots before becoming visible to route policy.
public actor ProfileConnectionRegistry {
    public typealias IncomingEnvelopeSink = @Sendable (BeakrNetEnvelope) async -> Void
    public typealias DeliveryAcknowledgementSink = @Sendable (DeliveryAcknowledgement) async -> Void

    private struct PeerContext: Sendable {
        let sessionID: SessionID
        let session: BeakrNetSession
        let coordinator: PeerRouteCoordinator
        let driver: SessionDeliveryDriver
        var owners: [TransportID: AuthenticatedTransportRouteOwner]
    }

    public let networkID: NetworkID
    public let localNodeID: NodeID
    private let revocations: RevocationSnapshotDistributor
    private let routePolicy: ProfileRoutePolicyController
    private let incomingEnvelopeSink: IncomingEnvelopeSink
    private let deliveryAcknowledgementSink: DeliveryAcknowledgementSink
    private var peers: [NodeID: PeerContext] = [:]
    private var peerByTransport: [TransportID: NodeID] = [:]
    private var nextSequenceByPeer: [NodeID: UInt64] = [:]
    private var peerUpdateContinuations: [UUID: AsyncStream<Set<NodeID>>.Continuation] = [:]

    public init(
        networkID: NetworkID,
        localNodeID: NodeID,
        revocations: RevocationSnapshotDistributor,
        routePolicy: ProfileRoutePolicyController,
        incomingEnvelopeSink: @escaping IncomingEnvelopeSink = { _ in },
        deliveryAcknowledgementSink: @escaping DeliveryAcknowledgementSink = { _ in }
    ) {
        self.networkID = networkID
        self.localNodeID = localNodeID
        self.revocations = revocations
        self.routePolicy = routePolicy
        self.incomingEnvelopeSink = incomingEnvelopeSink
        self.deliveryAcknowledgementSink = deliveryAcknowledgementSink
    }

    public func admit(
        transport: any BeakrNetTransport & RevocationSnapshotConsumer,
        remoteNodeID: NodeID,
        sessionID: SessionID
    ) async throws -> ProfilePeerConnection {
        guard remoteNodeID != localNodeID else { throw ProfileConnectionRegistryError.localPeer }
        let transportID = await transport.id
        guard peerByTransport[transportID] == nil else {
            throw ProfileConnectionRegistryError.duplicateTransport(transportID)
        }
        guard await revocations.latestSnapshot() != nil else {
            await transport.close()
            throw ProfileConnectionRegistryError.missingRevocationSnapshot
        }
        if case .failed = await revocations.register(transport) {
            await revocations.unregister(consumerID: transportID)
            await transport.close()
            throw ProfileConnectionRegistryError.revocationRejected
        }

        var context: PeerContext
        if let existing = peers[remoteNodeID] {
            guard existing.sessionID == sessionID else {
                await revocations.unregister(consumerID: transportID)
                await transport.close()
                throw ProfileConnectionRegistryError.sessionMismatch
            }
            context = existing
        } else {
            let session = BeakrNetSession(
                id: sessionID,
                networkID: networkID,
                localNodeID: localNodeID,
                remoteNodeID: remoteNodeID,
                state: .active
            )
            let coordinator = PeerRouteCoordinator(networkID: networkID, remoteNodeID: remoteNodeID)
            context = PeerContext(
                sessionID: sessionID,
                session: session,
                coordinator: coordinator,
                driver: SessionDeliveryDriver(session: session, coordinator: coordinator),
                owners: [:]
            )
        }

        let owner = await AuthenticatedTransportRouteOwner(
            transport: transport,
            coordinator: context.coordinator,
            driver: context.driver,
            incomingEnvelopeSink: incomingEnvelopeSink,
            deliveryAcknowledgementSink: deliveryAcknowledgementSink
        )
        context.owners[transportID] = owner
        peers[remoteNodeID] = context
        peerByTransport[transportID] = remoteNodeID
        await routePolicy.register(owner)
        publishPeerUpdate()
        return ProfilePeerConnection(
            session: context.session,
            coordinator: context.coordinator,
            driver: context.driver,
            routeOwner: owner
        )
    }

    public func remove(
        transport: any BeakrNetTransport & RevocationSnapshotConsumer
    ) async {
        let transportID = await transport.id
        guard let peer = peerByTransport.removeValue(forKey: transportID),
              var context = peers[peer],
              let owner = context.owners.removeValue(forKey: transportID) else { return }
        await routePolicy.unregister(transportID)
        await owner.setPermitted(false)
        await revocations.unregister(consumerID: transportID)
        await transport.close()
        if context.owners.isEmpty { peers.removeValue(forKey: peer) }
        else { peers[peer] = context }
        publishPeerUpdate()
    }

    public func connectionCount() -> Int { peerByTransport.count }
    public func peerCount() -> Int { peers.count }
    public func peerNodeIDs() -> Set<NodeID> { Set(peers.keys) }

    /// Emits the complete authenticated peer set immediately and whenever
    /// admission or removal changes route presence.
    public func peerNodeIDUpdates() -> AsyncStream<Set<NodeID>> {
        let identifier = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Set<NodeID>.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        peerUpdateContinuations[identifier] = continuation
        continuation.yield(Set(peers.keys))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removePeerUpdateContinuation(identifier) }
        }
        return stream
    }
    public func session(for peer: NodeID) -> BeakrNetSession? { peers[peer]?.session }

    public func nextSequenceNumber(for peer: NodeID) -> UInt64 {
        let sequence = nextSequenceByPeer[peer, default: 0]
        nextSequenceByPeer[peer] = sequence &+ 1
        return sequence
    }

    public func submit(_ envelope: BeakrNetEnvelope) async -> HostDeliveryAttempt {
        guard let peer = peers[envelope.destinationNodeID] else { return .routeUnavailable }
        do {
            switch try await peer.driver.deliver(envelope) {
            case .sent:
                return .submitted
            case .ambiguousFailure, .expired, .routeUnavailable, .staleRouteGeneration:
                return .routeUnavailable
            }
        } catch {
            return .routeUnavailable
        }
    }

    private func publishPeerUpdate() {
        let peerIDs = Set(peers.keys)
        for continuation in peerUpdateContinuations.values {
            continuation.yield(peerIDs)
        }
    }

    private func removePeerUpdateContinuation(_ identifier: UUID) {
        peerUpdateContinuations.removeValue(forKey: identifier)
    }
}
