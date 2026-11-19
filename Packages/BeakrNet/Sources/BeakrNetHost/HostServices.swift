import Foundation
import BeakrBlackboard
import BeakrNetCore
import BeakrNetControl
import BeakrNetData
import BeakrNetTransfer

public protocol HostDataLifecycleService: Sendable {
    func open() async throws
    func restorePending() async throws
    func reconcileExpired() async throws
    func checkpoint() async throws
    func setAdmissionPermitted(_ permitted: Bool) async
    func pendingCount() async -> Int
}

public protocol HostBlackboardLifecycleService: Sendable {
    func open() async throws
    func checkpoint() async throws
}

public protocol HostTransferLifecycleService: Sendable {
    func open() async throws
    func garbageCollectExpired() async throws
    func checkpoint() async throws
    func setAdmissionPermitted(_ permitted: Bool) async
    func activeCount() async -> Int
}

public protocol HostTrustLifecycleService: Sendable {
    func restore() async throws
    func renewCredentialIfNeeded() async throws
    func refreshRevocations() async throws
    func checkpoint() async throws
}

public protocol HostRoutePolicySink: Sendable {
    func setAllRoutesPermitted(_ permitted: Bool) async
    func setLANPermitted(_ permitted: Bool) async
}

/// Composes protocol-specific authorities without making any repository subordinate to a UI lifecycle.
public actor CompositeHostRecoveryService: HostRecoveryService {
    private let data: any HostDataLifecycleService
    private let blackboard: any HostBlackboardLifecycleService
    private let transfers: any HostTransferLifecycleService
    private let trust: any HostTrustLifecycleService
    private let routes: any HostRoutePolicySink

    public init(data: any HostDataLifecycleService, blackboard: any HostBlackboardLifecycleService,
                transfers: any HostTransferLifecycleService, trust: any HostTrustLifecycleService,
                routes: any HostRoutePolicySink) {
        self.data = data; self.blackboard = blackboard; self.transfers = transfers
        self.trust = trust; self.routes = routes
    }

    public func openRepositories() async throws {
        try await data.open(); try await blackboard.open(); try await transfers.open()
    }
    public func restorePendingWork() async throws { try await data.restorePending() }
    public func restoreTrustState() async throws {
        try await trust.restore()
        try await trust.renewCredentialIfNeeded()
        try await trust.refreshRevocations()
    }
    public func reconcileExpiredWork() async throws {
        try await data.reconcileExpired(); try await transfers.garbageCollectExpired()
    }
    public func checkpoint() async throws {
        try await data.checkpoint(); try await blackboard.checkpoint()
        try await transfers.checkpoint(); try await trust.checkpoint()
    }
    public func setRoutesPermitted(_ permitted: Bool) async { await routes.setAllRoutesPermitted(permitted) }
    public func setLANPermitted(_ permitted: Bool) async { await routes.setLANPermitted(permitted) }
    public func setNewDurableWorkPermitted(_ permitted: Bool) async { await data.setAdmissionPermitted(permitted) }
    public func setNewTransfersPermitted(_ permitted: Bool) async { await transfers.setAdmissionPermitted(permitted) }
    public func pendingMessageCount() async -> Int { await data.pendingCount() }
    public func activeTransferCount() async -> Int { await transfers.activeCount() }
}

/// Lifecycle adapter for an already-open, atomically persisted Data repository.
public actor ProfileDataLifecycleService: HostDataLifecycleService {
    public typealias PendingRestorer = @Sendable () async throws -> Void

    private let state: PersistentDataState
    private let restorePendingAction: PendingRestorer
    private let now: @Sendable () -> Date
    public private(set) var admissionPermitted = false

    public init(
        state: PersistentDataState,
        now: @escaping @Sendable () -> Date = Date.init,
        restorePending: @escaping PendingRestorer
    ) {
        self.state = state
        self.now = now
        restorePendingAction = restorePending
    }

    public func open() async throws {}
    public func restorePending() async throws { try await restorePendingAction() }
    public func reconcileExpired() async throws { _ = try await state.pending(now: now()) }
    public func checkpoint() async throws { _ = try await state.pending(now: now()) }
    public func setAdmissionPermitted(_ permitted: Bool) { admissionPermitted = permitted }
    public func pendingCount() async -> Int { (try? await state.pending(now: now()).count) ?? 0 }
}

/// Blackboard writes are persisted atomically by the repository itself.
public actor ProfileBlackboardLifecycleService: HostBlackboardLifecycleService {
    private let repository: PersistentBlackboardRepository

    public init(repository: PersistentBlackboardRepository) { self.repository = repository }
    public func open() async throws { _ = await repository.fileURL }
    public func checkpoint() async throws { _ = await repository.fileURL }
}

/// Lifecycle and admission boundary around profile-owned transfer staging.
public actor ProfileTransferLifecycleService: HostTransferLifecycleService {
    private let store: TransferStagingStore
    private let now: @Sendable () -> Date
    public private(set) var admissionPermitted = false

    public init(store: TransferStagingStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public func open() async throws { _ = await store.rootURL }
    public func garbageCollectExpired() async throws { try await store.garbageCollect(now: now()) }
    public func checkpoint() async throws { try await store.garbageCollect(now: now()) }
    public func setAdmissionPermitted(_ permitted: Bool) { admissionPermitted = permitted }
    public func activeCount() async -> Int { await store.activeTransferCount() }
}

public struct ProfileHostServices: Sendable {
    public let coordinator: BeakrNetHostCoordinator
    public let recovery: CompositeHostRecoveryService
    public let data: ProfileDataLifecycleService
    public let blackboard: ProfileBlackboardLifecycleService
    public let transfers: ProfileTransferLifecycleService

    public static func make(
        runtime: ProfileRuntimeRepositories,
        trust: any HostTrustLifecycleService,
        routes: any HostRoutePolicySink,
        now: @escaping @Sendable () -> Date = Date.init,
        restorePendingData: @escaping ProfileDataLifecycleService.PendingRestorer
    ) -> ProfileHostServices {
        let data = ProfileDataLifecycleService(
            state: runtime.dataState,
            now: now,
            restorePending: restorePendingData
        )
        let blackboard = ProfileBlackboardLifecycleService(repository: runtime.blackboardRepository)
        let transfers = ProfileTransferLifecycleService(store: runtime.transferStore, now: now)
        let recovery = CompositeHostRecoveryService(
            data: data,
            blackboard: blackboard,
            transfers: transfers,
            trust: trust,
            routes: routes
        )
        return ProfileHostServices(
            coordinator: BeakrNetHostCoordinator(recovery: recovery),
            recovery: recovery,
            data: data,
            blackboard: blackboard,
            transfers: transfers
        )
    }
}

/// Explicit authenticated-trust operations used by the host recovery sequence.
/// There are intentionally no default no-op implementations.
public actor AuthenticatedTrustLifecycleService: HostTrustLifecycleService {
    public typealias Operation = @Sendable () async throws -> Void

    private let restoreAction: Operation
    private let renewalAction: Operation
    private let revocationAction: Operation
    private let checkpointAction: Operation

    public init(
        restore: @escaping Operation,
        renewCredentialIfNeeded: @escaping Operation,
        refreshRevocations: @escaping Operation,
        checkpoint: @escaping Operation
    ) {
        restoreAction = restore
        renewalAction = renewCredentialIfNeeded
        revocationAction = refreshRevocations
        checkpointAction = checkpoint
    }

    public func restore() async throws { try await restoreAction() }
    public func renewCredentialIfNeeded() async throws { try await renewalAction() }
    public func refreshRevocations() async throws { try await revocationAction() }
    public func checkpoint() async throws { try await checkpointAction() }
}

public protocol HostManagedRoute: Sendable {
    var id: TransportID { get }
    var kind: TransportKind { get }
    func setPermitted(_ permitted: Bool) async
}

/// Applies host lifecycle and local-network permission to registered transport
/// owners. Registration is advisory: this type never authenticates or selects a route.
public actor ProfileRoutePolicyController: HostRoutePolicySink {
    private var routes: [TransportID: any HostManagedRoute] = [:]
    private var allRoutesPermitted = false
    private var lanPermitted = false

    public init() {}

    public func register(_ route: any HostManagedRoute) async {
        routes[route.id] = route
        await route.setPermitted(isPermitted(kind: route.kind))
    }

    public func unregister(_ transportID: TransportID) {
        routes.removeValue(forKey: transportID)
    }

    public func setAllRoutesPermitted(_ permitted: Bool) async {
        allRoutesPermitted = permitted
        await applyPolicy()
    }

    public func setLANPermitted(_ permitted: Bool) async {
        lanPermitted = permitted
        await applyPolicy()
    }

    public func routeCount() -> Int { routes.count }

    private func applyPolicy() async {
        for route in routes.values {
            await route.setPermitted(isPermitted(kind: route.kind))
        }
    }

    private func isPermitted(kind: TransportKind) -> Bool {
        allRoutesPermitted && (kind != .local || lanPermitted)
    }
}

/// Owns the route-candidate registration for a transport that has already
/// completed its transport-specific authentication.
public actor AuthenticatedTransportRouteOwner: HostManagedRoute {
    public nonisolated let id: TransportID
    public nonisolated let kind: TransportKind

    private let transport: any BeakrNetTransport
    private let coordinator: PeerRouteCoordinator
    private let driver: SessionDeliveryDriver
    private let incomingEnvelopeSink: ProfileConnectionRegistry.IncomingEnvelopeSink
    private let deliveryAcknowledgementSink: ProfileConnectionRegistry.DeliveryAcknowledgementSink
    private let peerLifecycleSink: ProfileConnectionRegistry.PeerLifecycleSink
    private let peerNetworkInfoChanged: @Sendable () async -> Void
    private var reportedNetworkInfo: (info: PeerNetworkInfo, receivedAt: Date)?
    private var activeGeneration: UInt64?
    private var receiveTask: Task<Void, Never>?

    public init(
        transport: any BeakrNetTransport,
        coordinator: PeerRouteCoordinator,
        driver: SessionDeliveryDriver,
        incomingEnvelopeSink: @escaping ProfileConnectionRegistry.IncomingEnvelopeSink = { _ in false },
        deliveryAcknowledgementSink: @escaping ProfileConnectionRegistry.DeliveryAcknowledgementSink = { _ in },
        peerLifecycleSink: @escaping ProfileConnectionRegistry.PeerLifecycleSink = { _, _ in },
        peerNetworkInfoChanged: @escaping @Sendable () async -> Void = {}
    ) async {
        id = await transport.id
        kind = await transport.kind
        self.transport = transport
        self.coordinator = coordinator
        self.driver = driver
        self.incomingEnvelopeSink = incomingEnvelopeSink
        self.deliveryAcknowledgementSink = deliveryAcknowledgementSink
        self.peerLifecycleSink = peerLifecycleSink
        self.peerNetworkInfoChanged = peerNetworkInfoChanged
    }

    public func setPermitted(_ permitted: Bool) async {
        if permitted {
            guard activeGeneration == nil else { return }
            let generation = await coordinator.beginCandidate(
                transportID: id,
                kind: kind,
                capabilities: await transport.capabilities
            )
            guard await coordinator.candidateAuthenticated(
                transportID: id,
                generation: generation
            ), await coordinator.candidateReady(
                transportID: id,
                generation: generation
            ) else {
                _ = await coordinator.removeCandidate(
                    transportID: id,
                    generation: generation,
                    reason: .authenticationRejected
                )
                return
            }
            await driver.register(transport, generation: generation)
            activeGeneration = generation
            let transportID = id
            receiveTask = Task { [transport, driver, incomingEnvelopeSink, deliveryAcknowledgementSink, peerLifecycleSink] in
                while !Task.isCancelled, let envelope = await transport.receive() {
                    guard let result = try? await driver.receive(
                        envelope,
                        receivedOn: transportID,
                        generation: generation
                    ) else { continue }

                    if envelope.payloadType == DeliveryAcknowledgement.payloadType {
                        guard let acknowledgement = try? JSONDecoder().decode(
                            DeliveryAcknowledgement.self,
                            from: envelope.payload
                        ), await driver.acknowledge(
                            acknowledgement,
                            receivedOn: transportID,
                            generation: generation
                        ) else { continue }
                        await deliveryAcknowledgementSink(acknowledgement)
                        continue
                    }

                    if envelope.payloadType == ControlMessageType.peerNetworkInfo.rawValue {
                        if result.acceptance == .accepted,
                           case .peerNetworkInfo(let header, let info) = try? ControlCodec().decode(envelope: envelope),
                           header.context == ControlContext(networkID: envelope.networkID, sourceNodeID: envelope.sourceNodeID, destinationNodeID: envelope.destinationNodeID, sessionID: envelope.sessionID),
                           self.activeGeneration == generation {
                            let changed = self.reportedNetworkInfo?.info != info
                                || self.peerReportedIPv4Address() != info.ipv4Address
                            self.reportedNetworkInfo = (info, Date())
                            if changed { await self.peerNetworkInfoChanged() }
                        }
                        continue
                    }

                    if envelope.payloadType == ControlMessageType.peerLifecycle.rawValue,
                       case .peerLifecycle(_, let notice) = try? ControlCodec().decode(envelope: envelope) {
                        await peerLifecycleSink(envelope.sourceNodeID, notice)
                        continue
                    }

                    // Session replay acceptance precedes application persistence. A
                    // duplicate may be a retry of an earlier failed save, so it must
                    // revisit the idempotent sink before we can acknowledge it.
                    guard result.acceptance == .accepted || result.acceptance == .duplicate,
                          await incomingEnvelopeSink(envelope),
                          self.activeGeneration == generation,
                          !Task.isCancelled else { continue }
                    if let acknowledgement = result.acknowledgement,
                       let payload = try? JSONEncoder().encode(acknowledgement) {
                        let acknowledgementEnvelope = BeakrNetEnvelope(
                            networkID: acknowledgement.networkID,
                            sessionID: acknowledgement.sessionID,
                            sourceNodeID: envelope.destinationNodeID,
                            destinationNodeID: envelope.sourceNodeID,
                            sequenceNumber: envelope.sequenceNumber,
                            channel: .control,
                            deliveryPolicy: DeliveryPolicy(durability: .ephemeral),
                            payloadType: DeliveryAcknowledgement.payloadType,
                            payload: payload
                        )
                        try? await transport.send(acknowledgementEnvelope)
                    }
                }
            }
        } else if let generation = activeGeneration {
            reportedNetworkInfo = nil
            receiveTask?.cancel()
            receiveTask = nil
            await driver.unregister(transportID: id, generation: generation)
            _ = await coordinator.removeCandidate(
                transportID: id,
                generation: generation,
                reason: .withdrawn
            )
            activeGeneration = nil
        }
    }

    public func peerReportedIPv4Address(now: Date = Date()) -> String? {
        guard activeGeneration != nil, let report = reportedNetworkInfo,
              now.timeIntervalSince(report.receivedAt) < 20 else { return nil }
        return report.info.ipv4Address
    }

    public func generation() -> UInt64? { activeGeneration }
}
