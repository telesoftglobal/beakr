import CryptoKit
import Foundation
import BeakrNetCore

public struct AuthorityRecoverySigner: Sendable {
    private let privateKey: P256.Signing.PrivateKey

    public var publicKeyRepresentation: Data { privateKey.publicKey.x963Representation }
    public var recoveryKeyID: AuthorityID {
        CredentialVerifier.authorityID(for: publicKeyRepresentation)
    }

    public init() {
        privateKey = P256.Signing.PrivateKey()
    }

    public init(privateKeyRepresentation: Data) throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRepresentation)
    }

    public var privateKeyRepresentation: Data { privateKey.rawRepresentation }

    public func issueRecoveryPackage(
        replacementAuthorityPublicKey: Data,
        targetGeneration: UInt64,
        environment: String,
        validity: TimeInterval = 24 * 60 * 60,
        now: Date = Date()
    ) throws -> AuthorityRecoveryPackage {
        guard targetGeneration > 0,
              !environment.isEmpty,
              validity > 0,
              validity <= AuthorityRecoveryVerifier.maximumValidity,
              (try? P256.Signing.PublicKey(
                x963Representation: replacementAuthorityPublicKey
              )) != nil else {
            throw AuthorityRecoveryError.invalidPackage
        }
        let replacementID = CredentialVerifier.authorityID(for: replacementAuthorityPublicKey)
        guard replacementID != recoveryKeyID else {
            throw AuthorityRecoveryError.recoveryKeyCannotBeOperationalAuthority
        }
        let issuedAt = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        let unsigned = AuthorityRecoveryPackage(
            targetGeneration: targetGeneration,
            environment: environment,
            recoveryKeyID: recoveryKeyID,
            replacementAuthorityID: replacementID,
            replacementAuthorityPublicKey: replacementAuthorityPublicKey,
            issuedAtMilliseconds: issuedAt,
            expiresAtMilliseconds: Int64(
                ((now.timeIntervalSince1970 + validity) * 1_000).rounded(.down)
            ),
            recoverySignature: Data()
        )
        return AuthorityRecoveryPackage(
            targetGeneration: unsigned.targetGeneration,
            environment: unsigned.environment,
            recoveryKeyID: unsigned.recoveryKeyID,
            replacementAuthorityID: unsigned.replacementAuthorityID,
            replacementAuthorityPublicKey: unsigned.replacementAuthorityPublicKey,
            issuedAtMilliseconds: unsigned.issuedAtMilliseconds,
            expiresAtMilliseconds: unsigned.expiresAtMilliseconds,
            recoverySignature: try privateKey.signature(
                for: AuthorityRecoveryTranscript.data(for: unsigned)
            ).derRepresentation
        )
    }
}

public struct AuthorityRecoveryPackage: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let targetGeneration: UInt64
    public let environment: String
    public let recoveryKeyID: AuthorityID
    public let replacementAuthorityID: AuthorityID
    public let replacementAuthorityPublicKey: Data
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let recoverySignature: Data

    public init(
        version: Int = Self.currentVersion,
        targetGeneration: UInt64,
        environment: String,
        recoveryKeyID: AuthorityID,
        replacementAuthorityID: AuthorityID,
        replacementAuthorityPublicKey: Data,
        issuedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        recoverySignature: Data
    ) {
        self.version = version
        self.targetGeneration = targetGeneration
        self.environment = environment
        self.recoveryKeyID = recoveryKeyID
        self.replacementAuthorityID = replacementAuthorityID
        self.replacementAuthorityPublicKey = replacementAuthorityPublicKey
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.recoverySignature = recoverySignature
    }
}

public enum AuthorityRecoveryVerifier {
    public static let maximumValidity: TimeInterval = 7 * 24 * 60 * 60

    public static func verify(
        _ package: AuthorityRecoveryPackage,
        trustedRecoveryPublicKey: Data,
        environment: String,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 60
    ) throws {
        guard package.version == AuthorityRecoveryPackage.currentVersion else {
            throw AuthorityRecoveryError.unsupportedVersion
        }
        guard package.environment == environment else {
            throw AuthorityRecoveryError.wrongEnvironment
        }
        guard package.recoveryKeyID == CredentialVerifier.authorityID(
            for: trustedRecoveryPublicKey
        ) else {
            throw AuthorityRecoveryError.wrongRecoveryKey
        }
        guard package.replacementAuthorityID == CredentialVerifier.authorityID(
            for: package.replacementAuthorityPublicKey
        ),
              package.replacementAuthorityID != package.recoveryKeyID,
              (try? P256.Signing.PublicKey(
                x963Representation: package.replacementAuthorityPublicKey
              )) != nil else {
            throw AuthorityRecoveryError.invalidReplacementAuthority
        }
        let validity = package.expiresAtMilliseconds - package.issuedAtMilliseconds
        guard package.targetGeneration > 0,
              validity > 0,
              validity <= Int64(maximumValidity * 1_000) else {
            throw AuthorityRecoveryError.invalidPackage
        }
        let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        let skew = Int64(allowedClockSkew * 1_000)
        guard package.issuedAtMilliseconds <= nowMilliseconds + skew else {
            throw AuthorityRecoveryError.issuedInFuture
        }
        guard package.expiresAtMilliseconds > nowMilliseconds - skew else {
            throw AuthorityRecoveryError.expired
        }
        guard let key = try? P256.Signing.PublicKey(x963Representation: trustedRecoveryPublicKey),
              let signature = try? P256.Signing.ECDSASignature(
                derRepresentation: package.recoverySignature
              ),
              key.isValidSignature(signature, for: AuthorityRecoveryTranscript.data(for: package)) else {
            throw AuthorityRecoveryError.invalidSignature
        }
    }
}

public extension AuthorityTrustState {
    func recovering(
        with package: AuthorityRecoveryPackage,
        trustedRecoveryPublicKey: Data,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 60
    ) throws -> AuthorityTrustState {
        guard package.targetGeneration > generation else {
            throw AuthorityRecoveryError.nonIncreasingGeneration
        }
        try AuthorityRecoveryVerifier.verify(
            package,
            trustedRecoveryPublicKey: trustedRecoveryPublicKey,
            environment: environment,
            now: now,
            allowedClockSkew: allowedClockSkew
        )
        return try AuthorityTrustState(
            generation: package.targetGeneration,
            environment: environment,
            currentAuthorityPublicKey: package.replacementAuthorityPublicKey
        )
    }
}

public enum AuthorityRecoveryError: Error, Equatable, Sendable {
    case unsupportedVersion
    case wrongEnvironment
    case wrongRecoveryKey
    case invalidReplacementAuthority
    case invalidPackage
    case issuedInFuture
    case expired
    case invalidSignature
    case nonIncreasingGeneration
    case recoveryKeyCannotBeOperationalAuthority
}

private enum AuthorityRecoveryTranscript {
    private static let domain = Data("BeakrNet authority recovery v1\0".utf8)

    static func data(for package: AuthorityRecoveryPackage) -> Data {
        var data = domain
        append(UInt64(package.version), to: &data)
        append(package.targetGeneration, to: &data)
        append(package.environment, to: &data)
        append(package.recoveryKeyID.rawValue.uuidString.lowercased(), to: &data)
        append(package.replacementAuthorityID.rawValue.uuidString.lowercased(), to: &data)
        append(package.replacementAuthorityPublicKey, to: &data)
        append(UInt64(bitPattern: package.issuedAtMilliseconds), to: &data)
        append(UInt64(bitPattern: package.expiresAtMilliseconds), to: &data)
        return data
    }

    private static func append(_ value: String, to data: inout Data) {
        append(Data(value.utf8), to: &data)
    }

    private static func append(_ value: Data, to data: inout Data) {
        append(UInt64(value.count), to: &data)
        data.append(value)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        data.append(withUnsafeBytes(of: &bigEndian) { Data($0) })
    }
}
