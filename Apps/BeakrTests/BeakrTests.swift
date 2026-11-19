import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetData
import BeakrNetEnrollment
import BeakrNetHost
import BeakrNetSecurity
@testable import Beakr

private actor LifecycleDiagnosticTransport: BeakrNetTransport, RevocationSnapshotConsumer {
    nonisolated let id = TransportID()
    nonisolated var revocationConsumerID: TransportID { id }
    nonisolated let kind = TransportKind.local
    nonisolated let capabilities = TransportCapabilities(
        preservesOrder: true, supportsImmediateDelivery: true,
        supportsQueuedDelivery: true, supportsBackgroundDelivery: false
    )
    func send(_ envelope: BeakrNetEnvelope) async throws {}
    func receive() async -> BeakrNetEnvelope? { nil }
    func close() async {}
    func installRevocationSnapshot(_ snapshot: CredentialRevocationSnapshot) throws {}
}

private nonisolated final class LifecycleDiagnosticTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Duration = .zero
    func read() -> Duration { lock.withLock { elapsed } }
    func advance(_ duration: Duration) { lock.withLock { elapsed += duration } }
}

@MainActor
struct BeakrTests {

    @Test("Only admitted registry peers produce first-peer and recovery measurements")
    func lifecycleTraceRegistryAdmission() async throws {
        let journal = RuntimeTraceJournal()
        let trace = RuntimeLifecycleTrace(
            context: RuntimeTraceContext(runID: UUID(), profileID: UUID(), networkID: UUID(), generation: 1),
            journal: journal
        )
        // This fixture tests the registry's diagnostic boundary, not signature verification.
        let revocations = RevocationSnapshotDistributor(verifier: { _, _ in })
        let registry = ProfileConnectionRegistry(
            networkID: NetworkID(), localNodeID: NodeID(), revocations: revocations,
            routePolicy: ProfileRoutePolicyController(),
            peerDiagnosticSink: { trace.observePeers(Set($0.map { $0.rawValue })) }
        )
        let remote = NodeID()
        let session = SessionID()
        await #expect(throws: ProfileConnectionRegistryError.missingRevocationSnapshot) {
            _ = try await registry.admit(transport: LifecycleDiagnosticTransport(),
                                         remoteNodeID: remote, sessionID: session)
        }
        #expect(journal.snapshot().events.isEmpty)
        _ = try await revocations.publish(CredentialRevocationSnapshot(
            claims: CredentialRevocationClaims(issuerID: AuthorityID(rawValue: UUID()),
                                                generatedAtMilliseconds: 1_000_000, revocations: []),
            issuerSignature: Data([1])
        ))
        let original = LifecycleDiagnosticTransport()
        let replacement = LifecycleDiagnosticTransport()
        _ = try await registry.admit(transport: original, remoteNodeID: remote, sessionID: session)
        _ = try await registry.admit(transport: replacement, remoteNodeID: remote, sessionID: session)
        await registry.remove(transport: original)
        #expect(!journal.snapshot().events.contains { $0.stage == .peerLoss })
        await registry.remove(transport: replacement)
        let returned = LifecycleDiagnosticTransport()
        _ = try await registry.admit(transport: returned, remoteNodeID: remote, sessionID: session)
        #expect(journal.snapshot().events.filter { $0.stage == .firstPeer }.count == 1)
        #expect(journal.snapshot().events.filter { $0.stage == .peerRecovery }.count == 1)
        trace.close(.stopped)
        let count = journal.snapshot().events.count
        await registry.remove(transport: returned)
        #expect(journal.snapshot().events.count == count)
    }

    @Test("Lifecycle measurements distinguish startup, admission, and same-peer recovery")
    func lifecycleTraceMeasurements() throws {
        let clock = LifecycleDiagnosticTestClock()
        let journal = RuntimeTraceJournal()
        let context = RuntimeTraceContext(runID: UUID(), profileID: UUID(), networkID: UUID(), generation: 7)
        let trace = RuntimeLifecycleTrace(context: context, journal: journal, now: { clock.read() })
        let start = trace.instant()
        trace.record(.startup, .began)
        clock.advance(.milliseconds(20))
        trace.record(.startup, .completed, since: start)
        #expect(!journal.snapshot().events.contains { $0.stage == .firstPeer })
        let peer = UUID()
        clock.advance(.milliseconds(30))
        trace.observePeers([peer])
        trace.observePeers([peer]) // Address update / transport handoff.
        clock.advance(.milliseconds(10))
        trace.observePeers([])
        clock.advance(.milliseconds(40))
        trace.observePeers([UUID()]) // Another peer does not recover the original.
        #expect(!journal.snapshot().events.contains { $0.stage == .peerRecovery })
        clock.advance(.milliseconds(10))
        trace.observePeers([peer])
        let events = journal.snapshot().events
        #expect(events.first { $0.stage == .startup && $0.outcome == .completed }?.durationMilliseconds == 20)
        #expect(events.first { $0.stage == .firstPeer }?.durationMilliseconds == 50)
        #expect(events.first { $0.stage == .peerRecovery && $0.subjectID == peer }?.durationMilliseconds == 50)
        #expect(events.filter { $0.stage == .firstPeer }.count == 1)
        #expect(events.allSatisfy { $0.context == context })
        #expect(events.map(\.sequence) == Array(1...UInt64(events.count)))
    }

    @Test("Closing an observation prevents late callbacks crossing profile boundaries")
    func lifecycleTraceIsolation() {
        let journal = RuntimeTraceJournal()
        let old = RuntimeLifecycleTrace(
            context: RuntimeTraceContext(runID: UUID(), profileID: UUID(), networkID: UUID(), generation: 1),
            journal: journal
        )
        old.close(.cancelled)
        let count = journal.snapshot().events.count
        old.observePeers([UUID()])
        old.record(.startup, .completed)
        old.close(.completed)
        #expect(journal.snapshot().events.count == count)
        let missing = journal.snapshot().events.first { $0.stage == .firstPeer }
        #expect(missing?.outcome == .notObserved)
        #expect(missing?.durationMilliseconds == nil)
        let next = RuntimeLifecycleTrace(
            context: RuntimeTraceContext(runID: old.context.runID, profileID: UUID(),
                                         networkID: UUID(), generation: 2),
            journal: journal
        )
        next.observePeers([UUID()])
        #expect(journal.snapshot().events.last?.context == next.context)
        #expect(next.context.profileID != old.context.profileID)
    }

    @Test("Diagnostic retention, export, and peer observations remain bounded")
    func lifecycleTraceBounds() throws {
        let journal = RuntimeTraceJournal(policy: HostDiagnosticPolicy(maximumEvents: 4, maximumExportBytes: 1_200))
        let trace = RuntimeLifecycleTrace(
            context: RuntimeTraceContext(runID: UUID(), profileID: UUID(), networkID: UUID(), generation: 1),
            journal: journal, maximumPeers: 2
        )
        for _ in 0..<20 { trace.record(.retryScheduled, .waiting, scheduledDelay: .seconds(2)) }
        #expect(journal.snapshot().events.count == 4)
        #expect(journal.snapshot().droppedEvents == 16)
        #expect(journal.snapshot().events.last?.scheduledDelayMilliseconds == 2_000)
        let exported = try journal.export()
        #expect(exported.count <= 1_200)
        let decoded = try JSONDecoder().decode(RuntimeTraceJournal.Snapshot.self, from: exported)
        #expect(decoded.droppedEvents > 16)
        #expect(decoded.events.count < 4)
        trace.observePeers(Set((0..<100).map { _ in UUID() }))
        #expect(journal.snapshot().events.contains { $0.state == "peer-capacity" })
        trace.close(.stopped)
        #expect(journal.snapshot().events.count <= 4)
    }

    @Test("Transition timing is independent of peer observation and propagates to child tasks")
    func lifecycleTraceTransitionContext() async {
        let clock = LifecycleDiagnosticTestClock()
        let journal = RuntimeTraceJournal()
        let context = RuntimeTraceContext(runID: UUID(), profileID: UUID(), networkID: UUID(), generation: 1)
        let trace = RuntimeLifecycleTrace(context: context, journal: journal, observesPeers: false, now: { clock.read() })
        let requested = trace.instant()
        trace.record(.transitionWait, .began)
        clock.advance(.milliseconds(35))
        trace.record(.transitionWait, .completed, since: requested)
        await RuntimeLifecycleDiagnostics.$current.withValue(trace) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { RuntimeLifecycleDiagnostics.current?.record(.transition, .completed) }
            }
        }
        trace.close(.completed)
        #expect(journal.snapshot().events.first { $0.stage == .transitionWait && $0.outcome == .completed }?.durationMilliseconds == 35)
        #expect(journal.snapshot().events.contains { $0.stage == .transition && $0.context == context })
        #expect(!journal.snapshot().events.contains { $0.stage == .firstPeer })
        #expect(RuntimeLifecycleDiagnostics.current == nil)
    }

    @Test("Saved memberships are isolated, verified, and read without changing trust files")
    func savedMembershipPresentation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = CredentialAuthority()
        let local = NodeIdentity()
        let peer = NodeIdentity()
        let now = Date()
        let profiles = try ["One", "Two"].map {
            try NetworkProfile(networkID: NetworkID(), localNodeID: local.nodeID, displayName: $0)
        }
        for profile in profiles {
            let paths = ProfileRuntimePaths(rootURL: root.appendingPathComponent(profile.id.rawValue.uuidString))
            let localCredential = try authority.issue(nodeID: local.nodeID,
                nodePublicKey: local.publicKeyRepresentation, networkID: profile.networkID,
                environment: "test", validity: 3_600, serviceScopes: ["lan"])
            let peerCredential = try authority.issue(nodeID: peer.nodeID,
                nodePublicKey: peer.publicKeyRepresentation, networkID: profile.networkID,
                environment: "test", validity: 3_600, serviceScopes: ["lan"])
            let configuration = DevelopmentAuthorityConfiguration(
                controlPlaneURL: try #require(URL(string: "https://authority.example")),
                networkID: profile.networkID, authorityPublicKey: authority.publicKeyRepresentation,
                credential: localCredential)
            let snapshot = try ProfileMembershipAuthority(privateKeyRepresentation: authority.privateKeyRepresentation)
                .sign(ProfileMembershipClaims(networkID: profile.networkID, networkDisplayName: profile.displayName,
                    generation: 1, generatedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
                    records: [
                        .init(credential: localCredential, certificatePublicKey: local.publicKeyRepresentation, sessionID: SessionID()),
                        .init(credential: peerCredential, certificatePublicKey: peer.publicKeyRepresentation, sessionID: SessionID())
                    ]))
            let metadata = [peer.nodeID.rawValue: NetworkMemberMetadata(id: peer.nodeID.rawValue,
                displayName: "Peer in \(profile.displayName)", lastSeen: now)]
            func load(_ selectedProfile: NetworkProfile? = nil, at date: Date? = nil) -> SavedNetworkMembership {
                SavedNetworkMembershipLoader.load(paths: paths, profile: selectedProfile ?? profile,
                    configuration: configuration, metadata: metadata, now: date ?? now)
            }
            #expect(load().state == .unavailable)
            try FileManager.default.createDirectory(at: paths.membershipSnapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try ProfileMembershipWireCodec.encode(snapshot)
            try data.write(to: paths.membershipSnapshotURL)
            try CredentialFiles.saveRevocationSnapshot(authority.issueRevocationSnapshot(revocations: [], now: now),
                to: paths.revocationSnapshotURL)
            let result = load()
            #expect(result.state == .saved)
            #expect(result.members.map(\.id) == [peer.nodeID.rawValue])
            #expect(result.members.first?.displayName == "Peer in \(profile.displayName)")
            #expect(result.members.first?.deviceIPAddress == nil)
            #expect(result.members.first?.connectionIPAddress == nil)
            #expect(try Data(contentsOf: paths.membershipSnapshotURL) == data)
            let other = try #require(profiles.first { $0.id != profile.id })
            #expect(load(other).state == .unavailable)
            let expired = load(at: now.addingTimeInterval(7_200))
            #expect(expired.state == .stale)
            #expect(expired.members.map(\.id) == [peer.nodeID.rawValue])
            let revoked = try authority.issueRevocationSnapshot(revocations: [
                .init(credentialID: peerCredential.claims.credentialID, revokedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000), reason: "test")
            ], now: now)
            try CredentialFiles.saveRevocationSnapshot(revoked, to: paths.revocationSnapshotURL)
            #expect(load().members.isEmpty)
            let invalid = ProfileMembershipSnapshot(claims: snapshot.claims, authoritySignature: Data([0]))
            try ProfileMembershipWireCodec.encode(invalid).write(to: paths.membershipSnapshotURL)
            #expect(load().state == .unavailable)
            #expect(load().members.isEmpty)
        }
    }

    @Test("Production retry and acknowledgement wiring recover one inbox message",
          arguments: [false, true])
    func automaticDeliveryRecovery(lostAcknowledgement: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outgoingURL = root.appendingPathComponent("outgoing.json")
        let incomingURL = root.appendingPathComponent("incoming.json")
        let outgoingState = try await PersistentDataState.open(fileURL: outgoingURL)
        let incomingState = try await PersistentDataState.open(fileURL: incomingURL)
        let source = NodeID(), destination = NodeID(), network = NetworkID(), sessionID = SessionID()
        let inbox = ApplicationMessageInbox()
        await inbox.attach(incomingState, context: MessageProvenanceContext(
            profileID: UUID(), authorityID: UUID(), authorityEndpoint: "https://fixture.invalid",
            localCredentialID: UUID()
        ))
        let inboxStream = await inbox.updates()
        let firstInboxMessage = Task { () -> IncomingMessage? in
            for await message in inboxStream { return message }
            return nil
        }
        defer { firstInboxMessage.cancel() }
        let deliveryUpdates = ApplicationDeliveryUpdates()
        let sender = BeakrNetSession(id: sessionID, networkID: network, localNodeID: source,
                                    remoteNodeID: destination, state: .active)
        let receiver = BeakrNetSession(id: sessionID, networkID: network, localNodeID: destination,
                                      remoteNodeID: source, state: .active)
        let senderRoutes = PeerRouteCoordinator(networkID: network, remoteNodeID: destination)
        let receiverRoutes = PeerRouteCoordinator(networkID: network, remoteNodeID: source)
        let senderDriver = SessionDeliveryDriver(session: sender, coordinator: senderRoutes)
        let receiverDriver = SessionDeliveryDriver(session: receiver, coordinator: receiverRoutes)
        let forward = AsyncStream<BeakrNetEnvelope>.makeStream()
        let reverse = AsyncStream<BeakrNetEnvelope>.makeStream()
        let sendingLink = DeliveryFaultTransport(inbound: reverse.stream, outbound: forward.continuation)
        let receivingLink = DeliveryFaultTransport(inbound: forward.stream, outbound: reverse.continuation,
                                                   dropFirstAcknowledgement: lostAcknowledgement)
        let senderOwner = await AuthenticatedTransportRouteOwner(
            transport: sendingLink, coordinator: senderRoutes, driver: senderDriver,
            deliveryAcknowledgementSink: { acknowledgement in
                await ApplicationDeliveryPipeline.acknowledge(
                    acknowledgement, state: outgoingState, deliveryUpdates: deliveryUpdates
                )
            }
        )
        let receiverOwner = await AuthenticatedTransportRouteOwner(
            transport: receivingLink, coordinator: receiverRoutes, driver: receiverDriver,
            incomingEnvelopeSink: { await inbox.record($0) }
        )
        await receiverOwner.setPermitted(true)
        await senderOwner.setPermitted(lostAcknowledgement)
        defer {
            forward.continuation.finish()
            reverse.continuation.finish()
            Task { await senderOwner.setPermitted(false); await receiverOwner.setPermitted(false) }
        }
        let messaging = PersistentHostMessagingService(
            state: outgoingState,
            contextProvider: { _ in HostDeliveryContext(networkID: network, sessionID: sessionID,
                                                        sourceNodeID: source, sequenceNumber: 1) },
            submit: { envelope in
                if case .sent = try await senderDriver.deliver(envelope) { return .submitted }
                return .routeUnavailable
            }
        )
        let model = MessageComposerModel(messagingService: messaging, deliveryUpdates: deliveryUpdates,
                                         mailboxMetadataURL: root.appendingPathComponent("mailbox.json"))
        let deliveryObserver = Task { await model.observeDeliveryUpdates() }
        defer { deliveryObserver.cancel() }
        model.destinationID = destination.rawValue
        model.messageText = "Automatic recovery fixture"
        await model.send()
        let pending = try await outgoingState.pending()
        let original = try #require(pending.first)
        #expect(pending.count == 1)
        #expect(model.outgoingMessages.first?.state == .queued)
        // Simulate the route returning; the test never calls retryPending or
        // acknowledges a message directly. The production two-second loop does it.
        if !lostAcknowledgement { await senderOwner.setPermitted(true) }
        let retryTask = Task {
            await ApplicationDeliveryPipeline.runRetries(messaging: messaging, isRunning: { true })
        }
        defer { retryTask.cancel() }
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: .seconds(8))
        while model.outgoingMessages.first?.state != .delivered, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.outgoingMessages.first?.state == .delivered)
        #expect(started.duration(to: clock.now) >= .seconds(2))
        #expect(try await outgoingState.pending().isEmpty)
        let reopened = try await PersistentDataState.open(fileURL: outgoingURL)
        #expect(try await reopened.pending().isEmpty)
        let incoming = await incomingState.recordedResults()
        try #require(incoming.count == 1)
        #expect(incoming.first?.messageID == original.messageID)
        let firstMessage = await firstInboxMessage.value
        #expect(firstMessage?.id == model.outgoingMessages.first?.id)
        #expect(firstMessage?.body == "Automatic recovery fixture")
        let attempts = await sendingLink.sent
        #expect(attempts.count == (lostAcknowledgement ? 2 : 1))
        #expect(attempts.allSatisfy { $0 == original })
        #expect(await receivingLink.droppedAcknowledgements == (lostAcknowledgement ? 1 : 0))
        let history = await receiver.diagnosticHistory
        #expect(history.filter { if case .envelopeAccepted = $0 { true } else { false } }.count == 1)
        #expect(history.filter { if case .duplicateRejected = $0 { true } else { false } }.count == (lostAcknowledgement ? 1 : 0))
        // Allow a further production retry tick: an acknowledged message must
        // not be sent again or produce a second inbox record.
        try await Task.sleep(for: .milliseconds(2_100))
        #expect(await sendingLink.sent.count == attempts.count)
        #expect(await incomingState.recordedResults().count == 1)
        retryTask.cancel()
        await retryTask.value
        await senderOwner.setPermitted(false)
        await receiverOwner.setPermitted(false)
    }

    @Test("Concurrent inbox retries share one save and one new-message update",
          .timeLimit(.minutes(1)))
    func concurrentInboxRetriesPersistOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try await PersistentDataState.open(fileURL: root.appendingPathComponent("incoming.json"))
        let inbox = ApplicationMessageInbox()
        await inbox.attach(state, context: MessageProvenanceContext(profileID: UUID(), authorityID: UUID(),
            authorityEndpoint: "https://fixture.invalid", localCredentialID: UUID()))
        let updates = await inbox.updates()
        let source = NodeID(), destination = NodeID(), network = NetworkID(), session = SessionID()
        func makeEnvelope(_ body: String, sequence: UInt64) throws -> (BeakrNetEnvelope, UUID) {
            let message = DataMessage(kind: .message,
                operation: .init(namespace: "beakr", name: "text-message", version: 1),
                correlationID: DataCorrelationID(), body: Data(body.utf8))
            return (BeakrNetEnvelope(networkID: network, sessionID: session,
                sourceNodeID: source, destinationNodeID: destination, sequenceNumber: sequence,
                deliveryPolicy: .init(durability: .ephemeral), payloadType: DataMessage.payloadType,
                payload: try DataCodec().encode(message)), message.correlationID.rawValue)
        }
        let (original, originalID) = try makeEnvelope("Concurrent retry", sequence: 1)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 { group.addTask { await inbox.record(original) } }
            for await saved in group { #expect(saved) }
        }
        #expect(await state.recordedResults().count == 1)
        let (barrier, barrierID) = try makeEnvelope("Observer barrier", sequence: 2)
        #expect(await inbox.record(barrier))
        try await withThrowingTaskGroup(of: [IncomingMessage].self) { group in
            group.addTask {
                var values: [IncomingMessage] = []
                for await value in updates {
                    values.append(value)
                    if value.id == barrierID { return values }
                }
                return values
            }
            group.addTask { try await Task.sleep(for: .seconds(5)); return [] }
            defer { group.cancelAll() }
            let values = try #require(try await group.next())
            #expect(values.map(\.id) == [originalID, barrierID])
            #expect(values.allSatisfy { !$0.isRestored })
        }
    }

    @Test("A failed inbox write withholds acknowledgement and retries successfully",
          .timeLimit(.minutes(1)))
    func inboxSaveFailureRetainsSenderQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outgoingURL = root.appendingPathComponent("outgoing.json")
        let incomingURL = root.appendingPathComponent("incoming.json")
        let outgoing = try await PersistentDataState.open(fileURL: outgoingURL)
        let incoming = try await PersistentDataState.open(fileURL: incomingURL)
        // Make the destination a directory: atomic file replacement must fail.
        try FileManager.default.createDirectory(at: incomingURL, withIntermediateDirectories: true)
        let source = NodeID(), destination = NodeID(), network = NetworkID(), sessionID = SessionID()
        let inbox = ApplicationMessageInbox()
        await inbox.attach(incoming, context: MessageProvenanceContext(profileID: UUID(), authorityID: UUID(),
            authorityEndpoint: "https://fixture.invalid", localCredentialID: UUID()))
        let sender = BeakrNetSession(id: sessionID, networkID: network, localNodeID: source,
                                    remoteNodeID: destination, state: .active)
        let receiver = BeakrNetSession(id: sessionID, networkID: network, localNodeID: destination,
                                      remoteNodeID: source, state: .active)
        let senderRoutes = PeerRouteCoordinator(networkID: network, remoteNodeID: destination)
        let receiverRoutes = PeerRouteCoordinator(networkID: network, remoteNodeID: source)
        let senderDriver = SessionDeliveryDriver(session: sender, coordinator: senderRoutes)
        let receiverDriver = SessionDeliveryDriver(session: receiver, coordinator: receiverRoutes)
        let forward = AsyncStream<BeakrNetEnvelope>.makeStream()
        let reverse = AsyncStream<BeakrNetEnvelope>.makeStream()
        let sent = DeliveryFaultTransport(inbound: reverse.stream, outbound: forward.continuation)
        let received = DeliveryFaultTransport(inbound: forward.stream, outbound: reverse.continuation)
        let completed = AsyncStream<Void>.makeStream()
        let updates = ApplicationDeliveryUpdates()
        let senderOwner = await AuthenticatedTransportRouteOwner(
            transport: sent, coordinator: senderRoutes, driver: senderDriver,
            deliveryAcknowledgementSink: { await ApplicationDeliveryPipeline.acknowledge($0, state: outgoing, deliveryUpdates: updates) })
        let receiverOwner = await AuthenticatedTransportRouteOwner(
            transport: received, coordinator: receiverRoutes, driver: receiverDriver,
            incomingEnvelopeSink: { envelope in
                let saved = await inbox.record(envelope)
                completed.continuation.yield(())
                return saved
            })
        await senderOwner.setPermitted(true)
        await receiverOwner.setPermitted(true)
        defer {
            forward.continuation.finish(); reverse.continuation.finish(); completed.continuation.finish()
            Task { await senderOwner.setPermitted(false); await receiverOwner.setPermitted(false) }
        }
        let messaging = PersistentHostMessagingService(state: outgoing,
            contextProvider: { _ in HostDeliveryContext(networkID: network, sessionID: sessionID,
                                                        sourceNodeID: source, sequenceNumber: 1) },
            submit: { envelope in
                if case .sent = try await senderDriver.deliver(envelope) { return .submitted }
                return .routeUnavailable
            })
        let model = MessageComposerModel(messagingService: messaging, deliveryUpdates: updates,
                                         mailboxMetadataURL: root.appendingPathComponent("mailbox.json"))
        let observer = Task { await model.observeDeliveryUpdates() }
        defer { observer.cancel() }
        model.destinationID = destination.rawValue
        model.messageText = "Do not acknowledge until saved"
        await model.send()
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in completed.stream { return true }; return false }
            group.addTask { try await Task.sleep(for: .seconds(5)); return false }
            defer { group.cancelAll() }
            try #require(try await group.next() == true)
        }
        #expect(await received.sent.isEmpty)
        #expect(await incoming.recordedResults().isEmpty)
        let queued = try await outgoing.pending()
        try #require(queued.count == 1)
        let original = try #require(queued.first)
        let diskSender = try await PersistentDataState.open(fileURL: outgoingURL)
        #expect(try await diskSender.pending() == [original])
        #expect(model.outgoingMessages.first?.state == .queued)
        // Repair only this disposable destination, then use the production retry loop.
        try FileManager.default.removeItem(at: incomingURL)
        let retry = Task { await ApplicationDeliveryPipeline.runRetries(messaging: messaging, isRunning: { true }) }
        defer { retry.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while model.outgoingMessages.first?.state != .delivered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.outgoingMessages.first?.state == .delivered)
        let saved = try await PersistentDataState.open(fileURL: incomingURL)
        let results = await saved.recordedResults()
        try #require(results.count == 1)
        #expect(results[0].messageID == original.messageID)
        #expect(String(data: try #require(results[0].response).body, encoding: .utf8) == "Do not acknowledge until saved")
        let finalSender = try await PersistentDataState.open(fileURL: outgoingURL)
        #expect(try await finalSender.pending().isEmpty)
        #expect(await sent.sent == [original, original])
        #expect(await received.sent.count == 1)
        retry.cancel()
        await retry.value
        await senderOwner.setPermitted(false)
        await receiverOwner.setPermitted(false)
    }

    @Test("Receiver recreation after a lost acknowledgement preserves one inbox message",
          .timeLimit(.minutes(1)))
    func receiverRestartAfterLostAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outgoingURL = root.appendingPathComponent("outgoing.json")
        let incomingURL = root.appendingPathComponent("incoming.json")
        let outgoingState = try await PersistentDataState.open(fileURL: outgoingURL)
        let source = NodeID(), destination = NodeID(), network = NetworkID(), sessionID = SessionID()
        let context = MessageProvenanceContext(profileID: UUID(), authorityID: UUID(),
            authorityEndpoint: "https://fixture.invalid", localCredentialID: UUID())
        let sender = BeakrNetSession(id: sessionID, networkID: network, localNodeID: source,
                                    remoteNodeID: destination, state: .active)
        let senderRoutes = PeerRouteCoordinator(networkID: network, remoteNodeID: destination)
        let senderDriver = SessionDeliveryDriver(session: sender, coordinator: senderRoutes)
        let deliveryUpdates = ApplicationDeliveryUpdates()
        let messaging = PersistentHostMessagingService(state: outgoingState,
            contextProvider: { _ in HostDeliveryContext(networkID: network, sessionID: sessionID,
                                                        sourceNodeID: source, sequenceNumber: 1) },
            submit: { envelope in
                if case .sent = try await senderDriver.deliver(envelope) { return .submitted }
                return .routeUnavailable
            })
        let model = MessageComposerModel(messagingService: messaging, deliveryUpdates: deliveryUpdates,
                                         mailboxMetadataURL: root.appendingPathComponent("mailbox.json"))
        let observer = Task { await model.observeDeliveryUpdates() }
        defer { observer.cancel() }
        var original: BeakrNetEnvelope?
        var originalDisk: Data?
        for restarted in [false, true] {
            // Every receiver object and both links are recreated in the second phase.
            let state = try await PersistentDataState.open(fileURL: incomingURL)
            let inbox = ApplicationMessageInbox()
            let updates = await inbox.updates()
            await inbox.attach(state, context: context)
            let receiver = BeakrNetSession(id: sessionID, networkID: network, localNodeID: destination,
                                          remoteNodeID: source, state: .active)
            let routes = PeerRouteCoordinator(networkID: network, remoteNodeID: source)
            let driver = SessionDeliveryDriver(session: receiver, coordinator: routes)
            let forward = AsyncStream<BeakrNetEnvelope>.makeStream()
            let reverse = AsyncStream<BeakrNetEnvelope>.makeStream()
            let link = DeliveryFaultTransport(inbound: reverse.stream, outbound: forward.continuation)
            let peerLink = DeliveryFaultTransport(inbound: forward.stream, outbound: reverse.continuation,
                                                 dropFirstAcknowledgement: !restarted)
            let handled = AsyncStream<Void>.makeStream()
            let senderOwner = await AuthenticatedTransportRouteOwner(
                transport: link, coordinator: senderRoutes, driver: senderDriver,
                deliveryAcknowledgementSink: { acknowledgement in
                    await ApplicationDeliveryPipeline.acknowledge(acknowledgement,
                        state: outgoingState, deliveryUpdates: deliveryUpdates)
                })
            let receiverOwner = await AuthenticatedTransportRouteOwner(
                transport: peerLink, coordinator: routes, driver: driver,
                incomingEnvelopeSink: { envelope in
                    let saved = await inbox.record(envelope)
                    handled.continuation.yield(())
                    return saved
                })
            await receiverOwner.setPermitted(true)
            await senderOwner.setPermitted(true)
            defer {
                forward.continuation.finish(); reverse.continuation.finish(); handled.continuation.finish()
                Task { await senderOwner.setPermitted(false); await receiverOwner.setPermitted(false) }
            }
            var retryTask: Task<Void, Never>?
            defer { retryTask?.cancel() }
            if !restarted {
                model.destinationID = destination.rawValue
                model.messageText = "Persisted before receiver recreation"
                await model.send()
                let pending = try await outgoingState.pending()
                try #require(pending.count == 1)
                original = pending[0]
            } else {
                retryTask = Task {
                    await ApplicationDeliveryPipeline.runRetries(messaging: messaging, isRunning: { true })
                }
            }
            // Receipt of this fixture signal means the real inbox handler completed,
            // not merely that an acknowledgement was sent ahead of persistence.
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await _ in handled.stream { return true }
                    return false
                }
                group.addTask { try await Task.sleep(for: .seconds(8)); return false }
                defer { group.cancelAll() }
                try #require(try await group.next() == true)
            }
            let envelope = try #require(original)
            let results = await state.recordedResults()
            try #require(results.count == 1)
            #expect(results[0].messageID == envelope.messageID)
            #expect(String(data: try #require(results[0].response).body, encoding: .utf8)
                    == "Persisted before receiver recreation")
            #expect(await link.sent == [envelope])
            if !restarted {
                let acknowledgementDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                while await peerLink.droppedAcknowledgements == 0, ContinuousClock.now < acknowledgementDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(await peerLink.droppedAcknowledgements == 1)
                #expect(try await outgoingState.pending() == [envelope])
                #expect(model.outgoingMessages.first?.state == .queued)
                originalDisk = try Data(contentsOf: incomingURL)
            } else {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while model.outgoingMessages.first?.state != .delivered, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                try #require(model.outgoingMessages.first?.state == .delivered)
                let reopenedOutgoing = try await PersistentDataState.open(fileURL: outgoingURL)
                #expect(try await reopenedOutgoing.pending().isEmpty)
                #expect(try Data(contentsOf: incomingURL) == originalDisk)
                let reopenedIncoming = try await PersistentDataState.open(fileURL: incomingURL)
                #expect(await reopenedIncoming.recordedResults().count == 1)
                // New receiver session accepts the retry; restored inbox IDs suppress it.
                let history = await receiver.diagnosticHistory
                #expect(history.filter { if case .envelopeAccepted = $0 { true } else { false } }.count == 1)
                #expect(history.filter { if case .duplicateRejected = $0 { true } else { false } }.isEmpty)
                let barrierMessage = DataMessage(kind: .message,
                    operation: .init(namespace: "beakr", name: "text-message", version: 1),
                    correlationID: DataCorrelationID(), body: Data("Observer barrier".utf8))
                let barrier = BeakrNetEnvelope(networkID: network, sessionID: sessionID,
                    sourceNodeID: source, destinationNodeID: destination, sequenceNumber: 2,
                    deliveryPolicy: .init(durability: .ephemeral), payloadType: DataMessage.payloadType,
                    payload: try DataCodec().encode(barrierMessage))
                await inbox.record(barrier)
                try await withThrowingTaskGroup(of: [IncomingMessage].self) { group in
                    group.addTask {
                        var values: [IncomingMessage] = []
                        for await value in updates {
                            values.append(value)
                            if value.id == barrierMessage.correlationID.rawValue { return values }
                        }
                        return values
                    }
                    group.addTask { try await Task.sleep(for: .seconds(5)); return [] }
                    defer { group.cancelAll() }
                    let values = try #require(try await group.next())
                    try #require(values.count == 2)
                    #expect(values[0].id == results[0].response?.correlationID.rawValue)
                    #expect(values[0].isRestored)
                    #expect(values[1].id == barrierMessage.correlationID.rawValue)
                    #expect(!values[1].isRestored)
                }
            }
            retryTask?.cancel()
            await retryTask?.value
            await senderOwner.setPermitted(false)
            await receiverOwner.setPermitted(false)
        }
    }

    @Test("Only an admitted reply marks its original message read",
          arguments: ["queued", "online", "failure", "cancel", "forward", "resend", "recipient", "mailbox"])
    func replyReadOnAdmission(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mailbox.json")
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: url)
        let sender = UUID()
        let other = UUID()
        let message = IncomingMessage(id: UUID(), source: sender, body: "Unread original",
                                      receivedAt: Date(), isRestored: false)
        model.synchronizeRecipients(with: [NetworkMemberSummary(id: sender, displayName: "Sender")])
        model.prepareReply(to: message)
        #expect(!model.isRead(message.id))
        #expect(await service.requests.isEmpty)
        switch scenario {
        case "online": model.synchronizeOnlineRecipients(with: [sender])
        case "failure": model.replaceMessagingService(FailingMessagingService())
        case "cancel": model.discardDraft()
        case "forward": model.prepareForward(body: message.body)
        case "resend": model.prepareResend(to: sender, body: "Resend")
        case "mailbox": model.attachMailboxMetadata(fileURL: root.appendingPathComponent("other.json"))
        default: break
        }
        model.destinationID = scenario == "recipient" ? other : sender
        model.messageText = "Response"
        await model.send()

        let shouldRead = scenario == "queued" || scenario == "online"
        #expect(model.isRead(message.id) == shouldRead)
        let persistedURL = scenario == "mailbox" ? root.appendingPathComponent("other.json") : url
        #expect(try ContextMailboxMetadataStore.load(from: persistedURL).readMessageIDs.contains(message.id) == shouldRead)
        #expect(model.outgoingMessages.first?.state == (scenario == "failure" ? .failed : scenario == "online" ? .sent : .queued))
        let receipts = await service.requests.filter { $0.message.operation.name == "read-receipt" }
        #expect(receipts.count == (shouldRead ? 1 : 0))
        if shouldRead {
            let receipt = try JSONDecoder().decode(MessageReadReceipt.self, from: #require(receipts.first).message.body)
            #expect(receipt.messageID == message.id)
            await model.openIncomingMessage(message)
            #expect(await service.requests.filter { $0.message.operation.name == "read-receipt" }.count == 1)
        }
    }

    @Test("Discarding or starting a new message clears draft text, recipient and reply association",
          arguments: ["reply", "forward", "resend"])
    func discardedDraftDoesNotLeak(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service,
                                         mailboxMetadataURL: root.appendingPathComponent("mailbox.json"))
        let sender = UUID()
        let original = IncomingMessage(id: UUID(), source: sender, body: "Unread original",
                                       receivedAt: Date(), isRestored: false)
        model.synchronizeRecipients(with: [NetworkMemberSummary(id: sender, displayName: "Sender")])
        model.prepareReply(to: original)
        if mode == "forward" { model.prepareForward(body: original.body) }
        if mode == "resend" { model.prepareResend(to: sender, body: "Previous message") }
        model.destinationID = sender
        model.messageText = "Dad"

        // Shared action used by sheet dismissal and the New Message buttons.
        model.discardDraft()
        #expect(model.messageText.isEmpty)
        #expect(model.destinationID == nil)
        #expect(!model.canSend)
        #expect(!model.isRead(original.id))
        #expect(await service.requests.isEmpty)
        // Compose repeats this reset even if it opens without a prior dismissal.
        model.discardDraft()
        #expect(model.messageText.isEmpty)
        #expect(model.destinationID == nil)
        model.destinationID = sender
        model.messageText = "Fresh message"
        await model.send()
        let requests = await service.requests
        try #require(requests.count == 1)
        #expect(String(data: requests[0].message.body, encoding: .utf8) == "Fresh message")
        #expect(requests[0].message.operation.name == "text-message")
        #expect(!model.isRead(original.id))
        #expect(model.outgoingMessages.first?.body == "Fresh message")
    }

    @Test("Send to an offline recipient queues through the host API and clears the composer")
    func queueMessage() async {
        let suiteName = "BeakrTests.Queue.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        let destination = UUID()
        model.destinationID = destination
        model.messageText = "Hello from Beakr"

        await model.send()

        #expect(model.messageText.isEmpty)
        #expect(model.outgoingMessages.count == 1)
        #expect(model.outgoingMessages[0].state == .queued)
        let requests = await service.requests
        #expect(requests.count == 1)
        #expect(requests[0].destination == NodeID(rawValue: destination))
        #expect(String(data: requests[0].message.body, encoding: .utf8) == "Hello from Beakr")

        let restoredModel = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        #expect(restoredModel.outgoingMessages == model.outgoingMessages)
    }

    @Test("Send to an online recipient records sent until delivery is confirmed")
    func sendOnlineMessage() async {
        let suiteName = "BeakrTests.SendOnline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        let destination = UUID()
        model.destinationID = destination
        model.messageText = "Hello online device"
        model.synchronizeOnlineRecipients(with: [destination])

        await model.send()

        #expect(model.messageText.isEmpty)
        #expect(model.outgoingMessages.first?.state == .sent)
        #expect(model.statusMessage == "Message sent. Waiting for delivery confirmation.")
    }

    @Test("Missing destination never reaches the host service")
    func invalidDestination() async {
        let suiteName = "BeakrTests.InvalidDestination.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        model.destinationID = nil
        model.messageText = "Hello"

        await model.send()

        #expect(await service.requests.isEmpty)
        #expect(model.outgoingMessages.isEmpty)
    }

    @Test("Host failure remains visible and does not claim the message was queued")
    func hostFailure() async {
        let suiteName = "BeakrTests.HostFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = MessageComposerModel(messagingService: FailingMessagingService(), mailboxMetadataURL: metadataURL(suiteName))
        model.destinationID = UUID()
        model.messageText = "Hello"

        await model.send()

        #expect(model.outgoingMessages.count == 1)
        #expect(model.outgoingMessages[0].state == .failed)
        #expect(!model.messageText.isEmpty)
    }

    @Test("Recipients have friendly names and removed discoveries stay removed")
    func recipientDirectory() {
        let suiteName = "BeakrTests.Recipients.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        let address = UUID()
        let discovered = NetworkMemberSummary(id: address, displayName: "Network Device ABC123")

        model.synchronizeRecipients(with: [discovered])
        #expect(model.recipients.first?.name == "Network Device ABC123")
        model.synchronizeRecipients(with: [
            NetworkMemberSummary(id: address, displayName: "Hallway iPhone")
        ])
        #expect(model.recipients.first?.name == "Hallway iPhone")
        model.synchronizeRecipients(with: [
            NetworkMemberSummary(
                id: address,
                displayName: "Network Device ABC123",
                isPlaceholderName: true
            )
        ])
        #expect(model.recipients.first?.name == "Hallway iPhone")
        model.renameRecipient(id: address, name: "Kitchen iPhone")
        #expect(model.displayName(for: address) == "Kitchen iPhone")
        model.synchronizeRecipients(with: [
            NetworkMemberSummary(id: address, displayName: "Renamed Remotely")
        ])
        #expect(model.displayName(for: address) == "Renamed Remotely")

        model.removeRecipient(id: address)
        model.synchronizeRecipients(with: [discovered])
        #expect(model.recipients.isEmpty)

        #expect(model.addRecipient(name: "Alice", addressText: address.uuidString))
        #expect(model.displayName(for: address) == "Alice")
    }

    @Test("Recreated app inbox restores once and suppresses a retried stored envelope",
          .timeLimit(.minutes(1)))
    func inboxRestartSuppressesRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("incoming.json")
        let context = MessageProvenanceContext(profileID: UUID(), authorityID: UUID(),
            authorityEndpoint: "https://fixture.invalid", localCredentialID: UUID())
        let source = NodeID(), destination = NodeID(), network = NetworkID(), session = SessionID()
        let now = Date()
        func envelope(body: String, sequence: UInt64) throws -> (BeakrNetEnvelope, DataMessage) {
            let message = DataMessage(kind: .message,
                operation: .init(namespace: "beakr", name: "text-message", version: 1),
                correlationID: DataCorrelationID(), idempotencyKey: DataIdempotencyKey(), body: Data(body.utf8))
            return (BeakrNetEnvelope(networkID: network, sessionID: session,
                sourceNodeID: source, destinationNodeID: destination, sequenceNumber: sequence,
                deliveryPolicy: .init(durability: .durable, expiresAt: now.addingTimeInterval(60)),
                payloadType: DataMessage.payloadType, payload: try DataCodec().encode(message), createdAt: now), message)
        }
        // Reading through a distinct later message is a deterministic stream barrier:
        // any duplicate retry notification would precede it, without a timing-based sleep.
        func readThrough(_ stream: AsyncStream<IncomingMessage>, id: UUID) async throws -> [IncomingMessage] {
            try await withThrowingTaskGroup(of: [IncomingMessage].self) { group in
                group.addTask {
                    var values: [IncomingMessage] = []
                    for await value in stream {
                        values.append(value)
                        if value.id == id { return values }
                    }
                    return values
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw TestProfileRuntimeError.unavailable
                }
                defer { group.cancelAll() }
                return try #require(try await group.next())
            }
        }
        let (original, message) = try envelope(body: "Restart inbox original", sequence: 1)
        do {
            let state = try await PersistentDataState.open(fileURL: file)
            let inbox = ApplicationMessageInbox()
            await inbox.attach(state, context: context)
            let stream = await inbox.updates()
            await inbox.record(original)
            let updates = try await readThrough(stream, id: message.correlationID.rawValue)
            try #require(updates.count == 1)
            #expect(!updates[0].isRestored)
            #expect(updates[0].body == "Restart inbox original")
            #expect(updates[0].source == source.rawValue)
            #expect(await state.recordedResults().count == 1)
        }
        let reopened = try await PersistentDataState.open(fileURL: file)
        let inbox = ApplicationMessageInbox()
        let stream = await inbox.updates()
        await inbox.attach(reopened, context: context)
        let beforeRetry = try Data(contentsOf: file)
        await inbox.record(original)
        await inbox.record(original)
        let stored = await reopened.recordedResults()
        try #require(stored.count == 1)
        #expect(stored[0].messageID == original.messageID)
        #expect(stored[0].response == message)
        #expect(try Data(contentsOf: file) == beforeRetry)
        let diskCheck = try await PersistentDataState.open(fileURL: file)
        #expect(await diskCheck.recordedResults().count == 1)
        #expect(await diskCheck.result(for: original.messageID)?.response == message)

        let (barrier, barrierMessage) = try envelope(body: "Observer barrier", sequence: 2)
        await inbox.record(barrier)
        let updates = try await readThrough(stream, id: barrierMessage.correlationID.rawValue)
        try #require(updates.count == 2)
        #expect(updates[0].id == message.correlationID.rawValue)
        #expect(updates[0].isRestored)
        #expect(updates[0].body == "Restart inbox original")
        #expect(updates[0].source == source.rawValue)
        #expect(updates[0].provenance?.storageMessageID == original.messageID.rawValue)
        #expect(updates[0].provenance?.profileID == context.profileID)
        #expect(updates[1].id == barrierMessage.correlationID.rawValue)
        #expect(!updates[1].isRestored)
        #expect(updates.filter { $0.id == message.correlationID.rawValue && !$0.isRestored }.isEmpty)
        #expect(await reopened.recordedResults().count == 2)
    }

    @Test("Inbox metadata persists and legacy messages derive a subject")
    func inboxMetadata() {
        let suiteName = "BeakrTests.InboxMetadata.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let messageID = UUID()
        let message = IncomingMessage(
            id: messageID,
            source: UUID(),
            body: "Meeting Tomorrow\nPlease bring the latest notes.",
            receivedAt: Date(),
            isRestored: true
        )

        #expect(message.subject == "Meeting Tomorrow")
        #expect(message.preview == "Please bring the latest notes.")

        let model = MessageComposerModel(messagingService: RecordingMessagingService(), mailboxMetadataURL: metadataURL(suiteName))
        model.setRead(true, messageID: messageID)
        model.toggleFlag(messageID: messageID)

        let restoredModel = MessageComposerModel(messagingService: RecordingMessagingService(), mailboxMetadataURL: metadataURL(suiteName))
        #expect(restoredModel.isRead(messageID))
        #expect(restoredModel.isFlagged(messageID))
    }

    @Test("Opening an incoming message queues one durable read receipt")
    func readReceipt() async throws {
        let suiteName = "BeakrTests.ReadReceipt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        let message = IncomingMessage(
            id: UUID(),
            source: UUID(),
            body: "Hello",
            receivedAt: Date(),
            isRestored: false
        )

        await model.openIncomingMessage(message)
        await model.openIncomingMessage(message)

        let requests = await service.requests
        #expect(requests.count == 1)
        #expect(requests[0].destination.rawValue == message.source)
        #expect(requests[0].message.operation.name == "read-receipt")
        let receipt = try JSONDecoder().decode(MessageReadReceipt.self, from: requests[0].message.body)
        #expect(receipt.messageID == message.id)
        #expect(model.isRead(message.id))
    }

    @Test("Deleting queued messages cancels delivery and moves them to recoverable Trash")
    func separateMessageDeletion() async {
        let suiteName = "BeakrTests.Deletion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        model.destinationID = UUID()
        model.messageText = "Keep queued"
        await model.send()

        await model.deleteMessageHistory()
        #expect(model.outgoingMessages.count == 1)
        #expect(model.outgoingMessages[0].state == .queued)

        let correlationID = model.outgoingMessages[0].id
        await model.deleteQueuedMessages()
        #expect(model.outgoingMessages.count == 1)
        #expect(model.trashedMessageIDs.contains(correlationID))
        #expect(await service.cancelledCorrelationIDs == [correlationID])

        model.restoreMessage(id: correlationID)
        #expect(!model.trashedMessageIDs.contains(correlationID))
        await model.deleteOutgoingMessage(id: correlationID)
        model.permanentlyDeleteOutgoingMessage(id: correlationID)
        #expect(model.outgoingMessages.isEmpty)

        model.destinationID = UUID()
        model.messageText = "Delete one"
        await model.send()
        let individualID = model.outgoingMessages[0].id
        await model.deleteOutgoingMessage(id: individualID)
        #expect(model.outgoingMessages.count == 1)
        #expect(model.trashedMessageIDs.contains(individualID))
        #expect(await service.cancelledCorrelationIDs == [correlationID, correlationID, individualID])

        let restoredModel = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        #expect(restoredModel.outgoingMessages.count == 1)
        #expect(restoredModel.trashedMessageIDs.contains(individualID))

        restoredModel.restoreMessage(id: individualID)
        #expect(!restoredModel.trashedMessageIDs.contains(individualID))
    }

    @Test("Bootstrap restores a stable identity before requesting authority configuration")
    func bootstrapIdentity() async throws {
        let nodeID = NodeID()
        let profile = try NetworkProfile(networkID: NetworkID(), localNodeID: nodeID, displayName: "Test")
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: nodeID),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: NoopTrustBootstrapper(),
            profileRuntimeManager: MemoryProfileRuntimeManager(initialProfile: profile)
        )

        await model.start()

        #expect(model.nodeID == nodeID.rawValue)
        #expect(model.state == .needsConfiguration)
    }

    @Test("An empty profile registry creates no network sessions")
    func emptyRegistryCreatesNoNetworkSessions() async {
        let model = NodeBootstrapModel(
            identityLoader: FailingIdentityLoader(),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: NoopTrustBootstrapper(),
            profileRuntimeManager: MemoryProfileRuntimeManager()
        )

        await model.start()

        #expect(model.networkSessions.isEmpty)
        #expect(model.networks.isEmpty)
        #expect(model.state == .needsConfiguration)
        #expect(model.activeNetworkConnectivity == .inactive)
    }

    @Test("Bootstrap startup is idempotent across repeated window tasks")
    func bootstrapStartupIsIdempotent() async throws {
        let nodeID = NodeID()
        let profile = try NetworkProfile(networkID: NetworkID(), localNodeID: nodeID, displayName: "Test")
        let profileManager = MemoryProfileRuntimeManager(initialProfile: profile)
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: nodeID),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: NoopTrustBootstrapper(),
            profileRuntimeManager: profileManager
        )

        await model.start()
        await model.start()

        #expect(await profileManager.activeProfileRequests == 1)
    }

    @Test("Attached Context history is available without activating its profile runtime")
    func attachedContextHistoryLoadsForOfflineBrowsing() async throws {
        let nodeID = NodeID()
        let profile = try NetworkProfile(
            networkID: NetworkID(),
            localNodeID: nodeID,
            displayName: "Offline History"
        )
        let context = ContextRecord(
            displayName: "Offline History",
            knownNetworkIDs: [profile.networkID],
            attachedProfileIDs: [profile.id]
        )
        let message = IncomingMessage(
            id: UUID(),
            source: UUID(),
            body: "Stored message",
            receivedAt: Date(timeIntervalSince1970: 1_000),
            isRestored: true
        )
        let metadata = ContextMailboxMetadata(
            outgoingMessages: [OutgoingMessage(
                id: UUID(),
                destination: UUID(),
                body: "Stored outgoing message",
                state: .delivered
            )],
            recipients: [],
            removedRecipientIDs: [],
            readMessageIDs: [message.id],
            flaggedMessageIDs: [],
            sentReadReceiptIDs: []
        )
        let profileManager = MemoryProfileRuntimeManager(
            initialProfile: profile,
            contexts: [context],
            incomingMessages: [context.id: [message]],
            mailboxMetadata: [context.id: metadata]
        )
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: nodeID),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: NoopTrustBootstrapper(),
            profileRuntimeManager: profileManager
        )

        await model.start()

        #expect(model.storedIncomingMessages[profile.id] == [message])
        #expect(model.storedMailboxMetadata[profile.id] == metadata)
        #expect(model.archivedContexts.isEmpty)
    }

    @Test("Profile registry load failures remain distinct from an empty registry")
    func profileRegistryLoadFailure() async {
        let model = NodeBootstrapModel(
            identityLoader: FailingIdentityLoader(),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: NoopTrustBootstrapper(),
            profileRuntimeManager: MemoryProfileRuntimeManager(failsToLoad: true)
        )

        await model.start()

        #expect(model.state == .failed)
        #expect(model.activeNetworkConnectivity == .failed)
        #expect(model.profileRegistryLoadFailure != nil)
        #expect(model.statusMessage.contains("Network data could not be loaded"))
    }

    @Test("Bootstrap fails closed when secure identity storage is unavailable")
    func bootstrapFailure() async throws {
        let profile = try NetworkProfile(networkID: NetworkID(), localNodeID: NodeID(), displayName: "Test")
        let model = NodeBootstrapModel(
            identityLoader: FailingIdentityLoader(),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: NoopTrustBootstrapper(),
            profileRuntimeManager: MemoryProfileRuntimeManager(initialProfile: profile)
        )

        await model.start()

        #expect(model.nodeID == nil)
        #expect(model.state == .failed)
        #expect(model.networks.count == 1)
        #expect(model.networks.first?.id == profile.id)
        #expect(model.networks.first?.isActive == true)
        #expect(model.networks.first?.canExchangeMessages == false)
        let failureMessage = model.statusMessage
        model.prepareForNetworkJoin()
        #expect(model.statusMessage == failureMessage)
        #expect(model.networkSessions.first?.lastError == failureMessage)
    }

    @Test("A network can become active after the previous profile failed to start")
    func switchNetworkAfterBootstrapFailure() async throws {
        let nodeID = NodeID()
        let home = try NetworkProfile(networkID: NetworkID(), localNodeID: nodeID, displayName: "Home")
        let office = try NetworkProfile(networkID: NetworkID(), localNodeID: nodeID, displayName: "Office")
        let profileManager = MultipleProfileRuntimeManager(initialProfile: home)
        await profileManager.addAndActivate(office)
        try await profileManager.activate(home.id)
        let model = NodeBootstrapModel(
            identityLoader: FailingIdentityLoader(),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: NoopTrustBootstrapper(),
            profileRuntimeManager: profileManager
        )

        await model.start()
        #expect(model.state == .failed)
        let originalHomeSession = try #require(
            model.networkSessions.first(where: { $0.id == home.id })
        )

        await model.switchNetwork(to: office.id)

        #expect(await profileManager.activeProfile()?.id == office.id)
        #expect(model.networkSessions.first(where: { $0.id == home.id }) === originalHomeSession)
        #expect(model.networks.first(where: { $0.id == office.id })?.isActive == true)
        #expect(model.networks.first(where: { $0.id == home.id })?.isActive == false)
    }

    @Test("Verified development authority configuration advances bootstrap")
    func authorityConfiguration() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: MemoryProfileRuntimeManager(),
            lanRuntimeManager: TestLANRuntimeManager()
        )
        await model.start()
        model.controlPlaneURL = "https://authority.example"
        model.networkIDText = networkID.rawValue.uuidString
        model.authorityPublicKeyBase64 = authority.publicKeyRepresentation.base64EncodedString()
        model.credentialJSON = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)

        await model.saveDevelopmentConfiguration()

        #expect(model.state == .ready)
        #expect(model.credentialJSON.isEmpty)
    }

    @Test("A configured network remains inactive without a usable local network")
    func configuredNetworkWithoutLocalNetworkIsInactive() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager()
        await profileRuntimeManager.setInitialProfile(try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Test Network"
        ))
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: TestLANRuntimeManager(localNetworkAvailable: false),
            networkStartTimeout: .milliseconds(50)
        )

        await model.start()

        #expect(model.state == .ready)
        #expect(model.activeNetworkConnectivity == .inactive)
        #expect(model.activeNetworkStatusTitle == "Inactive")
    }

    @Test("Friendly name restart preserves connectivity and subsequent peer reconciliation")
    func friendlyNameRestartPreservesConnectivity() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager()
        let peerID = UUID()
        let lanRuntimeManager = TestLANRuntimeManager(authenticatedPeerIDs: [peerID])
        await profileRuntimeManager.setInitialProfile(try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Test Network"
        ))
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: lanRuntimeManager,
            networkStartTimeout: .milliseconds(50)
        )
        await model.start()

        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.onlineMemberIDs == [peerID])
        #expect(model.activeNetworkStatusTitle == "Active — Connected to 1 device")

        let originalName = model.deviceFriendlyName
        defer { model.deviceFriendlyName = originalName }
        let profileID = model.profileID
        model.deviceFriendlyName = "  E14 Renamed Device  "
        await model.applyDeviceFriendlyName()

        #expect(model.deviceFriendlyName == "E14 Renamed Device")
        #expect(await lanRuntimeManager.lastDisplayName == "E14 Renamed Device")
        #expect(await lanRuntimeManager.startCount == 2)
        #expect(await lanRuntimeManager.stopCount == 1)
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.onlineMemberIDs == [peerID])
        #expect(model.profileID == profileID)

        // Reconciliation used to turn the renamed device inactive because the
        // rename path cleared local availability without restoring its monitor.
        await model.refreshNetworkMembers()
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.onlineMemberIDs == [peerID])

        await lanRuntimeManager.failNextStarts(1)
        model.deviceFriendlyName = "E14 Retry Name"
        await model.applyDeviceFriendlyName()
        #expect(model.activeNetworkConnectivity == .failed)
        #expect(model.statusMessage == "Local Network startup failed. Pull down to retry.")
        #expect(model.profileID == profileID)
        await model.applyDeviceFriendlyName()
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(await lanRuntimeManager.lastDisplayName == "E14 Retry Name")
        await model.applicationDidEnterBackground()
    }

    @Test("A name saved before startup persists and is advertised by normal startup")
    func friendlyNameSavedBeforeStartup() async throws {
        let suiteName = "Beakr-E14-Inactive-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let nameKey = "net.beakr.app.deviceFriendlyName"
        defaults.set("Original fixture name", forKey: nameKey)

        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: try #require(URL(string: "https://authority.example")),
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profiles = MemoryProfileRuntimeManager()
        let profile = try NetworkProfile(
            networkID: networkID, localNodeID: identity.nodeID, displayName: "E14 fixture"
        )
        await profiles.setInitialProfile(profile)
        let peerID = UUID()
        let runtime = TestLANRuntimeManager(authenticatedPeerIDs: [peerID])
        func makeModel() -> NodeBootstrapModel {
            NodeBootstrapModel(
                identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
                configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
                trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
                profileRuntimeManager: profiles,
                lanRuntimeManager: runtime,
                friendlyNameDefaults: defaults
            )
        }

        // Exercise the non-ready branch without opening a live profile or runtime.
        do {
            let model = makeModel()
            #expect(model.deviceFriendlyName == "Original fixture name")
            model.deviceFriendlyName = "  E14 saved before startup  "
            await model.applyDeviceFriendlyName()
            #expect(model.deviceFriendlyName == "E14 saved before startup")
            #expect(defaults.string(forKey: nameKey) == "E14 saved before startup")
            #expect(await runtime.startCount == 0)
            #expect(await runtime.stopCount == 0)
            #expect(await runtime.lastDisplayName == nil)
            #expect(await profiles.profiles() == [profile])
        }

        // A new model must restore the saved name, not rely on the first instance.
        let restored = makeModel()
        #expect(restored.deviceFriendlyName == "E14 saved before startup")
        await restored.start()
        #expect(await runtime.startCount == 1)
        #expect(await runtime.lastDisplayName == "E14 saved before startup")
        #expect(restored.nodeID == identity.nodeID.rawValue)
        #expect(restored.profileID == profile.id.rawValue)
        #expect(restored.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(restored.onlineMemberIDs == [peerID])
        #expect(await profiles.profiles() == [profile])
        await restored.applicationDidEnterBackground()
    }

    @Test("Unavailable authority recovers automatically, while terminal credential failures do not retry",
          arguments: [LANHandshakeError.staleRevocationSnapshot, .expiredCredential, .revokedCredential, .invalidRevocationSnapshot])
    func automaticCredentialRecovery(error: LANHandshakeError) async throws {
        let fixture = try await credentialRecoveryFixture(error: error)
        let model = fixture.model
        let gate = CredentialRetryGate()
        model.credentialRecoveryDelay = { delay in await gate.wait(delay) }
        await model.start()
        #expect(await fixture.lan.startCount == 0)
        #expect(model.activeNetworkConnectivity == .failed)
        #expect(model.credentialStatus != .preparing)
        if error == .staleRevocationSnapshot {
            #expect(model.credentialStatus == .waitingForAuthority)
            #expect(model.networks.first?.credentialStatus == .waitingForAuthority)
            await gate.release()
            for _ in 0..<200 where model.state != .ready { try await Task.sleep(for: .milliseconds(10)) }
            #expect(model.state == .ready)
            #expect(model.credentialStatus == nil)
            #expect(await fixture.trust.attempts == 2)
            #expect(await fixture.lan.startCount == 1)
        } else {
            #expect(model.credentialStatus?.retriesAutomatically == false)
            #expect(await gate.delays.isEmpty)
            #expect(await fixture.trust.attempts == 1)
        }
        await model.applicationWillTerminate()
    }

    @Test("Missing authority endpoint waits and retries credential preparation")
    func credentialRecoveryUnavailableEndpoint() async throws {
        let fixture = try await credentialRecoveryFixture(error: DiscoveredAuthorityHTTPTransportError.endpointUnavailable)
        let gate = CredentialRetryGate()
        fixture.model.credentialRecoveryDelay = { delay in await gate.wait(delay) }
        await fixture.model.start()
        #expect(fixture.model.credentialStatus == .waitingForAuthority)
        #expect(await fixture.lan.startCount == 0)
        await gate.release()
        for _ in 0..<200 where fixture.model.state != .ready { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fixture.model.state == .ready)
        #expect(await fixture.trust.attempts == 2)
        await fixture.model.applicationWillTerminate()
    }

    @Test("Backgrounding cancels scheduled recovery; foregrounding retries immediately")
    func credentialRecoveryBackground() async throws {
        let fixture = try await credentialRecoveryFixture(error: LANHandshakeError.staleRevocationSnapshot)
        let gate = CredentialRetryGate()
        fixture.model.credentialRecoveryDelay = { delay in await gate.wait(delay) }
        await fixture.model.start()
        await fixture.model.applicationDidEnterBackground()
        await gate.release()
        #expect(await fixture.lan.startCount == 0)
        #expect(await fixture.trust.attempts == 1)
        await fixture.model.applicationBecameActive()
        #expect(fixture.model.state == .ready)
        #expect(await fixture.trust.attempts == 2)
        await fixture.model.applicationWillTerminate()
    }

    @Test("Late trust completion cannot start messaging after backgrounding")
    func credentialRecoveryInFlightCancellation() async throws {
        let fixture = try await credentialRecoveryFixture(error: LANHandshakeError.staleRevocationSnapshot)
        let gate = CredentialRetryGate()
        fixture.trust.firstAttemptGate = gate
        let startup = Task { await fixture.model.start() }
        for _ in 0..<200 where fixture.trust.attempts == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fixture.trust.attempts == 1)
        let background = Task { await fixture.model.applicationDidEnterBackground() }
        // Allow the background callback to invalidate the in-flight operation.
        await Task.yield()
        await gate.release()
        await startup.value
        await background.value
        #expect(await fixture.lan.startCount == 0)
        await fixture.model.applicationBecameActive()
        #expect(fixture.model.state == .ready)
        #expect(await fixture.lan.startCount == 1)
        await fixture.model.applicationWillTerminate()
    }

    @Test("Explicit network selection cancels the old scheduled credential retry")
    func credentialRecoverySelection() async throws {
        let fixture = try await credentialRecoveryFixture(error: LANHandshakeError.staleRevocationSnapshot)
        let gate = CredentialRetryGate()
        fixture.model.credentialRecoveryDelay = { delay in await gate.wait(delay) }
        await fixture.model.start()
        let profileID = try #require(fixture.model.networks.first?.id)
        await fixture.model.switchNetwork(to: profileID)
        await gate.release()
        #expect(fixture.model.state == .ready)
        #expect(fixture.trust.attempts == 2)
        #expect(await fixture.lan.startCount == 1)
        await fixture.model.applicationWillTerminate()
    }

    private func credentialRecoveryFixture(error: any Error) async throws
        -> (model: NodeBootstrapModel, trust: RecoveringTrustFixture, lan: TestLANRuntimeManager) {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let profile = try NetworkProfile(networkID: NetworkID(), localNodeID: identity.nodeID, displayName: "Recovery")
        let credential = try authority.issue(nodeID: identity.nodeID, nodePublicKey: identity.publicKeyRepresentation,
            networkID: profile.networkID, environment: "development", validity: 3_600, serviceScopes: ["lan"])
        let configuration = DevelopmentAuthorityConfiguration(controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: profile.networkID, authorityPublicKey: authority.publicKeyRepresentation, credential: credential)
        let profiles = MemoryProfileRuntimeManager()
        await profiles.setInitialProfile(profile)
        let trust = RecoveringTrustFixture(authority: authority, firstError: error)
        let lan = TestLANRuntimeManager(authenticatedPeerIDs: [])
        let model = NodeBootstrapModel(identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: trust, profileRuntimeManager: profiles, lanRuntimeManager: lan)
        return (model, trust, lan)
    }

    @Test("Certificate and revocation recovery are required before bootstrap is ready")
    func trustRecovery() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager()
        let peerID = UUID()
        let lanRuntimeManager = TestLANRuntimeManager(authenticatedPeerIDs: [peerID])
        await profileRuntimeManager.setInitialProfile(try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Test Network"
        ))
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: lanRuntimeManager,
            networkStartTimeout: .milliseconds(50)
        )
        await model.start()

        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.onlineMemberIDs == [peerID])
        #expect(model.activeNetworkStatusTitle == "Active — Connected to 1 device")

        model.applicationDidBecomeInactive()
        await model.applicationBecameActive()

        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.onlineMemberIDs == [peerID])
        #expect(await lanRuntimeManager.startCount == 1)
        #expect(await lanRuntimeManager.stopCount == 0)

        await model.applicationDidEnterBackground()

        #expect(model.state == .ready)
        #expect(model.activeNetworkConnectivity == .inactive)
        #expect(model.onlineMemberIDs.isEmpty)
        #expect(await lanRuntimeManager.startCount == 1)
        #expect(await lanRuntimeManager.stopCount == 1)
        #expect(await profileRuntimeManager.checkpointLifecycles == [.background])

        // iOS passes through inactive while returning from the background.
        // Preserve the background origin so activation still reconnects.
        model.applicationDidBecomeInactive()
        await model.applicationBecameActive()

        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.onlineMemberIDs == [peerID])
        #expect(await lanRuntimeManager.startCount == 2)

        await model.reconnectActiveNetwork()

        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(await lanRuntimeManager.startCount == 3)
        #expect(await lanRuntimeManager.stopCount == 2)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    await model.reconnectActiveNetwork()
                }
            }
        }

        #expect(await lanRuntimeManager.startCount == 4)
        #expect(await lanRuntimeManager.stopCount == 3)

        await lanRuntimeManager.setStartDelay(.seconds(5))
        await model.reconnectActiveNetwork()

        #expect(model.state == .ready)
        #expect(model.activeNetworkConnectivity == .failed)
        #expect(model.statusMessage == "Local Network startup timed out. Pull down to retry.")

        await lanRuntimeManager.setStartDelay(nil)
        await model.reconnectActiveNetwork()

        #expect(model.state == .ready)
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))

    }

    @Test("Lifecycle migration failure prevents messaging from starting")
    func lifecycleMigrationFailureStopsMessaging() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Test Network"
        )
        let lanRuntimeManager = TestLANRuntimeManager()
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: MemoryProfileRuntimeManager(initialProfile: profile),
            lanRuntimeManager: lanRuntimeManager,
            lifecycleMigrator: FailingLifecycleMigrator()
        )

        await model.start()

        #expect(model.state == .identityReady)
        #expect(model.activeNetworkConnectivity == .failed)
        #expect(model.credentialStatus == .invalid)
        #expect(await lanRuntimeManager.startCount == 0)
        #expect(await lanRuntimeManager.stopCount == 0)
    }

    @Test("A prepared lifecycle bypasses legacy migration")
    func preparedLifecycleBypassesLegacyMigration() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Prepared Network"
        )
        let lanRuntimeManager = TestLANRuntimeManager()
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: MemoryProfileRuntimeManager(initialProfile: profile),
            lanRuntimeManager: lanRuntimeManager,
            lifecycleMigrator: FailingLifecycleMigrator(),
            enrollmentRouter: FixedApplicationEnrollmentRouter(
                route: .member,
                lifecycleExists: true
            )
        )

        await model.start()

        #expect(model.state == .ready)
        #expect(await lanRuntimeManager.startCount == 1)
    }

    @Test("Persisted lifecycle route gates startup and manual refresh", arguments: [
        EnrollmentApplicationRoute.credentialRecovery, .trustRecovery
    ])
    func persistedLifecycleRouteGatesMessaging(route: EnrollmentApplicationRoute) async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Test Network"
        )
        let lanRuntimeManager = TestLANRuntimeManager()
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: MemoryProfileRuntimeManager(initialProfile: profile),
            lanRuntimeManager: lanRuntimeManager,
            enrollmentRouter: FixedApplicationEnrollmentRouter(route: route)
        )

        await model.start()

        #expect(model.state == .identityReady)
        #expect(model.activeNetworkConnectivity == (route == .trustRecovery ? .failed : .inactive))
        #expect(model.credentialStatus == (route == .trustRecovery ? .waitingForAuthority : nil))
        if route == .trustRecovery {
            #expect(model.networkSessions.first(where: \.isSelected)?.lastError == model.statusMessage)
        }
        await model.reconnectActiveNetwork()
        #expect(model.state == .identityReady)
        #expect(await lanRuntimeManager.startCount == 0)
    }

    @Test("Fresh cached revocations allow offline startup without an authority request")
    func freshRevocationCacheAvoidsRequest() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let authority = CredentialAuthority()
        let snapshot = try authority.issueRevocationSnapshot(revocations: [], now: now)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("revocations.json")
        try CredentialFiles.saveRevocationSnapshot(snapshot, to: url)
        let requester = RecoverySnapshotRequester(snapshot: nil, offline: true)

        try await DevelopmentNodeTrustBootstrapper.recoverRevocations(
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            revocationSnapshotURL: url, requester: requester, now: { now }
        )

        #expect(await requester.generations.isEmpty)
        #expect(try CredentialFiles.loadRevocationSnapshot(from: url) == snapshot)
    }

    @Test("Stale cached revocations fetch and persist fresh signed evidence")
    func staleRevocationCacheRecovers() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let authority = CredentialAuthority()
        let old = try authority.issueRevocationSnapshot(
            revocations: [], now: now.addingTimeInterval(-90_000)
        )
        let fresh = try authority.issueRevocationSnapshot(revocations: [], now: now)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("revocations.json")
        try CredentialFiles.saveRevocationSnapshot(old, to: url)
        let requester = RecoverySnapshotRequester(snapshot: fresh)

        try await DevelopmentNodeTrustBootstrapper.recoverRevocations(
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            revocationSnapshotURL: url, requester: requester, now: { now }
        )

        #expect(await requester.generations == [old.claims.generatedAtMilliseconds])
        #expect(try CredentialFiles.loadRevocationSnapshot(from: url) == fresh)
        _ = try LANHandshakeAuthenticator.validatedRevokedCredentialIDs(
            in: CredentialFiles.loadRevocationSnapshot(from: url),
            trustedAuthorityPublicKey: authority.publicKeyRepresentation, now: now
        )
    }

    @Test("Stale trust cannot be rescued by offline, unchanged, invalid, or rollback responses",
          arguments: ["offline", "unchanged", "wrongAuthority", "rollback", "stillStale"])
    func staleRevocationRecoveryFailsClosed(response: String) async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let authority = CredentialAuthority()
        let old = try authority.issueRevocationSnapshot(
            revocations: [], now: now.addingTimeInterval(-100_000)
        )
        let candidate: CredentialRevocationSnapshot?
        switch response {
        case "wrongAuthority":
            candidate = try CredentialAuthority().issueRevocationSnapshot(revocations: [], now: now)
        case "rollback":
            candidate = try authority.issueRevocationSnapshot(
                revocations: [], now: now.addingTimeInterval(-110_000)
            )
        case "stillStale":
            candidate = try authority.issueRevocationSnapshot(
                revocations: [], now: now.addingTimeInterval(-90_000)
            )
        default:
            candidate = nil
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("revocations.json")
        try CredentialFiles.saveRevocationSnapshot(old, to: url)
        let requester = RecoverySnapshotRequester(snapshot: candidate, offline: response == "offline")

        await #expect(throws: LANHandshakeError.staleRevocationSnapshot) {
            try await DevelopmentNodeTrustBootstrapper.recoverRevocations(
                trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                revocationSnapshotURL: url, requester: requester, now: { now }
            )
        }
        #expect(await requester.generations == [old.claims.generatedAtMilliseconds])
        #expect(try CredentialFiles.loadRevocationSnapshot(from: url) ==
                (response == "stillStale" ? candidate : old))
    }

    @Test("Cold-start leave recovery removes the profile before committing unconfigured")
    func coldStartLeaveRecoveryCompletes() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let profile = try NetworkProfile(
            networkID: NetworkID(),
            localNodeID: identity.nodeID,
            displayName: "Leaving Network"
        )
        let network = NetworkBinding(
            networkID: profile.networkID,
            displayName: profile.displayName,
            environment: "development",
            authorityID: authority.authorityID,
            authorityPublicKey: authority.publicKeyRepresentation
        )
        let record = try EnrollmentLifecycleRecord(
            installationID: profile.id.rawValue,
            phase: .leaving,
            nodeID: identity.nodeID,
            network: network,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 2
        )
        let lifecycleStore = InMemoryEnrollmentLifecycleStore(record: record)
        let profileRuntimeManager = MemoryProfileRuntimeManager(initialProfile: profile)
        let runtime = try await profileRuntimeManager.start(profile: profile)
        let resumer = ApplicationEnrollmentColdStartResumer(
            lifecycleStore: lifecycleStore,
            runtime: runtime,
            namespace: ProfileKeychainNamespace(
                baseService: "net.beakr.tests.leave",
                profileID: profile.id
            ),
            profileRuntimeManager: profileRuntimeManager,
            configurationStore: MemoryAuthorityConfigurationStore()
        )

        try await resumer.finishLeaving(record: record)

        #expect(await lifecycleStore.load()?.phase == .unconfigured)
        #expect(try await profileRuntimeManager.profiles().isEmpty)
    }

    @Test("Normal leave records the durable phase before cleanup")
    func normalLeaveRecordsLifecyclePhase() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let profile = try NetworkProfile(
            networkID: NetworkID(),
            localNodeID: identity.nodeID,
            displayName: "Leaving Network"
        )
        let paths = ProfileRuntimePaths(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(profile.id.rawValue.uuidString, isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: paths.rootURL) }
        let network = NetworkBinding(
            networkID: profile.networkID,
            displayName: profile.displayName,
            environment: "development",
            authorityID: authority.authorityID,
            authorityPublicKey: authority.publicKeyRepresentation,
            activeCredentialID: UUID()
        )
        let record = try EnrollmentLifecycleRecord(
            installationID: profile.id.rawValue,
            phase: .member,
            nodeID: identity.nodeID,
            network: network,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 2
        )
        let store = try PersistentEnrollmentLifecycleStore.open(
            fileURL: paths.rootURL.appendingPathComponent("enrollment/lifecycle.json")
        )
        try await store.save(record, condition: .create)
        let router = ApplicationEnrollmentRouter(
            profileRuntimeManager: MemoryProfileRuntimeManager(initialProfile: profile),
            configurationStore: MemoryAuthorityConfigurationStore()
        )

        try await router.prepareToLeave(profile: profile)

        let reloadedStore = try PersistentEnrollmentLifecycleStore.open(
            fileURL: paths.rootURL.appendingPathComponent("enrollment/lifecycle.json")
        )
        #expect(await reloadedStore.load()?.phase == .leaving)
    }

    @Test("Normal creation records membership installation before trust startup")
    func normalCreationRecordsInstallation() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan", "admin"]
        )
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Created Network"
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager(initialProfile: profile)
        let runtime = try await profileRuntimeManager.start(profile: profile)
        defer { try? FileManager.default.removeItem(at: runtime.paths.rootURL) }
        let router = ApplicationEnrollmentRouter(
            profileRuntimeManager: profileRuntimeManager,
            configurationStore: MemoryAuthorityConfigurationStore()
        )

        try await router.prepareMembershipInstallation(
            profile: profile,
            configuration: configuration,
            runtime: runtime,
            kind: .createNetwork,
            pendingEnrollment: nil
        )

        let store = try PersistentEnrollmentLifecycleStore.open(
            fileURL: runtime.paths.rootURL.appendingPathComponent("enrollment/lifecycle.json")
        )
        let record = await store.load()
        #expect(record?.phase == .installingMembership)
        #expect(record?.transaction?.kind == .createNetwork)
        #expect(record?.network?.activeCredentialID == credential.claims.credentialID)
    }

    @Test("Normal join records an approved durable installation transaction")
    func normalJoinRecordsInstallation() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Joined Network"
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let manager = MemoryProfileRuntimeManager(initialProfile: profile)
        let runtime = try await manager.start(profile: profile)
        defer { try? FileManager.default.removeItem(at: runtime.paths.rootURL) }
        let router = ApplicationEnrollmentRouter(
            profileRuntimeManager: manager,
            configurationStore: MemoryAuthorityConfigurationStore()
        )
        let pending = PendingEnrollment(
            invitationID: UUID(),
            requestID: UUID(),
            networkID: networkID,
            expectedAuthorityID: authority.authorityID,
            localNodeID: identity.nodeID,
            createdAtMilliseconds: 1,
            expiresAtMilliseconds: Int64.max,
            status: .approved
        )

        try await router.prepareMembershipInstallation(
            profile: profile,
            configuration: configuration,
            runtime: runtime,
            kind: .joinNetwork,
            pendingEnrollment: pending
        )

        let store = try PersistentEnrollmentLifecycleStore.open(
            fileURL: runtime.paths.rootURL.appendingPathComponent("enrollment/lifecycle.json")
        )
        let record = await store.load()
        #expect(record?.phase == .installingMembership)
        #expect(record?.transaction?.kind == .joinNetwork)
        #expect(record?.pendingEnrollment?.status == .approved)
        #expect(record?.pendingEnrollment?.requestID == pending.requestID)
    }

    @Test("Disk-reopened create and join installations recover to member exactly once")
    func diskReopenedInstallationsRecoverExactlyOnce() async throws {
        for kind in [EnrollmentTransactionKind.createNetwork, .joinNetwork] {
            let authority = CredentialAuthority()
            let networkID = NetworkID()
            let profileID = NetworkProfileID()
            let namespace = ProfileKeychainNamespace(
                baseService: "net.beakr.tests.recovery.\(UUID().uuidString)",
                profileID: profileID
            )
            let identityStore = KeychainNodeIdentityStore(namespace: namespace)
            let credentialStore = KeychainNodeCredentialStore(namespace: namespace)
            let identity = try identityStore.loadOrCreate()
            let profile = try NetworkProfile(
                id: profileID,
                networkID: networkID,
                localNodeID: identity.nodeID,
                displayName: "Recovered Network"
            )
            let credential = try authority.issue(
                nodeID: identity.nodeID,
                nodePublicKey: identity.publicKeyRepresentation,
                networkID: networkID,
                environment: "test",
                validity: 3_600,
                serviceScopes: ["lan"]
            )
            try credentialStore.save(credential, for: profile)
            let manager = MemoryProfileRuntimeManager(initialProfile: profile)
            let runtime = try await manager.start(profile: profile)
            defer {
                try? identityStore.delete()
                try? credentialStore.delete()
                try? FileManager.default.removeItem(at: runtime.paths.rootURL)
            }
            let now = Date()
            let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
            let membership = try ProfileMembershipAuthority(
                privateKeyRepresentation: authority.privateKeyRepresentation
            ).sign(ProfileMembershipClaims(
                networkID: networkID,
                networkDisplayName: profile.displayName,
                generation: 1,
                generatedAtMilliseconds: nowMilliseconds,
                records: [.init(
                    credential: credential,
                    certificatePublicKey: identity.publicKeyRepresentation,
                    sessionID: SessionID()
                )]
            ))
            let revocations = try authority.issueRevocationSnapshot(revocations: [], now: now)
            try FileManager.default.createDirectory(
                at: runtime.paths.membershipSnapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try ProfileMembershipWireCodec.encode(membership).write(
                to: runtime.paths.membershipSnapshotURL,
                options: .atomic
            )
            try CredentialFiles.saveRevocationSnapshot(
                revocations,
                to: runtime.paths.revocationSnapshotURL
            )
            let pending: PendingEnrollment? = kind == .joinNetwork
                ? PendingEnrollment(
                    invitationID: UUID(),
                    requestID: UUID(),
                    networkID: networkID,
                    expectedAuthorityID: authority.authorityID,
                    localNodeID: identity.nodeID,
                    createdAtMilliseconds: nowMilliseconds,
                    expiresAtMilliseconds: nowMilliseconds + 60_000,
                    status: .approved
                )
                : nil
            let record = try EnrollmentLifecycleRecord(
                installationID: profileID.rawValue,
                phase: .installingMembership,
                nodeID: identity.nodeID,
                network: NetworkBinding(
                    networkID: networkID,
                    displayName: profile.displayName,
                    environment: "test",
                    authorityID: authority.authorityID,
                    authorityPublicKey: authority.publicKeyRepresentation,
                    activeCredentialID: credential.claims.credentialID
                ),
                pendingEnrollment: pending,
                transaction: .init(id: UUID(), kind: kind),
                createdAtMilliseconds: nowMilliseconds,
                updatedAtMilliseconds: nowMilliseconds
            )
            let lifecycleURL = runtime.paths.rootURL.appendingPathComponent(
                "enrollment/lifecycle.json"
            )
            let preCrashStore = try PersistentEnrollmentLifecycleStore.open(fileURL: lifecycleURL)
            try await preCrashStore.save(record, condition: .create)

            let reopenedStore = try PersistentEnrollmentLifecycleStore.open(fileURL: lifecycleURL)
            let resumer = ApplicationEnrollmentColdStartResumer(
                lifecycleStore: reopenedStore,
                runtime: runtime,
                namespace: namespace,
                profileRuntimeManager: manager,
                configurationStore: MemoryAuthorityConfigurationStore()
            )

            try credentialStore.delete()
            await #expect(throws: (any Error).self) {
                if kind == .createNetwork {
                    try await resumer.resumeNetworkCreation()
                } else {
                    try await resumer.resumeMembershipInstallation(identity: identity)
                }
            }
            #expect(await reopenedStore.load()?.revision == record.revision)
            try credentialStore.save(credential, for: profile)

            let validMembershipData = try ProfileMembershipWireCodec.encode(membership)
            try Data("invalid-membership".utf8).write(
                to: runtime.paths.membershipSnapshotURL,
                options: .atomic
            )
            await #expect(throws: (any Error).self) {
                if kind == .createNetwork {
                    try await resumer.resumeNetworkCreation()
                } else {
                    try await resumer.resumeMembershipInstallation(identity: identity)
                }
            }
            #expect(await reopenedStore.load()?.revision == record.revision)
            try validMembershipData.write(to: runtime.paths.membershipSnapshotURL, options: .atomic)

            let staleRevocations = try authority.issueRevocationSnapshot(
                revocations: [],
                now: now.addingTimeInterval(-48 * 60 * 60)
            )
            try CredentialFiles.saveRevocationSnapshot(
                staleRevocations,
                to: runtime.paths.revocationSnapshotURL
            )
            await #expect(throws: ApplicationEnrollmentColdStartError.self) {
                if kind == .createNetwork {
                    try await resumer.resumeNetworkCreation()
                } else {
                    try await resumer.resumeMembershipInstallation(identity: identity)
                }
            }
            #expect(await reopenedStore.load()?.revision == record.revision)
            try CredentialFiles.saveRevocationSnapshot(
                revocations,
                to: runtime.paths.revocationSnapshotURL
            )

            if kind == .createNetwork {
                try await resumer.resumeNetworkCreation()
            } else {
                try await resumer.resumeMembershipInstallation(identity: identity)
            }
            let completed = try #require(await reopenedStore.load())
            #expect(completed.phase == .member)
            #expect(completed.revision == record.revision + 1)

            if kind == .createNetwork {
                await #expect(throws: ApplicationEnrollmentColdStartError.self) {
                    try await resumer.resumeNetworkCreation()
                }
            } else {
                await #expect(throws: ApplicationEnrollmentColdStartError.self) {
                    try await resumer.resumeMembershipInstallation(identity: identity)
                }
            }
            #expect(await reopenedStore.load()?.revision == completed.revision)
        }
    }

    @Test("Joining membership installation is idempotent across secure storage and trust files")
    func joiningMembershipInstallationIsIdempotent() async throws {
        let now = Date()
        let authority = CredentialAuthority()
        let identity = NodeIdentity()
        let profile = try NetworkProfile(
            networkID: NetworkID(),
            localNodeID: identity.nodeID,
            displayName: "Joining Network"
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakr-joining-installer-\(UUID())", isDirectory: true)
        let paths = ProfileRuntimePaths(rootURL: root)
        let configurationStore = DevelopmentAuthorityConfigurationStore()
        defer {
            try? configurationStore.delete(profile: profile)
            try? FileManager.default.removeItem(at: root)
        }
        let invitation = try EnrollmentWireSigner.invitation(
            authority: authority,
            networkID: profile.networkID,
            networkDisplayName: profile.displayName,
            environment: "test",
            controlPlaneURL: URL(string: "https://authority.example")!,
            authorityCertificateDER: Data([1, 2, 3]),
            serviceScopes: ["lan"],
            invitationSecret: Data(repeating: 7, count: 32),
            issuedAt: now,
            validity: 600
        )
        let request = try EnrollmentWireSigner.request(
            invitation: invitation,
            identity: identity,
            requestNonce: Data(repeating: 8, count: 32)
        )
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: profile.networkID,
            environment: "test",
            validity: 3_600,
            serviceScopes: ["lan"],
            now: now
        )
        let membership = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        ).sign(.init(
            networkID: profile.networkID,
            networkDisplayName: profile.displayName,
            generation: 1,
            generatedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            records: [.init(
                credential: credential,
                certificatePublicKey: identity.publicKeyRepresentation,
                sessionID: SessionID()
            )]
        ))
        let approval = try EnrollmentWireSigner.approval(
            request: request,
            credential: credential,
            membership: membership,
            revocations: try authority.issueRevocationSnapshot(revocations: [], now: now),
            authority: authority,
            issuedAt: now
        )
        let installer = ApplicationJoiningMembershipInstaller(
            profile: profile,
            paths: paths,
            controlPlaneURL: try #require(invitation.controlPlaneURL),
            authorityPublicKey: invitation.authorityPublicKey,
            authorityCertificateDER: invitation.authorityCertificateDER,
            configurationStore: configurationStore
        )

        try await installer.installMembership(from: approval, identity: identity)
        try await installer.installMembership(from: approval, identity: identity)

        #expect(try configurationStore.load(profile: profile)?.credential == credential)
        #expect(try ProfileMembershipWireCodec.decode(
            Data(contentsOf: paths.membershipSnapshotURL)
        ) == membership)
        #expect(try CredentialFiles.loadRevocationSnapshot(
            from: paths.revocationSnapshotURL
        ) == approval.revocations)
        #expect(try FileRevocationSnapshotStore(
            fileURL: paths.revocationSnapshotURL
        ).loadSnapshot() == approval.revocations)
    }

    @Test("Cold start replays a staged Release 1 approval before configuration exists",
          arguments: [false, true])
    func coldStartReplaysStagedReleaseApproval(throughApplicationStartup: Bool) async throws {
        let now = Date()
        let authority = CredentialAuthority()
        let profileID = NetworkProfileID()
        let namespace = ProfileKeychainNamespace(
            baseService: throughApplicationStartup ? "net.beakr.app" : "net.beakr.tests.release-recovery.\(UUID())",
            profileID: profileID
        )
        let identityStore = KeychainNodeIdentityStore(namespace: namespace)
        let identity = try identityStore.loadOrCreate()
        defer { try? identityStore.delete() }
        let profile = try NetworkProfile(
            id: profileID,
            networkID: NetworkID(),
            localNodeID: identity.nodeID,
            displayName: "Recovered Release Network"
        )
        let manager = MemoryProfileRuntimeManager(initialProfile: profile)
        let runtime = try await manager.start(profile: profile)
        let configurationStore = DevelopmentAuthorityConfigurationStore()
        defer {
            try? configurationStore.delete(profile: profile)
            try? FileManager.default.removeItem(at: runtime.paths.rootURL)
        }
        let lifecycleURL = runtime.paths.rootURL.appendingPathComponent("enrollment/lifecycle.json")
        let lifecycleStore = try PersistentEnrollmentLifecycleStore.open(fileURL: lifecycleURL)
        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        try await lifecycleStore.save(
            EnrollmentLifecycleRecord(
                installationID: profileID.rawValue,
                phase: .identityReady,
                nodeID: identity.nodeID,
                createdAtMilliseconds: nowMilliseconds,
                updatedAtMilliseconds: nowMilliseconds
            ),
            condition: .create
        )
        let joiningStore = try PersistentJoiningEnrollmentStore.open(
            fileURL: runtime.paths.rootURL.appendingPathComponent("enrollment/joining.json")
        )
        let invitation = try EnrollmentWireSigner.invitation(
            authority: authority,
            networkID: profile.networkID,
            networkDisplayName: profile.displayName,
            environment: "test",
            controlPlaneURL: URL(string: "https://authority.example")!,
            authorityCertificateDER: Data([1, 2, 3]),
            serviceScopes: ["lan"],
            invitationSecret: Data(repeating: 3, count: 32),
            issuedAt: now,
            validity: 600
        )
        let coordinator = JoiningEnrollmentCoordinator(
            lifecycleStore: lifecycleStore,
            enrollmentStore: joiningStore,
            membershipInstaller: FailingJoiningMembershipInstaller(),
            allowedClockSkew: 60,
            now: { now },
            makeNonce: { Data(repeating: 4, count: 32) }
        )
        let request = try await coordinator.beginJoining(invitation: invitation, identity: identity)
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: profile.networkID,
            environment: "test",
            validity: 3_600,
            serviceScopes: ["lan"],
            now: now
        )
        let membership = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        ).sign(.init(
            networkID: profile.networkID,
            networkDisplayName: profile.displayName,
            generation: 1,
            generatedAtMilliseconds: nowMilliseconds,
            records: [.init(
                credential: credential,
                certificatePublicKey: identity.publicKeyRepresentation,
                sessionID: SessionID()
            )]
        ))
        let approval = try EnrollmentWireSigner.approval(
            request: request,
            credential: credential,
            membership: membership,
            revocations: try authority.issueRevocationSnapshot(revocations: [], now: now),
            authority: authority,
            issuedAt: now
        )
        await #expect(throws: TestJoiningInstallationError.self) {
            try await coordinator.receiveApproval(approval, identity: identity)
        }

        let reopened = try PersistentEnrollmentLifecycleStore.open(fileURL: lifecycleURL)
        let resumer = ApplicationEnrollmentColdStartResumer(
            lifecycleStore: reopened,
            runtime: runtime,
            namespace: namespace,
            profileRuntimeManager: manager,
            configurationStore: configurationStore
        )
        #expect(try configurationStore.load(profile: profile) == nil)
        if throughApplicationStartup {
            let model = NodeBootstrapModel(
                identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
                configurationStore: configurationStore,
                trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
                profileRuntimeManager: manager,
                lanRuntimeManager: TestLANRuntimeManager(),
                networkStartTimeout: .milliseconds(50)
            )
            await model.start()
            #expect(model.state == .ready)
            #expect(model.profileID == profileID.rawValue)
            #expect(model.nodeID == identity.nodeID.rawValue)
        } else {
            try await resumer.resumeMembershipInstallation(identity: identity)
        }

        let recovered = try PersistentEnrollmentLifecycleStore.open(fileURL: lifecycleURL)
        #expect(await recovered.load()?.phase == .member)
        #expect(try configurationStore.load(profile: profile)?.credential == credential)
        let restoredMembership = try ProfileMembershipWireCodec.decode(
            Data(contentsOf: runtime.paths.membershipSnapshotURL)
        )
        #expect(restoredMembership.claims.networkID == membership.claims.networkID)
        #expect(restoredMembership.claims.records.map(\.credential) == [credential])
        if !throughApplicationStartup {
            #expect(restoredMembership == membership)
        }
    }

    @Test("A shared network rename preserves profile identity and online peers")
    func sharedNetworkRenamePreservesIdentityAndConnectivity() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Green"
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager(initialProfile: profile)
        let peerID = UUID()
        let lanRuntimeManager = TestLANRuntimeManager(authenticatedPeerIDs: [peerID])
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: lanRuntimeManager,
            networkStartTimeout: .milliseconds(50)
        )
        await model.start()
        await lanRuntimeManager.setSharedNetworkName("Home")

        await model.refreshNetworkMembers()

        let renamed = try #require(await profileRuntimeManager.profiles().first)
        #expect(renamed.id == profile.id)
        #expect(renamed.networkID == profile.networkID)
        #expect(renamed.localNodeID == profile.localNodeID)
        #expect(renamed.displayName == "Home")
        #expect(model.onlineMemberIDs == [peerID])
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
    }

    @Test("Confirmed Local Network denial survives reconciliation and clears on permission recovery", arguments: [false, true])
    func localNetworkPermissionRecovery(deniedAtStartup: Bool) async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID, nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID, environment: "development", validity: 3_600, serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID, authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profile = try NetworkProfile(
            networkID: networkID, localNodeID: identity.nodeID, displayName: "Permission Test"
        )
        let peerID = UUID()
        let runtime = TestLANRuntimeManager(authenticatedPeerIDs: [peerID])
        if deniedAtStartup {
            await runtime.reportPermissionDiagnostic(.permissionDenied(component: "browser"))
        }
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: MemoryProfileRuntimeManager(initialProfile: profile),
            lanRuntimeManager: runtime
        )
        await model.start()
        if !deniedAtStartup {
            #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
            await runtime.reportPermissionDiagnostic(.permissionDenied(component: "browser"))
        }
        for _ in 0..<1000 where !model.isLocalNetworkPermissionDenied {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.state == .ready)
        #expect(model.activeNetworkConnectivity == .localNetworkDenied)
        #expect(model.activeNetworkStatusTitle == "Local Network Permission Required")
        #expect(model.onlineMemberIDs.isEmpty)
        #expect(model.profileID == profile.id.rawValue)
        // Wi-Fi availability and stale peer snapshots are not permission grants.
        await model.reconcileLocalNetworkMembers()
        await runtime.reportPermissionDiagnostic(.listenerState(.ready(port: 1234)))
        #expect(model.activeNetworkConnectivity == .localNetworkDenied)
        await runtime.reportPermissionDiagnostic(.browserState(.ready))
        for _ in 0..<1000 where model.activeNetworkConnectivity != .connected(peerCount: 1) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!model.isLocalNetworkPermissionDenied)
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.onlineMemberIDs == [peerID])
        #expect(model.profileID == profile.id.rawValue)
        #expect(await runtime.startCount == 1)
        await model.applicationDidEnterBackground()
        await runtime.reportPermissionDiagnostic(.permissionDenied(component: "browser"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.activeNetworkConnectivity == .inactive)
        #expect(!model.isLocalNetworkPermissionDenied)
    }

    @Test("Permission reporting distinguishes denial from ordinary network failure")
    func localNetworkPermissionEvidence() async {
        let monitor = LocalNetworkPermissionMonitor()
        monitor.observe(.browserState(.waiting(reason: "network unavailable")))
        #expect(!monitor.isDenied)
        monitor.observe(.permissionDenied(component: "browser"))
        monitor.observe(.permissionDenied(component: "listener"))
        var iterator = monitor.updates().makeAsyncIterator()
        #expect(await iterator.next() == true)
        monitor.observe(.browserState(.ready))
        #expect(monitor.isDenied)
        monitor.observe(.listenerState(.ready(port: 1234)))
        #expect(await iterator.next() == false)
        #expect(!monitor.isDenied)
    }

    @Test("Foregrounding retries a failed LAN startup instead of remaining inactive")
    func foregroundRetriesFailedLANStartup() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Home"
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager(initialProfile: profile)
        let peerID = UUID()
        let lanRuntimeManager = TestLANRuntimeManager(authenticatedPeerIDs: [peerID])
        await lanRuntimeManager.failNextStarts(1)
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: lanRuntimeManager,
            networkStartTimeout: .milliseconds(50)
        )

        await model.start()
        #expect(model.state == .identityReady)
        #expect(model.activeNetworkConnectivity == .failed)

        await model.applicationDidEnterBackground()
        #expect(model.activeNetworkConnectivity == .inactive)

        await model.applicationBecameActive()

        #expect(model.state == .ready)
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.onlineMemberIDs == [peerID])
        #expect(await lanRuntimeManager.startCount == 2)
        let events = BeakrDiagnosticLog.lifecycleJournal.snapshot().events.filter {
            $0.context.profileID == profile.id.rawValue && $0.stage == .startup
        }
        #expect(events.map(\.outcome) == [.began, .failed, .began, .completed])
        #expect(events[1].reason == .startupError)
        #expect(Set(events.map { $0.context.operationID }).count == 2)
        #expect(await lanRuntimeManager.diagnosticContexts.compactMap { $0 }.count == 2)
    }

    @Test("Peer address events refresh members without waiting for periodic UI reconciliation")
    func peerAddressEventsRefreshMembers() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Home"
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager(initialProfile: profile)
        let peerID = UUID()
        let lanRuntimeManager = ReportingLANRuntimeManager(peerID: peerID)
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: lanRuntimeManager,
            networkStartTimeout: .milliseconds(50)
        )

        await model.start()
        await lanRuntimeManager.report("192.0.2.10")
        for _ in 0..<1000 where model.networkMembers.first?.deviceIPAddress != "192.0.2.10" {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.onlineMemberIDs == [peerID])
        #expect(model.networkMembers.first?.deviceIPAddress == "192.0.2.10")
        await lanRuntimeManager.report("192.0.2.11")
        for _ in 0..<1000 where model.networkMembers.first?.deviceIPAddress != "192.0.2.11" {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.networkMembers.first?.deviceIPAddress == "192.0.2.11")
        await lanRuntimeManager.report(nil)
        for _ in 0..<1000 where model.networkMembers.first?.deviceIPAddress != nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.networkMembers.first?.deviceIPAddress == nil)
        await lanRuntimeManager.stop()
    }

    @Test("Losing the last peer keeps discovery running and accepts its return")
    func peerLossKeepsRuntimeRunning() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Home"
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager(initialProfile: profile)
        let peerID = UUID()
        let lanRuntimeManager = TestLANRuntimeManager(authenticatedPeerIDs: [peerID])
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: lanRuntimeManager,
            networkStartTimeout: .milliseconds(50)
        )

        await model.start()
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        let stopsBeforeLoss = await lanRuntimeManager.stopCount
        await lanRuntimeManager.setPeerIDs([])
        // A restart would now fail, modelling an unavailable authority.
        await lanRuntimeManager.failNextStarts(1)
        await model.reconcileLocalNetworkMembers()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.activeNetworkConnectivity == .readyNoPeers)
        #expect(model.onlineMemberIDs.isEmpty)
        #expect(await lanRuntimeManager.startCount == 1)
        #expect(await lanRuntimeManager.stopCount == stopsBeforeLoss)

        await lanRuntimeManager.setPeerIDs([peerID])
        await model.reconcileLocalNetworkMembers()
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.onlineMemberIDs == [peerID])
        #expect(await lanRuntimeManager.startCount == 1)
    }

    @Test("Backgrounding cancels a pending foreground restart", arguments: [false, true])
    func backgroundInterruptsForegroundRestart(duringStart: Bool) async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Home"
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager(initialProfile: profile)
        let peerID = UUID()
        let lanRuntimeManager = TestLANRuntimeManager(authenticatedPeerIDs: [peerID])
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: lanRuntimeManager,
            networkStartTimeout: .seconds(5)
        )


        await model.start()
        await model.applicationDidEnterBackground()
        await lanRuntimeManager.setStartDelay(.seconds(3))
        let foreground = Task { await model.applicationBecameActive() }
        if duringStart {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await lanRuntimeManager.startCount < 2, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await lanRuntimeManager.startCount == 2)
        } else {
            // Interrupt the foreground debounce before any runtime work starts.
            try await Task.sleep(for: .milliseconds(30))
        }
        await model.applicationDidEnterBackground()
        await foreground.value
        #expect(model.activeNetworkConnectivity == .inactive)
        #expect(model.onlineMemberIDs.isEmpty)
        #expect(await lanRuntimeManager.startCount == (duringStart ? 2 : 1))

        await lanRuntimeManager.setStartDelay(nil)
        await model.applicationBecameActive()
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.onlineMemberIDs == [peerID])
        #expect(await lanRuntimeManager.startCount == (duringStart ? 3 : 2))
        await model.applicationDidEnterBackground()
        let cancelled = BeakrDiagnosticLog.lifecycleJournal.snapshot().events.filter {
            $0.context.profileID == profile.id.rawValue && $0.stage == .startup && $0.outcome == .cancelled
        }
        #expect(cancelled.count == (duringStart ? 1 : 0))
        #expect(cancelled.allSatisfy { $0.reason == .cancellation })
    }

    @Test("Peer reconciliation preserves a restart timeout until explicit recovery")
    func peerReconciliationPreservesRestartFailure() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Home"
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager(initialProfile: profile)
        let peerID = UUID()
        let lanRuntimeManager = TestLANRuntimeManager(authenticatedPeerIDs: [peerID])
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: lanRuntimeManager,
            networkStartTimeout: .milliseconds(50)
        )

        await model.start()
        await lanRuntimeManager.setPeerIDs([])
        await lanRuntimeManager.setStartDelay(.seconds(5))
        await model.reconnectActiveNetwork()
        #expect(model.activeNetworkConnectivity == .failed)
        let failureMessage = model.statusMessage
        #expect(model.networkSessions.first(where: { $0.isSelected })?.lastError == failureMessage)

        await model.reconcileLocalNetworkMembers()
        await model.refreshNetworkMembers()
        #expect(model.activeNetworkConnectivity == .failed)
        #expect(model.statusMessage == failureMessage)
        #expect(model.networkSessions.first(where: { $0.isSelected })?.lastError == failureMessage)

        await lanRuntimeManager.setStartDelay(nil)
        await lanRuntimeManager.setPeerIDs([peerID])
        await model.reconnectActiveNetwork()
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.networkSessions.first(where: { $0.isSelected })?.lastError == nil)
        let events = BeakrDiagnosticLog.lifecycleJournal.snapshot().events.filter {
            $0.context.profileID == profile.id.rawValue
        }
        let timeout = try #require(events.first { $0.stage == .startup && $0.outcome == .timedOut })
        #expect(timeout.reason == .deadline)
        #expect(timeout.durationMilliseconds != nil)
        let parentID = try #require(timeout.context.parentOperationID)
        #expect(events.contains { $0.context.operationID == parentID && $0.stage == .transitionWait })
        let contexts = await lanRuntimeManager.diagnosticContexts.compactMap { $0 }
        #expect(contexts.count == 3)
        #expect(contexts[1].operationID == timeout.context.operationID)
        #expect(contexts[2].operationID != timeout.context.operationID)
    }

    @Test("Member details require verified, profile-scoped revocation evidence")
    func memberRevocationPresentation() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let profile = try NetworkProfile(
            networkID: NetworkID(), localNodeID: identity.nodeID, displayName: "Revocation UI"
        )
        let credential = try authority.issue(
            nodeID: identity.nodeID, nodePublicKey: identity.publicKeyRepresentation,
            networkID: profile.networkID, environment: "development", validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: try #require(URL(string: "https://authority.example")),
            networkID: profile.networkID, authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let manager = MemoryProfileRuntimeManager(initialProfile: profile)
        let paths = try await manager.runtimePaths(for: profile)
        defer { try? FileManager.default.removeItem(at: paths.rootURL) }
        let peerID = UUID()
        let peerCredentialID = UUID()
        let lan = TestLANRuntimeManager(authenticatedPeerIDs: [peerID])
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: manager, lanRuntimeManager: lan
        )
        await model.start()
        #expect(model.memberStatus(profileID: profile.id, nodeID: peerID,
            credentialID: peerCredentialID, isLocalDevice: false) == .online)
        await lan.setPeerIDs([])
        await model.reconcileLocalNetworkMembers()
        // A missing member or transport loss alone is not revocation evidence.
        #expect(model.memberStatus(profileID: profile.id, nodeID: peerID,
            credentialID: peerCredentialID, isLocalDevice: false) == .offline)
        let revocation = CredentialRevocation(
            credentialID: peerCredentialID,
            revokedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            reason: "Disposable test"
        )
        try CredentialFiles.saveRevocationSnapshot(
            CredentialAuthority().issueRevocationSnapshot(revocations: [revocation]),
            to: paths.revocationSnapshotURL
        )
        await model.reconcileLocalNetworkMembers()
        #expect(model.memberStatus(profileID: profile.id, nodeID: peerID,
            credentialID: peerCredentialID, isLocalDevice: false) == .offline)
        try CredentialFiles.saveRevocationSnapshot(
            authority.issueRevocationSnapshot(revocations: [revocation]),
            to: paths.revocationSnapshotURL
        )
        await model.reconcileLocalNetworkMembers()
        #expect(model.memberStatus(profileID: profile.id, nodeID: peerID,
            credentialID: peerCredentialID, isLocalDevice: false) == .revoked)
        #expect(model.memberStatus(profileID: NetworkProfileID(), nodeID: peerID,
            credentialID: peerCredentialID, isLocalDevice: false) == .unknown)
        #expect(model.memberStatus(profileID: profile.id, nodeID: peerID,
            credentialID: UUID(), isLocalDevice: false) == .offline)
        try Data("invalid".utf8).write(to: paths.revocationSnapshotURL, options: .atomic)
        await model.reconcileLocalNetworkMembers()
        #expect(model.memberStatus(profileID: profile.id, nodeID: peerID,
            credentialID: peerCredentialID, isLocalDevice: false) == .revoked)
        await lan.stop()
    }

    @Test("Forgetting a joined network removes only the local profile")
    func forgetJoinedNetwork() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Joined Network"
        )
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://joined.local:8443")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager(initialProfile: profile)
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: TestLANRuntimeManager(),
            networkCreator: NonOwningNetworkCreator()
        )
        await model.start()

        await model.forgetJoinedNetwork(profile.id)

        #expect(await profileRuntimeManager.profiles().isEmpty)
        #expect(model.networks.isEmpty)
        #expect(model.state == .needsConfiguration)
    }

    @Test("Archiving preserves messages and the reason across reopening", arguments: [false, true])
    func forgettingPreservesContextMessageStore(revoked: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeakrContextForget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = try NetworkProfile(
            networkID: NetworkID(),
            localNodeID: NodeID(),
            displayName: "Preserved Network"
        )
        let manager = ApplicationProfileRuntimeManager(applicationRoot: directory)
        try await manager.addAndActivate(profile)
        let runtime = try await manager.start(profile: profile)
        try await runtime.dataState.clearRecordedResults()
        let correlationID = DataCorrelationID()
        let receivedAt = Date(timeIntervalSince1970: 1_760_000_000)
        try await runtime.dataState.record(StoredDataResult(
            messageID: MessageID(),
            idempotencyKey: DataIdempotencyKey(),
            response: DataMessage(
                kind: .message,
                operation: DataOperation(namespace: "beakr", name: "text-message", version: 1),
                correlationID: correlationID,
                idempotencyKey: DataIdempotencyKey(),
                body: Data("Preserved message".utf8)
            ),
            completedAt: receivedAt
        ))
        let messageStoreURL = runtime.paths.dataStateURL
        let contextID = try #require(runtime.contextID)

        let reason: ContextArchiveReason? = revoked ? .membershipRevoked : nil
        try await manager.forget(profile: profile, reason: reason)

        #expect(try await manager.profiles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: messageStoreURL.path))
        let exposedContext = try #require(try await manager.context(networkID: profile.networkID))
        #expect(exposedContext.id == contextID)
        #expect(exposedContext.attachedProfileIDs.isEmpty)
        #expect(try await manager.contexts().map(\.id) == [contextID])
        let archivedMessages = try await manager.incomingMessages(contextID: contextID)
        #expect(archivedMessages.map(\.id) == [correlationID.rawValue])
        #expect(archivedMessages.map(\.body) == ["Preserved message"])
        #expect(archivedMessages.map(\.receivedAt) == [receivedAt])
        let contexts = try PersistentContextRegistry.open(
            fileURL: directory.appendingPathComponent("contexts.json"),
            contextsRootURL: directory.appendingPathComponent("Contexts", isDirectory: true)
        )
        let archived = try #require(await contexts.context(networkID: profile.networkID))
        #expect(archived.id == contextID)
        #expect(archived.attachedProfileIDs.isEmpty)
        #expect(archived.archiveReason == reason)
        #expect(exposedContext.archiveReason == reason)

        let replacement = try NetworkProfile(
            networkID: profile.networkID,
            localNodeID: NodeID(),
            displayName: "Preserved Network"
        )
        try await manager.addAndActivate(replacement)
        let reattached = try await manager.start(profile: replacement)
        #expect(try await manager.context(networkID: profile.networkID)?.archiveReason == nil)
        #expect(reattached.contextID == contextID)
        #expect(reattached.messageStoreID == runtime.messageStoreID)
        #expect(
            reattached.paths.dataStateURL.resolvingSymlinksInPath()
                == messageStoreURL.resolvingSymlinksInPath()
        )
        #expect(FileManager.default.fileExists(atPath: reattached.paths.dataStateURL.path))
    }

    @Test("Deleting an archived Context permanently removes its registry entry and stored data")
    func deletingArchivedContextRemovesStoredData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeakrContextDelete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = try NetworkProfile(
            networkID: NetworkID(),
            localNodeID: NodeID(),
            displayName: "Disposable Network"
        )
        let manager = ApplicationProfileRuntimeManager(applicationRoot: directory)
        try await manager.addAndActivate(profile)
        let runtime = try await manager.start(profile: profile)
        let contextID = try #require(runtime.contextID)
        let metadataURL = try #require(runtime.mailboxMetadataURL)
        try ContextMailboxMetadataStore.save(.empty, to: metadataURL)
        let contextRoot = metadataURL.deletingLastPathComponent().deletingLastPathComponent()

        await #expect(throws: ApplicationContextDeletionError.contextStillAttached(contextID)) {
            try await manager.deleteContext(contextID)
        }

        try await manager.forget(profile: profile)
        #expect(FileManager.default.fileExists(atPath: contextRoot.path))

        try await manager.deleteContext(contextID)

        #expect(try await manager.contexts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: contextRoot.path))
        await #expect(throws: ContextRegistryError.unknownContext(contextID)) {
            _ = try await manager.mailboxMetadata(contextID: contextID)
        }
    }

    @Test("Create Network starts authority but requires explicit messaging selection")
    func createNetwork() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Red Network"
        )
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan", "admin"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://red-mac.local:8443")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let runner = TestAuthorityRunner()
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: CreationConfigurationStore(),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: MemoryProfileRuntimeManager(),
            lanRuntimeManager: TestLANRuntimeManager(),
            networkCreator: FixedAuthoritativeNetworkCreator(
                created: .init(
                    profile: profile,
                    configuration: configuration,
                    authority: runner
                )
            )
        )
        model.networkDisplayName = "Red Network"
        model.authorityHostname = "red-mac.local"
        model.authorityPort = "8443"

        await model.createNetwork()

        #expect(model.state == .needsConfiguration)
        #expect(model.profileID == nil)
        #expect(model.networks.allSatisfy { !$0.isActive })
        #expect(model.authorityHostingStates[profile.id] == .running)
        #expect(model.lastCreatedNetworkID == profile.id)
        let savedCredentials = try #require(await model.savedCredentialDetails(for: profile.id))
        #expect(savedCredentials.details.accessExpiresAt == Date(timeIntervalSince1970: Double(credential.claims.expiresAtMilliseconds) / 1_000))
        #expect(model.profileID == nil)
        await model.switchNetwork(to: profile.id)

        #expect(model.state == .ready)
        #expect(model.nodeID == identity.nodeID.rawValue)
        #expect(model.profileID == profile.id.rawValue)
        #expect(model.networkIDText == networkID.rawValue.uuidString)
        #expect(model.networkDisplayName == "Local Network")
        let createdNetwork = try #require(model.networks.first { $0.id == profile.id })
        #expect(createdNetwork.canManageNetwork)
        #expect(createdNetwork.isHostingAuthority)
        #expect(createdNetwork.canExchangeMessages)
        #expect(model.activeNetworkRole == "Authority Host and Manager")

        let invitation = try EnrollmentWireSigner.invitation(
            authority: authority, networkID: networkID, networkDisplayName: "Red Network",
            environment: "production", controlPlaneURL: nil,
            invitationSecret: Data(repeating: 7, count: 32), issuedAt: Date(), validity: 600
        )
        let request = try EnrollmentWireSigner.request(
            invitation: invitation, identity: NodeIdentity(), requestNonce: Data(repeating: 8, count: 32)
        )
        let invitationJSON = String(decoding: try EnrollmentWireCodec.encode(invitation), as: UTF8.self)
        await runner.setAuditRecords([EnrollmentAuditRecord(
            request: request, status: .pending, updatedAtMilliseconds: 500
        )])
        await model.reconcileLocalNetworkMembers()
        #expect(!model.invitationIsConsumed(invitationJSON))
        await runner.setAuditRecords([EnrollmentAuditRecord(
            request: request, status: .approved, updatedAtMilliseconds: 1_000
        )])
        await model.reconcileLocalNetworkMembers()
        #expect(model.enrollmentAuditRecords.first?.status == .approved)
        #expect(model.invitationIsConsumed(invitationJSON))
        await runner.setAuditRecords([EnrollmentAuditRecord(
            request: request, status: .confirmed, updatedAtMilliseconds: 2_000
        )])
        // No new peer event or manual Refresh is needed to observe confirmation.
        await model.reconcileLocalNetworkMembers()
        #expect(model.enrollmentAuditRecords.first?.status == .confirmed)
        #expect(model.invitationIsConsumed(invitationJSON))
        let freshInvitation = try EnrollmentWireSigner.invitation(
            authority: authority, networkID: networkID, networkDisplayName: "Red Network",
            environment: "production", controlPlaneURL: nil,
            invitationSecret: Data(repeating: 9, count: 32), issuedAt: Date(), validity: 600
        )
        #expect(!model.invitationIsConsumed(String(
            decoding: try EnrollmentWireCodec.encode(freshInvitation), as: UTF8.self
        )))

        await model.renameOwnedNetwork(profile.id, to: "Blue")

        #expect(model.activeNetworkName == "Blue")
        #expect(model.profileID == profile.id.rawValue)
        #expect(model.networkIDText == networkID.rawValue.uuidString)
    }

    @Test("Renaming an inactive owned network does not rename the active authority")
    func renameInactiveOwnedNetwork() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let activeNetworkID = NetworkID()
        let inactiveNetworkID = NetworkID()
        let activeProfile = try NetworkProfile(
            networkID: activeNetworkID,
            localNodeID: identity.nodeID,
            displayName: "Goose Bay"
        )
        let inactiveProfile = try NetworkProfile(
            networkID: inactiveNetworkID,
            localNodeID: identity.nodeID,
            displayName: "Red Deer"
        )
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: activeNetworkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan", "admin"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://goose-bay.local:8443")!,
            networkID: activeNetworkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let authorityRunner = TestAuthorityRunner()
        let profileRuntimeManager = MultipleProfileRuntimeManager(initialProfile: activeProfile)
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: TestLANRuntimeManager(),
            networkCreator: FixedAuthoritativeNetworkCreator(
                created: .init(
                    profile: activeProfile,
                    configuration: configuration,
                    authority: authorityRunner
                ),
                additionalOwnedProfileIDs: [inactiveProfile.id]
            )
        )

        await model.start()
        await profileRuntimeManager.add(inactiveProfile)
        await model.renameOwnedNetwork(inactiveProfile.id, to: "Red Deer-1")

        #expect(model.activeNetworkName == "Goose Bay")
        #expect(await profileRuntimeManager.activeProfile()?.id == activeProfile.id)
        #expect(await profileRuntimeManager.profiles().first { $0.id == activeProfile.id }?.displayName == "Goose Bay")
        #expect(await profileRuntimeManager.profiles().first { $0.id == inactiveProfile.id }?.displayName == "Red Deer-1")
        #expect(await authorityRunner.renamedNames.isEmpty)
    }

    @Test("Authority ownership ignores a mutable display-name mismatch")
    func authorityOwnershipUsesStableProfileIdentity() throws {
        let profileID = NetworkProfileID()
        let networkID = NetworkID()
        let nodeID = NodeID()
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let manifestProfile = try NetworkProfile(
            id: profileID,
            networkID: networkID,
            localNodeID: nodeID,
            displayName: "Goose Bay",
            createdAt: createdAt
        )
        let registeredProfile = try NetworkProfile(
            id: profileID,
            networkID: networkID,
            localNodeID: nodeID,
            displayName: "Red Deer-1",
            createdAt: createdAt
        )
        let wrongNetworkProfile = try NetworkProfile(
            id: profileID,
            networkID: NetworkID(),
            localNodeID: nodeID,
            displayName: "Red Deer-1",
            createdAt: createdAt
        )

        #expect(SystemAuthoritativeNetworkCreator.hasSameAuthorityIdentity(
            manifestProfile,
            registeredProfile
        ))
        #expect(!SystemAuthoritativeNetworkCreator.hasSameAuthorityIdentity(
            manifestProfile,
            wrongNetworkProfile
        ))
    }

    @Test("Authority identity survives millisecond JSON date serialization")
    func authorityIdentityDateRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        for offset in 0..<1000 {
            let original = try NetworkProfile(
                networkID: NetworkID(), localNodeID: NodeID(), displayName: "New",
                createdAt: Date(timeIntervalSince1970: 1_794_970_000 + Double(offset) / 1_000_000)
            )
            let persisted = try decoder.decode(NetworkProfile.self, from: encoder.encode(original))
            #expect(SystemAuthoritativeNetworkCreator.hasSameAuthorityIdentity(persisted, original))
        }
    }

    @Test("A signed admin credential grants management without hosting the authority")
    func portableNetworkManagementAuthorization() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Portable Authority"
        )
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan", "admin"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )

        let authorization = try #require(NodeBootstrapModel.verifiedAuthorization(
            profile: profile,
            configuration: configuration,
            isHostingAuthority: false
        ))

        #expect(authorization.networkID == networkID)
        #expect(authorization.nodeID == identity.nodeID)
        #expect(authorization.capabilities.contains(.manageNetwork))
        #expect(authorization.capabilities.contains(.exchangeMessages))
        #expect(!authorization.capabilities.contains(.hostAuthority))
    }

    @Test("An invalid admin credential cannot grant network management")
    func rejectsInvalidNetworkManagementAuthorization() throws {
        let identity = NodeIdentity()
        let signingAuthority = CredentialAuthority()
        let trustedAuthority = CredentialAuthority()
        let networkID = NetworkID()
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Untrusted Authority"
        )
        let credential = try signingAuthority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan", "admin"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: trustedAuthority.publicKeyRepresentation,
            credential: credential
        )

        #expect(NodeBootstrapModel.verifiedAuthorization(
            profile: profile,
            configuration: configuration,
            isHostingAuthority: false
        ) == nil)
    }

    @Test("Creating another network preserves the active runtime, including failures", arguments: [0, 1, 2])
    func createAdditionalNetwork(failureStage: Int) async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let originalNetworkID = NetworkID()
        let originalProfile = try NetworkProfile(
            networkID: originalNetworkID,
            localNodeID: identity.nodeID,
            displayName: "Original"
        )
        let originalCredential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: originalNetworkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let originalConfiguration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://original.local:8443")!,
            networkID: originalNetworkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: originalCredential
        )

        let newNetworkID = NetworkID()
        let newProfile = try NetworkProfile(
            networkID: newNetworkID,
            localNodeID: identity.nodeID,
            displayName: "New Network"
        )
        let newCredential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: newNetworkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan", "admin"]
        )
        let newConfiguration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://new.local:8443")!,
            networkID: newNetworkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: newCredential
        )
        let profileRuntimeManager = MultipleProfileRuntimeManager(initialProfile: originalProfile)
        let paths = try await profileRuntimeManager.runtimePaths(for: newProfile)
        let originalPaths = try await profileRuntimeManager.runtimePaths(for: originalProfile)
        defer {
            try? FileManager.default.removeItem(at: paths.rootURL)
            try? FileManager.default.removeItem(at: originalPaths.rootURL)
        }
        let configurations = CreationConfigurationStore()
        try configurations.save(originalConfiguration, profile: originalProfile)
        let originalRunner = TestAuthorityRunner()
        let newRunner = TestAuthorityRunner()
        let creator = CreationNetworkCreator(
            created: .init(profile: newProfile, configuration: newConfiguration, authority: newRunner),
            originalID: originalProfile.id, originalRunner: originalRunner,
            failCreation: failureStage == 1)
        let peerID = UUID()
        let lan = TestLANRuntimeManager(authenticatedPeerIDs: [peerID])
        let router = CreationEnrollmentRouter(manager: profileRuntimeManager, configurations: configurations,
                                               failPreparation: failureStage == 2)
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: configurations,
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: lan,
            networkCreator: creator,
            enrollmentRouter: router
        )

        await model.start()
        model.networkDisplayName = "New Network"
        let starts = await lan.startCount
        let stops = await lan.stopCount
        await model.createNetwork()

        #expect(await lan.startCount == starts)
        #expect(await lan.stopCount == stops)
        #expect(await originalRunner.stopCount == 0)
        #expect(await creator.restoredIDs == (failureStage == 0 ? [originalProfile.id, newProfile.id] : [originalProfile.id]))
        #expect(model.onlineMemberIDs == [peerID])
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.state == .ready)
        #expect(model.profileID == originalProfile.id.rawValue)
        #expect(await profileRuntimeManager.activeProfile()?.id == originalProfile.id)
        try await profileRuntimeManager.checkpoint(lifecycle: .foreground)
        if failureStage != 0 {
            #expect(await profileRuntimeManager.profiles().count == 1)
            #expect(try configurations.load(profile: newProfile) == nil)
            #expect(model.lastCreatedNetworkID == nil)
            await model.applicationWillTerminate()
            return
        }
        #expect(await profileRuntimeManager.profiles().count == 2)
        #expect(model.networkDisplayName == "Local Network")
        #expect(model.lastCreatedNetworkID == newProfile.id)
        #expect(model.authorityHostingStates[newProfile.id] == .running)
        #expect(model.authorityHostingEnabled.contains(newProfile.id))
        let store = try PersistentEnrollmentLifecycleStore.open(
            fileURL: paths.rootURL.appendingPathComponent("enrollment/lifecycle.json"))
        let record = await store.load()
        #expect(record?.phase == .installingMembership)
        #expect(record?.transaction?.kind == .createNetwork)
        let originalNetwork = try #require(model.networks.first { $0.id == originalProfile.id })
        let createdNetwork = try #require(model.networks.first { $0.id == newProfile.id })
        #expect(originalNetwork.canManageNetwork)
        #expect(originalNetwork.isHostingAuthority)
        #expect(originalNetwork.canExchangeMessages)
        #expect(createdNetwork.canManageNetwork)
        #expect(createdNetwork.isHostingAuthority)
        #expect(createdNetwork.canExchangeMessages)
        #expect(originalNetwork.isActive)
        #expect(!createdNetwork.isActive)

        await model.switchNetwork(to: newProfile.id)
        #expect(model.state == .ready)
        #expect(model.profileID == newProfile.id.rawValue)
        #expect(await profileRuntimeManager.activeProfile()?.id == newProfile.id)
        #expect(await originalRunner.stopCount == 0)
        #expect(await creator.restoredIDs == [originalProfile.id, newProfile.id])
        #expect(model.authorityHostingStates[newProfile.id] == .running)
        await model.setAuthorityHosting(true, for: newProfile.id)
        #expect(await creator.restoredIDs == [originalProfile.id, newProfile.id])
        #expect(model.authorityHostingStates[originalProfile.id] == .running)
        #expect(model.authorityHostingStates[newProfile.id] == .running)
        await model.createInvitation(for: originalProfile.id)
        #expect(await originalRunner.enrollmentInvitationCount == 1)
        #expect(await newRunner.enrollmentInvitationCount == 0)
        #expect(model.administration(for: originalProfile.id).message != nil)
        #expect(model.administration(for: newProfile.id).message == nil)
        await model.setAuthorityHosting(false, for: originalProfile.id)
        #expect(await originalRunner.stopCount == 1)
        #expect(await newRunner.stopCount == 0)
        #expect(model.profileID == newProfile.id.rawValue)
        #expect(await lan.startCount == starts + 1)
        #expect(await lan.stopCount == stops + 1)
        await model.applicationWillTerminate()
        #expect(await originalRunner.stopCount == 1)
        #expect(await newRunner.stopCount == 1)
    }

    @Test("Invitation metadata reports creation, expiration, and remaining time")
    func invitationMetadata() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let authority = CredentialAuthority()
        let invitation = try authority.issueNetworkInvitation(
            networkID: NetworkID(),
            environment: "production",
            controlPlaneURL: URL(string: "https://authority.local:8443")!,
            authorityCertificateDER: Data([0x01]),
            validity: 600,
            now: now
        )
        let encoded = String(
            decoding: try NetworkInvitationWireCodec.encode(invitation),
            as: UTF8.self
        )

        let metadata = try #require(InvitationMetadata(invitation: encoded))

        #expect(metadata.issuedAt == now)
        #expect(metadata.expiresAt == now.addingTimeInterval(600))
        #expect(metadata.remaining(at: now.addingTimeInterval(90)) == 510)
        #expect(!metadata.isExpired(at: now.addingTimeInterval(599)))
        #expect(metadata.isExpired(at: now.addingTimeInterval(600)))

        let releaseInvitation = try EnrollmentWireSigner.invitation(
            authority: authority,
            networkID: NetworkID(),
            networkDisplayName: "Release Network",
            environment: "production",
            controlPlaneURL: URL(string: "https://authority.local:8443")!,
            authorityCertificateDER: Data([0x01]),
            serviceScopes: ["lan"],
            invitationSecret: Data(repeating: 9, count: 32),
            issuedAt: now,
            validity: 600
        )
        let releaseEncoded = String(
            decoding: try EnrollmentWireCodec.encode(releaseInvitation),
            as: UTF8.self
        )
        let releaseMetadata = try #require(InvitationMetadata(invitation: releaseEncoded))
        #expect(releaseMetadata.issuedAt == now)
        #expect(releaseMetadata.expiresAt == now.addingTimeInterval(600))
    }

    @Test("Invitation review accepts pretty-printed enrollment JSON")
    func invitationReviewAcceptsPrettyPrintedJSON() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let authority = CredentialAuthority()
        let invitation = try EnrollmentWireSigner.invitation(
            authority: authority,
            networkID: NetworkID(),
            networkDisplayName: "Release Network",
            environment: "production",
            controlPlaneURL: URL(string: "https://authority.local:8443")!,
            authorityCertificateDER: Data([0x01]),
            serviceScopes: ["lan"],
            invitationSecret: Data(repeating: 9, count: 32),
            issuedAt: now,
            validity: 600
        )
        let canonicalData = try EnrollmentWireCodec.encode(invitation)
        let object = try JSONSerialization.jsonObject(with: canonicalData)
        let prettyData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: NodeID()),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: SignedFixtureTrustBootstrapper(authority: authority),
            profileRuntimeManager: MemoryProfileRuntimeManager()
        )

        let review = try #require(model.invitationReview(
            for: String(decoding: prettyData, as: UTF8.self),
            receivedAt: now
        ))

        #expect(review.id == invitation.invitationID)
        #expect(review.invitationJSON == String(decoding: canonicalData, as: UTF8.self))
        #expect(model.networkJoinAlert == nil)
    }

    @Test("Bootstrap errors have actionable Release 1 descriptions")
    func bootstrapErrorDescriptions() {
        #expect(NodeBootstrapModel.describe(NodeBootstrapError.noTrustedRevocationState) ==
            "The network’s current trust information could not be verified. The saved membership was not activated.")
        #expect(NodeBootstrapModel.describe(NodeBootstrapError.activeProfileMismatch) ==
            "Another network profile is still active. Close and reopen Network Settings, then try again.")
        #expect(NodeBootstrapModel.describe(NodeBootstrapError.invitationAuthorityMismatch)
            .contains("No network changes were made"))
        #expect(NodeBootstrapModel.describe(ActiveProfileRuntimeError.runtimeAlreadyActive(
            NetworkProfileID()
        )).contains("already running"))
    }

    @Test("A visible invitation review consumes delayed outcomes without a duplicate alert")
    func invitationReviewConsumesPollingResults() {
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: NodeID()),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: NoopTrustBootstrapper(),
            profileRuntimeManager: MemoryProfileRuntimeManager()
        )
        model.isInvitationReviewPresented = true
        for outcome in [
            NetworkJoinAlert(succeeded: false, title: "Awaiting Approval", message: "Pending", invitationAccepted: true),
            NetworkJoinAlert(succeeded: false, title: "Unable to Complete Join", message: "Failure", invitationAccepted: true),
            NetworkJoinAlert(succeeded: true, title: "Network Joined", message: "Ready", invitationAccepted: true)
        ] {
            model.networkJoinAlert = outcome
            #expect(model.standaloneNetworkJoinAlert == nil)
            // An underlying alert's dismissal must not erase the sheet's result.
            model.standaloneNetworkJoinAlert = nil
            #expect(model.consumeInvitationReviewResult() == outcome)
            #expect(model.networkJoinAlert == nil)
        }
        model.isInvitationReviewPresented = false
        let later = NetworkJoinAlert(succeeded: true, title: "Network Joined", message: "Ready")
        model.networkJoinAlert = later
        #expect(model.consumeInvitationReviewResult() == nil)
        #expect(model.standaloneNetworkJoinAlert == later)
    }

    @Test("Beginning a new invitation review clears an earlier join result")
    func preparingForNetworkJoinClearsStaleAlert() {
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: NodeID()),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: NoopTrustBootstrapper(),
            profileRuntimeManager: MemoryProfileRuntimeManager()
        )
        model.networkJoinAlert = NetworkJoinAlert(
            succeeded: false,
            title: "Earlier Failure",
            message: "This must not appear during the next invitation."
        )

        model.prepareForNetworkJoin()

        #expect(model.networkJoinAlert == nil)
    }

    @Test("Mailbox metadata remains isolated by Context")
    func mailboxMetadataIsContextScoped() async {
        let firstURL = metadataURL("BeakrTests.ContextA.\(UUID().uuidString)")
        let secondURL = metadataURL("BeakrTests.ContextB.\(UUID().uuidString)")
        let service = RecordingMessagingService()
        let recipient = UUID()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: firstURL)

        model.synchronizeRecipients(with: [
            NetworkMemberSummary(id: recipient, displayName: "Context A Device")
        ])
        model.destinationID = recipient
        model.messageText = "Stored only in Context A"
        await model.send()

        model.attachMailboxMetadata(fileURL: secondURL)
        #expect(model.outgoingMessages.isEmpty)
        #expect(model.recipients.isEmpty)

        model.attachMailboxMetadata(fileURL: firstURL)
        #expect(model.outgoingMessages.count == 1)
        #expect(model.outgoingMessages.first?.body == "Stored only in Context A")
        #expect(model.recipients.first?.name == "Context A Device")
    }

    @Test("Network member metadata preserves the last authenticated name and last-seen date")
    func networkMemberMetadataRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeakrTests.MemberMetadata.\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("network-members.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let memberID = UUID()
        let lastSeen = Date(timeIntervalSince1970: 1_760_000_000)
        let metadata = NetworkMemberMetadata(
            id: memberID,
            displayName: "Hallway iPhone",
            lastSeen: lastSeen
        )

        try NetworkMemberMetadataStore.save([memberID: metadata], to: fileURL)
        let restored = try NetworkMemberMetadataStore.load(from: fileURL)

        #expect(restored == [memberID: metadata])
    }

    private func metadataURL(_ suiteName: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
            .appendingPathComponent("mailbox-metadata.json")
    }
}

private actor RecordingMessagingService: HostMessagingService {
    private(set) var requests: [HostMessageRequest] = []
    private(set) var cancelledCorrelationIDs: [UUID] = []

    func send(_ request: HostMessageRequest) async throws {
        requests.append(request)
    }

    func cancel(correlationID: DataCorrelationID) async throws {
        cancelledCorrelationIDs.append(correlationID.rawValue)
    }
}

private struct FailingMessagingService: HostMessagingService {
    func send(_ request: HostMessageRequest) async throws {
        throw BeakrMessagingSetupError.notConfigured
    }

    func cancel(correlationID: DataCorrelationID) async throws {}
}

private struct FixedIdentityLoader: NodeIdentityLoading {
    let nodeID: NodeID
    func loadNodeID(profileID: NetworkProfileID) throws -> NodeID? { nodeID }
    func loadOrCreateNodeID(profileID: NetworkProfileID) throws -> NodeID { nodeID }
}

private struct FailingIdentityLoader: NodeIdentityLoading {
    func loadNodeID(profileID: NetworkProfileID) throws -> NodeID? { throw BeakrMessagingSetupError.notConfigured }
    func loadOrCreateNodeID(profileID: NetworkProfileID) throws -> NodeID { throw BeakrMessagingSetupError.notConfigured }
}

private struct MemoryAuthorityConfigurationStore: DevelopmentAuthorityConfigurationStoring {
    func load(profile: NetworkProfile) throws -> DevelopmentAuthorityConfiguration? { nil }
    func save(_ configuration: DevelopmentAuthorityConfiguration, profile: NetworkProfile) throws {}
    func delete(profile: NetworkProfile) throws {}
}

private struct FixedAuthorityConfigurationStore: DevelopmentAuthorityConfigurationStoring {
    let configuration: DevelopmentAuthorityConfiguration
    func load(profile: NetworkProfile) throws -> DevelopmentAuthorityConfiguration? { configuration }
    func save(_ configuration: DevelopmentAuthorityConfiguration, profile: NetworkProfile) throws {}
    func delete(profile: NetworkProfile) throws {}
}

private enum TestJoiningInstallationError: Error {
    case interrupted
}

private struct FailingJoiningMembershipInstaller: JoiningMembershipInstalling {
    func installMembership(from approval: EnrollmentApproval, identity: NodeIdentity) throws {
        throw TestJoiningInstallationError.interrupted
    }
}

/// For tests that never reach trust recovery; do not use for a ready runtime fixture.
private struct NoopTrustBootstrapper: NodeTrustBootstrapping {
    func enrollAndRecover(
        using configuration: DevelopmentAuthorityConfiguration,
        profile: NetworkProfile,
        revocationSnapshotURL: URL
    ) async throws {}
}

/// Supplies the signed evidence required by production membership recovery, without network I/O.
private struct SignedFixtureTrustBootstrapper: NodeTrustBootstrapping {
    let authority: CredentialAuthority

    func enrollAndRecover(
        using configuration: DevelopmentAuthorityConfiguration,
        profile: NetworkProfile,
        revocationSnapshotURL: URL
    ) async throws {
        let now = Date()
        let membership = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        ).sign(ProfileMembershipClaims(
            networkID: profile.networkID,
            networkDisplayName: profile.displayName,
            generation: 1,
            generatedAtMilliseconds: Int64((now.timeIntervalSince1970 * 1_000).rounded(.down)),
            records: [.init(
                credential: configuration.credential,
                certificatePublicKey: configuration.credential.claims.nodePublicKey,
                sessionID: SessionID()
            )]
        ))
        let trustDirectory = revocationSnapshotURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: trustDirectory, withIntermediateDirectories: true)
        try ProfileMembershipWireCodec.encode(membership).write(
            to: trustDirectory.appendingPathComponent("membership.json"),
            options: .atomic
        )
        try CredentialFiles.saveRevocationSnapshot(
            authority.issueRevocationSnapshot(revocations: [], now: now),
            to: revocationSnapshotURL
        )
    }
}

private enum TestProfileRuntimeError: Error {
    case unavailable
}

private actor MemoryProfileRuntimeManager: ApplicationProfileRuntimeManaging {
    private var active = false
    private var initialProfile: NetworkProfile?
    private(set) var checkpointLifecycles: [HostLifecycleState] = []
    private(set) var activeProfileRequests = 0
    private let failsToLoad: Bool
    private let contextRecords: [ContextRecord]
    private let incomingMessagesByContext: [ContextID: [IncomingMessage]]
    private let mailboxMetadataByContext: [ContextID: ContextMailboxMetadata]

    init(
        initialProfile: NetworkProfile? = nil,
        failsToLoad: Bool = false,
        contexts: [ContextRecord] = [],
        incomingMessages: [ContextID: [IncomingMessage]] = [:],
        mailboxMetadata: [ContextID: ContextMailboxMetadata] = [:]
    ) {
        self.initialProfile = initialProfile
        self.failsToLoad = failsToLoad
        contextRecords = contexts
        incomingMessagesByContext = incomingMessages
        mailboxMetadataByContext = mailboxMetadata
    }

    func setInitialProfile(_ profile: NetworkProfile) {
        initialProfile = profile
    }

    func activeProfile() throws -> NetworkProfile? {
        activeProfileRequests += 1
        if failsToLoad { throw TestProfileRuntimeError.unavailable }
        return initialProfile
    }

    func profiles() -> [NetworkProfile] { initialProfile.map { [$0] } ?? [] }

    func contexts() -> [ContextRecord] { contextRecords }

    func incomingMessages(contextID: ContextID) -> [IncomingMessage] {
        incomingMessagesByContext[contextID] ?? []
    }

    func mailboxMetadata(contextID: ContextID) -> ContextMailboxMetadata {
        mailboxMetadataByContext[contextID] ?? .empty
    }

    func activate(_ profileID: NetworkProfileID) throws {
        guard initialProfile?.id == profileID else {
            throw NetworkProfileRegistryError.unknownProfile(profileID)
        }
    }

    func add(_ profile: NetworkProfile) throws {
        guard initialProfile == nil else { throw TestProfileRuntimeError.unavailable }
        initialProfile = profile
    }

    func addAndActivate(_ profile: NetworkProfile) throws {
        initialProfile = profile
    }

    func rename(_ profileID: NetworkProfileID, to displayName: String) throws {
        guard let profile = initialProfile, profile.id == profileID else {
            throw NetworkProfileRegistryError.unknownProfile(profileID)
        }
        initialProfile = try NetworkProfile(
            id: profile.id,
            networkID: profile.networkID,
            localNodeID: profile.localNodeID,
            displayName: displayName,
            createdAt: profile.createdAt
        )
    }

    func start(profile proposedProfile: NetworkProfile) async throws -> ApplicationProfileRuntime {
        guard !active else { throw ActiveProfileRuntimeError.runtimeAlreadyActive(NetworkProfileID()) }
        active = true
        let profile: NetworkProfile
        if let initialProfile {
            profile = initialProfile
        } else {
            profile = try NetworkProfile(
                id: proposedProfile.id,
                networkID: proposedProfile.networkID,
                localNodeID: proposedProfile.localNodeID,
                displayName: "Test Network", createdAt: Date(timeIntervalSince1970: 1_000)
            )
        }
        guard profile.id == proposedProfile.id,
              profile.networkID == proposedProfile.networkID,
              profile.localNodeID == proposedProfile.localNodeID else {
            throw NodeBootstrapError.activeProfileMismatch
        }
        initialProfile = profile
        let paths = ProfileRuntimePaths(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(profile.id.rawValue.uuidString, isDirectory: true)
        )
        return ApplicationProfileRuntime(
            profile: profile,
            paths: paths,
            dataState: try await PersistentDataState.open(fileURL: paths.dataStateURL)
        )
    }

    func stop() throws {
        guard active else { throw ActiveProfileRuntimeError.runtimeNotActive }
        active = false
    }

    func delete(profile: NetworkProfile) {
        active = false
        if initialProfile?.id == profile.id { initialProfile = nil }
    }

    func checkpoint(lifecycle: HostLifecycleState) throws {
        guard active else { throw ActiveProfileRuntimeError.runtimeNotActive }
        checkpointLifecycles.append(lifecycle)
    }
}

private actor MultipleProfileRuntimeManager: ApplicationProfileRuntimeManaging {
    private var storedProfiles: [NetworkProfile]
    private var activeProfileID: NetworkProfileID?
    private var runtimeIsActive = false

    init(initialProfile: NetworkProfile) {
        storedProfiles = [initialProfile]
        activeProfileID = initialProfile.id
    }

    func activeProfile() -> NetworkProfile? {
        storedProfiles.first { $0.id == activeProfileID }
    }

    func profiles() -> [NetworkProfile] { storedProfiles }

    func activate(_ profileID: NetworkProfileID) throws {
        guard storedProfiles.contains(where: { $0.id == profileID }) else {
            throw NetworkProfileRegistryError.unknownProfile(profileID)
        }
        activeProfileID = profileID
    }

    func addAndActivate(_ profile: NetworkProfile) {
        storedProfiles.append(profile)
        activeProfileID = profile.id
    }

    func add(_ profile: NetworkProfile) {
        storedProfiles.append(profile)
    }

    func rename(_ profileID: NetworkProfileID, to displayName: String) throws {
        guard let index = storedProfiles.firstIndex(where: { $0.id == profileID }) else {
            throw NetworkProfileRegistryError.unknownProfile(profileID)
        }
        let profile = storedProfiles[index]
        storedProfiles[index] = try NetworkProfile(
            id: profile.id,
            networkID: profile.networkID,
            localNodeID: profile.localNodeID,
            displayName: displayName,
            createdAt: profile.createdAt
        )
    }

    func start(profile: NetworkProfile) async throws -> ApplicationProfileRuntime {
        guard !runtimeIsActive else {
            throw ActiveProfileRuntimeError.runtimeAlreadyActive(profile.id)
        }
        guard activeProfileID == profile.id else {
            throw NodeBootstrapError.activeProfileMismatch
        }
        runtimeIsActive = true
        let paths = ProfileRuntimePaths(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(profile.id.rawValue.uuidString, isDirectory: true)
        )
        return ApplicationProfileRuntime(
            profile: profile,
            paths: paths,
            dataState: try await PersistentDataState.open(fileURL: paths.dataStateURL)
        )
    }

    func checkpoint(lifecycle: HostLifecycleState) throws {
        guard runtimeIsActive else { throw ActiveProfileRuntimeError.runtimeNotActive }
    }

    func stop() throws {
        guard runtimeIsActive else { throw ActiveProfileRuntimeError.runtimeNotActive }
        runtimeIsActive = false
    }

    func delete(profile: NetworkProfile) {
        if activeProfileID == profile.id { runtimeIsActive = false }
        storedProfiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            activeProfileID = storedProfiles.first?.id
        }
    }
}

private actor TestLANRuntimeManager: ApplicationLANRuntimeManaging {
    private let permissionMonitor = LocalNetworkPermissionMonitor()

    func localNetworkPermissionDenied() -> Bool { permissionMonitor.isDenied }
    func localNetworkPermissionUpdates() -> AsyncStream<Bool> { permissionMonitor.updates() }
    func reportPermissionDiagnostic(_ diagnostic: BonjourDiagnostic) { permissionMonitor.observe(diagnostic) }

    private(set) var lastDisplayName: String?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var peerIDs: Set<UUID>
    private let isLocalNetworkAvailable: Bool
    private var sharedNetworkName: String?
    private var startDelay: Duration?
    private var startFailuresRemaining = 0
    private(set) var diagnosticContexts: [RuntimeTraceContext?] = []

    init(authenticatedPeerIDs: Set<UUID> = [], localNetworkAvailable: Bool = true) {
        peerIDs = authenticatedPeerIDs
        isLocalNetworkAvailable = localNetworkAvailable
    }

    func start(
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime,
        displayName: String
    ) async throws {
        lastDisplayName = displayName
        diagnosticContexts.append(RuntimeLifecycleDiagnostics.current?.context)
        startCount += 1
        if startFailuresRemaining > 0 {
            startFailuresRemaining -= 1
            throw ApplicationLANRuntimeError.notRunning
        }
        if let startDelay {
            try await Task.sleep(for: startDelay)
        }
    }

    func stop() {
        stopCount += 1
    }

    func authenticatedPeerIDs() -> Set<UUID> {
        peerIDs
    }

    func localNetworkAvailable() -> Bool {
        isLocalNetworkAvailable
    }

    func networkDisplayName() -> String? {
        sharedNetworkName
    }

    func setSharedNetworkName(_ name: String?) {
        sharedNetworkName = name
    }

    func localNetworkAvailabilityUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(isLocalNetworkAvailable)
            continuation.finish()
        }
    }

    func setPeerIDs(_ ids: Set<UUID>) {
        peerIDs = ids
    }

    func setStartDelay(_ delay: Duration?) {
        startDelay = delay
    }

    func failNextStarts(_ count: Int) {
        startFailuresRemaining = count
    }

}

private struct FailingLifecycleMigrator: ApplicationLifecycleMigrating {
    func migrate(
        profile: NetworkProfile,
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime
    ) async throws {
        throw BeakrMessagingSetupError.notConfigured
    }
}

private struct FixedApplicationEnrollmentRouter: ApplicationEnrollmentRouting {
    let route: EnrollmentApplicationRoute
    var lifecycleExists = false

    func hasLifecycleRecord(runtime: ApplicationProfileRuntime) async throws -> Bool {
        lifecycleExists
    }

    func route(runtime: ApplicationProfileRuntime) async throws -> EnrollmentApplicationRoute {
        route
    }
}

private actor TestAuthorityRunner: ApplicationAuthorityRunning {
    private(set) var enrollmentInvitationCount = 0
    func createEnrollmentInvitation() throws -> EnrollmentInvitation {
        enrollmentInvitationCount += 1
        throw NetworkInvitationError.invalidConfiguration
    }

    private var auditRecords: [EnrollmentAuditRecord] = []

    func setAuditRecords(_ records: [EnrollmentAuditRecord]) { auditRecords = records }
    func enrollmentAuditRecords() -> [EnrollmentAuditRecord] { auditRecords }

    private(set) var renamedNames: [String] = []
    private(set) var stopCount = 0

    func stop() { stopCount += 1 }

    func createInvitation(validity: TimeInterval) throws -> NetworkInvitation {
        throw NetworkInvitationError.invalidConfiguration
    }

    func removeMember(nodeID: NodeID, reason: String) throws {}

    func renameNetwork(to displayName: String) {
        renamedNames.append(displayName)
    }
}

private struct NonOwningNetworkCreator: AuthoritativeNetworkCreating {
    func create(displayName: String, hostname: String, port: UInt16) async throws
        -> CreatedAuthoritativeNetwork {
        throw BeakrMessagingSetupError.notConfigured
    }

    func restore(profile: NetworkProfile) async throws -> (any ApplicationAuthorityRunning)? { nil }

    func owns(profile: NetworkProfile) async throws -> Bool { false }

    func authorityCertificateDER(profile: NetworkProfile) async throws -> Data {
        throw BeakrMessagingSetupError.notConfigured
    }

    func rename(profile: NetworkProfile, to displayName: String) async throws {
        throw BeakrMessagingSetupError.notConfigured
    }

    func delete(profile: NetworkProfile) async throws {
        throw BeakrMessagingSetupError.notConfigured
    }
}

private struct FixedAuthoritativeNetworkCreator: AuthoritativeNetworkCreating {
    let created: CreatedAuthoritativeNetwork
    let createdProfileID: NetworkProfileID
    let additionalOwnedProfileIDs: Set<NetworkProfileID>
    let authorityCertificateDER: Data?

    init(
        created: CreatedAuthoritativeNetwork,
        additionalOwnedProfileIDs: Set<NetworkProfileID> = []
    ) {
        self.created = created
        createdProfileID = created.profile.id
        self.additionalOwnedProfileIDs = additionalOwnedProfileIDs
        authorityCertificateDER = created.configuration.authorityCertificateDER
    }

    func create(displayName: String, hostname: String, port: UInt16) async throws
        -> CreatedAuthoritativeNetwork {
        created
    }

    func restore(profile: NetworkProfile) async throws -> (any ApplicationAuthorityRunning)? {
        profile.id == createdProfileID ? created.authority : nil
    }

    func owns(profile: NetworkProfile) async throws -> Bool {
        profile.id == createdProfileID || additionalOwnedProfileIDs.contains(profile.id)
    }

    func authorityCertificateDER(profile: NetworkProfile) async throws -> Data {
        authorityCertificateDER ?? Data()
    }

    func rename(profile: NetworkProfile, to displayName: String) async throws {}

    func delete(profile: NetworkProfile) async throws {}
}

private actor ReportingLANRuntimeManager: ApplicationLANRuntimeManaging {
    let peerID: UUID
    private var address: String?
    private var continuation: AsyncStream<Set<UUID>>.Continuation?
    init(peerID: UUID) { self.peerID = peerID }
    func start(configuration: DevelopmentAuthorityConfiguration, runtime: ApplicationProfileRuntime, displayName: String) {}
    func stop() { continuation?.finish() }
    func localNetworkAvailable() -> Bool { true }
    func authenticatedPeerIDs() -> Set<UUID> { [peerID] }
    func authenticatedPeerIDUpdates() -> AsyncStream<Set<UUID>> {
        let (stream, continuation) = AsyncStream<Set<UUID>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        continuation.yield([peerID])
        return stream
    }
    func memberSummaries() -> [NetworkMemberSummary] {
        [.init(id: peerID, displayName: "Peer", deviceIPAddress: address)]
    }
    func report(_ address: String?) {
        self.address = address
        continuation?.yield([peerID])
    }
}

private final class CreationConfigurationStore: DevelopmentAuthorityConfigurationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NetworkProfileID: DevelopmentAuthorityConfiguration] = [:]
    func load(profile: NetworkProfile) throws -> DevelopmentAuthorityConfiguration? {
        lock.lock(); defer { lock.unlock() }
        return values[profile.id]
    }
    func save(_ configuration: DevelopmentAuthorityConfiguration, profile: NetworkProfile) throws {
        lock.lock(); defer { lock.unlock() }
        values[profile.id] = configuration
    }
    func delete(profile: NetworkProfile) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: profile.id)
    }
}

private actor CreationNetworkCreator: AuthoritativeNetworkCreating {
    let created: CreatedAuthoritativeNetwork
    let originalID: NetworkProfileID
    let originalRunner: TestAuthorityRunner
    let failCreation: Bool
    private(set) var restoredIDs: [NetworkProfileID] = []
    init(created: CreatedAuthoritativeNetwork, originalID: NetworkProfileID,
         originalRunner: TestAuthorityRunner, failCreation: Bool) {
        self.created = created
        self.originalID = originalID
        self.originalRunner = originalRunner
        self.failCreation = failCreation
    }
    func create(displayName: String, hostname: String, port: UInt16) throws -> CreatedAuthoritativeNetwork {
        if failCreation { throw TestProfileRuntimeError.unavailable }
        return created
    }
    func restore(profile: NetworkProfile) -> (any ApplicationAuthorityRunning)? {
        restoredIDs.append(profile.id)
        return profile.id == originalID ? originalRunner : created.authority
    }
    func owns(profile: NetworkProfile) -> Bool { true }
    func authorityCertificateDER(profile: NetworkProfile) -> Data { Data() }
    func rename(profile: NetworkProfile, to displayName: String) {}
    func delete(profile: NetworkProfile) {}
}

private actor RecoverySnapshotRequester: RevocationSnapshotRequesting {
    let snapshot: CredentialRevocationSnapshot?
    let offline: Bool
    private(set) var generations: [Int64?] = []

    init(snapshot: CredentialRevocationSnapshot?, offline: Bool = false) {
        self.snapshot = snapshot
        self.offline = offline
    }

    func fetchSnapshot(after generatedAtMilliseconds: Int64?) async throws -> CredentialRevocationSnapshot? {
        generations.append(generatedAtMilliseconds)
        if offline { throw URLError(.notConnectedToInternet) }
        return snapshot
    }
}

private struct CreationEnrollmentRouter: ApplicationEnrollmentRouting {
    let manager: MultipleProfileRuntimeManager
    let configurations: CreationConfigurationStore
    let failPreparation: Bool
    func route(runtime: ApplicationProfileRuntime) async throws -> EnrollmentApplicationRoute { .member }
    func prepareNetworkCreation(profile: NetworkProfile, configuration: DevelopmentAuthorityConfiguration,
                                paths: ProfileRuntimePaths) async throws {
        try await ApplicationEnrollmentRouter(profileRuntimeManager: manager, configurationStore: configurations)
            .prepareNetworkCreation(profile: profile, configuration: configuration, paths: paths)
        if failPreparation { throw TestProfileRuntimeError.unavailable }
    }
}

/// The injected boundary is transport only; owner/driver/inbox/ack/retry code is production.
private actor DeliveryFaultTransport: BeakrNetTransport {
    nonisolated let id = TransportID()
    nonisolated let kind = TransportKind.local
    nonisolated let capabilities = TransportCapabilities(
        preservesOrder: true, supportsImmediateDelivery: true,
        supportsQueuedDelivery: true, supportsBackgroundDelivery: false
    )
    private let inbound: AsyncStream<BeakrNetEnvelope>
    private let outbound: AsyncStream<BeakrNetEnvelope>.Continuation
    private var dropFirstAcknowledgement: Bool
    private(set) var droppedAcknowledgements = 0
    private(set) var sent: [BeakrNetEnvelope] = []

    init(inbound: AsyncStream<BeakrNetEnvelope>, outbound: AsyncStream<BeakrNetEnvelope>.Continuation,
         dropFirstAcknowledgement: Bool = false) {
        self.inbound = inbound
        self.outbound = outbound
        self.dropFirstAcknowledgement = dropFirstAcknowledgement
    }

    func send(_ envelope: BeakrNetEnvelope) async throws {
        sent.append(envelope)
        if dropFirstAcknowledgement && envelope.payloadType == DeliveryAcknowledgement.payloadType {
            dropFirstAcknowledgement = false
            droppedAcknowledgements += 1
            return
        }
        outbound.yield(envelope)
    }

    func receive() async -> BeakrNetEnvelope? {
        var iterator = inbound.makeAsyncIterator()
        return await iterator.next()
    }

    func close() async { outbound.finish() }
}


struct ApplicationStorageOwnershipTests {
    @Test("Second owner is rejected; release allows reacquisition without deleting the lock file")
    func exclusionAndRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var first: ApplicationStorageOwnership? = try ApplicationStorageOwnership(rootURL: root)
        withExtendedLifetime(first) {
            #expect(throws: ApplicationStorageOwnership.Failure.alreadyRunning) {
                _ = try ApplicationStorageOwnership(rootURL: root)
            }
        }
        first = nil
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".application-owner.lock").path))
        let replacement = try ApplicationStorageOwnership(rootURL: root)
        withExtendedLifetime(replacement) {
            #expect(throws: ApplicationStorageOwnership.Failure.alreadyRunning) {
                _ = try ApplicationStorageOwnership(rootURL: root)
            }
        }
    }

    @Test("Independent storage roots do not block each other")
    func independentRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ApplicationStorageOwnership(rootURL: root.appendingPathComponent("one"))
        let second = try ApplicationStorageOwnership(rootURL: root.appendingPathComponent("two"))
        withExtendedLifetime((first, second)) {}
    }

    @Test("Unusable storage fails closed")
    func unusableStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) {
            _ = try ApplicationStorageOwnership(rootURL: root)
        }
    }
}


extension ApplicationStorageOwnershipTests {
    @Test("Replacement waits for termination and still requires exclusive ownership")
    func replacementRequiresExitAndLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Even a free lock cannot authorize takeover while the old process is alive.
        guard case .waiting = ApplicationOwnershipHandover.poll(previousTerminated: false, timedOut: false, rootURL: root) else {
            Issue.record("Replacement proceeded before process termination")
            return
        }
        var rival: ApplicationStorageOwnership? = try ApplicationStorageOwnership(rootURL: root)
        withExtendedLifetime(rival) {
            guard case .waiting = ApplicationOwnershipHandover.poll(previousTerminated: true, timedOut: false, rootURL: root) else {
                Issue.record("Replacement bypassed an existing lock")
                return
            }
        }
        rival = nil
        guard case .acquired(let replacement) = ApplicationOwnershipHandover.poll(previousTerminated: true, timedOut: false, rootURL: root) else {
            Issue.record("Replacement failed after exit and lock release")
            return
        }
        withExtendedLifetime(replacement) {
            #expect(throws: ApplicationStorageOwnership.Failure.alreadyRunning) {
                _ = try ApplicationStorageOwnership(rootURL: root)
            }
        }
    }

    @Test("Expired replacement never acquires storage")
    func replacementTimeout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .failed = ApplicationOwnershipHandover.poll(previousTerminated: true, timedOut: true, rootURL: root) else {
            Issue.record("Replacement continued after its deadline")
            return
        }
        let owner = try ApplicationStorageOwnership(rootURL: root)
        withExtendedLifetime(owner) {}
    }

    @Test("Replacement storage errors fail closed")
    func replacementStorageFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .failed = ApplicationOwnershipHandover.poll(previousTerminated: true, timedOut: false, rootURL: root) else {
            Issue.record("Replacement accepted unusable storage")
            return
        }
    }
}


extension ApplicationStorageOwnershipTests {
    @Test("Cooperative quit requires a fresh request for the current owner and is consumed once")
    func cooperativeQuitRequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try ApplicationStorageOwnership(rootURL: root)
        #expect(!owner.consumeQuitRequest()) // A notification alone cannot request quit.
        let now = Date()
        _ = try ApplicationStorageOwnership.requestNormalQuit(rootURL: root,
            expectedPID: ProcessInfo.processInfo.processIdentifier, now: now)
        #expect(owner.consumeQuitRequest(now: now.addingTimeInterval(1)))
        #expect(!owner.consumeQuitRequest(now: now.addingTimeInterval(1)))
        #expect(throws: ApplicationStorageOwnership.Failure.alreadyRunning) {
            _ = try ApplicationStorageOwnership.requestNormalQuit(rootURL: root,
                expectedPID: ProcessInfo.processInfo.processIdentifier + 1, now: now)
        }
        #expect(!owner.consumeQuitRequest())
    }

    @Test("Expired, cancelled and previous-owner quit requests cannot stop the current owner")
    func cooperativeQuitLifetime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var owner: ApplicationStorageOwnership? = try ApplicationStorageOwnership(rootURL: root)
        let now = Date(), pid = ProcessInfo.processInfo.processIdentifier
        _ = try ApplicationStorageOwnership.requestNormalQuit(rootURL: root, expectedPID: pid, now: now)
        #expect(owner?.consumeQuitRequest(now: now.addingTimeInterval(15)) == false)
        let cancelled = try ApplicationStorageOwnership.requestNormalQuit(rootURL: root, expectedPID: pid, now: now)
        ApplicationStorageOwnership.removeQuitRequest(rootURL: root, token: cancelled)
        #expect(owner?.consumeQuitRequest(now: now) == false)
        _ = try ApplicationStorageOwnership.requestNormalQuit(rootURL: root, expectedPID: pid, now: now)
        owner = nil
        let next = try ApplicationStorageOwnership(rootURL: root)
        #expect(!next.consumeQuitRequest(now: now))
    }
}

private actor CredentialRetryGate {
    var delays: [Int] = []
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait(_ seconds: Int) async {
        delays.append(seconds)
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
private final class RecoveringTrustFixture: NodeTrustBootstrapping {
    let authority: CredentialAuthority
    let firstError: any Error
    var attempts = 0
    var firstAttemptGate: CredentialRetryGate?
    init(authority: CredentialAuthority, firstError: any Error) {
        self.authority = authority
        self.firstError = firstError
    }
    func enrollAndRecover(using configuration: DevelopmentAuthorityConfiguration, profile: NetworkProfile,
                          revocationSnapshotURL: URL) async throws {
        attempts += 1
        if attempts == 1 {
            if let firstAttemptGate { await firstAttemptGate.wait(0) }
            throw firstError
        }
        try await SignedFixtureTrustBootstrapper(authority: authority).enrollAndRecover(
            using: configuration, profile: profile, revocationSnapshotURL: revocationSnapshotURL)
    }
}

@Suite("Messaging TLS health")
struct MessagingTLSHealthTests {
    @Test("Only successful validation of the failed endpoint clears its warning")
    func endpointRecovery() async {
        let monitor = PeerTLSHealthMonitor()
        let failing = BonjourEndpointID()
        let other = BonjourEndpointID()
        var updates = monitor.updates().makeAsyncIterator()
        #expect(await updates.next() == 0)
        monitor.observe(endpoint: failing, trusted: false)
        #expect(await updates.next() == 1)
        monitor.observe(endpoint: other, trusted: true)
        #expect(await updates.next() == 1)
        monitor.observe(endpoint: failing, trusted: false)
        #expect(await updates.next() == 1)
        monitor.observe(endpoint: failing, trusted: true)
        #expect(await updates.next() == 0)
    }

    @Test("New runtimes do not inherit failures from previous networks")
    func runtimeIsolation() async {
        let old = PeerTLSHealthMonitor()
        let current = PeerTLSHealthMonitor()
        old.observe(endpoint: BonjourEndpointID(), trusted: false)
        var updates = current.updates().makeAsyncIterator()
        #expect(await updates.next() == 0)
    }
}
