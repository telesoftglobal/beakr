import CryptoKit
import Foundation
import BeakrNetCore
import BeakrNetSecurity

public struct CredentialAuthority: Sendable {
    private let privateKey: P256.Signing.PrivateKey

    public var authorityID: AuthorityID {
        CredentialVerifier.authorityID(for: publicKeyRepresentation)
    }

    public var privateKeyRepresentation: Data { privateKey.rawRepresentation }
    public var publicKeyRepresentation: Data { privateKey.publicKey.x963Representation }

    public init() {
        privateKey = P256.Signing.PrivateKey()
    }

    public init(privateKeyRepresentation: Data) throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRepresentation)
    }

    func signature(forCertificateEnrollmentResponse transcript: Data) throws -> Data {
        try privateKey.signature(for: transcript).derRepresentation
    }

    func signature(forNetworkInvitation transcript: Data) throws -> Data {
        try privateKey.signature(for: transcript).derRepresentation
    }

    public func issue(
        nodeID: NodeID,
        nodePublicKey: Data,
        networkID: NetworkID,
        environment: String,
        validity: TimeInterval,
        serviceScopes: [String] = [],
        now: Date = Date()
    ) throws -> NodeCredential {
        let issuedAt = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        let expiresAt = Int64(((now.timeIntervalSince1970 + validity) * 1_000).rounded(.down))
        let claims = NodeCredentialClaims(
            issuerID: authorityID,
            networkID: networkID,
            nodeID: nodeID,
            nodePublicKey: nodePublicKey,
            environment: environment,
            issuedAtMilliseconds: issuedAt,
            expiresAtMilliseconds: expiresAt,
            serviceScopes: serviceScopes
        )
        let signature = try privateKey.signature(for: CredentialTranscript.data(for: claims))
        return NodeCredential(claims: claims, issuerSignature: signature.derRepresentation)
    }
}

public enum CredentialVerificationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case wrongIssuer
    case invalidSignature
    case nodeIdentityMismatch
    case wrongNetwork
    case wrongEnvironment
    case revoked
    case issuedInFuture
    case expired
    case invalidValidityWindow
}

public enum CredentialVerifier {
    public static func verify(
        _ credential: NodeCredential,
        trustedAuthorityPublicKey: Data,
        networkID: NetworkID,
        environment: String,
        revokedCredentialIDs: Set<UUID> = [],
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 60
    ) throws {
        let claims = credential.claims
        guard claims.version == NodeCredentialClaims.currentVersion else {
            throw CredentialVerificationError.unsupportedVersion
        }
        guard claims.issuerID == authorityID(for: trustedAuthorityPublicKey) else {
            throw CredentialVerificationError.wrongIssuer
        }
        guard NodeIdentity.nodeID(
            forPublicKeyRepresentation: claims.nodePublicKey
        ) == claims.nodeID else {
            throw CredentialVerificationError.nodeIdentityMismatch
        }
        guard claims.networkID == networkID else {
            throw CredentialVerificationError.wrongNetwork
        }
        guard claims.environment == environment else {
            throw CredentialVerificationError.wrongEnvironment
        }
        guard !revokedCredentialIDs.contains(claims.credentialID) else {
            throw CredentialVerificationError.revoked
        }
        guard claims.expiresAtMilliseconds > claims.issuedAtMilliseconds else {
            throw CredentialVerificationError.invalidValidityWindow
        }

        let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        let skewMilliseconds = Int64(allowedClockSkew * 1_000)
        guard claims.issuedAtMilliseconds <= nowMilliseconds + skewMilliseconds else {
            throw CredentialVerificationError.issuedInFuture
        }
        guard claims.expiresAtMilliseconds > nowMilliseconds - skewMilliseconds else {
            throw CredentialVerificationError.expired
        }

        guard let publicKey = try? P256.Signing.PublicKey(
            x963Representation: trustedAuthorityPublicKey
        ),
              let signature = try? P256.Signing.ECDSASignature(
                derRepresentation: credential.issuerSignature
              ),
              publicKey.isValidSignature(signature, for: CredentialTranscript.data(for: claims)) else {
            throw CredentialVerificationError.invalidSignature
        }
    }

    public static func authorityID(for publicKey: Data) -> AuthorityID {
        let digest = SHA256.hash(data: Data("BeakrNet authority v1\0".utf8) + publicKey)
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        return AuthorityID(rawValue: UUID(uuidString: uuidString)!)
    }
}

private enum CredentialTranscript {
    private static let domain = Data("BeakrNet node credential v2\0".utf8)

    static func data(for claims: NodeCredentialClaims) -> Data {
        var result = domain
        append(UInt64(claims.version), to: &result)
        append(claims.credentialID.uuidString.lowercased(), to: &result)
        append(claims.issuerID.rawValue.uuidString.lowercased(), to: &result)
        append(claims.networkID.rawValue.uuidString.lowercased(), to: &result)
        append(claims.nodeID.rawValue.uuidString.lowercased(), to: &result)
        append(claims.nodePublicKey, to: &result)
        append(claims.environment, to: &result)
        append(UInt64(bitPattern: claims.issuedAtMilliseconds), to: &result)
        append(UInt64(bitPattern: claims.expiresAtMilliseconds), to: &result)
        append(UInt64(claims.serviceScopes.count), to: &result)
        for scope in claims.serviceScopes.sorted() {
            append(scope, to: &result)
        }
        return result
    }

    private static func append(_ string: String, to data: inout Data) {
        append(Data(string.utf8), to: &data)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        data.append(withUnsafeBytes(of: &bigEndian) { Data($0) })
    }

    private static func append(_ value: Data, to data: inout Data) {
        append(UInt64(value.count), to: &data)
        data.append(value)
    }
}
