import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetHost

@Suite("Host protocol service integration")
struct HostServicesTests {
    @Test("Queued work survives credential renewal and revocation refresh before routes open")
    func maintenanceWithQueuedWork() async throws {
        let log = ServiceLog()
        let data = DataService(log: log, pending: 3)
        let composite = CompositeHostRecoveryService(
            data: data, blackboard: BlackboardService(log: log), transfers: TransferService(log: log),
            trust: TrustService(log: log), routes: RouteSink(log: log)
        )
        let host = BeakrNetHostCoordinator(recovery: composite)
        try await host.start()
        #expect(await data.pendingCount() == 3)
        let events = await log.events
        let renewal = try #require(events.firstIndex(of: "trust.renew"))
        let revocation = try #require(events.firstIndex(of: "trust.revocation"))
        let routes = try #require(events.lastIndex(of: "routes.true"))
        #expect(renewal < revocation && revocation < routes)
    }

    @Test("Repository-open failure prevents trust maintenance and route eligibility")
    func recoveryFailure() async {
        let log = ServiceLog()
        let composite = CompositeHostRecoveryService(
            data: DataService(log: log, pending: 1, failsOpen: true), blackboard: BlackboardService(log: log),
            transfers: TransferService(log: log), trust: TrustService(log: log), routes: RouteSink(log: log)
        )
        let host = BeakrNetHostCoordinator(recovery: composite)
        await #expect(throws: ServiceFailure.failed) { try await host.start() }
        #expect(await host.synchronizationState().lifecycle == .failed)
        #expect(!(await log.events).contains("trust.restore"))
    }

    @Test("Profile repositories construct a host while trust and routes remain explicit")
    func profileHostConstruction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_000)
        let profile = try NetworkProfile(
            networkID: NetworkID(),
            localNodeID: NodeID(),
            displayName: "Red",
            createdAt: now
        )
        let runtime = try await ProfileRuntimeStorage.open(
            profile: profile,
            rootURL: directory,
            policy: ProfileRuntimePolicy(relayQueue: RelayQueuePolicy(
                maximumMessagesPerNode: 8,
                maximumTotalMessages: 16,
                messageTimeToLive: 60
            )),
            now: now
        )
        let log = ServiceLog()
        let services = ProfileHostServices.make(
            runtime: runtime,
            trust: TrustService(log: log),
            routes: RouteSink(log: log),
            now: { now },
            restorePendingData: { await log.add("data.restore.real") }
        )

        try await services.coordinator.start()

        let state = await services.coordinator.synchronizationState()
        #expect(state.recovered)
        #expect(await services.data.admissionPermitted)
        #expect(await services.transfers.admissionPermitted)
        let events = await log.events
        let trust = try #require(events.firstIndex(of: "trust.restore"))
        let routes = try #require(events.firstIndex(of: "routes.true"))
        #expect(trust < routes)
        #expect(events.contains("data.restore.real"))
    }

    @Test("Route policy gates authenticated owners without authorizing candidates")
    func routePolicyGating() async {
        let policy = ProfileRoutePolicyController()
        let lan = ManagedRoute(kind: .local)
        let relay = ManagedRoute(kind: .relay)
        await policy.register(lan)
        await policy.register(relay)
        #expect(await lan.latestPermission == false)
        #expect(await relay.latestPermission == false)

        await policy.setAllRoutesPermitted(true)
        #expect(await lan.latestPermission == false)
        #expect(await relay.latestPermission == true)

        await policy.setLANPermitted(true)
        #expect(await lan.latestPermission == true)
        await policy.setAllRoutesPermitted(false)
        #expect(await lan.latestPermission == false)
        #expect(await relay.latestPermission == false)
        #expect(await policy.routeCount() == 2)
    }

    @Test("Authenticated trust lifecycle executes every required operation")
    func authenticatedTrustLifecycle() async throws {
        let log = ServiceLog()
        let trust = AuthenticatedTrustLifecycleService(
            restore: { await log.add("restore") },
            renewCredentialIfNeeded: { await log.add("renew") },
            refreshRevocations: { await log.add("revocations") },
            checkpoint: { await log.add("checkpoint") }
        )
        try await trust.restore()
        try await trust.renewCredentialIfNeeded()
        try await trust.refreshRevocations()
        try await trust.checkpoint()
        #expect(await log.events == ["restore", "renew", "revocations", "checkpoint"])
    }

    @Test("Authenticated transport ownership follows host route permission")
    func authenticatedTransportOwnership() async throws {
        let networkID = NetworkID()
        let local = NodeID()
        let remote = NodeID()
        let session = BeakrNetSession(
            id: SessionID(),
            networkID: networkID,
            localNodeID: local,
            remoteNodeID: remote,
            state: .active
        )
        let coordinator = PeerRouteCoordinator(networkID: networkID, remoteNodeID: remote)
        let driver = SessionDeliveryDriver(session: session, coordinator: coordinator)
        let transport = HostTestTransport(kind: .local)
        let owner = await AuthenticatedTransportRouteOwner(
            transport: transport,
            coordinator: coordinator,
            driver: driver
        )
        let policy = ProfileRoutePolicyController()
        await policy.register(owner)
        #expect(await owner.generation() == nil)

        await policy.setAllRoutesPermitted(true)
        #expect(await owner.generation() == nil)
        await policy.setLANPermitted(true)
        let generation = try #require(await owner.generation())
        #expect(await coordinator.isAuthenticatedRoute(
            transportID: transport.id,
            generation: generation
        ))

        await policy.setAllRoutesPermitted(false)
        #expect(await owner.generation() == nil)
        #expect(await coordinator.candidate(transportID: transport.id) == nil)
    }

    @Test("Authenticated transport exchanges acknowledgements and reports accepted receipts")
    func authenticatedTransportAcknowledgements() async throws {
        let networkID = NetworkID()
        let sessionID = SessionID()
        let local = NodeID()
        let remote = NodeID()
        let session = BeakrNetSession(
            id: sessionID,
            networkID: networkID,
            localNodeID: local,
            remoteNodeID: remote,
            state: .active
        )
        let coordinator = PeerRouteCoordinator(networkID: networkID, remoteNodeID: remote)
        let driver = SessionDeliveryDriver(session: session, coordinator: coordinator)
        let transport = AcknowledgementTestTransport()
        let receipts = AcknowledgementReceiptLog()
        let owner = await AuthenticatedTransportRouteOwner(
            transport: transport,
            coordinator: coordinator,
            driver: driver,
            deliveryAcknowledgementSink: { acknowledgement in
                await receipts.record(acknowledgement)
            }
        )
        await owner.setPermitted(true)

        let outgoing = BeakrNetEnvelope(
            networkID: networkID,
            sessionID: sessionID,
            sourceNodeID: local,
            destinationNodeID: remote,
            sequenceNumber: 1,
            deliveryPolicy: DeliveryPolicy(durability: .durable),
            payloadType: "test.message",
            payload: Data([1])
        )
        _ = try await driver.deliver(outgoing)
        let acknowledgement = DeliveryAcknowledgement(
            networkID: networkID,
            sessionID: sessionID,
            messageID: outgoing.messageID
        )
        await transport.inject(BeakrNetEnvelope(
            networkID: networkID,
            sessionID: sessionID,
            sourceNodeID: remote,
            destinationNodeID: local,
            sequenceNumber: 2,
            channel: .control,
            deliveryPolicy: DeliveryPolicy(durability: .ephemeral),
            payloadType: DeliveryAcknowledgement.payloadType,
            payload: try JSONEncoder().encode(acknowledgement)
        ))

        for _ in 0..<50 where await receipts.received.isEmpty { await Task.yield() }
        #expect(await receipts.received == [acknowledgement])
        #expect(await session.pendingDelivery(for: outgoing.messageID) == nil)

        let incoming = BeakrNetEnvelope(
            networkID: networkID,
            sessionID: sessionID,
            sourceNodeID: remote,
            destinationNodeID: local,
            sequenceNumber: 3,
            deliveryPolicy: DeliveryPolicy(durability: .durable),
            payloadType: "test.message",
            payload: Data([2])
        )
        await transport.inject(incoming)
        for _ in 0..<50 where await transport.sent.count < 2 { await Task.yield() }
        let sentAcknowledgement = try #require(await transport.sent.last)
        #expect(sentAcknowledgement.payloadType == DeliveryAcknowledgement.payloadType)
        #expect(
            try JSONDecoder().decode(DeliveryAcknowledgement.self, from: sentAcknowledgement.payload)
                == DeliveryAcknowledgement(networkID: networkID, sessionID: sessionID, messageID: incoming.messageID)
        )

        await owner.setPermitted(false)
    }

    @Test("Connection registry requires revocation state and removes the complete route")
    func profileConnectionRegistry() async throws {
        let networkID = NetworkID()
        let local = NodeID()
        let remote = NodeID()
        let revocations = RevocationSnapshotDistributor(verifier: { _, _ in })
        let routePolicy = ProfileRoutePolicyController()
        let registry = ProfileConnectionRegistry(
            networkID: networkID,
            localNodeID: local,
            revocations: revocations,
            routePolicy: routePolicy
        )
        let rejected = RevocableHostTestTransport(kind: .local)
        await #expect(throws: ProfileConnectionRegistryError.missingRevocationSnapshot) {
            _ = try await registry.admit(
                transport: rejected,
                remoteNodeID: remote,
                sessionID: SessionID()
            )
        }
        #expect(await rejected.isClosed)

        let snapshot = CredentialRevocationSnapshot(
            claims: CredentialRevocationClaims(
                issuerID: AuthorityID(rawValue: UUID()),
                generatedAtMilliseconds: 1_000_000,
                revocations: []
            ),
            issuerSignature: Data([1])
        )
        _ = try await revocations.publish(snapshot)
        let transport = RevocableHostTestTransport(kind: .local)
        let sessionID = SessionID()
        let connection = try await registry.admit(
            transport: transport,
            remoteNodeID: remote,
            sessionID: sessionID
        )
        #expect(await transport.installedSnapshotCount == 1)
        #expect(await registry.connectionCount() == 1)
        #expect(await registry.peerCount() == 1)
        #expect(await connection.session.id == sessionID)

        await routePolicy.setAllRoutesPermitted(true)
        await routePolicy.setLANPermitted(true)
        #expect(await connection.routeOwner.generation() != nil)
        await registry.remove(transport: transport)
        #expect(await registry.connectionCount() == 0)
        #expect(await registry.peerCount() == 0)
        #expect(await transport.isClosed)
        #expect(await connection.routeOwner.generation() == nil)
    }

    @Test("Bonjour bridge admits only the expected authenticated peer and removes path loss")
    func profileLANConnectionController() async throws {
        let networkID = NetworkID()
        let local = NodeID()
        let remote = NodeID()
        let revocations = RevocationSnapshotDistributor(verifier: { _, _ in })
        _ = try await revocations.publish(CredentialRevocationSnapshot(
            claims: CredentialRevocationClaims(
                issuerID: AuthorityID(rawValue: UUID()),
                generatedAtMilliseconds: 1_000_000,
                revocations: []
            ),
            issuerSignature: Data([1])
        ))
        let routePolicy = ProfileRoutePolicyController()
        let registry = ProfileConnectionRegistry(
            networkID: networkID,
            localNodeID: local,
            revocations: revocations,
            routePolicy: routePolicy
        )
        let transport = RevocableHostTestTransport(kind: .local, peerNodeID: remote)
        let controller = ProfileLANConnectionController(
            registry: registry,
            maximumConnections: 1,
            authenticate: { _, _, _, _ in transport }
        )
        let connection = HostBonjourConnection()
        let peer = try await controller.authenticateAndAdmit(
            connection: connection,
            role: .initiator,
            expectedPeerNodeID: remote,
            advertisementNonce: Data(repeating: 1, count: 32),
            sessionID: SessionID()
        )
        #expect(await controller.connectionCount() == 1)
        #expect(await registry.connectionCount() == 1)
        #expect(await peer.session.remoteNodeID == remote)

        await controller.connectionEnded(connection.id)
        #expect(await controller.connectionCount() == 0)
        #expect(await registry.connectionCount() == 0)
        #expect(await transport.isClosed)
    }

    @Test("Profile Bonjour runtime owns lifecycle and rejects unresolved accepted peers")
    func profileBonjourRuntimeLifecycle() async throws {
        let local = NodeID()
        let revocations = RevocationSnapshotDistributor(verifier: { _, _ in })
        let routePolicy = ProfileRoutePolicyController()
        let registry = ProfileConnectionRegistry(
            networkID: NetworkID(),
            localNodeID: local,
            revocations: revocations,
            routePolicy: routePolicy
        )
        let connections = ProfileLANConnectionController(
            registry: registry,
            authenticate: { _, _, _, _ in
                Issue.record("An unresolved accepted peer must not authenticate")
                return RevocableHostTestTransport(kind: .local)
            }
        )
        let browser = HostBonjourBrowser()
        let listener = HostBonjourListener()
        let runtime = ProfileBonjourRuntimeService.make(
            localNodeID: local,
            localAdvertisementNonce: Data(repeating: 1, count: 32),
            browser: browser,
            connectionFactory: HostBonjourConnectionFactory(),
            listener: listener,
            connections: connections,
            sessionID: { _ in SessionID() },
            acceptedPeer: { _ in nil }
        )

        await runtime.start()
        #expect(await runtime.running())
        #expect(browser.started)
        #expect(listener.started)

        let accepted = HostBonjourConnection()
        listener.send(.connection(accepted))
        for _ in 0..<20 where !accepted.cancelled { await Task.yield() }
        #expect(accepted.cancelled)
        #expect(await registry.connectionCount() == 0)

        await runtime.stop()
        #expect(!(await runtime.running()))
        #expect(browser.cancelled)
        #expect(listener.cancelled)
    }
}

private enum ServiceFailure: Error { case failed }
private actor ServiceLog { var events: [String] = []; func add(_ value: String) { events.append(value) } }
private actor DataService: HostDataLifecycleService {
    let log: ServiceLog; let pending: Int; let failsOpen: Bool
    init(log: ServiceLog, pending: Int, failsOpen: Bool = false) { self.log = log; self.pending = pending; self.failsOpen = failsOpen }
    func open() async throws { await log.add("data.open"); if failsOpen { throw ServiceFailure.failed } }
    func restorePending() async { await log.add("data.restore") }; func reconcileExpired() async { await log.add("data.expire") }
    func checkpoint() async { await log.add("data.checkpoint") }; func setAdmissionPermitted(_ permitted: Bool) async { await log.add("data.admit.\(permitted)") }
    func pendingCount() -> Int { pending }
}
private actor BlackboardService: HostBlackboardLifecycleService {
    let log: ServiceLog; init(log: ServiceLog) { self.log = log }
    func open() async { await log.add("blackboard.open") }; func checkpoint() async { await log.add("blackboard.checkpoint") }
}
private actor TransferService: HostTransferLifecycleService {
    let log: ServiceLog; init(log: ServiceLog) { self.log = log }
    func open() async { await log.add("transfer.open") }; func garbageCollectExpired() async { await log.add("transfer.gc") }
    func checkpoint() async { await log.add("transfer.checkpoint") }; func setAdmissionPermitted(_ permitted: Bool) async { await log.add("transfer.admit.\(permitted)") }
    func activeCount() -> Int { 0 }
}
private actor TrustService: HostTrustLifecycleService {
    let log: ServiceLog; init(log: ServiceLog) { self.log = log }
    func restore() async { await log.add("trust.restore") }; func renewCredentialIfNeeded() async { await log.add("trust.renew") }
    func refreshRevocations() async { await log.add("trust.revocation") }; func checkpoint() async { await log.add("trust.checkpoint") }
}
private actor RouteSink: HostRoutePolicySink {
    let log: ServiceLog; init(log: ServiceLog) { self.log = log }
    func setAllRoutesPermitted(_ permitted: Bool) async { await log.add("routes.\(permitted)") }
    func setLANPermitted(_ permitted: Bool) async { await log.add("lan.\(permitted)") }
}

private actor ManagedRoute: HostManagedRoute {
    nonisolated let id = TransportID()
    nonisolated let kind: TransportKind
    private(set) var permissions: [Bool] = []
    var latestPermission: Bool? { permissions.last }

    init(kind: TransportKind) { self.kind = kind }
    func setPermitted(_ permitted: Bool) { permissions.append(permitted) }
}

private actor HostTestTransport: BeakrNetTransport {
    nonisolated let id = TransportID()
    nonisolated let kind: TransportKind
    nonisolated let capabilities = TransportCapabilities(
        preservesOrder: true,
        supportsImmediateDelivery: true,
        supportsQueuedDelivery: true,
        supportsBackgroundDelivery: false
    )

    init(kind: TransportKind) { self.kind = kind }
    func send(_ envelope: BeakrNetEnvelope) async throws {}
    func receive() async -> BeakrNetEnvelope? { nil }
    func close() async {}
}

private actor AcknowledgementReceiptLog {
    private(set) var received: [DeliveryAcknowledgement] = []
    func record(_ acknowledgement: DeliveryAcknowledgement) { received.append(acknowledgement) }
}

private actor AcknowledgementTestTransport: BeakrNetTransport {
    nonisolated let id = TransportID()
    nonisolated let kind = TransportKind.local
    nonisolated let capabilities = TransportCapabilities(
        preservesOrder: true,
        supportsImmediateDelivery: true,
        supportsQueuedDelivery: true,
        supportsBackgroundDelivery: false
    )
    private(set) var sent: [BeakrNetEnvelope] = []
    private var incoming: [BeakrNetEnvelope] = []
    private var waiter: CheckedContinuation<BeakrNetEnvelope?, Never>?

    func send(_ envelope: BeakrNetEnvelope) { sent.append(envelope) }

    func receive() async -> BeakrNetEnvelope? {
        if !incoming.isEmpty { return incoming.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    func inject(_ envelope: BeakrNetEnvelope) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: envelope)
        } else {
            incoming.append(envelope)
        }
    }

    func close() {
        waiter?.resume(returning: nil)
        waiter = nil
    }
}

private actor RevocableHostTestTransport: ProfileAuthenticatedPeerTransport {
    nonisolated let id = TransportID()
    nonisolated var revocationConsumerID: TransportID { id }
    nonisolated let kind: TransportKind
    nonisolated let peerNodeID: NodeID
    nonisolated let capabilities = TransportCapabilities(
        preservesOrder: true,
        supportsImmediateDelivery: true,
        supportsQueuedDelivery: true,
        supportsBackgroundDelivery: false
    )
    private(set) var installedSnapshotCount = 0
    private(set) var isClosed = false

    init(kind: TransportKind, peerNodeID: NodeID = NodeID()) {
        self.kind = kind
        self.peerNodeID = peerNodeID
    }
    func send(_ envelope: BeakrNetEnvelope) async throws {}
    func receive() async -> BeakrNetEnvelope? { nil }
    func close() { isClosed = true }
    func installRevocationSnapshot(_ snapshot: CredentialRevocationSnapshot) throws {
        installedSnapshotCount += 1
    }
}

private final class HostBonjourConnection: BonjourConnection, @unchecked Sendable {
    private let lock = NSLock()
    let id = UUID()
    private var isCancelled = false
    var cancelled: Bool { lock.withLock { isCancelled } }
    func start(stateHandler: @escaping @Sendable (BonjourConnectionState) -> Void) {}
    func sendFrame(_ data: Data) async throws {}
    func receiveFrame(maximumBytes: Int) async throws -> Data { Data() }
    func peerCertificate() throws -> BonjourPeerCertificate {
        BonjourPeerCertificate(derRepresentation: Data(), publicKeyRepresentation: Data())
    }
    func cancel() { lock.withLock { isCancelled = true } }
}

private final class HostBonjourBrowser: BonjourBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (BonjourBrowserEvent) -> Void)?
    private var didCancel = false
    var started: Bool { lock.withLock { handler != nil } }
    var cancelled: Bool { lock.withLock { didCancel } }
    func start(eventHandler: @escaping @Sendable (BonjourBrowserEvent) -> Void) {
        lock.withLock { handler = eventHandler }
    }
    func cancel() { lock.withLock { didCancel = true } }
}

private final class HostBonjourListener: BonjourListening, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (BonjourListenerEvent) -> Void)?
    private var didCancel = false
    var started: Bool { lock.withLock { handler != nil } }
    var cancelled: Bool { lock.withLock { didCancel } }
    func start(eventHandler: @escaping @Sendable (BonjourListenerEvent) -> Void) {
        lock.withLock { handler = eventHandler }
    }
    func send(_ event: BonjourListenerEvent) { lock.withLock { handler }?(event) }
    func cancel() { lock.withLock { didCancel = true } }
}

private struct HostBonjourConnectionFactory: BonjourConnectionFactory {
    func makeConnection(to endpointID: BonjourEndpointID) throws -> any BonjourConnection {
        HostBonjourConnection()
    }
}
