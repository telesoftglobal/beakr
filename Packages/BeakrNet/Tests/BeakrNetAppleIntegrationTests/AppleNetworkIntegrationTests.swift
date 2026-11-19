#if os(macOS) && canImport(Network)
import Foundation
import Network
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetData
import BeakrNetSecurity

@Suite(
    "Apple Network framework integration",
    .enabled(if: ProcessInfo.processInfo.environment["BEAKRNET_RUN_APPLE_NETWORK_INTEGRATION"] == "1"),
    .serialized
)
struct AppleNetworkIntegrationTests {
    @Test("Loopback TLS refuses invalid client credentials before admitting a message",
          .timeLimit(.minutes(1)), arguments: InvalidClientCredential.allCases)
    func rejectsInvalidCredentialOnLoopback(_ scenario: InvalidClientCredential) async throws {
        let fixture = try Fixture(loopbackOnly: true, invalidClient: scenario)
        defer { fixture.cancel() }
        let connections = try await fixture.connectLoopback()
        defer { connections.client.cancel(); connections.server.cancel() }
        try await fixture.verifyRejectedClient(connections, expected: scenario.expectedError)
    }

    @Test("Loopback TLS reconnect retries an accepted message once after its acknowledgement is lost",
          .timeLimit(.minutes(1)))
    func lostAcknowledgementOnLoopback() async throws {
        let fixture = try Fixture(loopbackOnly: true)
        defer { fixture.cancel() }
        let firstConnections = try await fixture.connectLoopback()
        defer { firstConnections.client.cancel(); firstConnections.server.cancel() }
        let first = try await fixture.authenticate(firstConnections)
        let envelope = fixture.envelope()
        let sender = BeakrNetSession(id: envelope.sessionID, networkID: envelope.networkID,
                                    localNodeID: envelope.sourceNodeID, remoteNodeID: envelope.destinationNodeID,
                                    state: .active, now: envelope.createdAt)
        let receiver = BeakrNetSession(id: envelope.sessionID, networkID: envelope.networkID,
                                      localNodeID: envelope.destinationNodeID, remoteNodeID: envelope.sourceNodeID,
                                      state: .active, now: envelope.createdAt)
        let routes = PeerRouteCoordinator(networkID: envelope.networkID, remoteNodeID: envelope.destinationNodeID)
        let driver = SessionDeliveryDriver(session: sender, coordinator: routes, clock: { envelope.createdAt })
        let receiverRoutes = PeerRouteCoordinator(networkID: envelope.networkID, remoteNodeID: envelope.sourceNodeID)
        let receiverDriver = SessionDeliveryDriver(session: receiver, coordinator: receiverRoutes, clock: { envelope.createdAt })
        let firstGeneration = await register(first.client, routes: routes, driver: driver)
        let firstReceiverGeneration = await register(first.server, routes: receiverRoutes, driver: receiverDriver)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("outgoing.json")
        let store = try await PersistentDataState.open(fileURL: file, now: envelope.createdAt)
        try await store.enqueue(envelope, now: envelope.createdAt)

        guard case .sent(_, let attempts) = try await driver.deliver(envelope) else {
            Issue.record("Initial TLS send failed"); return
        }
        #expect(attempts == 1)
        let received = try await receive(first.server)
        #expect(received == envelope)
        let accepted = try #require(try await receiverDriver.receive(
            received, receivedOn: first.server.id, generation: firstReceiverGeneration
        ))
        #expect(accepted.acceptance == .accepted)
        #expect(accepted.acknowledgement != nil)
        // Deterministically lose the acknowledgement after acceptance: close the
        // real connection before writing its acknowledgement frame.
        firstConnections.server.cancel()
        let lost = try await receiveOrEnd(first.client)
        #expect(lost == nil)
        #expect(await sender.pendingDelivery(for: envelope.messageID)?.attemptCount == 1)
        let reopened = try await PersistentDataState.open(fileURL: file, now: envelope.createdAt)
        let pending = try await reopened.pending(now: envelope.createdAt)
        #expect(pending == [envelope])
        let retry = try #require(pending.first)
        await driver.unregister(transportID: first.client.id, generation: firstGeneration)
        await receiverDriver.unregister(transportID: first.server.id, generation: firstReceiverGeneration)
        _ = await routes.removeCandidate(transportID: first.client.id, generation: firstGeneration, reason: .connectionFailed)
        _ = await receiverRoutes.removeCandidate(transportID: first.server.id, generation: firstReceiverGeneration, reason: .connectionFailed)
        await first.client.close()
        await first.server.close()

        let secondConnections = try await fixture.connectLoopback()
        defer { secondConnections.client.cancel(); secondConnections.server.cancel() }
        let second = try await fixture.authenticate(secondConnections)
        let secondGeneration = await register(second.client, routes: routes, driver: driver)
        let secondReceiverGeneration = await register(second.server, routes: receiverRoutes, driver: receiverDriver)
        guard case .sent(_, let retryAttempts) = try await driver.deliver(retry) else {
            Issue.record("Reconnected TLS send failed"); return
        }
        #expect(retryAttempts == 2)
        let duplicateEnvelope = try await receive(second.server)
        #expect(duplicateEnvelope == envelope)
        let duplicate = try #require(try await receiverDriver.receive(
            duplicateEnvelope, receivedOn: second.server.id, generation: secondReceiverGeneration
        ))
        #expect(duplicate.acceptance == .duplicate)
        let acknowledgement = try #require(duplicate.acknowledgement)
        let acknowledgementEnvelope = BeakrNetEnvelope(
            networkID: envelope.networkID, sessionID: envelope.sessionID,
            sourceNodeID: envelope.destinationNodeID, destinationNodeID: envelope.sourceNodeID,
            sequenceNumber: 1, channel: .control,
            deliveryPolicy: .init(durability: .ephemeral),
            payloadType: DeliveryAcknowledgement.payloadType,
            payload: try JSONEncoder().encode(acknowledgement), createdAt: envelope.createdAt
        )
        try await second.server.send(acknowledgementEnvelope)
        let acknowledgementReceived = try await receive(second.client)
        #expect(acknowledgementReceived == acknowledgementEnvelope)
        let decoded = try JSONDecoder().decode(DeliveryAcknowledgement.self, from: acknowledgementReceived.payload)
        #expect(!(await driver.acknowledge(decoded, receivedOn: first.client.id, generation: firstGeneration)))
        let cleared = await driver.acknowledge(decoded, receivedOn: second.client.id, generation: secondGeneration)
        try #require(cleared)
        // Test-host bridge to disk; product app acknowledgement wiring is separate.
        #expect(try await reopened.acknowledge(decoded.messageID))
        #expect(await sender.pendingDelivery(for: envelope.messageID) == nil)
        let finalStore = try await PersistentDataState.open(fileURL: file, now: envelope.createdAt)
        #expect(try await finalStore.pending(now: envelope.createdAt).isEmpty)
        let history = await receiver.diagnosticHistory
        #expect(history.filter { if case .envelopeAccepted = $0 { true } else { false } }.count == 1)
        #expect(history.filter { if case .duplicateRejected = $0 { true } else { false } }.count == 1)
        await second.client.close()
        await second.server.close()
        print("E11 message TLS: two connections, two sends with identical envelope, one acceptance, one duplicate, acknowledgement returned over TLS, durable queue empty")
    }

    private func register(_ transport: LANTransport, routes: PeerRouteCoordinator,
                          driver: SessionDeliveryDriver) async -> UInt64 {
        let generation = await routes.beginCandidate(transportID: transport.id, kind: .local,
                                                     capabilities: transport.capabilities)
        #expect(await routes.candidateAuthenticated(transportID: transport.id, generation: generation))
        #expect(await routes.candidateReady(transportID: transport.id, generation: generation))
        await driver.register(transport, generation: generation)
        return generation
    }

    private func receive(_ transport: LANTransport) async throws -> BeakrNetEnvelope {
        let envelope = try await receiveOrEnd(transport)
        return try #require(envelope)
    }

    private func receiveOrEnd(_ transport: LANTransport) async throws -> BeakrNetEnvelope? {
        try await withThrowingTaskGroup(of: BeakrNetEnvelope?.self) { group in
            group.addTask { await transport.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                await transport.close()
                throw IntegrationError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw IntegrationError.streamEnded }
            return result
        }
    }

    @Test("Bonjour, TLS, authenticated handshake, framing, and path-loss diagnostics")
    func loopbackLifecycle() async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        let connections = try await fixture.connect()
        defer {
            connections.client.cancel()
            connections.server.cancel()
        }
        let transports = try await fixture.authenticate(connections)
        let envelope = fixture.envelope()

        try await transports.client.send(envelope)
        #expect(await transports.server.receive() == envelope)

        connections.server.cancel()
        #expect(await transports.client.receive() == nil)
        let diagnostic = try await fixture.diagnostics.next(
            where: { if case .pathLost = $0 { true } else { false } },
            timeout: .seconds(5)
        )
        if case .pathLost = diagnostic {} else {
            Issue.record("Expected path-loss diagnostic")
        }

        await transports.client.close()
        await transports.server.close()
    }
}

enum InvalidClientCredential: CaseIterable, Sendable {
    case expired, revoked, wrongAuthority

    var expectedError: LANHandshakeError {
        switch self {
        case .expired: .expiredCredential
        case .revoked: .revokedCredential
        case .wrongAuthority: .invalidCredential
        }
    }
}

private final class Fixture: @unchecked Sendable {
    struct Connections: Sendable {
        let client: NetworkBonjourConnection
        let server: NetworkBonjourConnection
    }

    struct Transports: Sendable {
        let client: LANTransport
        let server: LANTransport
    }

    let diagnostics = Events<LANTransportDiagnostic>()
    private let browserEvents = Events<BonjourBrowserEvent>()
    private let listenerEvents = Events<BonjourListenerEvent>()
    private let registry = NetworkBonjourEndpointRegistry()
    private let authority = CredentialAuthority()
    private let networkID = NetworkID(
        rawValue: UUID(uuidString: "A1100000-0000-4000-8000-000000000001")!
    )
    private let clientIdentity = NodeIdentity()
    private let serverIdentity = NodeIdentity()
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let nonce = Data(repeating: 0xa5, count: 32)
    private let psk = Data(repeating: 0x42, count: 32)
    private let browser: NetworkBonjourBrowser
    private let listener: NetworkBonjourListener
    private let factory: NetworkBonjourConnectionFactory
    private let clientConfiguration: LANTransportConfiguration
    private let serverConfiguration: LANTransportConfiguration
    private let clientCertificate: BonjourPeerCertificate
    private let serverCertificate: BonjourPeerCertificate
    private var loopbackPort: UInt16?

    init(loopbackOnly: Bool = false, invalidClient: InvalidClientCredential? = nil) throws {
        let clientAuthority = invalidClient == .wrongAuthority ? CredentialAuthority() : authority
        let clientCredential = try clientAuthority.issue(
            nodeID: clientIdentity.nodeID,
            nodePublicKey: clientIdentity.publicKeyRepresentation,
            networkID: networkID,
            environment: "integration",
            validity: 3_600,
            serviceScopes: ["lan"],
            now: invalidClient == .expired ? now.addingTimeInterval(-7_200) : now
        )
        let serverCredential = try authority.issue(
            nodeID: serverIdentity.nodeID,
            nodePublicKey: serverIdentity.publicKeyRepresentation,
            networkID: networkID,
            environment: "integration",
            validity: 3_600,
            serviceScopes: ["lan"],
            now: now
        )
        let revocations = invalidClient == .revoked ? [CredentialRevocation(
            credentialID: clientCredential.claims.credentialID,
            revokedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            reason: "Disposable loopback rejection test"
        )] : []
        let snapshot = try authority.issueRevocationSnapshot(revocations: revocations, now: now)
        let clientDER = Data("integration-client-certificate".utf8)
        let serverDER = Data("integration-server-certificate".utf8)
        clientCertificate = BonjourPeerCertificate(
            derRepresentation: clientDER,
            publicKeyRepresentation: clientIdentity.publicKeyRepresentation
        )
        serverCertificate = BonjourPeerCertificate(
            derRepresentation: serverDER,
            publicKeyRepresentation: serverIdentity.publicKeyRepresentation
        )
        let capabilities = TransportCapabilities(
            maximumEnvelopeBytes: 512_000,
            preservesOrder: true,
            supportsImmediateDelivery: true,
            supportsQueuedDelivery: true,
            supportsBackgroundDelivery: false
        )
        clientConfiguration = LANTransportConfiguration(
            identity: clientIdentity,
            credential: clientCredential,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: networkID,
            environment: "integration",
            revocationSnapshot: snapshot,
            localCertificateDER: clientDER,
            localCertificatePublicKey: clientIdentity.publicKeyRepresentation,
            capabilities: capabilities,
            now: { [now] in now }
        )
        serverConfiguration = LANTransportConfiguration(
            identity: serverIdentity,
            credential: serverCredential,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: networkID,
            environment: "integration",
            revocationSnapshot: snapshot,
            localCertificateDER: serverDER,
            localCertificatePublicKey: serverIdentity.publicKeyRepresentation,
            capabilities: capabilities,
            now: { [now] in now }
        )

        let serviceType = "_beakrtest._tcp"
        if loopbackOnly {
            let parameters = try RelayTLSConfiguration.parameters(preSharedKey: psk)
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = NetworkBonjourListener(listener: try NWListener(using: parameters))
        } else {
            listener = try NetworkBonjourListener(
                parameters: RelayTLSConfiguration.parameters(preSharedKey: psk),
                serviceName: "beakr-\(UUID().uuidString)",
                serviceType: serviceType,
                metadata: BonjourDiscoveryMetadata(
                    protocolMajorVersion: TransportCapabilities.currentProtocolVersion,
                    nodeIDHint: serverIdentity.nodeID,
                    advertisementNonce: nonce
                )
            )
        }
        browser = NetworkBonjourBrowser(
            serviceType: serviceType,
            parameters: .tcp,
            registry: registry
        )
        factory = NetworkBonjourConnectionFactory(registry: registry) { [psk] in
            try! RelayTLSConfiguration.parameters(preSharedKey: psk)
        }
    }

    func connect() async throws -> Connections {
        listener.start { [listenerEvents] in listenerEvents.record($0) }
        browser.start { [browserEvents] in browserEvents.record($0) }
        _ = try await listenerEvents.next(
            where: { if case .state(.ready) = $0 { true } else { false } },
            timeout: .seconds(10)
        )
        let discovered = try await browserEvents.next(
            where: { if case .added = $0 { true } else { false } },
            timeout: .seconds(15)
        )
        guard case .added(let advertisement) = discovered,
              let client = try factory.makeConnection(to: advertisement.endpointID)
                as? NetworkBonjourConnection else {
            throw IntegrationError.unexpectedEvent
        }
        let clientStates = Events<BonjourConnectionState>()
        client.start { clientStates.record($0) }
        let accepted = try await listenerEvents.next(
            where: { if case .connection = $0 { true } else { false } },
            timeout: .seconds(10)
        )
        guard case .connection(let connection) = accepted,
              let server = connection as? NetworkBonjourConnection else {
            throw IntegrationError.unexpectedEvent
        }
        let serverStates = Events<BonjourConnectionState>()
        server.start { serverStates.record($0) }
        _ = try await clientStates.next(where: { $0 == .ready }, timeout: .seconds(10))
        _ = try await serverStates.next(where: { $0 == .ready }, timeout: .seconds(10))
        return Connections(client: client, server: server)
    }

    func connectLoopback() async throws -> Connections {
        if loopbackPort == nil {
            listener.start { [listenerEvents] in listenerEvents.record($0) }
            let ready = try await listenerEvents.next(
                where: { if case .state(.ready) = $0 { true } else { false } }, timeout: .seconds(5)
            )
            guard case .state(.ready(let port)) = ready else { throw IntegrationError.unexpectedEvent }
            loopbackPort = port
        }
        let port = try #require(loopbackPort)
        let endpointPort = try #require(NWEndpoint.Port(rawValue: port))
        let client = NetworkBonjourConnection(connection: NWConnection(
            host: "127.0.0.1", port: endpointPort,
            using: try RelayTLSConfiguration.parameters(preSharedKey: psk)
        ))
        let clientStates = Events<BonjourConnectionState>()
        client.start { clientStates.record($0) }
        do {
            let accepted = try await listenerEvents.next(
                where: { if case .connection = $0 { true } else { false } }, timeout: .seconds(5)
            )
            guard case .connection(let connection) = accepted,
                  let server = connection as? NetworkBonjourConnection else { throw IntegrationError.unexpectedEvent }
            let serverStates = Events<BonjourConnectionState>()
            server.start { serverStates.record($0) }
            do {
                _ = try await clientStates.next(where: { $0 == .ready }, timeout: .seconds(5))
                _ = try await serverStates.next(where: { $0 == .ready }, timeout: .seconds(5))
                return Connections(client: client, server: server)
            } catch { server.cancel(); throw error }
        } catch { client.cancel(); throw error }
    }

    func authenticate(_ pair: Connections) async throws -> Transports {
        let client = TestCertificateConnection(base: pair.client, certificate: serverCertificate)
        let server = TestCertificateConnection(base: pair.server, certificate: clientCertificate)
        async let clientTransport = LANTransport.authenticate(
            connection: client,
            role: .initiator,
            expectedPeerNodeID: serverIdentity.nodeID,
            advertisementNonce: nonce,
            configuration: clientConfiguration,
            diagnosticSink: { [diagnostics] in diagnostics.record($0) }
        )
        async let serverTransport = LANTransport.authenticate(
            connection: server,
            role: .acceptor,
            expectedPeerNodeID: clientIdentity.nodeID,
            advertisementNonce: nonce,
            configuration: serverConfiguration,
            diagnosticSink: { [diagnostics] in diagnostics.record($0) }
        )
        return try await Transports(client: clientTransport, server: serverTransport)
    }

    func verifyRejectedClient(_ pair: Connections, expected: LANHandshakeError) async throws {
        // Queue an application frame directly behind the proof, before the peer's
        // admission decision. TLS is real; certificate metadata is a fixture seam.
        let client = TestCertificateConnection(base: pair.client, certificate: serverCertificate,
                                              frameAfterProof: try JSONEncoder().encode(envelope()))
        let server = TestCertificateConnection(base: pair.server, certificate: clientCertificate)
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            pair.client.cancel()
            pair.server.cancel()
        }
        defer { deadline.cancel() }
        let clientTask = Task {
            do {
                let transport = try await LANTransport.authenticate(
                    connection: client, role: .initiator, expectedPeerNodeID: serverIdentity.nodeID,
                    advertisementNonce: nonce, configuration: clientConfiguration)
                await transport.close()
            } catch {
                // Only the receiver's precise rejection is acceptance evidence.
            }
        }
        do {
            let transport = try await LANTransport.authenticate(
                connection: server, role: .acceptor, expectedPeerNodeID: clientIdentity.nodeID,
                advertisementNonce: nonce, configuration: serverConfiguration,
                diagnosticSink: { [diagnostics] in diagnostics.record($0) })
            Issue.record("Receiver admitted an invalid credential")
            await transport.close()
        } catch {
            #expect(error as? LANHandshakeError == expected)
        }
        await clientTask.value
        let failure = try await diagnostics.next(where: {
            if case .authenticationFailed(let id, _) = $0 { id == pair.server.id } else { false }
        }, timeout: .seconds(2))
        if case .authenticationFailed(_, let reason) = failure {
            #expect(reason == String(describing: expected))
        }
        #expect(server.receivedFrameCount == 2)
        #expect(client.attemptedPayload)
        print("Negative trust loopback: \(expected), receiver read hello/proof only, no admitted transport")
    }

    func envelope() -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            networkID: networkID,
            sessionID: SessionID(),
            sourceNodeID: clientIdentity.nodeID,
            destinationNodeID: serverIdentity.nodeID,
            sequenceNumber: 1,
            deliveryPolicy: .init(durability: .durable, expiresAt: now.addingTimeInterval(60)),
            payloadType: "integration.message",
            payload: Data("real-network-frame".utf8),
            createdAt: now
        )
    }

    func cancel() {
        browser.cancel()
        listener.cancel()
        registry.removeAll()
    }
}

private final class TestCertificateConnection: BonjourConnection, @unchecked Sendable {
    let id: UUID
    private let base: NetworkBonjourConnection
    private let certificate: BonjourPeerCertificate
    private let frameAfterProof: Data?
    private let lock = NSLock()
    private var frameCount = 0
    private var payloadAttempt = false
    var receivedFrameCount: Int { lock.withLock { frameCount } }
    var attemptedPayload: Bool { lock.withLock { payloadAttempt } }

    init(base: NetworkBonjourConnection, certificate: BonjourPeerCertificate, frameAfterProof: Data? = nil) {
        self.base = base
        self.certificate = certificate
        self.frameAfterProof = frameAfterProof
        id = base.id
    }

    func start(stateHandler: @escaping @Sendable (BonjourConnectionState) -> Void) {
        base.start(stateHandler: stateHandler)
    }
    func sendFrame(_ data: Data) async throws {
        try await base.sendFrame(data)
        if let frameAfterProof, case .proof = try LANHandshakeWireCodec.decode(data) {
            lock.withLock { payloadAttempt = true }
            // A peer closing immediately after rejection can fail this write.
            try? await base.sendFrame(frameAfterProof)
        }
    }
    func receiveFrame(maximumBytes: Int) async throws -> Data {
        let frame = try await base.receiveFrame(maximumBytes: maximumBytes)
        lock.withLock { frameCount += 1 }
        return frame
    }
    func peerCertificate() throws -> BonjourPeerCertificate { certificate }
    func cancel() { base.cancel() }
}

private final class Events<Element: Sendable>: @unchecked Sendable {
    private let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func record(_ element: Element) {
        continuation.yield(element)
    }

    func next(
        where predicate: @escaping @Sendable (Element) -> Bool,
        timeout: Duration
    ) async throws -> Element {
        try await withThrowingTaskGroup(of: Element.self) { group in
            group.addTask { [stream] in
                for await element in stream where predicate(element) { return element }
                throw IntegrationError.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw IntegrationError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private enum IntegrationError: Error {
    case streamEnded
    case timedOut
    case unexpectedEvent
}
#endif
