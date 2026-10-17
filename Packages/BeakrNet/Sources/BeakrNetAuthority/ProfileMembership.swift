import CryptoKit
import Foundation
import BeakrNetCore

public struct ProfileMembershipRecord: Codable, Equatable, Sendable {
    public let credential: NodeCredential
    public let certificatePublicKey: Data
    public let sessionID: SessionID

    public init(credential: NodeCredential, certificatePublicKey: Data, sessionID: SessionID) {
        self.credential = credential
        self.certificatePublicKey = certificatePublicKey
        self.sessionID = sessionID
    }
}

public struct ProfileMembershipClaims: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public let version: Int
    public let networkID: NetworkID
    public let networkDisplayName: String
    public let generation: UInt64
    public let generatedAtMilliseconds: Int64
    public let records: [ProfileMembershipRecord]

    public init(
        version: Int = Self.currentVersion,
        networkID: NetworkID,
        networkDisplayName: String = "Network",
        generation: UInt64,
        generatedAtMilliseconds: Int64,
        records: [ProfileMembershipRecord]
    ) {
        self.version = version
        self.networkID = networkID
        self.networkDisplayName = networkDisplayName
        self.generation = generation
        self.generatedAtMilliseconds = generatedAtMilliseconds
        self.records = records.sorted {
            $0.credential.claims.nodeID.rawValue.uuidString <
            $1.credential.claims.nodeID.rawValue.uuidString
        }
    }
}

public struct ProfileMembershipSnapshot: Codable, Equatable, Sendable {
    public let claims: ProfileMembershipClaims
    public let authoritySignature: Data

    public init(claims: ProfileMembershipClaims, authoritySignature: Data) {
        self.claims = claims
        self.authoritySignature = authoritySignature
    }
}

public enum ProfileMembershipVerificationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case wrongNetwork
    case invalidNetworkDisplayName
    case generatedInFuture
    case capacityExceeded
    case duplicateNode
    case duplicateCredential
    case duplicateCertificateKey
    case duplicateSession
    case certificateCredentialMismatch
    case invalidSignature
}

public struct ProfileMembershipAuthority: Sendable {
    private let privateKey: P256.Signing.PrivateKey

    public init(privateKeyRepresentation: Data) throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRepresentation)
    }

    public func sign(_ claims: ProfileMembershipClaims) throws -> ProfileMembershipSnapshot {
        let signature = try privateKey.signature(for: Self.transcript(claims))
        return ProfileMembershipSnapshot(
            claims: claims,
            authoritySignature: signature.derRepresentation
        )
    }

    fileprivate static func transcript(_ claims: ProfileMembershipClaims) throws -> Data {
        var data = Data("BeakrNet profile membership v1\0".utf8)
        data.append(try canonicalEncoder().encode(claims))
        return data
    }

    public static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public enum ProfileMembershipVerifier {
    public static func verify(
        _ snapshot: ProfileMembershipSnapshot,
        networkID: NetworkID,
        environment: String,
        trustedAuthorityPublicKey: Data,
        revokedCredentialIDs: Set<UUID>,
        maximumRecords: Int = 1_024,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 60
    ) throws {
        let claims = snapshot.claims
        guard claims.version == ProfileMembershipClaims.currentVersion else {
            throw ProfileMembershipVerificationError.unsupportedVersion
        }
        guard claims.networkID == networkID else {
            throw ProfileMembershipVerificationError.wrongNetwork
        }
        guard !claims.networkDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              claims.networkDisplayName.utf8.count <= NetworkProfile.maximumDisplayNameBytes else {
            throw ProfileMembershipVerificationError.invalidNetworkDisplayName
        }
        guard claims.records.count <= maximumRecords else {
            throw ProfileMembershipVerificationError.capacityExceeded
        }
        let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        guard claims.generatedAtMilliseconds <= nowMilliseconds + Int64(allowedClockSkew * 1_000) else {
            throw ProfileMembershipVerificationError.generatedInFuture
        }
        let nodeIDs = claims.records.map { $0.credential.claims.nodeID }
        let credentialIDs = claims.records.map { $0.credential.claims.credentialID }
        let certificateKeys = claims.records.map(\.certificatePublicKey)
        let sessionIDs = claims.records.map(\.sessionID)
        guard Set(nodeIDs).count == nodeIDs.count else {
            throw ProfileMembershipVerificationError.duplicateNode
        }
        guard Set(credentialIDs).count == credentialIDs.count else {
            throw ProfileMembershipVerificationError.duplicateCredential
        }
        guard Set(certificateKeys).count == certificateKeys.count else {
            throw ProfileMembershipVerificationError.duplicateCertificateKey
        }
        guard Set(sessionIDs).count == sessionIDs.count else {
            throw ProfileMembershipVerificationError.duplicateSession
        }
        for record in claims.records {
            let credential = record.credential
            guard record.certificatePublicKey == credential.claims.nodePublicKey else {
                throw ProfileMembershipVerificationError.certificateCredentialMismatch
            }
            try CredentialVerifier.verify(
                credential,
                trustedAuthorityPublicKey: trustedAuthorityPublicKey,
                networkID: networkID,
                environment: environment,
                revokedCredentialIDs: revokedCredentialIDs,
                now: now,
                allowedClockSkew: allowedClockSkew
            )
        }
        guard let key = try? P256.Signing.PublicKey(x963Representation: trustedAuthorityPublicKey),
              let signature = try? P256.Signing.ECDSASignature(
                derRepresentation: snapshot.authoritySignature
              ),
              key.isValidSignature(signature, for: try ProfileMembershipAuthority.transcript(claims))
        else {
            throw ProfileMembershipVerificationError.invalidSignature
        }
    }
}
