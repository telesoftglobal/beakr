import Foundation

public struct NodeCredentialClaims: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public let version: Int
    public let credentialID: UUID
    public let issuerID: AuthorityID
    public let networkID: NetworkID
    public let nodeID: NodeID
    public let nodePublicKey: Data
    public let environment: String
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let serviceScopes: [String]

    public init(
        version: Int = Self.currentVersion,
        credentialID: UUID = UUID(),
        issuerID: AuthorityID,
        networkID: NetworkID,
        nodeID: NodeID,
        nodePublicKey: Data,
        environment: String,
        issuedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        serviceScopes: [String] = []
    ) {
        self.version = version
        self.credentialID = credentialID
        self.issuerID = issuerID
        self.networkID = networkID
        self.nodeID = nodeID
        self.nodePublicKey = nodePublicKey
        self.environment = environment
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.serviceScopes = serviceScopes.sorted()
    }
}

public struct NodeCredential: Codable, Equatable, Sendable {
    public let claims: NodeCredentialClaims
    public let issuerSignature: Data

    public init(claims: NodeCredentialClaims, issuerSignature: Data) {
        self.claims = claims
        self.issuerSignature = issuerSignature
    }
}
