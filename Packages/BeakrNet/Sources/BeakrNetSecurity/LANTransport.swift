import CryptoKit
import Foundation
import BeakrNetCore

public struct LANTransportConfiguration: Sendable {
    public let identity: NodeIdentity
    public let credential: NodeCredential
    public let trustedAuthorityPublicKey: Data
    public let environment: String
    public let revocationSnapshot: CredentialRevocationSnapshot
    public let localCertificateDER: Data
    public let localCertificatePublicKey: Data
    public let capabilities: TransportCapabilities
    public let now: @Sendable () -> Date

    public init(
        identity: NodeIdentity,
        credential: NodeCredential,
        trustedAuthorityPublicKey: Data,
        environment: String,
        revocationSnapshot: CredentialRevocationSnapshot,
        localCertificateDER: Data,
        localCertificatePublicKey: Data,
        capabilities: TransportCapabilities,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.identity = identity
        self.credential = credential
        self.trustedAuthorityPublicKey = trustedAuthorityPublicKey
        self.environment = environment
        self.revocationSnapshot = revocationSnapshot
        self.localCertificateDER = localCertificateDER
        self.localCertificatePublicKey = localCertificatePublicKey
        self.capabilities = capabilities
        self.now = now
    }
}

public enum LANTransportError: Error, Equatable, Sendable {
    case unexpectedHandshakeMessage
    case localIdentityMismatch
    case envelopeTooLarge(maximumBytes: Int, actualBytes: Int)
    case unsupportedEnvelope
    case revokedPeer
    case closed
}

public enum LANTransportDiagnostic: Equatable, Sendable {
    case authenticating(connectionID: UUID, role: LANHandshakeRole)
    case authenticated(connectionID: UUID, peerNodeID: NodeID)
    case authenticationFailed(connectionID: UUID, reason: String)
    case pathLost(connectionID: UUID, reason: String)
    case permissionDenied(component: String)
    case peerRevoked(NodeID)
}

public typealias LANTransportDiagnosticSink = @Sendable (LANTransportDiagnostic) -> Void

public actor LANTransport: BeakrNetTransport, RevocationSnapshotConsumer {
    public nonisolated let id: TransportID
    public nonisolated let kind: TransportKind = .local
    public nonisolated let capabilities: TransportCapabilities
    public nonisolated let peerNodeID: NodeID
    public nonisolated var revocationConsumerID: TransportID { id }

    private let connection: any BonjourConnection
    private let peerCredentialID: UUID
    private let trustedAuthorityPublicKey: Data
    private let now: @Sendable () -> Date
    private let diagnosticSink: LANTransportDiagnosticSink
    private var isClosed = false

    private init(
        connection: any BonjourConnection,
        authentication: LANHandshakeAuthentication,
        trustedAuthorityPublicKey: Data,
        now: @escaping @Sendable () -> Date,
        diagnosticSink: @escaping LANTransportDiagnosticSink
    ) {
        id = TransportID()
        self.connection = connection
        peerNodeID = authentication.peerNodeID
        peerCredentialID = authentication.peerCredentialID
        capabilities = authentication.negotiatedCapabilities
        self.trustedAuthorityPublicKey = trustedAuthorityPublicKey
        self.now = now
        self.diagnosticSink = diagnosticSink
    }

    public static func authenticate(
        connection: any BonjourConnection,
        role: LANHandshakeRole,
        expectedPeerNodeID: NodeID,
        advertisementNonce: Data,
        configuration: LANTransportConfiguration,
        authenticator: LANHandshakeAuthenticator = LANHandshakeAuthenticator(),
        diagnosticSink: @escaping LANTransportDiagnosticSink = { _ in }
    ) async throws -> LANTransport {
        diagnosticSink(.authenticating(connectionID: connection.id, role: role))
        do {
            guard configuration.identity.nodeID == configuration.credential.claims.nodeID else {
                throw LANTransportError.localIdentityMismatch
            }
            let peerCertificate = try connection.peerCertificate()
            let localHello = LANHandshakeHello(
                role: role,
                nodeID: configuration.identity.nodeID,
                credential: configuration.credential,
                nonce: randomNonce(),
                advertisementNonce: advertisementNonce,
                capabilities: configuration.capabilities,
                certificateFingerprint: Data(SHA256.hash(data: configuration.localCertificateDER))
            )
            try await connection.sendFrame(LANHandshakeWireCodec.encode(.hello(localHello)))
            let peerHelloData = try await connection.receiveFrame(maximumBytes: 262_144)
            guard case .hello(let peerHello) = try LANHandshakeWireCodec.decode(peerHelloData) else {
                throw LANTransportError.unexpectedHandshakeMessage
            }

            let localProof = try await authenticator.makeProof(
                identity: configuration.identity,
                localHello: localHello,
                peerHello: peerHello
            )
            try await connection.sendFrame(LANHandshakeWireCodec.encode(.proof(localProof)))
            let peerProofData = try await connection.receiveFrame(maximumBytes: 262_144)
            guard case .proof(let peerProof) = try LANHandshakeWireCodec.decode(peerProofData) else {
                throw LANTransportError.unexpectedHandshakeMessage
            }

            let authentication = try await authenticator.authenticate(
                localHello: localHello,
                peerHello: peerHello,
                peerProof: peerProof,
                expectedPeerNodeID: expectedPeerNodeID,
                expectedAdvertisementNonce: advertisementNonce,
                trustedAuthorityPublicKey: configuration.trustedAuthorityPublicKey,
                environment: configuration.environment,
                revocationSnapshot: configuration.revocationSnapshot,
                localCertificateDER: configuration.localCertificateDER,
                localCertificatePublicKey: configuration.localCertificatePublicKey,
                peerCertificateDER: peerCertificate.derRepresentation,
                peerCertificatePublicKey: peerCertificate.publicKeyRepresentation,
                now: configuration.now()
            )
            diagnosticSink(.authenticated(connectionID: connection.id, peerNodeID: authentication.peerNodeID))
            return LANTransport(
                connection: connection,
                authentication: authentication,
                trustedAuthorityPublicKey: configuration.trustedAuthorityPublicKey,
                now: configuration.now,
                diagnosticSink: diagnosticSink
            )
        } catch {
            connection.cancel()
            diagnosticSink(.authenticationFailed(connectionID: connection.id, reason: String(describing: error)))
            throw error
        }
    }

    public func send(_ envelope: BeakrNetEnvelope) async throws {
        guard !isClosed else { throw LANTransportError.closed }
        try envelope.validate(now: now())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= capabilities.maximumEnvelopeBytes else {
            throw LANTransportError.envelopeTooLarge(
                maximumBytes: capabilities.maximumEnvelopeBytes,
                actualBytes: data.count
            )
        }
        guard capabilities.supports(envelope, envelopeSizeBytes: data.count) else {
            throw LANTransportError.unsupportedEnvelope
        }
        do { try await connection.sendFrame(data) }
        catch {
            isClosed = true
            diagnosticSink(.pathLost(connectionID: connection.id, reason: String(describing: error)))
            throw error
        }
    }

    public func receive() async -> BeakrNetEnvelope? {
        guard !isClosed else { return nil }
        do {
            let data = try await connection.receiveFrame(maximumBytes: capabilities.maximumEnvelopeBytes)
            let envelope = try JSONDecoder().decode(BeakrNetEnvelope.self, from: data)
            try envelope.validate(now: now())
            guard capabilities.supports(envelope, envelopeSizeBytes: data.count) else {
                throw LANTransportError.unsupportedEnvelope
            }
            return envelope
        } catch {
            isClosed = true
            connection.cancel()
            diagnosticSink(.pathLost(connectionID: connection.id, reason: String(describing: error)))
            return nil
        }
    }

    public func installRevocationSnapshot(_ snapshot: CredentialRevocationSnapshot) async throws {
        let revoked = try LANHandshakeAuthenticator.validatedRevokedCredentialIDs(
            in: snapshot,
            trustedAuthorityPublicKey: trustedAuthorityPublicKey,
            now: now()
        )
        guard !revoked.contains(peerCredentialID) else {
            isClosed = true
            connection.cancel()
            diagnosticSink(.peerRevoked(peerNodeID))
            throw LANTransportError.revokedPeer
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
    }

    private static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
