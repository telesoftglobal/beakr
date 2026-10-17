import CryptoKit
import Foundation
import BeakrNetCore

public struct NodeIdentity: Sendable {
    private static let proofDomain = Data("BeakrNet relay registration v1\0".utf8)

    private let privateKey: P256.Signing.PrivateKey

    public var nodeID: NodeID {
        Self.nodeID(forPublicKeyRepresentation: publicKeyRepresentation)
    }

    public var publicKeyRepresentation: Data {
        privateKey.publicKey.x963Representation
    }

    public var privateKeyRepresentation: Data {
        privateKey.rawRepresentation
    }

    public init() {
        privateKey = P256.Signing.PrivateKey()
    }

    public init(privateKeyRepresentation: Data) throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRepresentation)
    }

    public func signature(forRegistrationChallenge challenge: Data) throws -> Data {
        let signature = try privateKey.signature(
            for: Self.registrationProofPayload(nodeID: nodeID, challenge: challenge)
        )
        return signature.derRepresentation
    }

    public func signature(forLANHandshakeTranscript transcript: Data) throws -> Data {
        try privateKey.signature(for: transcript).derRepresentation
    }

    public func signature(forCertificateEnrollmentTranscript transcript: Data) throws -> Data {
        try privateKey.signature(for: transcript).derRepresentation
    }

    /// Creates a PKCS#10 request whose public key is this identity's P-256 key.
    public func certificateSigningRequest(commonName: String) throws -> Data {
        let subject = Self.der(0x30, Self.der(0x31,
            Self.der(0x30,
                Data([0x06, 0x03, 0x55, 0x04, 0x03])
                    + Self.der(0x0c, Data(commonName.utf8))
            )
        ))
        let publicKeyInfo = Data([
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
            0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
            0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
            0x42, 0x00
        ]) + publicKeyRepresentation
        let requestInfo = Self.der(0x30, Data([0x02, 0x01, 0x00]) + subject + publicKeyInfo + Data([0xa0, 0x00]))
        let signature = try privateKey.signature(for: requestInfo).derRepresentation
        let algorithm = Data([0x30, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02])
        return Self.der(0x30, requestInfo + algorithm + Self.der(0x03, Data([0x00]) + signature))
    }

    public static func verifyLANHandshakeProof(
        publicKeyRepresentation: Data,
        transcript: Data,
        signature: Data
    ) -> Bool {
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyRepresentation),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: transcript)
    }

    public static func verifyCertificateEnrollmentSignature(
        publicKeyRepresentation: Data,
        transcript: Data,
        signature: Data
    ) -> Bool {
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyRepresentation),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: transcript)
    }

    public static func verifyRegistrationProof(
        nodeID: NodeID,
        publicKeyRepresentation: Data,
        challenge: Data,
        signature: Data
    ) -> Bool {
        guard nodeID == self.nodeID(forPublicKeyRepresentation: publicKeyRepresentation),
              let publicKey = try? P256.Signing.PublicKey(
                x963Representation: publicKeyRepresentation
              ),
              let signature = try? P256.Signing.ECDSASignature(
                derRepresentation: signature
              ) else {
            return false
        }

        return publicKey.isValidSignature(
            signature,
            for: registrationProofPayload(nodeID: nodeID, challenge: challenge)
        )
    }

    public static func nodeID(forPublicKeyRepresentation representation: Data) -> NodeID {
        var bytes = Array(SHA256.hash(data: representation).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        return NodeID(rawValue: UUID(uuidString: uuidString)!)
    }

    private static func registrationProofPayload(
        nodeID: NodeID,
        challenge: Data
    ) -> Data {
        var payload = proofDomain
        payload.append(Data(nodeID.rawValue.uuidString.lowercased().utf8))
        payload.append(0)
        payload.append(challenge)
        return payload
    }

    private static func der(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        if content.count < 128 {
            result.append(UInt8(content.count))
        } else {
            var length = content.count
            var bytes: [UInt8] = []
            while length > 0 {
                bytes.insert(UInt8(length & 0xff), at: 0)
                length >>= 8
            }
            result.append(0x80 | UInt8(bytes.count))
            result.append(contentsOf: bytes)
        }
        result.append(content)
        return result
    }
}

public struct FileNodeIdentityStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadOrCreate() throws -> NodeIdentity {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try NodeIdentity(privateKeyRepresentation: Data(contentsOf: fileURL))
        }

        let identity = NodeIdentity()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try identity.privateKeyRepresentation.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        return identity
    }
}
