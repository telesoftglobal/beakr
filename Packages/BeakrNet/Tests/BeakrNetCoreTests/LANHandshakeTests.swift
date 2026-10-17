import CryptoKit
import Foundation
import Testing
import BeakrNetCore
import BeakrNetSecurity
import BeakrNetAuthority

@Suite("Direct LAN handshake")
struct LANHandshakeTests {
    @Test("Mutual handshake authenticates both peers and has deterministic wire bytes")
    func mutualSuccess() async throws {
        let fixture = try Fixture()
        let initiatorProof = try await fixture.initiatorAuthenticator.makeProof(
            identity: fixture.initiatorIdentity,
            localHello: fixture.initiatorHello,
            peerHello: fixture.acceptorHello
        )
        let acceptorProof = try await fixture.acceptorAuthenticator.makeProof(
            identity: fixture.acceptorIdentity,
            localHello: fixture.acceptorHello,
            peerHello: fixture.initiatorHello
        )

        let acceptedInitiator = try await fixture.authenticateAtAcceptor(proof: initiatorProof)
        let acceptedAcceptor = try await fixture.authenticateAtInitiator(proof: acceptorProof)
        #expect(acceptedInitiator.peerNodeID == fixture.initiatorIdentity.nodeID)
        #expect(acceptedAcceptor.peerNodeID == fixture.acceptorIdentity.nodeID)
        #expect(acceptedInitiator.networkID == .test)
        #expect(acceptedInitiator.negotiatedCapabilities.maximumEnvelopeBytes == 512_000)

        let first = try LANHandshakeWireCodec.encode(.hello(fixture.initiatorHello))
        let second = try LANHandshakeWireCodec.encode(.hello(fixture.initiatorHello))
        #expect(first == second)
        #expect(try LANHandshakeWireCodec.decode(first) == .hello(fixture.initiatorHello))
    }

    @Test("Role confusion is rejected")
    func roleConfusion() async throws {
        let fixture = try Fixture()
        let proof = try await fixture.acceptorProof()
        let confused = fixture.copy(fixture.acceptorHello, role: .initiator)
        await #expect(throws: LANHandshakeError.incorrectRole) {
            try await fixture.authenticateAtInitiator(peerHello: confused, proof: proof)
        }
    }

    @Test("A proof for the wrong peer is rejected")
    func wrongPeer() async throws {
        let fixture = try Fixture()
        let proof = try await fixture.acceptorProof()
        await #expect(throws: LANHandshakeError.wrongPeer) {
            try await fixture.authenticateAtInitiator(
                proof: proof,
                expectedPeer: NodeIdentity().nodeID
            )
        }
    }

    @Test("Credentials from another network cannot authenticate")
    func wrongNetwork() async throws {
        let fixture = try Fixture()
        let proof = try await fixture.acceptorProof()

        await #expect(throws: LANHandshakeError.wrongNetwork) {
            try await fixture.authenticateAtInitiator(
                proof: proof,
                expectedNetworkID: NetworkID()
            )
        }
    }

    @Test("Altered negotiated capabilities invalidate the proof")
    func alteredCapabilities() async throws {
        let fixture = try Fixture()
        let proof = try await fixture.acceptorProof()
        let changed = fixture.copy(
            fixture.acceptorHello,
            capabilities: fixture.capabilities(maximumBytes: 128_000)
        )
        await #expect(throws: LANHandshakeError.capabilityMismatch) {
            try await fixture.authenticateAtInitiator(peerHello: changed, proof: proof)
        }
    }

    @Test("Altered certificate fingerprint is rejected")
    func alteredFingerprint() async throws {
        let fixture = try Fixture()
        let proof = try await fixture.acceptorProof()
        let changed = fixture.copy(
            fixture.acceptorHello,
            certificateFingerprint: Data(repeating: 0x99, count: 32)
        )
        await #expect(throws: LANHandshakeError.certificateFingerprintMismatch) {
            try await fixture.authenticateAtInitiator(peerHello: changed, proof: proof)
        }
    }

    @Test("An accepted proof cannot be replayed")
    func replayedProof() async throws {
        let fixture = try Fixture()
        let proof = try await fixture.acceptorProof()
        _ = try await fixture.authenticateAtInitiator(proof: proof)
        await #expect(throws: LANHandshakeError.replayedProof) {
            try await fixture.authenticateAtInitiator(proof: proof)
        }
    }

    @Test("Invalid authority credential is rejected")
    func invalidCredential() async throws {
        let fixture = try Fixture()
        let invalid = NodeCredential(
            claims: fixture.acceptorCredential.claims,
            issuerSignature: Data(repeating: 0, count: 16)
        )
        let hello = fixture.copy(fixture.acceptorHello, credential: invalid)
        let proof = try await fixture.acceptorAuthenticator.makeProof(
            identity: fixture.acceptorIdentity,
            localHello: hello,
            peerHello: fixture.initiatorHello
        )
        await #expect(throws: LANHandshakeError.invalidCredential) {
            try await fixture.authenticateAtInitiator(peerHello: hello, proof: proof)
        }
    }

    @Test("Expired credential is rejected")
    func expiredCredential() async throws {
        let fixture = try Fixture()
        let expired = try fixture.authority.issue(
            nodeID: fixture.acceptorIdentity.nodeID,
            nodePublicKey: fixture.acceptorIdentity.publicKeyRepresentation,
            networkID: .test,
            environment: fixture.environment,
            validity: 60,
            serviceScopes: ["lan"],
            now: fixture.now.addingTimeInterval(-3_600)
        )
        let hello = fixture.copy(fixture.acceptorHello, credential: expired)
        let proof = try await fixture.acceptorAuthenticator.makeProof(
            identity: fixture.acceptorIdentity,
            localHello: hello,
            peerHello: fixture.initiatorHello
        )
        await #expect(throws: LANHandshakeError.expiredCredential) {
            try await fixture.authenticateAtInitiator(peerHello: hello, proof: proof)
        }
    }

    @Test("Revoked credential is rejected")
    func revokedCredential() async throws {
        let fixture = try Fixture(revokeAcceptor: true)
        let proof = try await fixture.acceptorProof()
        await #expect(throws: LANHandshakeError.revokedCredential) {
            try await fixture.authenticateAtInitiator(proof: proof)
        }
    }

    @Test("Credential without LAN scope is rejected")
    func wrongScope() async throws {
        let fixture = try Fixture(acceptorScopes: ["relay"])
        let proof = try await fixture.acceptorProof()
        await #expect(throws: LANHandshakeError.missingLANScope) {
            try await fixture.authenticateAtInitiator(proof: proof)
        }
    }

    @Test("Stale revocation state fails closed")
    func staleRevocationState() async throws {
        let fixture = try Fixture(snapshotAge: 86_401)
        let proof = try await fixture.acceptorProof()
        await #expect(throws: LANHandshakeError.staleRevocationSnapshot) {
            try await fixture.authenticateAtInitiator(proof: proof, allowedClockSkew: 0)
        }
    }

    @Test("Unsupported handshake and capability versions fail closed")
    func unsupportedVersions() async throws {
        let fixture = try Fixture()
        let proof = try await fixture.acceptorProof()
        let hello = fixture.copy(fixture.acceptorHello, version: 2)
        await #expect(throws: LANHandshakeError.unsupportedVersion) {
            try await fixture.authenticateAtInitiator(peerHello: hello, proof: proof)
        }

        let unsupported = fixture.copy(
            fixture.acceptorHello,
            capabilities: fixture.capabilities(protocolVersion: 2)
        )
        await #expect(throws: LANHandshakeError.unsupportedVersion) {
            try await fixture.authenticateAtInitiator(peerHello: unsupported, proof: proof)
        }
    }

    @Test("Malformed and noncanonical wire messages fail closed")
    func malformedWireMessages() throws {
        #expect(throws: LANHandshakeWireError.malformedMessage) {
            try LANHandshakeWireCodec.decode(Data("{}".utf8))
        }
        let fixture = try Fixture()
        let canonical = try LANHandshakeWireCodec.encode(.hello(fixture.initiatorHello))
        #expect(throws: LANHandshakeWireError.nonCanonicalMessage) {
            try LANHandshakeWireCodec.decode(Data(" \n".utf8) + canonical)
        }
    }
}

private struct Fixture {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let environment = "development"
    let advertisementNonce = Data(repeating: 0xa5, count: 16)
    let initiatorCertificate = Data("initiator certificate".utf8)
    let acceptorCertificate = Data("acceptor certificate".utf8)
    let authority = CredentialAuthority()
    let initiatorIdentity = try! NodeIdentity(
        privateKeyRepresentation: Data(repeating: 0, count: 31) + Data([1])
    )
    let acceptorIdentity = try! NodeIdentity(
        privateKeyRepresentation: Data(repeating: 0, count: 31) + Data([2])
    )
    let initiatorCredential: NodeCredential
    let acceptorCredential: NodeCredential
    let revocationSnapshot: CredentialRevocationSnapshot
    let initiatorHello: LANHandshakeHello
    let acceptorHello: LANHandshakeHello
    let initiatorAuthenticator = LANHandshakeAuthenticator()
    let acceptorAuthenticator = LANHandshakeAuthenticator()

    init(
        acceptorScopes: [String] = ["lan"],
        revokeAcceptor: Bool = false,
        snapshotAge: TimeInterval = 0
    ) throws {
        initiatorCredential = try authority.issue(
            nodeID: initiatorIdentity.nodeID,
            nodePublicKey: initiatorIdentity.publicKeyRepresentation,
            networkID: .test,
            environment: environment,
            validity: 3_600,
            serviceScopes: ["lan"],
            now: now
        )
        acceptorCredential = try authority.issue(
            nodeID: acceptorIdentity.nodeID,
            nodePublicKey: acceptorIdentity.publicKeyRepresentation,
            networkID: .test,
            environment: environment,
            validity: 3_600,
            serviceScopes: acceptorScopes,
            now: now
        )
        let revocations = revokeAcceptor ? [
            CredentialRevocation(
                credentialID: acceptorCredential.claims.credentialID,
                revokedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
                reason: "test"
            )
        ] : []
        revocationSnapshot = try authority.issueRevocationSnapshot(
            revocations: revocations,
            now: now.addingTimeInterval(-snapshotAge)
        )
        initiatorHello = LANHandshakeHello(
            role: .initiator,
            nodeID: initiatorIdentity.nodeID,
            credential: initiatorCredential,
            nonce: Data(repeating: 0x11, count: 32),
            advertisementNonce: advertisementNonce,
            capabilities: Self.makeCapabilities(maximumBytes: 1_048_576),
            certificateFingerprint: Data(SHA256.hash(data: initiatorCertificate))
        )
        acceptorHello = LANHandshakeHello(
            role: .acceptor,
            nodeID: acceptorIdentity.nodeID,
            credential: acceptorCredential,
            nonce: Data(repeating: 0x22, count: 32),
            advertisementNonce: advertisementNonce,
            capabilities: Self.makeCapabilities(maximumBytes: 512_000),
            certificateFingerprint: Data(SHA256.hash(data: acceptorCertificate))
        )
    }

    func acceptorProof() async throws -> LANHandshakeProof {
        try await acceptorAuthenticator.makeProof(
            identity: acceptorIdentity,
            localHello: acceptorHello,
            peerHello: initiatorHello
        )
    }

    func authenticateAtInitiator(
        peerHello: LANHandshakeHello? = nil,
        proof: LANHandshakeProof,
        expectedNetworkID: NetworkID = .test,
        expectedPeer: NodeID? = nil,
        allowedClockSkew: TimeInterval = 60
    ) async throws -> LANHandshakeAuthentication {
        try await initiatorAuthenticator.authenticate(
            localHello: initiatorHello,
            peerHello: peerHello ?? acceptorHello,
            peerProof: proof,
            expectedNetworkID: expectedNetworkID,
            expectedPeerNodeID: expectedPeer ?? acceptorIdentity.nodeID,
            expectedAdvertisementNonce: advertisementNonce,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            environment: environment,
            revocationSnapshot: revocationSnapshot,
            localCertificateDER: initiatorCertificate,
            localCertificatePublicKey: initiatorIdentity.publicKeyRepresentation,
            peerCertificateDER: acceptorCertificate,
            peerCertificatePublicKey: acceptorIdentity.publicKeyRepresentation,
            now: now,
            allowedClockSkew: allowedClockSkew
        )
    }

    func authenticateAtAcceptor(proof: LANHandshakeProof) async throws -> LANHandshakeAuthentication {
        try await acceptorAuthenticator.authenticate(
            localHello: acceptorHello,
            peerHello: initiatorHello,
            peerProof: proof,
            expectedNetworkID: .test,
            expectedPeerNodeID: initiatorIdentity.nodeID,
            expectedAdvertisementNonce: advertisementNonce,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            environment: environment,
            revocationSnapshot: revocationSnapshot,
            localCertificateDER: acceptorCertificate,
            localCertificatePublicKey: acceptorIdentity.publicKeyRepresentation,
            peerCertificateDER: initiatorCertificate,
            peerCertificatePublicKey: initiatorIdentity.publicKeyRepresentation,
            now: now
        )
    }

    func capabilities(
        protocolVersion: Int = TransportCapabilities.currentProtocolVersion,
        maximumBytes: Int = 512_000
    ) -> TransportCapabilities {
        Self.makeCapabilities(protocolVersion: protocolVersion, maximumBytes: maximumBytes)
    }

    private static func makeCapabilities(
        protocolVersion: Int = TransportCapabilities.currentProtocolVersion,
        maximumBytes: Int
    ) -> TransportCapabilities {
        TransportCapabilities(
            protocolVersion: protocolVersion,
            maximumEnvelopeBytes: maximumBytes,
            preservesOrder: true,
            supportsImmediateDelivery: true,
            supportsQueuedDelivery: false,
            supportsBackgroundDelivery: false
        )
    }

    func copy(
        _ hello: LANHandshakeHello,
        version: Int? = nil,
        role: LANHandshakeRole? = nil,
        credential: NodeCredential? = nil,
        capabilities: TransportCapabilities? = nil,
        certificateFingerprint: Data? = nil
    ) -> LANHandshakeHello {
        LANHandshakeHello(
            version: version ?? hello.version,
            role: role ?? hello.role,
            nodeID: hello.nodeID,
            credential: credential ?? hello.credential,
            nonce: hello.nonce,
            advertisementNonce: hello.advertisementNonce,
            capabilities: capabilities ?? hello.capabilities,
            certificateFingerprint: certificateFingerprint ?? hello.certificateFingerprint
        )
    }
}
