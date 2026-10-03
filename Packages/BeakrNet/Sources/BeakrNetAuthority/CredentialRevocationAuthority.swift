import CryptoKit
import Foundation
import BeakrNetCore

public extension CredentialAuthority {
    func issueRevocationSnapshot(
        revocations: [CredentialRevocation],
        now: Date = Date()
    ) throws -> CredentialRevocationSnapshot {
        let claims = CredentialRevocationClaims(
            issuerID: authorityID,
            generatedAtMilliseconds: Int64(
                (now.timeIntervalSince1970 * 1_000).rounded(.down)
            ),
            revocations: revocations
        )
        let privateKey = try P256.Signing.PrivateKey(
            rawRepresentation: privateKeyRepresentation
        )
        let signature = try privateKey.signature(
            for: RevocationTranscript.data(for: claims)
        )
        return CredentialRevocationSnapshot(
            claims: claims,
            issuerSignature: signature.derRepresentation
        )
    }
}

public enum RevocationVerificationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case wrongIssuer
    case generatedInFuture
    case duplicateCredentialID
    case invalidSignature
}

public enum RevocationVerifier {
    public static func verify(
        _ snapshot: CredentialRevocationSnapshot,
        trustedAuthorityPublicKey: Data,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 60
    ) throws -> Set<UUID> {
        let claims = snapshot.claims
        guard claims.version == CredentialRevocationClaims.currentVersion else {
            throw RevocationVerificationError.unsupportedVersion
        }
        guard claims.issuerID == CredentialVerifier.authorityID(
            for: trustedAuthorityPublicKey
        ) else {
            throw RevocationVerificationError.wrongIssuer
        }
        let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        guard claims.generatedAtMilliseconds <= nowMilliseconds + Int64(allowedClockSkew * 1_000) else {
            throw RevocationVerificationError.generatedInFuture
        }
        let identifiers = claims.revocations.map(\.credentialID)
        guard Set(identifiers).count == identifiers.count else {
            throw RevocationVerificationError.duplicateCredentialID
        }
        guard let publicKey = try? P256.Signing.PublicKey(
            x963Representation: trustedAuthorityPublicKey
        ),
              let signature = try? P256.Signing.ECDSASignature(
                derRepresentation: snapshot.issuerSignature
              ),
              publicKey.isValidSignature(
                signature,
                for: RevocationTranscript.data(for: claims)
              ) else {
            throw RevocationVerificationError.invalidSignature
        }
        return Set(identifiers)
    }
}

private enum RevocationTranscript {
    private static let domain = Data("BeakrNet credential revocations v1\0".utf8)

    static func data(for claims: CredentialRevocationClaims) -> Data {
        var result = domain
        append(UInt64(claims.version), to: &result)
        append(claims.issuerID.rawValue.uuidString.lowercased(), to: &result)
        append(UInt64(bitPattern: claims.generatedAtMilliseconds), to: &result)
        let revocations = claims.revocations.sorted {
            $0.credentialID.uuidString < $1.credentialID.uuidString
        }
        append(UInt64(revocations.count), to: &result)
        for revocation in revocations {
            append(revocation.credentialID.uuidString.lowercased(), to: &result)
            append(UInt64(bitPattern: revocation.revokedAtMilliseconds), to: &result)
            append(revocation.reason, to: &result)
        }
        return result
    }

    private static func append(_ string: String, to data: inout Data) {
        let value = Data(string.utf8)
        append(UInt64(value.count), to: &data)
        data.append(value)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        data.append(withUnsafeBytes(of: &bigEndian) { Data($0) })
    }
}
