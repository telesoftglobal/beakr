import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

@Suite("Authenticated LAN transport")
struct LANTransportTests {
    @Test("Paired loopback transports authenticate and preserve envelopes")
    func authenticatedLoopback() async throws {
        let fixture = try Fixture()
        async let initiator = LANTransport.authenticate(
            connection: fixture.initiatorConnection,
            role: .initiator,
            expectedPeerNodeID: fixture.acceptorIdentity.nodeID,
            advertisementNonce: fixture.advertisementNonce,
            configuration: fixture.initiatorConfiguration
        )
        async let acceptor = LANTransport.authenticate(
            connection: fixture.acceptorConnection,
            role: .acceptor,
            expectedPeerNodeID: fixture.initiatorIdentity.nodeID,
            advertisementNonce: fixture.advertisementNonce,
            configuration: fixture.acceptorConfiguration
        )
        let (left, right) = try await (initiator, acceptor)
        let envelope = fixture.envelope()

        try await left.send(envelope)
        #expect(await right.receive() == envelope)
        #expect(left.capabilities.maximumEnvelopeBytes == 512_000)
    }

    @Test("A dishonest discovery identity never becomes an authenticated transport")
    func wrongExpectedPeer() async throws {
        let fixture = try Fixture()
        let initiator = Task { try await LANTransport.authenticate(
            connection: fixture.initiatorConnection,
            role: .initiator,
            expectedPeerNodeID: NodeIdentity().nodeID,
            advertisementNonce: fixture.advertisementNonce,
            configuration: fixture.initiatorConfiguration
        ) }
        let acceptor = Task { try await LANTransport.authenticate(
            connection: fixture.acceptorConnection,
            role: .acceptor,
            expectedPeerNodeID: fixture.initiatorIdentity.nodeID,
            advertisementNonce: fixture.advertisementNonce,
            configuration: fixture.acceptorConfiguration
        ) }
        await #expect(throws: LANHandshakeError.wrongPeer) { _ = try await initiator.value }
        _ = try? await acceptor.value
        #expect(fixture.initiatorConnection.cancelCount == 1)
    }

    @Test("Installing a signed revocation snapshot disconnects an authenticated peer")
    func liveRevocation() async throws {
        let fixture = try Fixture()
        async let initiator = LANTransport.authenticate(
            connection: fixture.initiatorConnection,
            role: .initiator,
            expectedPeerNodeID: fixture.acceptorIdentity.nodeID,
            advertisementNonce: fixture.advertisementNonce,
            configuration: fixture.initiatorConfiguration
        )
        async let acceptor = LANTransport.authenticate(
            connection: fixture.acceptorConnection,
            role: .acceptor,
            expectedPeerNodeID: fixture.initiatorIdentity.nodeID,
            advertisementNonce: fixture.advertisementNonce,
            configuration: fixture.acceptorConfiguration
        )
        let (transport, _) = try await (initiator, acceptor)
        let snapshot = try fixture.authority.issueRevocationSnapshot(
            revocations: [CredentialRevocation(
                credentialID: fixture.acceptorCredential.claims.credentialID,
                revokedAtMilliseconds: Int64(fixture.now.timeIntervalSince1970 * 1_000),
                reason: "test"
            )],
            now: fixture.now
        )

        await #expect(throws: LANTransportError.revokedPeer) {
            try await transport.installRevocationSnapshot(snapshot)
        }
        #expect(fixture.initiatorConnection.cancelCount == 1)
    }
}

private struct Fixture {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let advertisementNonce = Data(repeating: 0xa5, count: 32)
    let authority = CredentialAuthority()
    let initiatorIdentity = NodeIdentity()
    let acceptorIdentity = NodeIdentity()
    let initiatorCredential: NodeCredential
    let acceptorCredential: NodeCredential
    let initiatorConfiguration: LANTransportConfiguration
    let acceptorConfiguration: LANTransportConfiguration
    let initiatorConnection: LoopbackConnection
    let acceptorConnection: LoopbackConnection

    init() throws {
        initiatorCredential = try authority.issue(
            nodeID: initiatorIdentity.nodeID,
            nodePublicKey: initiatorIdentity.publicKeyRepresentation,
            networkID: .test,
            environment: "test",
            validity: 3_600,
            serviceScopes: ["lan"],
            now: now
        )
        acceptorCredential = try authority.issue(
            nodeID: acceptorIdentity.nodeID,
            nodePublicKey: acceptorIdentity.publicKeyRepresentation,
            networkID: .test,
            environment: "test",
            validity: 3_600,
            serviceScopes: ["lan"],
            now: now
        )
        let snapshot = try authority.issueRevocationSnapshot(revocations: [], now: now)
        let initiatorCertificate = Data("initiator-certificate".utf8)
        let acceptorCertificate = Data("acceptor-certificate".utf8)
        let capabilities = TransportCapabilities(
            maximumEnvelopeBytes: 512_000,
            preservesOrder: true,
            supportsImmediateDelivery: true,
            supportsQueuedDelivery: true,
            supportsBackgroundDelivery: false
        )
        initiatorConfiguration = LANTransportConfiguration(
            identity: initiatorIdentity,
            credential: initiatorCredential,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: .test,
            environment: "test",
            revocationSnapshot: snapshot,
            localCertificateDER: initiatorCertificate,
            localCertificatePublicKey: initiatorIdentity.publicKeyRepresentation,
            capabilities: capabilities,
            now: { [now] in now }
        )
        acceptorConfiguration = LANTransportConfiguration(
            identity: acceptorIdentity,
            credential: acceptorCredential,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: .test,
            environment: "test",
            revocationSnapshot: snapshot,
            localCertificateDER: acceptorCertificate,
            localCertificatePublicKey: acceptorIdentity.publicKeyRepresentation,
            capabilities: capabilities,
            now: { [now] in now }
        )
        let leftInbound = FramePipe()
        let rightInbound = FramePipe()
        initiatorConnection = LoopbackConnection(
            inbound: leftInbound,
            outbound: rightInbound,
            peerCertificate: BonjourPeerCertificate(
                derRepresentation: acceptorCertificate,
                publicKeyRepresentation: acceptorIdentity.publicKeyRepresentation
            )
        )
        acceptorConnection = LoopbackConnection(
            inbound: rightInbound,
            outbound: leftInbound,
            peerCertificate: BonjourPeerCertificate(
                derRepresentation: initiatorCertificate,
                publicKeyRepresentation: initiatorIdentity.publicKeyRepresentation
            )
        )
    }

    func envelope() -> BeakrNetEnvelope {
        BeakrNetEnvelope(
            networkID: .test,
            sessionID: SessionID(),
            sourceNodeID: initiatorIdentity.nodeID,
            destinationNodeID: acceptorIdentity.nodeID,
            sequenceNumber: 1,
            payloadType: "test.message",
            payload: Data("hello".utf8),
            createdAt: now
        )
    }
}

private actor FramePipe {
    private var frames: [Data] = []
    private var waiters: [CheckedContinuation<Data, any Error>] = []

    func send(_ frame: Data) {
        if waiters.isEmpty { frames.append(frame) }
        else { waiters.removeFirst().resume(returning: frame) }
    }

    func receive() async throws -> Data {
        if !frames.isEmpty { return frames.removeFirst() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
}

private final class LoopbackConnection: BonjourConnection, @unchecked Sendable {
    let id = UUID()
    private let inbound: FramePipe
    private let outbound: FramePipe
    private let certificate: BonjourPeerCertificate
    private let lock = NSLock()
    private var cancellationCount = 0

    var cancelCount: Int { lock.withLock { cancellationCount } }

    init(inbound: FramePipe, outbound: FramePipe, peerCertificate: BonjourPeerCertificate) {
        self.inbound = inbound
        self.outbound = outbound
        certificate = peerCertificate
    }

    func start(stateHandler: @escaping @Sendable (BonjourConnectionState) -> Void) {
        stateHandler(.ready)
    }

    func sendFrame(_ data: Data) async throws { await outbound.send(data) }

    func receiveFrame(maximumBytes: Int) async throws -> Data {
        let data = try await inbound.receive()
        guard data.count <= maximumBytes else {
            throw BonjourConnectionIOError.frameTooLarge(maximumBytes: maximumBytes, actualBytes: data.count)
        }
        return data
    }

    func peerCertificate() throws -> BonjourPeerCertificate { certificate }

    func cancel() { lock.withLock { cancellationCount += 1 } }
}
