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
