import Foundation

public struct CredentialRevocation: Codable, Equatable, Sendable {
    public let credentialID: UUID
    public let revokedAtMilliseconds: Int64
    public let reason: String

    public init(
        credentialID: UUID,
        revokedAtMilliseconds: Int64,
        reason: String
    ) {
        self.credentialID = credentialID
        self.revokedAtMilliseconds = revokedAtMilliseconds
        self.reason = reason
    }
}

public struct CredentialRevocationClaims: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let issuerID: AuthorityID
    public let generatedAtMilliseconds: Int64
    public let revocations: [CredentialRevocation]

    public init(
        version: Int = Self.currentVersion,
        issuerID: AuthorityID,
        generatedAtMilliseconds: Int64,
        revocations: [CredentialRevocation]
    ) {
        self.version = version
        self.issuerID = issuerID
        self.generatedAtMilliseconds = generatedAtMilliseconds
        self.revocations = revocations.sorted {
            $0.credentialID.uuidString < $1.credentialID.uuidString
        }
    }
}

public struct CredentialRevocationSnapshot: Codable, Equatable, Sendable {
    public let claims: CredentialRevocationClaims
    public let issuerSignature: Data

    public init(claims: CredentialRevocationClaims, issuerSignature: Data) {
        self.claims = claims
        self.issuerSignature = issuerSignature
    }
}
