#if os(macOS)
import Foundation
import Network
import Security
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetData
import BeakrNetHost
import BeakrNetOperations
import BeakrNetSecurity

extension ProductionLANTLSIntegrationTests {
    @Test("HTTPS-refreshed trust gates production TLS delivery and survives reopening", .timeLimit(.minutes(2)))
    func refreshedTrustAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("beakr-refreshed-trust-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = CertificateFixture(root: root)
        try fixture.createCA("ca")
        let anchor = try fixture.certificate("ca")
        let httpsIdentity = try fixture.identity("https", ca: "ca", dnsName: "authority.test")
        let authority = CredentialAuthority()
        let network = NetworkID()
        let nodes = [NodeIdentity(), NodeIdentity(), NodeIdentity()] // observer, eligible control, candidate
        let identities = try nodes.enumerated().map { try fixture.identity("peer\($0.offset)", ca: "ca", node: $0.element) }
        let certificates = try nodes.indices.map { try fixture.certificate("peer\($0)") }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let credentials = try nodes.map {
            try authority.issue(nodeID: $0.nodeID, nodePublicKey: $0.publicKeyRepresentation,
                                networkID: network, environment: "refresh-test", validity: 3600, serviceScopes: ["lan"], now: now)
        }
        let trust = try await AuthorityTrustStateCoordinator.open(authority: authority, networkID: network,
            environment: "refresh-test", ledgerURL: root.appendingPathComponent("authority.json"), now: now)
        for index in 0..<2 {
            try await trust.approve(credential: credentials[index], certificatePublicKey: nodes[index].publicKeyRepresentation, now: now)
        }
        let server = try RefreshHTTPSFixture(identity: httpsIdentity, trust: trust)
        let port: UInt16
        do { port = try await server.start() }
        catch { await server.stop(); throw error }
        let transport = CurlAuthorityTransport(baseURL: try #require(URL(string: "https://authority.test:\(port)")),
            caCertificate: root.appendingPathComponent("ca.pem"), directory: root)
        do {
            var observer = try await RefreshedObserver.open(root: root, authority: authority, network: network, transport: transport)
            _ = await observer.maintenance.refreshNow(revocationTrigger: .startup, membershipTrigger: .startup)
            let initialGeneration = try #require(await observer.directory.generation())
            let incomingURL = root.appendingPathComponent("incoming.json")
            let sender = try await PersistentDataState.open(fileURL: root.appendingPathComponent("outgoing.json"))
            var sink = try await DurableTrustSink.open(incomingURL)
            var expectedMessages: [MessageID: DataMessage] = [:]
            let sessionID = SessionID()

            func envelope(_ peer: Int, _ label: String) throws -> BeakrNetEnvelope {
                let message = DataMessage(kind: .message, operation: .init(namespace: "beakr", name: "text-message", version: 1),
                    correlationID: DataCorrelationID(), idempotencyKey: DataIdempotencyKey(), body: Data(label.utf8))
                return BeakrNetEnvelope(networkID: network, sessionID: sessionID, sourceNodeID: nodes[peer].nodeID,
                    destinationNodeID: nodes[0].nodeID, sequenceNumber: 1,
                    deliveryPolicy: .init(durability: .durable, expiresAt: Date().addingTimeInterval(120)),
                    payloadType: DataMessage.payloadType, payload: try DataCodec().encode(message))
            }

            func attempt(_ peer: Int, envelope: BeakrNetEnvelope, observer: RefreshedObserver,
                         sink: DurableTrustSink, outcome: TrustAttempt) async throws {
                let snapshot = try #require(await observer.distributor.latestSnapshot())
                func configuration(_ index: Int) -> LANTransportConfiguration {
                    LANTransportConfiguration(identity: nodes[index], credential: credentials[index],
                        trustedAuthorityPublicKey: authority.publicKeyRepresentation, networkID: network,
                        environment: "refresh-test", revocationSnapshot: snapshot,
                        localCertificateDER: SecCertificateCopyData(certificates[index]) as Data,
                        localCertificatePublicKey: nodes[index].publicKeyRepresentation,
                        capabilities: .init(maximumEnvelopeBytes: 512_000, preservesOrder: true,
                            supportsImmediateDelivery: true, supportsQueuedDelivery: true, supportsBackgroundDelivery: false))
                }
                let beforeCalls = await sink.calls
                let beforeBytes = try Data(contentsOf: incomingURL)
                try await connect(client: identities[peer], server: identities[0], anchor: anchor, rejectingSide: nil) { client, server in
                    let incoming = NetworkBonjourConnection(connection: server)
                    let outgoing = NetworkBonjourConnection(connection: client)
                    let resolver = observer.directory.acceptedPeerResolver { await observer.maintenance.recoverUnknownPeer() }
                    let accepted = await resolver(incoming)
                    if outcome == .unknown {
                        #expect(accepted == nil)
                        #expect(await observer.directory.resolve(certificatePublicKey: nodes[peer].publicKeyRepresentation) == nil)
                        // Production membership resolver has rejected a real, TLS-authenticated certificate.
                        // No application handshake or route is allowed after this result.
                        return
                    }
                    #expect((accepted != nil) == (outcome == .accepted))
                    let nonce = Data(repeating: 0x64, count: 32)
                    let deadline = Task {
                        do { try await Task.sleep(for: .seconds(8)) } catch { return }
                        client.cancel(); server.cancel()
                    }
                    defer { deadline.cancel() }
                    let writer = Task<Bool, Never> {
                        do {
                            let lan = try await LANTransport.authenticate(connection: outgoing, role: .initiator,
                                expectedPeerNodeID: nodes[0].nodeID, advertisementNonce: nonce, configuration: configuration(peer))
                            try await lan.send(envelope)
                            if outcome == .accepted { try await lan.send(envelope) }
                            guard let response = await lan.receive(), response.payloadType == DeliveryAcknowledgement.payloadType else {
                                await lan.close(); return false
                            }
                            let ack = try JSONDecoder().decode(DeliveryAcknowledgement.self, from: response.payload)
                            #expect(ack.messageID == envelope.messageID)
                            #expect(await sink.contains(envelope.messageID))
                            // Fixture bridge consumes a real wire acknowledgement only after durable acceptance.
                            _ = try await sender.acknowledge(ack.messageID)
                            await lan.close()
                            return true
                        } catch { return false }
                    }
                    do {
                        // For revoked peers the production resolver already refused. Deliberately bypass
                        // only that gate to independently prove the signed handshake rejects the old credential.
                        let lan = try await LANTransport.authenticate(connection: incoming, role: .acceptor,
                            expectedPeerNodeID: nodes[peer].nodeID, advertisementNonce: nonce, configuration: configuration(0))
                        #expect(outcome == .accepted)
                        if outcome != .accepted { await lan.close(); _ = await writer.value; return }
                        let session = BeakrNetSession(id: sessionID, networkID: network, localNodeID: nodes[0].nodeID,
                            remoteNodeID: nodes[peer].nodeID, state: .active)
                        let routes = PeerRouteCoordinator(networkID: network, remoteNodeID: nodes[peer].nodeID)
                        let driver = SessionDeliveryDriver(session: session, coordinator: routes)
                        let owner = await AuthenticatedTransportRouteOwner(transport: lan, coordinator: routes, driver: driver,
                            incomingEnvelopeSink: { await sink.record($0) })
                        await owner.setPermitted(true)
                        #expect(await writer.value)
                        await owner.setPermitted(false)
                        await lan.close()
                    } catch {
                        #expect(outcome == .revoked)
                        #expect(error as? LANHandshakeError == .revokedCredential)
                        server.cancel(); client.cancel()
                        #expect(await writer.value == false)
                    }
                }
                if outcome != .accepted {
                    #expect(await sink.calls == beforeCalls)
                    #expect(try Data(contentsOf: incomingURL) == beforeBytes)
                    #expect(try await sender.pending().contains { $0.messageID == envelope.messageID })
                }
                print("Refreshed trust: \(outcome), peer=\(nodes[peer].nodeID), message=\(envelope.messageID)")
            }

            let control = try envelope(1, "eligible-before")
            try await sender.enqueue(control)
            // Establish a durable empty file before byte-level negative comparisons.
            try await sink.initialize()
            try await attempt(1, envelope: control, observer: observer, sink: sink, outcome: .accepted)
            expectedMessages[control.messageID] = try DataCodec().decode(envelope: control)
            try await trust.approve(credential: credentials[2], certificatePublicKey: nodes[2].publicKeyRepresentation, now: now.addingTimeInterval(1))
            await server.setMode(.offline)
            let candidate = try envelope(2, "unknown-then-admitted")
            try await sender.enqueue(candidate)
            let beforeRequests = await server.paths.count
            try await attempt(2, envelope: candidate, observer: observer, sink: sink, outcome: .unknown)
            #expect(await observer.directory.generation() == initialGeneration)
            let afterRequests = await server.paths.count
            #expect(afterRequests == beforeRequests + 2)
            for _ in 0..<10 { await observer.maintenance.recoverUnknownPeer() }
            #expect(await server.paths.count == afterRequests)
            await server.setMode(.online)
            try await Task.sleep(for: .milliseconds(2100))
            try await attempt(2, envelope: candidate, observer: observer, sink: sink, outcome: .accepted)
            expectedMessages[candidate.messageID] = try DataCodec().decode(envelope: candidate)
            let recoveredGeneration = try #require(await observer.directory.generation())
            #expect(recoveredGeneration > initialGeneration)
            print("Verified membership generation: \(initialGeneration) -> \(recoveredGeneration); outage refresh requests=\(afterRequests - beforeRequests), ten immediate misses add zero requests")
            #expect(try await sender.pending().isEmpty)
            let refreshedPaths = await server.paths
            #expect(Array(refreshedPaths.suffix(2)) == [RevocationSnapshotHTTPEndpoint.path, ProfileMembershipHTTPEndpoint.path])

            try await trust.removeAndRevoke(nodeID: nodes[2].nodeID, reason: "Disposable integration fixture", now: now.addingTimeInterval(2))
            await server.setMode(.membershipOffline)
            let report = await observer.maintenance.refreshNow(revocationTrigger: .scheduled, membershipTrigger: .scheduled)
            #expect(report.revokedCredentialCount == 1)
            guard case .failed = report.membership else { throw TrustFixtureError.expectedMembershipFailure }
            let revoked = try envelope(2, "revoked-fresh-payload")
            try await sender.enqueue(revoked)
            try await attempt(2, envelope: revoked, observer: observer, sink: sink, outcome: .revoked)
            // Refresh the removal membership before reopening: a persisted pre-removal membership
            // containing a now-revoked credential must not be treated as a valid new snapshot.
            await server.setMode(.online)
            _ = await observer.maintenance.refreshNow(revocationTrigger: .scheduled, membershipTrigger: .scheduled)
            await server.setMode(.offline)
            observer = try await RefreshedObserver.open(root: root, authority: authority, network: network, transport: transport)
            sink = try await DurableTrustSink.open(incomingURL)
            let reopenedAttempt = try envelope(2, "revoked-after-reopen")
            try await sender.enqueue(reopenedAttempt)
            try await attempt(2, envelope: reopenedAttempt, observer: observer, sink: sink, outcome: .revoked)
            let finalControl = try envelope(1, "eligible-after")
            try await sender.enqueue(finalControl)
            try await attempt(1, envelope: finalControl, observer: observer, sink: sink, outcome: .accepted)
            expectedMessages[finalControl.messageID] = try DataCodec().decode(envelope: finalControl)
            let reopened = try await PersistentDataState.open(fileURL: incomingURL)
            let records = await reopened.recordedResults()
            #expect(records.count == expectedMessages.count)
            #expect(Set(records.map(\.messageID)) == Set(expectedMessages.keys))
            for record in records {
                #expect(record.response == expectedMessages[record.messageID])
                #expect(record.idempotencyKey == expectedMessages[record.messageID]?.idempotencyKey)
            }
            let reopenedSender = try await PersistentDataState.open(fileURL: root.appendingPathComponent("outgoing.json"))
            #expect(Set(try await reopenedSender.pending().map(\.messageID)) == [revoked.messageID, reopenedAttempt.messageID])
            #expect(Set(try await sender.pending().map(\.messageID)) == [revoked.messageID, reopenedAttempt.messageID])
            print("Refreshed trust complete: three authorized durable records; two rejected fresh payloads remain pending; HTTPS requests=\(await server.paths.count)")
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }
}

private enum TrustAttempt { case unknown, accepted, revoked }
private enum TrustFixtureError: Error { case closed, timeout, expectedMembershipFailure }

private struct RefreshedObserver {
    let directory: ProfileMembershipDirectory
    let distributor: RevocationSnapshotDistributor
    let maintenance: ProfileTrustMaintenanceController

    static func open(root: URL, authority: CredentialAuthority, network: NetworkID,
                     transport: CurlAuthorityTransport) async throws -> Self {
        let distributor = RevocationSnapshotDistributor(trustedAuthorityPublicKey: authority.publicKeyRepresentation)
        let refresh = RevocationRefreshController(distributor: distributor,
            requester: RevocationSnapshotNetworkClient(transport: transport),
            store: FileRevocationSnapshotStore(fileURL: root.appendingPathComponent("revocations.json")), policy: try .init())
        _ = try await refresh.restorePersistedSnapshot()
        let snapshot = await distributor.latestSnapshot()
        let revoked = try snapshot.map { try RevocationVerifier.verify($0, trustedAuthorityPublicKey: authority.publicKeyRepresentation) } ?? []
        let directory = try await ProfileMembershipDirectory.open(fileURL: root.appendingPathComponent("membership.json"),
            networkID: network, environment: "refresh-test", trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            revokedCredentialIDs: revoked)
        return Self(directory: directory, distributor: distributor, maintenance: ProfileTrustMaintenanceController(
            revocationRefresh: refresh, revocations: distributor, membershipDirectory: directory,
            membershipRefresh: ProfileMembershipRefreshController(directory: directory,
                requester: ProfileMembershipNetworkClient(transport: transport), policy: try .init())))
    }
}

private actor DurableTrustSink {
    let state: PersistentDataState
    private(set) var calls = 0
    init(_ state: PersistentDataState) { self.state = state }
    static func open(_ url: URL) async throws -> DurableTrustSink { try await DurableTrustSink(PersistentDataState.open(fileURL: url)) }
    func initialize() async throws { try await state.clearRecordedResults() }
    func contains(_ id: MessageID) async -> Bool { await state.result(for: id) != nil }
    func record(_ envelope: BeakrNetEnvelope) async -> Bool {
        calls += 1
        do {
            if await state.result(for: envelope.messageID) != nil { return true }
            let message = try DataCodec().decode(envelope: envelope)
            try await state.record(.init(messageID: envelope.messageID, idempotencyKey: message.idempotencyKey,
                                         response: message, completedAt: Date()))
            return true
        } catch { Issue.record("Fixture durable sink failed: \(error)"); return false }
    }
}

/// Test-owned listener; production HTTP codec, signed endpoints and TLS parameters.
/// 503 is a controlled authority outage, not a raw network/packet-loss claim.
private actor RefreshHTTPSFixture {
    enum Mode { case online, offline, membershipOffline }
    private let listener: NWListener
    private let trust: AuthorityTrustStateCoordinator
    private var mode = Mode.online
    private var connections: [UUID: NWConnection] = [:]
    private(set) var paths: [String] = []
    init(identity: SecIdentity, trust: AuthorityTrustStateCoordinator) throws {
        self.trust = trust
        let parameters = try AuthorityServerTLSConfiguration.parameters(localIdentity: identity)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        let (events, continuation) = AsyncStream<Result<UInt16, Error>>.makeStream()
        listener.stateUpdateHandler = { [listener] state in
            if case .ready = state, let port = listener.port { continuation.yield(.success(port.rawValue)) }
            if case .failed(let error) = state { continuation.yield(.failure(error)) }
        }
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.handle(connection) } }
        listener.start(queue: DispatchQueue(label: "Beakr.Tests.TrustHTTPS"))
        let timeout = Task { try? await Task.sleep(for: .seconds(5)); continuation.yield(.failure(TrustFixtureError.timeout)) }
        defer { timeout.cancel(); continuation.finish() }
        for await result in events { return try result.get() }
        throw TrustFixtureError.closed
    }
    func setMode(_ mode: Mode) { self.mode = mode }
    func stop() {
        listener.cancel(); listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }
    private func handle(_ connection: NWConnection) async {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: DispatchQueue(label: "Beakr.Tests.TrustHTTPS.Connection"))
        let timeout = Task { try? await Task.sleep(for: .seconds(5)); connection.cancel() }
        defer { timeout.cancel(); connection.cancel(); connections[id] = nil }
        do {
            var bytes = Data()
            while true {
                let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: TrustFixtureError.closed) }
                    }
                }
                bytes.append(chunk)
                guard bytes.count <= 278532 else { throw AuthorityHTTP1CodecError.bodyTooLarge }
                do {
                    let request = try AuthorityHTTP1Codec.decodeRequest(bytes)
                    paths.append(request.path)
                    let response: CertificateEnrollmentHTTPResponse
                    if mode == .offline || (mode == .membershipOffline && request.path == ProfileMembershipHTTPEndpoint.path) {
                        response = .init(statusCode: 503)
                    } else if request.path == ProfileMembershipHTTPEndpoint.path {
                        response = await trust.membershipEndpoint.handle(request)
                    } else if request.path == RevocationSnapshotHTTPEndpoint.path {
                        response = await trust.revocationEndpoint.handle(request)
                    } else { response = .init(statusCode: 404) }
                    let encoded = AuthorityHTTP1Codec.encodeResponse(response)
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        connection.send(content: encoded, completion: .contentProcessed { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        })
                    }
                    return
                } catch AuthorityHTTP1CodecError.incomplete { continue }
            }
        } catch { /* Client disconnects and fixture shutdown are expected. Request assertions detect missing responses. */ }
    }
}
#endif
