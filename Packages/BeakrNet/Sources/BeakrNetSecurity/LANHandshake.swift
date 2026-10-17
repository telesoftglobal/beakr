import CryptoKit
import Foundation
import BeakrNetCore

public enum LANHandshakeRole: String, Codable, Sendable {
    case initiator
    case acceptor
}

public struct LANHandshakeHello: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let role: LANHandshakeRole
    public let nodeID: NodeID
    public let credential: NodeCredential
    public let nonce: Data
    public let advertisementNonce: Data
    public let capabilities: TransportCapabilities
    public let certificateFingerprint: Data

    public init(
        version: Int = Self.currentVersion,
        role: LANHandshakeRole,
        nodeID: NodeID,
        credential: NodeCredential,
        nonce: Data,
        advertisementNonce: Data,
        capabilities: TransportCapabilities,
        certificateFingerprint: Data
    ) {
        self.version = version
        self.role = role
        self.nodeID = nodeID
        self.credential = credential
        self.nonce = nonce
        self.advertisementNonce = advertisementNonce
        self.capabilities = capabilities
        self.certificateFingerprint = certificateFingerprint
    }
}

public struct LANHandshakeProof: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let role: LANHandshakeRole
    public let nodeID: NodeID
    public let negotiatedCapabilities: TransportCapabilities
    public let signature: Data

    public init(
        version: Int = Self.currentVersion,
        role: LANHandshakeRole,
        nodeID: NodeID,
        negotiatedCapabilities: TransportCapabilities,
        signature: Data
    ) {
        self.version = version
        self.role = role
        self.nodeID = nodeID
        self.negotiatedCapabilities = negotiatedCapabilities
        self.signature = signature
    }
}

public enum LANHandshakeWireMessage: Equatable, Sendable {
    case hello(LANHandshakeHello)
    case proof(LANHandshakeProof)
}

public enum LANHandshakeWireError: Error, Equatable, Sendable {
    case malformedMessage
    case nonCanonicalMessage
    case unsupportedVersion
}

public enum LANHandshakeWireCodec {
    private struct Container: Codable {
        let wireVersion: Int
        let kind: String
        let hello: LANHandshakeHello?
        let proof: LANHandshakeProof?
    }

    public static func encode(_ message: LANHandshakeWireMessage) throws -> Data {
        let value: Container
        switch message {
        case .hello(let hello):
            value = Container(wireVersion: 1, kind: "hello", hello: hello, proof: nil)
        case .proof(let proof):
            value = Container(wireVersion: 1, kind: "proof", hello: nil, proof: proof)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode(_ data: Data) throws -> LANHandshakeWireMessage {
        guard let value = try? JSONDecoder().decode(Container.self, from: data) else {
            throw LANHandshakeWireError.malformedMessage
        }
        guard value.wireVersion == 1 else {
            throw LANHandshakeWireError.unsupportedVersion
        }
        let message: LANHandshakeWireMessage
        switch (value.kind, value.hello, value.proof) {
        case ("hello", .some(let hello), nil):
            message = .hello(hello)
        case ("proof", nil, .some(let proof)):
            message = .proof(proof)
        default:
            throw LANHandshakeWireError.malformedMessage
        }
        guard try encode(message) == data else {
            throw LANHandshakeWireError.nonCanonicalMessage
        }
        return message
    }
}

public enum LANHandshakeError: Error, Equatable, Sendable {
    case unsupportedVersion
    case incorrectRole
    case wrongPeer
    case wrongLocalIdentity
    case invalidNonce
    case advertisementNonceMismatch
    case capabilityMismatch
    case invalidCredential
    case wrongNetwork
    case wrongEnvironment
    case expiredCredential
    case revokedCredential
    case missingLANScope
    case staleRevocationSnapshot
    case invalidRevocationSnapshot
    case certificateKeyMismatch
    case certificateFingerprintMismatch
    case invalidProof
    case replayedProof
}

public struct LANHandshakeAuthentication: Equatable, Sendable {
    public let networkID: NetworkID
    public let peerNodeID: NodeID
    public let peerCredentialID: UUID
    public let negotiatedCapabilities: TransportCapabilities
}

public actor LANHandshakeAuthenticator {
    public static let requiredScope = "lan"
    public static let maximumRevocationAge: TimeInterval = 86_400
    private var acceptedProofs: Set<Data> = []

    public init() {}

    public nonisolated static func validatedRevokedCredentialIDs(
        in snapshot: CredentialRevocationSnapshot,
        trustedAuthorityPublicKey: Data,
        now: Date,
        allowedClockSkew: TimeInterval = 60,
        maximumAge: TimeInterval = LANHandshakeAuthenticator.maximumRevocationAge
    ) throws -> Set<UUID> {
        try verifySnapshot(
            snapshot,
            authorityKey: trustedAuthorityPublicKey,
            now: now,
            skew: allowedClockSkew,
            maximumAge: maximumAge
        )
    }

    public func makeProof(
        identity: NodeIdentity,
        localHello: LANHandshakeHello,
        peerHello: LANHandshakeHello
    ) throws -> LANHandshakeProof {
        let pair = try Transcript.ordered(localHello, peerHello)
        let capabilities = try Self.negotiate(pair.0.capabilities, pair.1.capabilities)
        let bytes = Transcript.bytes(pair.0, pair.1, capabilities)
        return LANHandshakeProof(
            role: localHello.role,
            nodeID: localHello.nodeID,
            negotiatedCapabilities: capabilities,
            signature: try identity.signature(forLANHandshakeTranscript: bytes)
        )
    }

    public func authenticate(
        localHello: LANHandshakeHello,
        peerHello: LANHandshakeHello,
        peerProof: LANHandshakeProof,
        expectedNetworkID: NetworkID,
        expectedPeerNodeID: NodeID,
        expectedAdvertisementNonce: Data,
        trustedAuthorityPublicKey: Data,
        environment: String,
        revocationSnapshot: CredentialRevocationSnapshot,
        localCertificateDER: Data,
        localCertificatePublicKey: Data,
        peerCertificateDER: Data,
        peerCertificatePublicKey: Data,
        now: Date,
        allowedClockSkew: TimeInterval = 60,
        maximumRevocationAge: TimeInterval = LANHandshakeAuthenticator.maximumRevocationAge
    ) throws -> LANHandshakeAuthentication {
        guard localHello.version == 1, peerHello.version == 1, peerProof.version == 1 else {
            throw LANHandshakeError.unsupportedVersion
        }
        guard localHello.role != peerHello.role, peerProof.role == peerHello.role else {
            throw LANHandshakeError.incorrectRole
        }
        guard localHello.nodeID == localHello.credential.claims.nodeID else {
            throw LANHandshakeError.wrongLocalIdentity
        }
        guard localHello.credential.claims.networkID == expectedNetworkID,
              peerHello.credential.claims.networkID == expectedNetworkID else {
            throw LANHandshakeError.wrongNetwork
        }
        guard peerHello.nodeID == expectedPeerNodeID,
              peerProof.nodeID == expectedPeerNodeID,
              peerHello.credential.claims.nodeID == expectedPeerNodeID else {
            throw LANHandshakeError.wrongPeer
        }
        guard localHello.nonce.count == 32, peerHello.nonce.count == 32,
              localHello.nonce != peerHello.nonce,
              localHello.nonce.contains(where: { $0 != 0 }),
              peerHello.nonce.contains(where: { $0 != 0 }) else {
            throw LANHandshakeError.invalidNonce
        }
        guard !expectedAdvertisementNonce.isEmpty,
              localHello.advertisementNonce == expectedAdvertisementNonce,
              peerHello.advertisementNonce == expectedAdvertisementNonce else {
            throw LANHandshakeError.advertisementNonceMismatch
        }

        let pair = try Transcript.ordered(localHello, peerHello)
        let capabilities = try Self.negotiate(pair.0.capabilities, pair.1.capabilities)
        guard peerProof.negotiatedCapabilities == capabilities else {
            throw LANHandshakeError.capabilityMismatch
        }
        let revoked = try Self.verifySnapshot(
            revocationSnapshot,
            authorityKey: trustedAuthorityPublicKey,
            now: now,
            skew: allowedClockSkew,
            maximumAge: maximumRevocationAge
        )
        try Self.verifyCredential(
            localHello.credential, authorityKey: trustedAuthorityPublicKey,
            environment: environment, revoked: revoked, now: now, skew: allowedClockSkew
        )
        try Self.verifyCredential(
            peerHello.credential, authorityKey: trustedAuthorityPublicKey,
            environment: environment, revoked: revoked, now: now, skew: allowedClockSkew
        )
        guard localHello.credential.claims.serviceScopes.contains(Self.requiredScope),
              peerHello.credential.claims.serviceScopes.contains(Self.requiredScope) else {
            throw LANHandshakeError.missingLANScope
        }
        guard localHello.credential.claims.nodePublicKey == localCertificatePublicKey,
              peerHello.credential.claims.nodePublicKey == peerCertificatePublicKey else {
            throw LANHandshakeError.certificateKeyMismatch
        }
        guard localHello.certificateFingerprint == Data(SHA256.hash(data: localCertificateDER)),
              peerHello.certificateFingerprint == Data(SHA256.hash(data: peerCertificateDER)) else {
            throw LANHandshakeError.certificateFingerprintMismatch
        }

        let transcript = Transcript.bytes(pair.0, pair.1, capabilities)
        guard NodeIdentity.verifyLANHandshakeProof(
            publicKeyRepresentation: peerHello.credential.claims.nodePublicKey,
            transcript: transcript,
            signature: peerProof.signature
        ) else {
            throw LANHandshakeError.invalidProof
        }
        var replayMaterial = transcript
        replayMaterial.append(peerProof.signature)
        let replayKey = Data(SHA256.hash(data: replayMaterial))
        guard acceptedProofs.insert(replayKey).inserted else {
            throw LANHandshakeError.replayedProof
        }
        return LANHandshakeAuthentication(
            networkID: expectedNetworkID,
            peerNodeID: peerHello.nodeID,
            peerCredentialID: peerHello.credential.claims.credentialID,
            negotiatedCapabilities: capabilities
        )
    }

    private static func negotiate(
        _ first: TransportCapabilities,
        _ second: TransportCapabilities
    ) throws -> TransportCapabilities {
        guard first.protocolVersion == TransportCapabilities.currentProtocolVersion,
              second.protocolVersion == TransportCapabilities.currentProtocolVersion else {
            throw LANHandshakeError.unsupportedVersion
        }
        let channels = first.supportedChannels.intersection(second.supportedChannels)
        let representations = first.supportedRepresentations.intersection(second.supportedRepresentations)
        guard !channels.isEmpty, !representations.isEmpty,
              first.preservesOrder, second.preservesOrder,
              first.supportsImmediateDelivery, second.supportsImmediateDelivery,
              first.maximumEnvelopeBytes > 0, second.maximumEnvelopeBytes > 0 else {
            throw LANHandshakeError.capabilityMismatch
        }
        return TransportCapabilities(
            supportedChannels: channels,
            supportedRepresentations: representations,
            maximumEnvelopeBytes: min(first.maximumEnvelopeBytes, second.maximumEnvelopeBytes),
            preservesOrder: true,
            supportsImmediateDelivery: true,
            supportsQueuedDelivery: first.supportsQueuedDelivery && second.supportsQueuedDelivery,
            supportsBackgroundDelivery: first.supportsBackgroundDelivery && second.supportsBackgroundDelivery
        )
    }

    private static func verifyCredential(
        _ credential: NodeCredential,
        authorityKey: Data,
        environment: String,
        revoked: Set<UUID>,
        now: Date,
        skew: TimeInterval
    ) throws {
        let claims = credential.claims
        guard claims.version == NodeCredentialClaims.currentVersion,
              claims.issuerID == authorityID(authorityKey),
              NodeIdentity.nodeID(forPublicKeyRepresentation: claims.nodePublicKey) == claims.nodeID,
              claims.expiresAtMilliseconds > claims.issuedAtMilliseconds else {
            throw LANHandshakeError.invalidCredential
        }
        guard claims.environment == environment else { throw LANHandshakeError.wrongEnvironment }
        guard !revoked.contains(claims.credentialID) else { throw LANHandshakeError.revokedCredential }
        let nowMS = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        let skewMS = Int64(skew * 1_000)
        guard claims.issuedAtMilliseconds <= nowMS + skewMS,
              claims.expiresAtMilliseconds > nowMS - skewMS else {
            throw LANHandshakeError.expiredCredential
        }
        guard let key = try? P256.Signing.PublicKey(x963Representation: authorityKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: credential.issuerSignature),
              key.isValidSignature(signature, for: credentialBytes(claims)) else {
            throw LANHandshakeError.invalidCredential
        }
    }

    private static func verifySnapshot(
        _ snapshot: CredentialRevocationSnapshot,
        authorityKey: Data,
        now: Date,
        skew: TimeInterval,
        maximumAge: TimeInterval
    ) throws -> Set<UUID> {
        let claims = snapshot.claims
        let nowMS = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        let skewMS = Int64(skew * 1_000)
        guard claims.version == CredentialRevocationClaims.currentVersion,
              claims.issuerID == authorityID(authorityKey),
              claims.generatedAtMilliseconds <= nowMS + skewMS else {
            throw LANHandshakeError.invalidRevocationSnapshot
        }
        guard nowMS - claims.generatedAtMilliseconds <= Int64(maximumAge * 1_000) + skewMS else {
            throw LANHandshakeError.staleRevocationSnapshot
        }
        let ids = claims.revocations.map(\.credentialID)
        guard Set(ids).count == ids.count,
              let key = try? P256.Signing.PublicKey(x963Representation: authorityKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: snapshot.issuerSignature),
              key.isValidSignature(signature, for: revocationBytes(claims)) else {
            throw LANHandshakeError.invalidRevocationSnapshot
        }
        return Set(ids)
    }

    private static func authorityID(_ key: Data) -> AuthorityID {
        var bytes = Array(SHA256.hash(data: Data("BeakrNet authority v1\0".utf8) + key).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let string = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        return AuthorityID(rawValue: UUID(uuidString: string)!)
    }

    private static func credentialBytes(_ claims: NodeCredentialClaims) -> Data {
        var data = Data("BeakrNet node credential v2\0".utf8)
        Binary.append(UInt64(claims.version), to: &data)
        Binary.append(claims.credentialID.uuidString.lowercased(), to: &data)
        Binary.append(claims.issuerID.rawValue.uuidString.lowercased(), to: &data)
        Binary.append(claims.networkID.rawValue.uuidString.lowercased(), to: &data)
        Binary.append(claims.nodeID.rawValue.uuidString.lowercased(), to: &data)
        Binary.append(claims.nodePublicKey, to: &data)
        Binary.append(claims.environment, to: &data)
        Binary.append(UInt64(bitPattern: claims.issuedAtMilliseconds), to: &data)
        Binary.append(UInt64(bitPattern: claims.expiresAtMilliseconds), to: &data)
        Binary.append(UInt64(claims.serviceScopes.count), to: &data)
        claims.serviceScopes.sorted().forEach { Binary.append($0, to: &data) }
        return data
    }

    private static func revocationBytes(_ claims: CredentialRevocationClaims) -> Data {
        var data = Data("BeakrNet credential revocations v1\0".utf8)
        Binary.append(UInt64(claims.version), to: &data)
        Binary.append(claims.issuerID.rawValue.uuidString.lowercased(), to: &data)
        Binary.append(UInt64(bitPattern: claims.generatedAtMilliseconds), to: &data)
        let values = claims.revocations.sorted { $0.credentialID.uuidString < $1.credentialID.uuidString }
        Binary.append(UInt64(values.count), to: &data)
        for value in values {
            Binary.append(value.credentialID.uuidString.lowercased(), to: &data)
            Binary.append(UInt64(bitPattern: value.revokedAtMilliseconds), to: &data)
            Binary.append(value.reason, to: &data)
        }
        return data
    }
}

private enum Transcript {
    static func ordered(
        _ first: LANHandshakeHello,
        _ second: LANHandshakeHello
    ) throws -> (LANHandshakeHello, LANHandshakeHello) {
        if first.role == .initiator && second.role == .acceptor { return (first, second) }
        if first.role == .acceptor && second.role == .initiator { return (second, first) }
        throw LANHandshakeError.incorrectRole
    }

    static func bytes(
        _ initiator: LANHandshakeHello,
        _ acceptor: LANHandshakeHello,
        _ capabilities: TransportCapabilities
    ) -> Data {
        var data = Data("BeakrNet direct LAN handshake v1\0".utf8)
        Binary.append(UInt64(LANHandshakeHello.currentVersion), to: &data)
        appendParty(initiator, to: &data)
        appendParty(acceptor, to: &data)
        Binary.append(initiator.advertisementNonce, to: &data)
        Binary.append(UInt64(capabilities.protocolVersion), to: &data)
        let channels = capabilities.supportedChannels.map(\.rawValue).sorted()
        Binary.append(UInt64(channels.count), to: &data)
        channels.forEach { Binary.append($0, to: &data) }
        let representations = capabilities.supportedRepresentations.map(\.rawValue).sorted()
        Binary.append(UInt64(representations.count), to: &data)
        representations.forEach { Binary.append($0, to: &data) }
        Binary.append(UInt64(capabilities.maximumEnvelopeBytes), to: &data)
        Binary.append(capabilities.preservesOrder, to: &data)
        Binary.append(capabilities.supportsImmediateDelivery, to: &data)
        Binary.append(capabilities.supportsQueuedDelivery, to: &data)
        Binary.append(capabilities.supportsBackgroundDelivery, to: &data)
        Binary.append(initiator.certificateFingerprint, to: &data)
        Binary.append(acceptor.certificateFingerprint, to: &data)
        return data
    }

    private static func appendParty(_ hello: LANHandshakeHello, to data: inout Data) {
        Binary.append(hello.role.rawValue, to: &data)
        Binary.append(hello.nodeID.rawValue.uuidString.lowercased(), to: &data)
        Binary.append(hello.credential.claims.credentialID.uuidString.lowercased(), to: &data)
        Binary.append(hello.nonce, to: &data)
    }
}

private enum Binary {
    static func append(_ string: String, to data: inout Data) {
        append(Data(string.utf8), to: &data)
    }

    static func append(_ value: Bool, to data: inout Data) {
        data.append(value ? 1 : 0)
    }

    static func append(_ value: UInt64, to data: inout Data) {
        var value = value.bigEndian
        data.append(withUnsafeBytes(of: &value) { Data($0) })
    }

    static func append(_ value: Data, to data: inout Data) {
        append(UInt64(value.count), to: &data)
        data.append(value)
    }
}
