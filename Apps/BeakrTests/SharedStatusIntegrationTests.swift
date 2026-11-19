import Foundation
import Testing
import BeakrNetCore
import BeakrNetData
import BeakrNetHost
import BeakrNetAuthority
import BeakrNetSecurity
@testable import Beakr

private actor StatusMailbox {
    private var queue: [BeakrNetEnvelope] = []
    private var waiter: CheckedContinuation<BeakrNetEnvelope?, Never>?
    private var closed = false
    func put(_ envelope: BeakrNetEnvelope) {
        guard !closed else { return }
        if let waiter { self.waiter = nil; waiter.resume(returning: envelope) }
        else { queue.append(envelope) }
    }
    func next() async -> BeakrNetEnvelope? {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }
    func close() { closed = true; waiter?.resume(returning: nil); waiter = nil }
}

private actor StatusFixtureTransport: BeakrNetTransport, RevocationSnapshotConsumer {
    nonisolated let id = TransportID()
    nonisolated var revocationConsumerID: TransportID { id }
    nonisolated let kind = TransportKind.local
    nonisolated let capabilities = TransportCapabilities(preservesOrder: true, supportsImmediateDelivery: true,
                                                         supportsQueuedDelivery: true, supportsBackgroundDelivery: false)
    let incoming: StatusMailbox
    let outgoing: StatusMailbox
    private(set) var sent: [BeakrNetEnvelope] = []
    init(incoming: StatusMailbox, outgoing: StatusMailbox) { self.incoming = incoming; self.outgoing = outgoing }
    func send(_ envelope: BeakrNetEnvelope) async throws { sent.append(envelope); await outgoing.put(envelope) }
    func receive() async -> BeakrNetEnvelope? { await incoming.next() }
    func close() async { await incoming.close() }
    func installRevocationSnapshot(_ snapshot: CredentialRevocationSnapshot) throws {}
}

private actor StatusIntegrationProbe {
    private(set) var samples = 0
    private(set) var inboxCalls = 0
    let deliveries: AsyncStream<UUID>
    private let deliverySink: AsyncStream<UUID>.Continuation
    init() {
        let stream = AsyncStream<UUID>.makeStream()
        deliveries = stream.stream; deliverySink = stream.continuation
    }
    func sample() -> SharedStatusSnapshot {
        samples += 1
        return SharedStatusSnapshot(schemaVersion: 1, sampledAt: Date(), applicationVersion: "integration",
                                    runtimeState: .running, authenticatedPeerCount: 1)
    }
    func inbox() { inboxCalls += 1 }
    func delivered(_ id: UUID) { deliverySink.yield(id) }
}

@MainActor
private struct StatusIntegrationPair {
    let network: NetworkID
    let a: NodeID
    let b: NodeID
    let left: SharedStatusRuntime
    let right: SharedStatusRuntime
    let leftRegistry: ProfileConnectionRegistry
    let rightRegistry: ProfileConnectionRegistry
    let leftWire: StatusFixtureTransport
    let rightWire: StatusFixtureTransport
    let probe: StatusIntegrationProbe
    let store: PersistentDataState
    let root: URL

    static func make() async throws -> Self {
        let network = NetworkID(), a = NodeID(), b = NodeID(), session = SessionID()
        let probe = StatusIntegrationProbe()
        let left = SharedStatusRuntime(profileID: UUID(), networkID: network, localNodeID: a, sample: { await probe.sample() })
        let right = SharedStatusRuntime(profileID: UUID(), networkID: network, localNodeID: b, sample: { await probe.sample() })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try await PersistentDataState.open(fileURL: root.appendingPathComponent("data.json"))
        let inbox = ApplicationMessageInbox()
        await inbox.attach(store, context: MessageProvenanceContext(profileID: UUID(), authorityID: UUID(),
                                                                    authorityEndpoint: "fixture", localCredentialID: UUID()))
        let revocations = RevocationSnapshotDistributor(verifier: { _, _ in })
        _ = try await revocations.publish(CredentialRevocationSnapshot(
            claims: CredentialRevocationClaims(issuerID: AuthorityID(rawValue: UUID()),
                                                generatedAtMilliseconds: 1_000_000, revocations: []), issuerSignature: Data([1])))
        let leftPolicy = ProfileRoutePolicyController(), rightPolicy = ProfileRoutePolicyController()
        let leftRegistry = ProfileConnectionRegistry(
            networkID: network, localNodeID: a, revocations: revocations, routePolicy: leftPolicy,
            deliveryAcknowledgementSink: { await probe.delivered($0.messageID.rawValue) },
            authenticatedApplicationSink: { await left.receive($0, peer: $1, route: $2) },
            peerRouteEnded: { peer, id in Task { await left.routeEnded(peer: peer, routeID: id) } })
        let rightRegistry = ProfileConnectionRegistry(
            networkID: network, localNodeID: b, revocations: revocations, routePolicy: rightPolicy,
            incomingEnvelopeSink: { envelope in await probe.inbox(); return await inbox.record(envelope) },
            authenticatedApplicationSink: { await right.receive($0, peer: $1, route: $2) },
            peerRouteEnded: { peer, id in Task { await right.routeEnded(peer: peer, routeID: id) } })
        await left.configure(resolve: { await leftRegistry.applicationRoute(for: $0) },
                             submit: { await leftRegistry.submit($0, expectedRouteID: $1) },
                             nextSequence: { await leftRegistry.nextSequenceNumber(for: $0) })
        await right.configure(resolve: { await rightRegistry.applicationRoute(for: $0) },
                              submit: { await rightRegistry.submit($0, expectedRouteID: $1) },
                              nextSequence: { await rightRegistry.nextSequenceNumber(for: $0) })
        let leftMailbox = StatusMailbox(), rightMailbox = StatusMailbox()
        let leftWire = StatusFixtureTransport(incoming: leftMailbox, outgoing: rightMailbox)
        let rightWire = StatusFixtureTransport(incoming: rightMailbox, outgoing: leftMailbox)
        await leftPolicy.setAllRoutesPermitted(true); await leftPolicy.setLANPermitted(true)
        await rightPolicy.setAllRoutesPermitted(true); await rightPolicy.setLANPermitted(true)
        _ = try await leftRegistry.admit(transport: leftWire, remoteNodeID: b, sessionID: session)
        _ = try await rightRegistry.admit(transport: rightWire, remoteNodeID: a, sessionID: session)
        return Self(network: network, a: a, b: b, left: left, right: right, leftRegistry: leftRegistry,
                    rightRegistry: rightRegistry, leftWire: leftWire, rightWire: rightWire, probe: probe,
                    store: store, root: root)
    }

    func close() async {
        await left.invalidate(); await right.invalidate()
        await leftRegistry.remove(transport: leftWire); await rightRegistry.remove(transport: rightWire)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor StatusRouteFixture {
    var route: ProfileApplicationRoute? = ProfileApplicationRoute(id: UUID(), sessionID: SessionID())
    private var sequence: UInt64 = 0
    let sent: AsyncStream<BeakrNetEnvelope>
    private let sink: AsyncStream<BeakrNetEnvelope>.Continuation
    private(set) var writes = 0
    init() {
        let stream = AsyncStream<BeakrNetEnvelope>.makeStream()
        sent = stream.stream; sink = stream.continuation
    }
    func resolve() -> ProfileApplicationRoute? { route }
    func replaceRoute() { route = ProfileApplicationRoute(id: UUID(), sessionID: route?.sessionID ?? SessionID()) }
    func deny() { route = nil }
    func restore(_ previous: ProfileApplicationRoute) { route = previous }
    func next() -> UInt64 { sequence += 1; return sequence }
    func send(_ envelope: BeakrNetEnvelope) -> HostDeliveryAttempt {
        writes += 1; sink.yield(envelope); return .submitted
    }
}

private actor StatusSampleGate {
    let entered: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var waiter: CheckedContinuation<Void, Never>?
    init() {
        let stream = AsyncStream<Void>.makeStream()
        entered = stream.stream; signal = stream.continuation
    }
    func sample() async -> SharedStatusSnapshot {
        await withCheckedContinuation { waiter = $0; signal.yield(()) }
        return SharedStatusSnapshot(schemaVersion: 1, sampledAt: Date(), applicationVersion: "gated",
                                    runtimeState: .running, authenticatedPeerCount: 1)
    }
    func release() { waiter?.resume(); waiter = nil }
}

@MainActor
@Suite("Selected-runtime status integration")
struct SharedStatusIntegrationTests {
    @Test("Recovered trust requires fresh permission even when the registry route is unchanged")
    func trustRecoveryPermission() async throws {
        let wire = StatusRouteFixture(), peer = NodeID()
        let service = makeRuntime()
        await configure(service, wire)
        let originalRoute = try #require(await wire.resolve())
        let permission = try #require(await service.availability(for: peer).bindingID)
        try await service.setSharing(true, peer: peer, bindingID: permission)
        await wire.deny()
        await service.revalidate()
        await wire.restore(originalRoute)
        await service.revalidate()
        let recovered = await service.availability(for: peer)
        #expect(recovered.bindingID != permission)
        #expect(!recovered.sharing)
        await #expect(throws: SharedStatusError.unavailable) {
            try await service.setSharing(true, peer: peer, bindingID: permission)
        }
        await service.invalidate()
    }

    @Test("Deadline precision tolerance is bounded to one millisecond")
    func deadlinePrecision() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let local = NodeID(), peer = NodeID(), network = NetworkID(), session = SessionID()
        let client = SharedStatusBinding(runtimeID: UUID(), networkID: network, localNodeID: peer,
                                         peerNodeID: local, sessionID: session)
        let server = SharedStatusBinding(runtimeID: UUID(), networkID: network, localNodeID: local,
                                         peerNodeID: peer, sessionID: session)
        let probe = StatusIntegrationProbe()
        let responder = SharedStatusResponder(binding: server, enabled: true, clock: { now }, sample: { await probe.sample() })
        for delta in [0.000_000_2, 0.0005, 0.01] {
            let envelope = try SharedStatusProtocol.envelope(
                DataMessage(kind: .request, operation: SharedStatusProtocol.operation,
                            correlationID: DataCorrelationID(), deadline: now.addingTimeInterval(9)),
                binding: client, sequence: 1, now: now, expiresAt: now.addingTimeInterval(9 + delta))
            let response = await responder.receive(envelope, authenticatedPeer: peer)
            #expect(response?.kind == (delta < 0.001 ? .response : .applicationError))
            if delta > 0.001 { #expect(response?.errorCode == .invalidRequest) }
        }
        #expect(await probe.samples == 2)
    }

    @Test("Withdrawal during sampling produces no outgoing snapshot")
    func withdrawalDuringSampling() async throws { try await blockedDisclosure(false) }

    @Test("Runtime stop during sampling produces no outgoing snapshot")
    func stopDuringSampling() async throws { try await blockedDisclosure(true) }

    private func blockedDisclosure(_ stop: Bool) async throws {
        let gate = StatusSampleGate(), wire = StatusRouteFixture()
        let network = NetworkID(), local = NodeID(), peer = NodeID()
        let service = SharedStatusRuntime(profileID: UUID(), networkID: network, localNodeID: local,
                                          sample: { await gate.sample() })
        await configure(service, wire)
        let route = try #require(await wire.resolve())
        let permission = try #require(await service.availability(for: peer).bindingID)
        try await service.setSharing(true, peer: peer, bindingID: permission)
        let now = Date()
        let binding = SharedStatusBinding(runtimeID: UUID(), networkID: network, localNodeID: peer,
                                          peerNodeID: local, sessionID: route.sessionID)
        let request = try SharedStatusProtocol.envelope(
            DataMessage(kind: .request, operation: SharedStatusProtocol.operation,
                        correlationID: DataCorrelationID(), deadline: now.addingTimeInterval(10)),
            binding: binding, sequence: 1, now: now, expiresAt: now.addingTimeInterval(10))
        let task = Task { await service.receive(request, peer: peer, route: route) }
        var entered = await gate.entered.makeAsyncIterator()
        _ = await entered.next()
        if stop { await service.invalidate() }
        else { try await service.setSharing(false, peer: peer, bindingID: permission) }
        await gate.release()
        #expect(await task.value == false)
        #expect(await wire.writes == 0)
        await service.invalidate()
    }

    @Test("Route substitution is checked again before submission")
    func staleRouteSubmit() async throws {
        let pair = try await StatusIntegrationPair.make()
        do {
            let route = try #require(await pair.leftRegistry.applicationRoute(for: pair.b))
            let now = Date()
            let envelope = try SharedStatusProtocol.envelope(
                DataMessage(kind: .request, operation: SharedStatusProtocol.operation,
                            correlationID: DataCorrelationID(), deadline: now.addingTimeInterval(10)),
                binding: SharedStatusBinding(runtimeID: UUID(), networkID: pair.network, localNodeID: pair.a,
                                             peerNodeID: pair.b, sessionID: route.sessionID),
                sequence: await pair.leftRegistry.nextSequenceNumber(for: pair.b), now: now,
                expiresAt: now.addingTimeInterval(10))
            #expect(await pair.leftRegistry.submit(envelope, expectedRouteID: UUID()) == .routeUnavailable)
            #expect(await pair.leftWire.sent.filter { $0.payloadType == DataMessage.payloadType }.isEmpty)
            await pair.close()
        } catch { await pair.close(); throw error }
    }

    @Test("Authenticated application route separates status from durable chat and acknowledgements")
    func registryRoundTripAndChat() async throws {
        let pair = try await StatusIntegrationPair.make()
        do {
            let leftID = try #require(await pair.left.availability(for: pair.b).bindingID)
            let rightID = try #require(await pair.right.availability(for: pair.a).bindingID)
            await #expect(throws: SharedStatusError.remote(.unauthorized)) {
                try await pair.left.request(peer: pair.b, bindingID: leftID)
            }
            #expect(await pair.probe.samples == 0)
            try await pair.right.setSharing(true, peer: pair.a, bindingID: rightID)
            let result = try await pair.left.request(peer: pair.b, bindingID: leftID)
            #expect(result.snapshot.applicationVersion == "integration")
            #expect(result.binding.networkID == pair.network)
            #expect(await pair.probe.samples == 1)
            #expect(await pair.probe.inboxCalls == 0)
            #expect(await pair.store.recordedResults().isEmpty)
            #expect(await pair.rightWire.sent.filter { $0.payloadType == DeliveryAcknowledgement.payloadType }.isEmpty)

            let route = try #require(await pair.leftRegistry.applicationRoute(for: pair.b))
            let chat = try DataCodec().makeEnvelope(
                for: HostMessageRequest.text(destination: pair.b, body: "preserved chat path").message,
                networkID: pair.network, sessionID: route.sessionID, sourceNodeID: pair.a, destinationNodeID: pair.b,
                sequenceNumber: await pair.leftRegistry.nextSequenceNumber(for: pair.b), createdAt: Date(),
                deliveryPolicy: DeliveryPolicy(durability: .durable, expiresAt: Date().addingTimeInterval(60)))
            #expect(await pair.leftRegistry.submit(chat) == .submitted)
            var acknowledgements = await pair.probe.deliveries.makeAsyncIterator()
            #expect(await acknowledgements.next() == chat.messageID.rawValue)
            #expect(await pair.store.recordedResults().count == 1)
            #expect(await pair.probe.inboxCalls == 1)
            try await pair.right.setSharing(false, peer: pair.a, bindingID: rightID)
            await #expect(throws: SharedStatusError.remote(.unauthorized)) {
                try await pair.left.request(peer: pair.b, bindingID: leftID)
            }
            await pair.close()
        } catch { await pair.close(); throw error }
    }

    @Test("New peer route cannot inherit sharing or accept a delayed old UI command")
    func replacementRoute() async throws {
        let wire = StatusRouteFixture()
        let peer = NodeID()
        let service = makeRuntime()
        await configure(service, wire)
        let originalRoute = try #require(await wire.resolve())
        let first = try #require(await service.availability(for: peer).bindingID)
        try await service.setSharing(true, peer: peer, bindingID: first)
        await wire.replaceRoute()
        await service.revalidate()
        let replacement = await service.availability(for: peer)
        #expect(replacement.bindingID != first)
        #expect(!replacement.sharing)
        await #expect(throws: SharedStatusError.unavailable) {
            try await service.setSharing(true, peer: peer, bindingID: first)
        }
        await service.routeEnded(peer: peer, routeID: originalRoute.id)
        #expect(await service.availability(for: peer) == replacement)
        await service.invalidate()
    }

    @Test("Trust loss and stop invalidate a pending request and erase sharing", arguments: [false, true])
    func pendingInvalidation(_ stop: Bool) async throws {
        let wire = StatusRouteFixture(), peer = NodeID()
        let service = makeRuntime()
        await configure(service, wire)
        let id = try #require(await service.availability(for: peer).bindingID)
        try await service.setSharing(true, peer: peer, bindingID: id)
        let request = Task { try await service.request(peer: peer, bindingID: id) }
        var sent = await wire.sent.makeAsyncIterator()
        _ = await sent.next()
        if stop { await service.invalidate() }
        else { await wire.deny(); await service.revalidate() }
        await #expect(throws: SharedStatusError.invalidated) { try await request.value }
        #expect(await service.availability(for: peer) == .unavailable)
        #expect(await wire.writes == 1)
        await service.invalidate()
    }

    @Test("Inactive profile never obtains a selected-runtime service")
    func inactiveSelection() async {
        let bootstrap = NodeBootstrapModel()
        #expect(await bootstrap.sharedStatusRuntime(for: NetworkProfileID()) == nil)
    }

    private func makeRuntime() -> SharedStatusRuntime {
        SharedStatusRuntime(profileID: UUID(), networkID: NetworkID(), localNodeID: NodeID(), sample: {
            SharedStatusSnapshot(schemaVersion: 1, sampledAt: Date(), applicationVersion: "test",
                                 runtimeState: .running, authenticatedPeerCount: 1)
        })
    }

    private func configure(_ runtime: SharedStatusRuntime, _ wire: StatusRouteFixture) async {
        await runtime.configure(resolve: { _ in await wire.resolve() },
                                submit: { envelope, _ in await wire.send(envelope) },
                                nextSequence: { _ in await wire.next() })
    }
}

// Persistent-permission tests use real signed membership verification and disposable files.
// Transport admission remains fixture supplied; these do not certify live TLS or Shortcuts.
nonisolated private final class StatusPermissionIO: @unchecked Sendable {
    private let lock = NSLock()
    private var fails = false
    private var date = Date()
    func fail(_ value: Bool) { lock.lock(); defer { lock.unlock() }; fails = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
    func write(_ data: Data, _ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        if fails { throw SharedStatusPermissionError.persistenceFailed }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

@MainActor
private struct PersistentStatusFixture {
    let root: URL
    let profile: NetworkProfile
    let peer: NodeID
    let authority: CredentialAuthority
    let directory: ProfileMembershipDirectory
    let store: SharedStatusPermissionStore
    let io: StatusPermissionIO
    var url: URL { root.appendingPathComponent("permissions.json") }

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let authority = CredentialAuthority(), local = NodeIdentity(), remote = NodeIdentity()
        let network = NetworkID(), io = StatusPermissionIO()
        let profile = try NetworkProfile(networkID: network, localNodeID: local.nodeID, displayName: "permission fixture")
        let records = try [local, remote].map { node in
            ProfileMembershipRecord(credential: try authority.issue(
                nodeID: node.nodeID, nodePublicKey: node.publicKeyRepresentation, networkID: network,
                environment: "permission-test", validity: 3_600, serviceScopes: ["lan"], now: io.now()),
                certificatePublicKey: node.publicKeyRepresentation, sessionID: SessionID())
        }
        let directory = try await ProfileMembershipDirectory.open(
            fileURL: root.appendingPathComponent("membership.json"), networkID: network,
            environment: "permission-test", trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            revokedCredentialIDs: [], now: { io.now() })
        let signer = try ProfileMembershipAuthority(privateKeyRepresentation: authority.privateKeyRepresentation)
        try await directory.activate(try signer.sign(.init(
            networkID: network, generation: 1, generatedAtMilliseconds: Int64(io.now().timeIntervalSince1970 * 1_000),
            records: records)))
        let store = try SharedStatusPermissionStore(profile: profile, fileURL: root.appendingPathComponent("permissions.json"),
                                                    write: { try io.write($0, $1) })
        return Self(root: root, profile: profile, peer: remote.nodeID, authority: authority,
                    directory: directory, store: store, io: io)
    }

    func identity() async throws -> SharedStatusPermissionIdentity {
        let snapshot = try #require(await directory.serviceAuthorizationSnapshot())
        return try #require(SharedStatusPermissionIdentity(snapshot: snapshot, local: profile.localNodeID, peer: peer))
    }

    func grant() async throws {
        try await store.setSharing(true, peer: peer, identity: identity(), expectedRevision: store.state(for: peer).revision)
    }

    func withdraw() async throws {
        try await store.setSharing(false, peer: peer, identity: nil, expectedRevision: store.state(for: peer).revision)
    }

    func runtime(wire: StatusRouteFixture, gate: StatusSampleGate? = nil,
                 commitGate: StatusSampleGate? = nil, submissionGate: StatusSampleGate? = nil) async throws -> SharedStatusRuntime {
        let session = try #require(await directory.connectionSessionID(localNodeID: profile.localNodeID, peerNodeID: peer))
        await wire.restore(ProfileApplicationRoute(id: UUID(), sessionID: session))
        let directory = directory
        let runtime = SharedStatusRuntime(
            profileID: profile.id.rawValue, networkID: profile.networkID, localNodeID: profile.localNodeID,
            permissions: store, persistentPermissions: true,
            authorizationSnapshot: { await directory.serviceAuthorizationSnapshot() },
            beforeDisclosureCommit: { if let commitGate { _ = await commitGate.sample() } }, sample: {
                if let gate { return await gate.sample() }
                return SharedStatusSnapshot(schemaVersion: 1, sampledAt: Date(), applicationVersion: "persistent",
                                            runtimeState: .running, authenticatedPeerCount: 1)
            })
        await runtime.configure(resolve: { _ in await wire.resolve() },
                                submit: { envelope, _ in
                                    if let submissionGate { _ = await submissionGate.sample() }
                                    return await wire.send(envelope)
                                },
                                nextSequence: { _ in await wire.next() })
        return runtime
    }

    func publish(_ records: [ProfileMembershipRecord], generation: UInt64) async throws {
        let signer = try ProfileMembershipAuthority(privateKeyRepresentation: authority.privateKeyRepresentation)
        try await directory.activate(try signer.sign(.init(networkID: profile.networkID, generation: generation,
            generatedAtMilliseconds: Int64(io.now().timeIntervalSince1970 * 1_000), records: records)))
    }
}

@MainActor
@Suite("Persistent Shared Status permission lifetime")
struct SharedStatusPermissionTests {
    @Test("Default off; reconnect retains deliberate intent while capabilities change")
    func reconnect() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let wire = StatusRouteFixture(), service = try await f.runtime(wire: wire)
        #expect(await service.availability(for: f.peer).sharing == false)
        try await f.grant()
        let first = await service.availability(for: f.peer)
        #expect(first.sharing)
        let old = try #require(await wire.resolve())
        await wire.deny(); await service.routeEnded(peer: f.peer, routeID: old.id)
        #expect(await service.availability(for: f.peer).bindingID == nil)
        #expect(await f.store.state(for: f.peer).sharing)
        await wire.restore(ProfileApplicationRoute(id: UUID(), sessionID: old.sessionID))
        let next = await service.availability(for: f.peer)
        #expect(next.sharing && next.bindingID != first.bindingID)
        await service.routeEnded(peer: f.peer, routeID: old.id)
        #expect(await service.availability(for: f.peer).bindingID == next.bindingID)
        await service.invalidate()
    }

    @Test("Clean restart preserves intent; interrupted session requires explicit confirmation")
    func restartRecovery() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.grant()
        await f.store.checkpointStopped()
        let clean = try SharedStatusPermissionStore(profile: f.profile, fileURL: f.url)
        #expect(await clean.state(for: f.peer).sharing)
        let interrupted = try SharedStatusPermissionStore(profile: f.profile, fileURL: f.url)
        #expect(await interrupted.state(for: f.peer).sharing == false)
        #expect(await interrupted.state(for: f.peer).needsConfirmation)
        try await interrupted.setSharing(true, peer: f.peer, identity: f.identity(),
                                         expectedRevision: interrupted.state(for: f.peer).revision)
        #expect(await interrupted.state(for: f.peer).sharing)
    }

    @Test("Offline withdrawal persists through reconnection and restart")
    func offlineWithdrawal() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let wire = StatusRouteFixture(), service = try await f.runtime(wire: wire)
        try await f.grant()
        let route = try #require(await wire.resolve())
        await wire.deny(); await service.routeEnded(peer: f.peer, routeID: route.id)
        try await f.withdraw()
        await wire.restore(route)
        #expect(await service.availability(for: f.peer).sharing == false)
        await service.invalidate(); await f.store.checkpointStopped()
        let reopened = try SharedStatusPermissionStore(profile: f.profile, fileURL: f.url)
        #expect(await reopened.state(for: f.peer).sharing == false)
    }

    @Test("Failed enable grants nothing; failed withdrawal cannot resurrect after restart")
    func failedPersistence() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.io.fail(true)
        await #expect(throws: SharedStatusPermissionError.persistenceFailed) { try await f.grant() }
        #expect(await f.store.state(for: f.peer).sharing == false)
        f.io.fail(false)
        try await f.withdraw() // Explicit recovery clears the failed-write block.
        try await f.grant()
        f.io.fail(true)
        await #expect(throws: SharedStatusPermissionError.persistenceFailed) { try await f.withdraw() }
        #expect(await f.store.state(for: f.peer).sharing == false)
        await f.store.checkpointStopped() // Must not mark an unsuccessful withdrawal clean.
        let reopened = try SharedStatusPermissionStore(profile: f.profile, fileURL: f.url)
        #expect(await reopened.state(for: f.peer).sharing == false)
        #expect(await reopened.state(for: f.peer).needsConfirmation)
    }

    @Test("Delayed UI commands cannot restore a withdrawn grant")
    func staleCommands() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.grant()
        let stale = await f.store.state(for: f.peer).revision
        try await f.withdraw()
        await #expect(throws: SharedStatusPermissionError.staleRevision) {
            try await f.store.setSharing(true, peer: f.peer, identity: f.identity(), expectedRevision: stale)
        }
        #expect(await f.store.state(for: f.peer).sharing == false)
    }

    @Test("Temporary credential expiry blocks capability without erasing intent")
    func temporaryTrustLoss() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let wire = StatusRouteFixture(), service = try await f.runtime(wire: wire)
        try await f.grant()
        #expect(await service.availability(for: f.peer).sharing)
        f.io.advance(7_200)
        #expect(await service.availability(for: f.peer).sharing == false)
        #expect(await f.store.state(for: f.peer).sharing)
        f.io.advance(-7_200)
        #expect(await service.availability(for: f.peer).sharing)
        await service.invalidate()
    }

    @Test("Local revocation invalidates saved grants")
    func localRevoked() async throws { try await identityInvalidation("localRevoked") }
    @Test("Peer revocation invalidates saved grants")
    func peerRevoked() async throws { try await identityInvalidation("peerRevoked") }
    @Test("Signed membership removal invalidates offline grants")
    func removed() async throws { try await identityInvalidation("removed") }
    @Test("Same-node local credential replacement requires a fresh grant")
    func localCredential() async throws { try await identityInvalidation("localCredential") }
    @Test("Same-node remote credential replacement requires a fresh grant")
    func peerCredential() async throws { try await identityInvalidation("peerCredential") }

    private func identityInvalidation(_ kind: String) async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.grant()
        let snapshot = try #require(await f.directory.serviceAuthorizationSnapshot())
        switch kind {
        case "localRevoked", "peerRevoked":
            let node = kind == "localRevoked" ? f.profile.localNodeID : f.peer
            let credential = try #require(snapshot.records[node]?.credential.claims.credentialID)
            await f.directory.updateRevokedCredentialIDs([credential])
        case "removed":
            try await f.publish(snapshot.records.values.filter { $0.credential.claims.nodeID != f.peer }, generation: 2)
        default:
            let node = kind == "localCredential" ? f.profile.localNodeID : f.peer
            let records = try snapshot.records.values.map { record in
                guard record.credential.claims.nodeID == node else { return record }
                return ProfileMembershipRecord(credential: try f.authority.issue(
                    nodeID: node, nodePublicKey: record.certificatePublicKey, networkID: f.profile.networkID,
                    environment: "permission-test", validity: 3_600, serviceScopes: ["lan"], now: f.io.now()),
                    certificatePublicKey: record.certificatePublicKey, sessionID: record.sessionID)
            }
            try await f.publish(records, generation: 2)
        }
        await f.store.reconcile(try #require(await f.directory.serviceAuthorizationSnapshot()))
        #expect(await f.store.state(for: f.peer).sharing == false)
        await f.store.checkpointStopped()
        let reopened = try SharedStatusPermissionStore(profile: f.profile, fileURL: f.url)
        #expect(await reopened.state(for: f.peer).sharing == false)
    }

    @Test("Membership republication with unchanged credential and key preserves permission")
    func renewalIdentity() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.grant()
        let snapshot = try #require(await f.directory.serviceAuthorizationSnapshot())
        try await f.publish(Array(snapshot.records.values), generation: 2)
        await f.store.reconcile(try #require(await f.directory.serviceAuthorizationSnapshot()))
        #expect(await f.store.state(for: f.peer).sharing)
    }

    @Test("Profile and peer isolation; malformed and unsupported stores remain untouched", arguments: ["profile", "network", "local", "malformed", "version", "operation"])
    func storageIsolation(_ kind: String) async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.grant()
        #expect(await f.store.state(for: NodeID()).sharing == false)
        var profile = f.profile
        switch kind {
        case "profile": profile = try NetworkProfile(networkID: f.profile.networkID, localNodeID: f.profile.localNodeID, displayName: "other")
        case "network": profile = try NetworkProfile(id: f.profile.id, networkID: NetworkID(), localNodeID: f.profile.localNodeID, displayName: "other")
        case "local": profile = try NetworkProfile(id: f.profile.id, networkID: f.profile.networkID, localNodeID: NodeID(), displayName: "other")
        case "malformed": try Data("{broken".utf8).write(to: f.url)
        default:
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.url)) as? [String: Any])
            if kind == "version" { json["version"] = 99 }
            else {
                var grants = try #require(json["grants"] as? [[String: Any]])
                grants[0]["operation"] = "beakr.config/write/v1"
                json["grants"] = grants
            }
            try JSONSerialization.data(withJSONObject: json).write(to: f.url)
        }
        let bytes = try Data(contentsOf: f.url)
        #expect(throws: (any Error).self) { _ = try SharedStatusPermissionStore(profile: profile, fileURL: f.url) }
        #expect(try Data(contentsOf: f.url) == bytes)
    }

    @Test("Withdrawal during suspended sampling suppresses disclosure with persistent permission")
    func suspendedDisclosure() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let wire = StatusRouteFixture(), gate = StatusSampleGate()
        let service = try await f.runtime(wire: wire, gate: gate)
        try await f.grant()
        let route = try #require(await wire.resolve())
        let now = Date()
        let binding = SharedStatusBinding(runtimeID: UUID(), networkID: f.profile.networkID,
            localNodeID: f.peer, peerNodeID: f.profile.localNodeID, sessionID: route.sessionID)
        let request = try SharedStatusProtocol.envelope(
            DataMessage(kind: .request, operation: SharedStatusProtocol.operation,
                        correlationID: DataCorrelationID(), deadline: now.addingTimeInterval(10)),
            binding: binding, sequence: 1, now: now, expiresAt: now.addingTimeInterval(10))
        let task = Task { await service.receive(request, peer: f.peer, route: route) }
        var entered = await gate.entered.makeAsyncIterator()
        _ = await entered.next()
        try await f.withdraw()
        await gate.release()
        #expect(await task.value == false)
        #expect(await wire.writes == 0)
        await service.invalidate()
    }
    @Test("Withdrawal after final permission read suppresses an uncommitted response")
    func withdrawalBeforeCommit() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let wire = StatusRouteFixture(), gate = StatusSampleGate()
        let service = try await f.runtime(wire: wire, commitGate: gate)
        try await f.grant()
        let route = try #require(await wire.resolve())
        let now = Date()
        let binding = SharedStatusBinding(runtimeID: UUID(), networkID: f.profile.networkID,
            localNodeID: f.peer, peerNodeID: f.profile.localNodeID, sessionID: route.sessionID)
        let request = try SharedStatusProtocol.envelope(
            DataMessage(kind: .request, operation: SharedStatusProtocol.operation,
                        correlationID: DataCorrelationID(), deadline: now.addingTimeInterval(10)),
            binding: binding, sequence: 1, now: now, expiresAt: now.addingTimeInterval(10))
        let task = Task { await service.receive(request, peer: f.peer, route: route) }
        var entered = await gate.entered.makeAsyncIterator()
        _ = await entered.next()
        try await f.withdraw()
        await gate.release()
        #expect(await task.value == false)
        #expect(await wire.writes == 0)
        await service.invalidate()
    }
    @Test("Committed response is in flight; withdrawal completes without waiting for transport")
    func withdrawalAfterCommit() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let wire = StatusRouteFixture(), gate = StatusSampleGate()
        let service = try await f.runtime(wire: wire, submissionGate: gate)
        try await f.grant()
        let route = try #require(await wire.resolve())
        let now = Date()
        let binding = SharedStatusBinding(runtimeID: UUID(), networkID: f.profile.networkID,
            localNodeID: f.peer, peerNodeID: f.profile.localNodeID, sessionID: route.sessionID)
        let request = try SharedStatusProtocol.envelope(
            DataMessage(kind: .request, operation: SharedStatusProtocol.operation,
                        correlationID: DataCorrelationID(), deadline: now.addingTimeInterval(10)),
            binding: binding, sequence: 1, now: now, expiresAt: now.addingTimeInterval(10))
        let task = Task { await service.receive(request, peer: f.peer, route: route) }
        var entered = await gate.entered.makeAsyncIterator()
        _ = await entered.next()
        try await f.withdraw()
        #expect(await f.store.state(for: f.peer).sharing == false)
        #expect(await wire.writes == 0)
        await gate.release()
        #expect(await task.value == false)
        #expect(await wire.writes == 1)
        #expect(await service.availability(for: f.peer).sharing == false)
        await service.invalidate()
    }
    @Test("Retirement before commitment suppresses a prepared response")
    func retirementBeforeCommit() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let wire = StatusRouteFixture(), gate = StatusSampleGate()
        let service = try await f.runtime(wire: wire, commitGate: gate)
        try await f.grant()
        let route = try #require(await wire.resolve())
        let now = Date()
        let binding = SharedStatusBinding(runtimeID: UUID(), networkID: f.profile.networkID,
            localNodeID: f.peer, peerNodeID: f.profile.localNodeID, sessionID: route.sessionID)
        let request = try SharedStatusProtocol.envelope(
            DataMessage(kind: .request, operation: SharedStatusProtocol.operation,
                        correlationID: DataCorrelationID(), deadline: now.addingTimeInterval(10)),
            binding: binding, sequence: 1, now: now, expiresAt: now.addingTimeInterval(10))
        let task = Task { await service.receive(request, peer: f.peer, route: route) }
        var entered = await gate.entered.makeAsyncIterator()
        _ = await entered.next()
        await f.store.retire()
        await gate.release()
        #expect(await task.value == false)
        #expect(await wire.writes == 0)
        await service.invalidate()
    }
}

extension SharedStatusPermissionTests {
    @Test("Persistent service returns denial, allowed snapshot after reconnect, then denial after withdrawal")
    func persistentExchange() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let wire = StatusRouteFixture(), service = try await f.runtime(wire: wire)
        var replies = await wire.sent.makeAsyncIterator()
        func request() async throws -> DataMessage {
            let route = try #require(await wire.resolve())
            let now = Date()
            let binding = SharedStatusBinding(runtimeID: UUID(), networkID: f.profile.networkID,
                localNodeID: f.peer, peerNodeID: f.profile.localNodeID, sessionID: route.sessionID)
            let envelope = try SharedStatusProtocol.envelope(
                DataMessage(kind: .request, operation: SharedStatusProtocol.operation,
                            correlationID: DataCorrelationID(), deadline: now.addingTimeInterval(10)),
                binding: binding, sequence: await wire.next(), now: now, expiresAt: now.addingTimeInterval(10))
            #expect(await service.receive(envelope, peer: f.peer, route: route) == false)
            return try DataCodec().decode(envelope: #require(await replies.next()))
        }
        #expect(try await request().errorCode == .unauthorized)
        let old = try #require(await wire.resolve())
        await wire.deny(); await service.routeEnded(peer: f.peer, routeID: old.id)
        // The UI can save intent for a verified member with no transport connection.
        try await service.setSavedSharing(true, peer: f.peer, expectedRevision: f.store.state(for: f.peer).revision)
        #expect(await f.store.state(for: f.peer).sharing)
        #expect(await service.availability(for: f.peer).bindingID == nil)
        await #expect(throws: SharedStatusError.unavailable) {
            try await service.request(peer: f.peer, bindingID: UUID())
        }
        await wire.restore(ProfileApplicationRoute(id: UUID(), sessionID: old.sessionID))
        #expect(try await request().kind == .response)
        try await f.withdraw()
        #expect(try await request().errorCode == .unauthorized)
        await service.invalidate()
    }

    @Test("Offline enable still requires valid membership credentials")
    func offlineEnableExpiredMembership() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let wire = StatusRouteFixture(), service = try await f.runtime(wire: wire)
        await wire.deny()
        f.io.advance(7_200)
        await #expect(throws: SharedStatusPermissionError.unavailable) {
            try await service.setSavedSharing(true, peer: f.peer,
                                             expectedRevision: f.store.state(for: f.peer).revision)
        }
        #expect(await f.store.state(for: f.peer).sharing == false)
        await service.invalidate()
    }

    @Test("Offline enable cannot use saved display data without verified membership")
    func offlineEnableMissingMembership() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let service = SharedStatusRuntime(
            profileID: f.profile.id.rawValue, networkID: f.profile.networkID,
            localNodeID: f.profile.localNodeID, permissions: f.store, persistentPermissions: true,
            authorizationSnapshot: { nil }, sample: { throw SharedStatusError.unavailable })
        await #expect(throws: SharedStatusPermissionError.unavailable) {
            try await service.setSavedSharing(true, peer: f.peer,
                                             expectedRevision: f.store.state(for: f.peer).revision)
        }
        #expect(await f.store.state(for: f.peer).sharing == false)
        await service.invalidate()
    }

    @Test("Persistent grants do not preserve pending requests across disconnect")
    func pendingDisconnect() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let wire = StatusRouteFixture(), service = try await f.runtime(wire: wire)
        try await f.grant()
        let binding = try #require(await service.availability(for: f.peer).bindingID)
        let task = Task { try await service.request(peer: f.peer, bindingID: binding) }
        var sent = await wire.sent.makeAsyncIterator()
        _ = await sent.next()
        await wire.deny(); await service.revalidate()
        await #expect(throws: SharedStatusError.invalidated) { try await task.value }
        #expect(await f.store.state(for: f.peer).sharing)
        await service.invalidate()
    }

    @Test("Shared writer publishes withdrawal to both observers and retirement blocks stale handles")
    func observersAndRetirement() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.grant()
        var first = await f.store.updates(for: f.peer).makeAsyncIterator()
        var second = await f.store.updates(for: f.peer).makeAsyncIterator()
        #expect(await first.next()?.sharing == true)
        #expect(await second.next()?.sharing == true)
        try await f.withdraw()
        #expect(await first.next()?.sharing == false)
        #expect(await second.next()?.sharing == false)
        await f.store.retire()
        await #expect(throws: SharedStatusPermissionError.unavailable) { try await f.grant() }
    }

    @Test("Failed recovery-guard creation never enables a capability")
    func guardFailure() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.grant()
        await f.store.checkpointStopped()
        f.io.fail(true)
        let identity = try await f.identity()
        #expect(await f.store.authorization(for: f.peer, identity: identity) == nil)
        #expect(await f.store.state(for: f.peer).saveFailed)
        #expect(await f.store.state(for: f.peer).sharing == false)
        #expect(throws: (any Error).self) {
            _ = try SharedStatusPermissionStore(profile: f.profile, fileURL: f.url, write: { try f.io.write($0, $1) })
        }
    }
}

extension SharedStatusPermissionTests {
    @Test("Changed authority cannot inherit a grant for the same network and nodes")
    func changedAuthority() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.grant()
        let old = try #require(await f.directory.serviceAuthorizationSnapshot())
        let authority = CredentialAuthority()
        let records = try old.records.values.map { record in
            ProfileMembershipRecord(credential: try authority.issue(
                nodeID: record.credential.claims.nodeID, nodePublicKey: record.certificatePublicKey,
                networkID: f.profile.networkID, environment: "permission-test", validity: 3_600,
                serviceScopes: ["lan"], now: f.io.now()), certificatePublicKey: record.certificatePublicKey,
                sessionID: record.sessionID)
        }
        let replacement = try await ProfileMembershipDirectory.open(
            fileURL: f.root.appendingPathComponent("replacement-membership.json"), networkID: f.profile.networkID,
            environment: "permission-test", trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            revokedCredentialIDs: [])
        let signer = try ProfileMembershipAuthority(privateKeyRepresentation: authority.privateKeyRepresentation)
        try await replacement.activate(try signer.sign(.init(networkID: f.profile.networkID, generation: 1,
            generatedAtMilliseconds: Int64(f.io.now().timeIntervalSince1970 * 1_000), records: records)))
        await f.store.reconcile(try #require(await replacement.serviceAuthorizationSnapshot()))
        #expect(await f.store.state(for: f.peer).sharing == false)
    }

    @Test("Removal followed by reappearance between observations cannot resurrect intent")
    func removalAndReappearance() async throws {
        let f = try await PersistentStatusFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.grant()
        let snapshot = try #require(await f.directory.serviceAuthorizationSnapshot())
        try await f.publish(snapshot.records.values.filter { $0.credential.claims.nodeID != f.peer }, generation: 2)
        try await f.publish(Array(snapshot.records.values), generation: 3)
        await f.store.reconcile(try #require(await f.directory.serviceAuthorizationSnapshot()))
        #expect(await f.store.state(for: f.peer).sharing == false)
    }
}

@MainActor
private struct MonitorFixture {
    let base: PersistentStatusFixture
    let store: SharedStatusPermissionStore
    let wire: StatusRouteFixture
    let service: StatusMonitor

    static func make(gate: StatusSampleGate? = nil, submissionGate: StatusSampleGate? = nil, automaticTicks: Bool = false) async throws -> Self {
        let base = try await PersistentStatusFixture.make()
        let store = try SharedStatusPermissionStore(profile: base.profile,
            fileURL: base.root.appendingPathComponent("monitor.json"), operation: .monitor,
            write: { try base.io.write($0, $1) })
        let wire = StatusRouteFixture()
        let session = try #require(await base.directory.connectionSessionID(localNodeID: base.profile.localNodeID, peerNodeID: base.peer))
        await wire.restore(ProfileApplicationRoute(id: UUID(), sessionID: session))
        let origin = base.io.now(), io = base.io, directory = base.directory
        let service = StatusMonitor(profileID: base.profile.id.rawValue, network: base.profile.networkID,
            local: base.profile.localNodeID, permissions: store,
            authorization: { await directory.serviceAuthorizationSnapshot() },
            resolve: { _ in await wire.resolve() }, submit: { envelope, _ in
                if let submissionGate,
                   let message = try? SharedStatusProtocol.codec.decode(envelope: envelope),
                   message.operation == MonitorAction.sample.operation { _ = await submissionGate.sample() }
                return await wire.send(envelope)
            },
            nextSequence: { _ in await wire.next() }, elapsed: { .seconds(io.now().timeIntervalSince(origin)) },
            wall: { io.now() }, automaticTicks: automaticTicks,
            beforeCommit: { if let gate { _ = await gate.sample() } },
            sample: { SharedStatusSnapshot(schemaVersion: 1, sampledAt: io.now(), applicationVersion: "monitor",
                                          runtimeState: .running, authenticatedPeerCount: 1) })
        return Self(base: base, store: store, wire: wire, service: service)
    }

    func grant() async throws {
        try await service.setSharing(true, peer: base.peer, revision: store.state(for: base.peer).revision)
    }

    func envelope(_ action: MonitorAction, body: MonitorBody, kind: DataMessageKind = .message,
                  correlation: DataCorrelationID = DataCorrelationID()) async throws -> BeakrNetEnvelope {
        let route = try #require(await wire.resolve())
        let now = base.io.now()
        let message = try MonitorProtocol.message(action, kind: kind, body: body, correlation: correlation, now: now)
        let binding = SharedStatusBinding(runtimeID: UUID(), networkID: base.profile.networkID,
            localNodeID: base.peer, peerNodeID: base.profile.localNodeID, sessionID: route.sessionID)
        return try SharedStatusProtocol.envelope(message, binding: binding, sequence: await wire.next(),
                                                now: now, expiresAt: now.addingTimeInterval(10))
    }

    func deliver(_ envelope: BeakrNetEnvelope) async throws {
        let route = try #require(await wire.resolve())
        #expect(await service.receive(envelope, peer: base.peer, route: route) == false)
    }

    func receive(_ action: MonitorAction, body: MonitorBody, kind: DataMessageKind = .message,
                 correlation: DataCorrelationID = DataCorrelationID()) async throws {
        try await deliver(envelope(action, body: body, kind: kind, correlation: correlation))
    }

    func close() async {
        await service.invalidate()
        try? FileManager.default.removeItem(at: base.root)
    }
}

@MainActor
@Suite("Foreground status monitoring", .timeLimit(.minutes(1)))
struct StatusMonitorTests {
    @Test("Read and monitor permissions have separate files and operation validation")
    func operationIsolation() async throws {
        let f = try await MonitorFixture.make()
        try await f.base.grant()
        #expect(await f.store.state(for: f.base.peer).sharing == false)
        let coordinator = SharedStatusPermissionCoordinator()
        let read = try await coordinator.store(profile: f.base.profile, rootURL: f.base.root)
        let monitor = try await coordinator.store(profile: f.base.profile, rootURL: f.base.root, operation: .monitor)
        #expect(read !== monitor)
        try await f.base.withdraw()
        try await f.grant()
        #expect(await f.base.store.state(for: f.base.peer).sharing == false)
        #expect(await f.store.state(for: f.base.peer).sharing)
        #expect(throws: (any Error).self) {
            _ = try SharedStatusPermissionStore(profile: f.base.profile, fileURL: f.base.root.appendingPathComponent("monitor.json"))
        }
        await f.close()
    }

    @Test("One-shot permission does not admit monitoring; explicit monitor grant does")
    func defaultDenialAndCadence() async throws {
        let f = try await MonitorFixture.make()
        var sent = await f.wire.sent.makeAsyncIterator()
        try await f.base.grant()
        try await f.receive(.start, body: MonitorBody(subscription: UUID()), kind: .request)
        let denial = try SharedStatusProtocol.codec.decode(envelope: #require(await sent.next()))
        #expect(denial.errorCode == .unauthorized)
        try await f.grant()
        let id = UUID()
        try await f.receive(.start, body: MonitorBody(subscription: id), kind: .request)
        let accepted = try SharedStatusProtocol.codec.decode(envelope: #require(await sent.next()))
        #expect(accepted.kind == .response)
        let sample = try SharedStatusProtocol.codec.decode(envelope: #require(await sent.next()))
        let (_, body) = try MonitorProtocol.decode(sample)
        #expect(body.sequence == 1 && body.snapshot?.applicationVersion == "monitor")
        let count = await f.wire.writes
        f.base.io.advance(2)
        await f.service.tick()
        #expect(await f.wire.writes == count) // No second sample without application ACK.
        try await f.receive(.ack, body: MonitorBody(subscription: id, sequence: 99))
        await f.service.tick()
        #expect(await f.wire.writes == count)
        try await f.receive(.ack, body: MonitorBody(subscription: id, sequence: 1))
        f.base.io.advance(2)
        await f.service.tick()
        let second = try SharedStatusProtocol.codec.decode(envelope: #require(await sent.next()))
        #expect(try MonitorProtocol.decode(second).1.sequence == 2)
        await f.close()
    }

    @Test("Duplicate Start does not allocate or extend the lease; renew generations are checked")
    func duplicatesAndLease() async throws {
        let f = try await MonitorFixture.make()
        var sent = await f.wire.sent.makeAsyncIterator()
        try await f.grant()
        let id = UUID()
        let start = try await f.envelope(.start, body: MonitorBody(subscription: id), kind: .request)
        try await f.deliver(start)
        _ = await sent.next(); _ = await sent.next()
        try await f.receive(.ack, body: MonitorBody(subscription: id, sequence: 1))
        f.base.io.advance(5)
        try await f.deliver(start)
        let repeated = try SharedStatusProtocol.codec.decode(envelope: #require(await sent.next()))
        #expect(repeated.kind == .response)
        let renewal = try await f.envelope(.renew, body: MonitorBody(subscription: id, sequence: 1), kind: .request)
        try await f.deliver(renewal)
        _ = await sent.next()
        f.base.io.advance(4)
        try await f.deliver(renewal)
        _ = await sent.next()
        f.base.io.advance(27) // First renew expires at t=35; duplicate must not extend it to t=39.
        await f.service.tick()
        #expect(await f.service.diagnostics().incoming == false)
        await f.close()
    }

    @Test("Unacknowledged sample expires; Stop tombstones cannot revive")
    func ackTimeoutAndStop() async throws {
        let f = try await MonitorFixture.make()
        var sent = await f.wire.sent.makeAsyncIterator()
        try await f.grant()
        let id = UUID()
        try await f.receive(.start, body: MonitorBody(subscription: id), kind: .request)
        _ = await sent.next(); _ = await sent.next()
        f.base.io.advance(10)
        await f.service.tick()
        #expect(await f.service.diagnostics().incoming == false)
        // Same identifier remains terminal even with a new correlation.
        try await f.receive(.start, body: MonitorBody(subscription: id), kind: .request)
        #expect(await f.service.diagnostics().incoming == false)
        let newID = UUID()
        try await f.receive(.start, body: MonitorBody(subscription: newID), kind: .request)
        #expect(await f.service.diagnostics().incoming)
        try await f.receive(.stop, body: MonitorBody(subscription: newID))
        try await f.receive(.renew, body: MonitorBody(subscription: newID, sequence: 1), kind: .request)
        #expect(await f.service.diagnostics().incoming == false)
        await f.close()
    }

    @Test("Outgoing session validates samples, becomes stale, stops and ignores late responses")
    func outgoingLifecycle() async throws {
        let f = try await MonitorFixture.make()
        var sent = await f.wire.sent.makeAsyncIterator()
        let owner = UUID()
        try await f.service.start(peer: f.base.peer, owner: owner)
        let request = try SharedStatusProtocol.codec.decode(envelope: #require(await sent.next()))
        let body = try MonitorProtocol.decode(request).1
        try await f.receive(.start, body: body, kind: .response, correlation: request.correlationID)
        let snapshot = SharedStatusSnapshot(schemaVersion: 1, sampledAt: Date.distantFuture,
            applicationVersion: "remote", runtimeState: .running, authenticatedPeerCount: 0)
        try await f.receive(.sample, body: MonitorBody(subscription: body.subscription, sequence: 1, snapshot: snapshot))
        #expect(await f.service.current().phase == .monitoring)
        f.base.io.advance(6)
        await f.service.tick()
        #expect(await f.service.current().phase == .stale)
        #expect(await f.service.current().ageSeconds == 6) // Remote clock does not control local freshness.
        await #expect(throws: SharedStatusError.busy) { try await f.service.start(peer: f.base.peer, owner: UUID()) }
        await f.service.stop(owner: UUID())
        #expect(await f.service.diagnostics().outgoing)
        await f.service.stop(owner: owner)
        try await f.receive(.start, body: body, kind: .response, correlation: request.correlationID)
        try await f.receive(.sample, body: MonitorBody(subscription: body.subscription, sequence: 2, snapshot: snapshot))
        #expect(await f.service.current().phase == .stopped)
        #expect(await f.service.current().sequence == 1)
        #expect(await f.service.diagnostics().timerActive == false)
        await f.close()
    }

    @Test("Disconnect ends monitoring and reconnect does not resume it")
    func reconnectRequiresStart() async throws {
        let f = try await MonitorFixture.make()
        try await f.grant()
        try await f.service.start(peer: f.base.peer, owner: UUID())
        let route = try #require(await f.wire.resolve())
        await f.wire.deny()
        await f.service.revalidate()
        #expect(await f.service.current().phase == .disconnected)
        await f.wire.restore(route)
        await f.service.revalidate(); await f.service.tick()
        #expect(await f.service.diagnostics().outgoing == false)
        #expect(await f.store.state(for: f.base.peer).sharing)
        await f.close()
    }

    @Test("Withdrawal between sample and commit suppresses the sample")
    func withdrawalBeforeCommit() async throws {
        let gate = StatusSampleGate(), f = try await MonitorFixture.make(gate: gate)
        var sent = await f.wire.sent.makeAsyncIterator()
        try await f.grant()
        try await f.receive(.start, body: MonitorBody(subscription: UUID()), kind: .request)
        _ = await sent.next() // Accepted control response, not a sample.
        var entered = await gate.entered.makeAsyncIterator()
        _ = await entered.next()
        try await f.store.setSharing(false, peer: f.base.peer, identity: nil, expectedRevision: f.store.state(for: f.base.peer).revision)
        await gate.release()
        // Ending is the only permissible next message; it contains no status snapshot.
        let next = try SharedStatusProtocol.codec.decode(envelope: #require(await sent.next()))
        #expect(next.operation == MonitorAction.ended.operation)
        #expect(try MonitorProtocol.decode(next).1.snapshot == nil)
        await f.close()
    }

    @Test("Control cache stays bounded under authenticated admission pressure")
    func boundedAdmission() async throws {
        let f = try await MonitorFixture.make()
        for _ in 0..<80 {
            try await f.receive(.start, body: MonitorBody(subscription: UUID()), kind: .request)
        }
        #expect(await f.service.diagnostics().retained <= 64)
        #expect(await f.service.diagnostics().incoming == false)
        #expect(await f.service.diagnostics().timerActive == false)
        await f.close()
    }

    @Test("Operation/kind and body matrix rejects malformed monitoring messages")
    func protocolValidation() throws {
        let body = MonitorBody(subscription: UUID(), sequence: 1)
        let sampleWithoutData = try MonitorProtocol.message(.sample, body: body, now: Date())
        #expect(throws: SharedStatusError.invalidResponse) { try MonitorProtocol.decode(sampleWithoutData) }
        let invalidStart = try MonitorProtocol.message(.start, body: body, now: Date())
        #expect(throws: SharedStatusError.invalidResponse) { try MonitorProtocol.decode(invalidStart) }
        let unknownEnd = try MonitorProtocol.message(.ended,
            body: MonitorBody(subscription: UUID(), reason: "unknown"), now: Date())
        #expect(throws: SharedStatusError.invalidResponse) { try MonitorProtocol.decode(unknownEnd) }
        let withdrawal = try MonitorProtocol.message(.ended,
            body: MonitorBody(subscription: UUID(), reason: "permission-withdrawn"), now: Date())
        #expect(try MonitorProtocol.decode(withdrawal).1.reason == "permission-withdrawn")
        let invalidAck = try MonitorProtocol.message(.ack, kind: .response, body: body, now: Date())
        #expect(throws: SharedStatusError.invalidResponse) { try MonitorProtocol.decode(invalidAck) }
    }
}

extension StatusMonitorTests {
    @Test("Stop arriving before Start leaves a tombstone and prevents revival")
    func stopOvertakesStart() async throws {
        let f = try await MonitorFixture.make()
        try await f.grant()
        let id = UUID()
        try await f.receive(.stop, body: MonitorBody(subscription: id))
        try await f.receive(.start, body: MonitorBody(subscription: id), kind: .request)
        #expect(await f.service.diagnostics().incoming == false)
        #expect(await f.store.state(for: f.base.peer).sharing)
        await f.close()
    }

    @Test("Ack after expiry cannot keep a sample alive before timer maintenance")
    func lateAck() async throws {
        let f = try await MonitorFixture.make()
        var sent = await f.wire.sent.makeAsyncIterator()
        try await f.grant()
        let id = UUID()
        try await f.receive(.start, body: MonitorBody(subscription: id), kind: .request)
        _ = await sent.next(); _ = await sent.next()
        f.base.io.advance(10)
        try await f.receive(.ack, body: MonitorBody(subscription: id, sequence: 1))
        await f.service.tick()
        #expect(await f.service.diagnostics().incoming == false)
        await f.close()
    }

    @Test("Withdrawal after commitment does not wait for a slow transport")
    func committedSample() async throws {
        let gate = StatusSampleGate(), f = try await MonitorFixture.make(submissionGate: gate)
        var sent = await f.wire.sent.makeAsyncIterator()
        try await f.grant()
        try await f.receive(.start, body: MonitorBody(subscription: UUID()), kind: .request)
        _ = await sent.next()
        var entered = await gate.entered.makeAsyncIterator()
        _ = await entered.next()
        try await f.store.setSharing(false, peer: f.base.peer, identity: nil, expectedRevision: f.store.state(for: f.base.peer).revision)
        #expect(await f.store.state(for: f.base.peer).sharing == false)
        await gate.release()
        let next = try SharedStatusProtocol.codec.decode(envelope: #require(await sent.next()))
        #expect(next.operation == MonitorAction.sample.operation)
        await f.service.revalidate()
        #expect(await f.service.diagnostics().incoming == false)
        await f.close()
    }

    @Test("Failed withdrawal save blocks a prepared monitor response")
    func failedSaveBlocksSample() async throws {
        let gate = StatusSampleGate(), f = try await MonitorFixture.make(gate: gate)
        var sent = await f.wire.sent.makeAsyncIterator()
        try await f.grant()
        try await f.receive(.start, body: MonitorBody(subscription: UUID()), kind: .request)
        _ = await sent.next()
        var entered = await gate.entered.makeAsyncIterator()
        _ = await entered.next()
        f.base.io.fail(true)
        await #expect(throws: SharedStatusPermissionError.persistenceFailed) {
            try await f.store.setSharing(false, peer: f.base.peer, identity: nil, expectedRevision: f.store.state(for: f.base.peer).revision)
        }
        await gate.release()
        let next = try SharedStatusProtocol.codec.decode(envelope: #require(await sent.next()))
        #expect(next.operation == MonitorAction.ended.operation)
        #expect(try MonitorProtocol.decode(next).1.reason == "stopped")
        await f.close()
    }

    @Test("Outgoing Start and renewal have bounded timeouts; invalidation ends observation")
    func controlTimeouts() async throws {
        let f = try await MonitorFixture.make()
        var sent = await f.wire.sent.makeAsyncIterator()
        try await f.service.start(peer: f.base.peer, owner: UUID())
        _ = await sent.next()
        f.base.io.advance(10)
        await f.service.tick()
        #expect(await f.service.current().phase == .failed)
        try await f.service.start(peer: f.base.peer, owner: UUID())
        let start = try SharedStatusProtocol.codec.decode(envelope: #require(await sent.next()))
        let body = try MonitorProtocol.decode(start).1
        try await f.receive(.start, body: body, kind: .response, correlation: start.correlationID)
        f.base.io.advance(10)
        await f.service.tick()
        let renew = try SharedStatusProtocol.codec.decode(envelope: #require(await sent.next()))
        #expect(renew.operation == MonitorAction.renew.operation)
        f.base.io.advance(10)
        await f.service.tick()
        #expect(await f.service.current().phase == .failed)
        await f.service.invalidate()
        await #expect(throws: SharedStatusError.busy) { try await f.service.start(peer: f.base.peer, owner: UUID()) }
        await f.close()
    }

    @Test("Monitoring namespace is consumed by authenticated integration without chat or durable ACK")
    func registrySeparation() async throws {
        let pair = try await StatusIntegrationPair.make()
        await pair.left.configureMonitoring(permissions: nil)
        await pair.right.configureMonitoring(permissions: nil)
        let monitor = try #require(await pair.left.monitoring)
        var updates = await monitor.updates().makeAsyncIterator()
        try await monitor.start(peer: pair.b, owner: UUID())
        while let state = await updates.next() { if state.phase == .denied { break } }
        #expect(await pair.probe.inboxCalls == 0)
        #expect(await pair.store.recordedResults().isEmpty)
        #expect(await pair.rightWire.sent.filter { $0.payloadType == DeliveryAcknowledgement.payloadType }.isEmpty)
        await pair.close()
    }
}

private actor MonitorBridge {
    var caller: StatusMonitor?
    var responder: StatusMonitor?
    let peer: NodeID
    let local: NodeID
    let route: ProfileApplicationRoute
    private(set) var acknowledgements = 0
    init(peer: NodeID, local: NodeID, route: ProfileApplicationRoute) { self.peer = peer; self.local = local; self.route = route }
    func connect(caller: StatusMonitor, responder: StatusMonitor) { self.caller = caller; self.responder = responder }
    func toResponder(_ envelope: BeakrNetEnvelope) async -> HostDeliveryAttempt {
        guard let responder else { return .routeUnavailable }
        _ = await responder.receive(envelope, peer: peer, route: route)
        if let data = try? SharedStatusProtocol.codec.decode(envelope: envelope), data.operation == MonitorAction.ack.operation { acknowledgements += 1 }
        return .submitted
    }
    func toCaller(_ envelope: BeakrNetEnvelope) async -> HostDeliveryAttempt {
        guard let caller else { return .routeUnavailable }
        _ = await caller.receive(envelope, peer: local, route: route)
        return .submitted
    }
    func disconnect() { caller = nil; responder = nil }
}

extension StatusMonitorTests {
    @Test("Two monitoring endpoints exchange accepted samples and stop the responder")
    func twoEndpointExchange() async throws {
        let f = try await MonitorFixture.make()
        try await f.grant()
        let route = try #require(await f.wire.resolve())
        let bridge = MonitorBridge(peer: f.base.peer, local: f.base.profile.localNodeID, route: route)
        let directory = f.base.directory, wire = f.wire
        let caller = StatusMonitor(profileID: UUID(), network: f.base.profile.networkID, local: f.base.peer,
            permissions: nil, authorization: { await directory.serviceAuthorizationSnapshot() },
            resolve: { _ in await wire.resolve() }, submit: { envelope, _ in await bridge.toResponder(envelope) },
            nextSequence: { _ in await wire.next() }, automaticTicks: false,
            sample: { throw SharedStatusError.unavailable })
        let responder = StatusMonitor(profileID: f.base.profile.id.rawValue, network: f.base.profile.networkID,
            local: f.base.profile.localNodeID, permissions: f.store,
            authorization: { await directory.serviceAuthorizationSnapshot() },
            resolve: { _ in await wire.resolve() }, submit: { envelope, _ in await bridge.toCaller(envelope) },
            nextSequence: { _ in await wire.next() }, automaticTicks: false,
            sample: { SharedStatusSnapshot(schemaVersion: 1, sampledAt: Date(), applicationVersion: "paired",
                                          runtimeState: .running, authenticatedPeerCount: 1) })
        await bridge.connect(caller: caller, responder: responder)
        var updates = await caller.updates().makeAsyncIterator()
        let owner = UUID()
        try await caller.start(peer: f.base.profile.localNodeID, owner: owner)
        while let state = await updates.next() { if state.snapshot?.applicationVersion == "paired" { break } }
        #expect(await caller.current().sequence == 1)
        await caller.stop(owner: owner)
        #expect(await responder.diagnostics().incoming == false)
        #expect(await caller.current().phase == .stopped)
        await caller.invalidate(); await responder.invalidate(); await bridge.disconnect()
        await f.close()
    }

    @Test("Explicit withdrawal reports its reason and subsequent Start is denied")
    func explicitWithdrawalReason() async throws {
        let f = try await MonitorFixture.make()
        try await f.grant()
        let route = try #require(await f.wire.resolve())
        let bridge = MonitorBridge(peer: f.base.peer, local: f.base.profile.localNodeID, route: route)
        let directory = f.base.directory, wire = f.wire
        let caller = StatusMonitor(profileID: UUID(), network: f.base.profile.networkID, local: f.base.peer,
            permissions: nil, authorization: { await directory.serviceAuthorizationSnapshot() },
            resolve: { _ in await wire.resolve() }, submit: { envelope, _ in await bridge.toResponder(envelope) },
            nextSequence: { _ in await wire.next() }, automaticTicks: false,
            sample: { throw SharedStatusError.unavailable })
        let responder = StatusMonitor(profileID: f.base.profile.id.rawValue, network: f.base.profile.networkID,
            local: f.base.profile.localNodeID, permissions: f.store,
            authorization: { await directory.serviceAuthorizationSnapshot() },
            resolve: { _ in await wire.resolve() }, submit: { envelope, _ in await bridge.toCaller(envelope) },
            nextSequence: { _ in await wire.next() }, automaticTicks: false,
            sample: { SharedStatusSnapshot(schemaVersion: 1, sampledAt: Date(), applicationVersion: "paired",
                                          runtimeState: .running, authenticatedPeerCount: 1) })
        await bridge.connect(caller: caller, responder: responder)
        var updates = await caller.updates().makeAsyncIterator()
        let owner = UUID()
        try await caller.start(peer: f.base.profile.localNodeID, owner: owner)
        while let state = await updates.next() { if state.snapshot?.applicationVersion == "paired" { break } }
        #expect(await caller.current().sequence == 1)
        let permission = await f.store.state(for: f.base.peer)
        try await f.store.setSharing(false, peer: f.base.peer, identity: nil, expectedRevision: permission.revision)
        await responder.revalidate()
        while let state = await updates.next() { if state.phase == .permissionWithdrawn { break } }
        #expect(await responder.diagnostics().incoming == false)
        #expect(await caller.current().phase == .permissionWithdrawn)
        #expect(await caller.current().owner == nil)
        #expect(await caller.current().presentationOwner == owner)
        #expect(await caller.current().snapshot?.applicationVersion == "paired")
        try await caller.start(peer: f.base.profile.localNodeID, owner: owner)
        #expect(await caller.current().phase == .denied)
        await caller.invalidate(); await responder.invalidate(); await bridge.disconnect()
        await f.close()
    }

    @Test("Verified membership removal invalidates monitoring grant and session")
    func membershipRemoval() async throws {
        let f = try await MonitorFixture.make()
        var sent = await f.wire.sent.makeAsyncIterator()
        try await f.grant()
        try await f.receive(.start, body: MonitorBody(subscription: UUID()), kind: .request)
        _ = await sent.next(); _ = await sent.next()
        let snapshot = try #require(await f.base.directory.serviceAuthorizationSnapshot())
        let retained = snapshot.records.values.filter { $0.credential.claims.nodeID != f.base.peer }
        try await f.base.publish(retained, generation: 2)
        await f.service.revalidate()
        #expect(await f.service.diagnostics().incoming == false)
        #expect(await f.store.state(for: f.base.peer).sharing == false)
        let ended = try SharedStatusProtocol.codec.decode(envelope: #require(await sent.next()))
        #expect(try MonitorProtocol.decode(ended).1.reason == "stopped")
        await f.close()
    }

    @Test("Wrong route, destination, and unsolicited samples cannot update the view")
    func bindingRejection() async throws {
        let f = try await MonitorFixture.make()
        let body = MonitorBody(subscription: UUID(), sequence: 1,
            snapshot: SharedStatusSnapshot(schemaVersion: 1, sampledAt: Date(), applicationVersion: "unsolicited",
                                           runtimeState: .running, authenticatedPeerCount: 1))
        let envelope = try await f.envelope(.sample, body: body)
        let route = try #require(await f.wire.resolve())
        #expect(await f.service.receive(envelope, peer: NodeID(), route: route) == false)
        #expect(await f.service.receive(envelope, peer: f.base.peer,
            route: ProfileApplicationRoute(id: UUID(), sessionID: route.sessionID)) == false)
        try await f.deliver(envelope)
        #expect(await f.service.current().snapshot == nil)
        await f.close()
    }
}

extension StatusMonitorTests {
    @Test("Production timer exists only while a subscription is active")
    func idleTimer() async throws {
        let f = try await MonitorFixture.make(automaticTicks: true)
        #expect(await f.service.diagnostics().timerActive == false)
        try await f.grant()
        #expect(await f.service.diagnostics().timerActive == false)
        let owner = UUID()
        try await f.service.start(peer: f.base.peer, owner: owner)
        #expect(await f.service.diagnostics().timerActive)
        await f.service.stop(owner: owner)
        #expect(await f.service.diagnostics().timerActive == false)
        await f.close()
    }
}
