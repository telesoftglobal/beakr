#if os(macOS) && canImport(Network)
import Foundation
import Network
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

@Suite(
    "Apple Network framework integration",
    .enabled(if: ProcessInfo.processInfo.environment["BEAKRNET_RUN_APPLE_NETWORK_INTEGRATION"] == "1"),
    .serialized
)
struct AppleNetworkIntegrationTests {
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

    init() throws {
        let clientCredential = try authority.issue(
            nodeID: clientIdentity.nodeID,
            nodePublicKey: clientIdentity.publicKeyRepresentation,
            networkID: networkID,
            environment: "integration",
            validity: 3_600,
            serviceScopes: ["lan"],
            now: now
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
        let snapshot = try authority.issueRevocationSnapshot(revocations: [], now: now)
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

    func envelope() -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            networkID: networkID,
            sessionID: SessionID(),
            sourceNodeID: clientIdentity.nodeID,
            destinationNodeID: serverIdentity.nodeID,
            sequenceNumber: 1,
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

    init(base: NetworkBonjourConnection, certificate: BonjourPeerCertificate) {
        self.base = base
        self.certificate = certificate
        id = base.id
    }

    func start(stateHandler: @escaping @Sendable (BonjourConnectionState) -> Void) {
        base.start(stateHandler: stateHandler)
    }
    func sendFrame(_ data: Data) async throws { try await base.sendFrame(data) }
    func receiveFrame(maximumBytes: Int) async throws -> Data {
        try await base.receiveFrame(maximumBytes: maximumBytes)
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
