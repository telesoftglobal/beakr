import Foundation
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetControl

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

public struct ProfileApplicationRoute: Equatable, Sendable {
    public let id: UUID
    public let sessionID: SessionID

    public init(id: UUID, sessionID: SessionID) {
        self.id = id
        self.sessionID = sessionID
    }
}

/// Owns authenticated connections for one profile. Transports must have
/// completed their own handshake before admission and must accept revocation
/// snapshots before becoming visible to route policy.
public actor ProfileConnectionRegistry {
    /// Return true only after durable application acceptance. Retries (including
    /// protocol duplicates) may call this again; handlers must be idempotent.
    public typealias IncomingEnvelopeSink = @Sendable (BeakrNetEnvelope) async -> Bool
    public typealias DeliveryAcknowledgementSink = @Sendable (DeliveryAcknowledgement) async -> Void
    public typealias PeerLifecycleSink = @Sendable (NodeID, PeerLifecycleNotice) async -> Void
    /// nil delegates to the durable inbox; false consumes ephemeral traffic without a storage acknowledgement.
    public typealias AuthenticatedApplicationSink = @Sendable (BeakrNetEnvelope, NodeID, ProfileApplicationRoute) async -> Bool?

    private struct PeerContext: Sendable {
        let routeID = UUID()
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
    private let peerLifecycleSink: PeerLifecycleSink
    private let peerDiagnosticSink: @Sendable (Set<NodeID>) -> Void
    private let authenticatedApplicationSink: AuthenticatedApplicationSink
    private let peerRouteEnded: @Sendable (NodeID, UUID) -> Void
    private var peers: [NodeID: PeerContext] = [:]
    private var peerByTransport: [TransportID: NodeID] = [:]
    private var localNetworkInfo: PeerNetworkInfo?
    private var nextSequenceByPeer: [NodeID: UInt64] = [:]
    private var peerUpdateContinuations: [UUID: AsyncStream<Set<NodeID>>.Continuation] = [:]

    public init(
        networkID: NetworkID,
        localNodeID: NodeID,
        revocations: RevocationSnapshotDistributor,
        routePolicy: ProfileRoutePolicyController,
        incomingEnvelopeSink: @escaping IncomingEnvelopeSink = { _ in false },
        deliveryAcknowledgementSink: @escaping DeliveryAcknowledgementSink = { _ in },
        peerLifecycleSink: @escaping PeerLifecycleSink = { _, _ in },
        peerDiagnosticSink: @escaping @Sendable (Set<NodeID>) -> Void = { _ in },
        authenticatedApplicationSink: @escaping AuthenticatedApplicationSink = { _, _, _ in nil },
        peerRouteEnded: @escaping @Sendable (NodeID, UUID) -> Void = { _, _ in }
    ) {
        self.networkID = networkID
        self.localNodeID = localNodeID
        self.revocations = revocations
        self.routePolicy = routePolicy
        self.incomingEnvelopeSink = incomingEnvelopeSink
        self.deliveryAcknowledgementSink = deliveryAcknowledgementSink
        self.peerLifecycleSink = peerLifecycleSink
        self.peerDiagnosticSink = peerDiagnosticSink
        self.authenticatedApplicationSink = authenticatedApplicationSink
        self.peerRouteEnded = peerRouteEnded
    }

    /// New handshakes must use the same verified evidence as route admission,
    /// rather than retaining the snapshot captured when the runtime started.
    func currentRevocationSnapshot() async throws -> CredentialRevocationSnapshot {
        guard let snapshot = await revocations.latestSnapshot() else {
            throw ProfileConnectionRegistryError.missingRevocationSnapshot
        }
        return snapshot
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

        let applicationRoute = ProfileApplicationRoute(id: context.routeID, sessionID: sessionID)
        let owner = await AuthenticatedTransportRouteOwner(
            transport: transport,
            coordinator: context.coordinator,
            driver: context.driver,
            incomingEnvelopeSink: { [incomingEnvelopeSink, authenticatedApplicationSink] envelope in
                if let handled = await authenticatedApplicationSink(envelope, remoteNodeID, applicationRoute) {
                    return handled
                }
                return await incomingEnvelopeSink(envelope)
            },
            deliveryAcknowledgementSink: deliveryAcknowledgementSink,
            peerLifecycleSink: peerLifecycleSink,
            peerNetworkInfoChanged: { [weak self] in
                await self?.networkInfoChanged(transportID: transportID)
            }
        )
        context.owners[transportID] = owner
        peers[remoteNodeID] = context
        peerByTransport[transportID] = remoteNodeID
        await routePolicy.register(owner)
        publishPeerUpdate()
        // Diagnostics must not hold up admission or application messaging.
        Task { [weak self] in
            await self?.sendNetworkInfo(to: remoteNodeID, transportID: transportID)
        }
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

        // Commit ownership before cleanup suspends. A replacement transport may be
        // admitted while the awaits below run; writing this older context afterward
        // would otherwise discard the replacement and transiently remove the peer.
        if context.owners.isEmpty {
            peers.removeValue(forKey: peer)
            peerRouteEnded(peer, context.routeID)
        }
        else { peers[peer] = context }
        publishPeerUpdate()

        await routePolicy.unregister(transportID)
        await owner.setPermitted(false)
        await revocations.unregister(consumerID: transportID)
        await transport.close()
    }

    public func connectionCount() -> Int { peerByTransport.count }
    public func peerCount() -> Int { peers.count }
    public func peerNodeIDs() -> Set<NodeID> { Set(peers.keys) }

    /// Emits the complete authenticated peer set immediately and whenever
    /// admission/removal changes route presence or a peer address report changes.
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

    public func applicationRoute(for peer: NodeID) -> ProfileApplicationRoute? {
        peers[peer].map { ProfileApplicationRoute(id: $0.routeID, sessionID: $0.sessionID) }
    }

    public func nextSequenceNumber(for peer: NodeID) -> UInt64 {
        let sequence = nextSequenceByPeer[peer, default: 0]
        nextSequenceByPeer[peer] = sequence &+ 1
        return sequence
    }

    public func submit(_ envelope: BeakrNetEnvelope, expectedRouteID: UUID? = nil) async -> HostDeliveryAttempt {
        guard let peer = peers[envelope.destinationNodeID],
              expectedRouteID == nil || peer.routeID == expectedRouteID else { return .routeUnavailable }
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

    public func notifyPeers(_ notice: PeerLifecycleNotice, now: Date = Date()) async -> Int {
        let codec = ControlCodec()
        var submitted = 0
        for (peerNodeID, peer) in peers {
            let context = ControlContext(
                networkID: networkID,
                sourceNodeID: localNodeID,
                destinationNodeID: peerNodeID,
                sessionID: peer.sessionID
            )
            let message = ControlMessage.peerLifecycle(
                ControlHeader(type: .peerLifecycle, context: context),
                notice
            )
            let sequenceNumber = nextSequenceByPeer[peerNodeID, default: 0]
            nextSequenceByPeer[peerNodeID] = sequenceNumber &+ 1
            guard let envelope = try? codec.makeEnvelope(
                for: message,
                sequenceNumber: sequenceNumber,
                createdAt: now
            ) else { continue }
            do {
                if case .sent = try await peer.driver.deliver(envelope) {
                    submitted += 1
                }
            } catch {
                continue
            }
        }
        return submitted
    }

    public func publishNetworkInfo(_ info: PeerNetworkInfo, now: Date = Date()) async {
        localNetworkInfo = info
        for nodeID in peers.keys {
            await sendNetworkInfo(to: nodeID, now: now)
        }
    }

    private func sendNetworkInfo(to nodeID: NodeID, transportID: TransportID? = nil, now: Date = Date()) async {
        guard let info = localNetworkInfo, let peer = peers[nodeID],
              transportID.map({ peer.owners[$0] != nil }) ?? true else { return }
        let header = ControlHeader(type: .peerNetworkInfo, context: ControlContext(
            networkID: networkID, sourceNodeID: localNodeID,
            destinationNodeID: nodeID, sessionID: peer.sessionID
        ))
        guard let envelope = try? ControlCodec().makeEnvelope(
            for: .peerNetworkInfo(header, info),
            sequenceNumber: nextSequenceNumber(for: nodeID), createdAt: now
        ) else { return }
        _ = try? await peer.driver.deliver(envelope)
    }

    private func networkInfoChanged(transportID: TransportID) {
        // Ignore reports from a removed/replaced owner.
        guard peerByTransport[transportID] != nil else { return }
        publishPeerUpdate()
    }

    public func peerReportedIPv4Addresses() async -> [NodeID: String] {
        var result: [NodeID: String] = [:]
        for (nodeID, peer) in peers {
            for (transportID, owner) in peer.owners {
                if let address = await owner.peerReportedIPv4Address(),
                   peers[nodeID]?.owners[transportID] != nil {
                    result[nodeID] = address
                    break
                }
            }
        }
        return result
    }

    private func publishPeerUpdate() {
        let peerIDs = Set(peers.keys)
        peerDiagnosticSink(peerIDs)
        for continuation in peerUpdateContinuations.values {
            continuation.yield(peerIDs)
        }
    }

    private func removePeerUpdateContinuation(_ identifier: UUID) {
        peerUpdateContinuations.removeValue(forKey: identifier)
    }
}
