import CryptoKit
import Foundation
import BeakrNetCore

public struct AuthorityRotationStatement: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let generation: UInt64
    public let environment: String
    public let previousAuthorityID: AuthorityID
    public let nextAuthorityID: AuthorityID
    public let nextAuthorityPublicKey: Data
    public let issuedAtMilliseconds: Int64
    public let overlapEndsAtMilliseconds: Int64
    public let previousAuthoritySignature: Data

    public init(
        version: Int = Self.currentVersion,
        generation: UInt64,
        environment: String,
        previousAuthorityID: AuthorityID,
        nextAuthorityID: AuthorityID,
        nextAuthorityPublicKey: Data,
        issuedAtMilliseconds: Int64,
        overlapEndsAtMilliseconds: Int64,
        previousAuthoritySignature: Data
    ) {
        self.version = version
        self.generation = generation
        self.environment = environment
        self.previousAuthorityID = previousAuthorityID
        self.nextAuthorityID = nextAuthorityID
        self.nextAuthorityPublicKey = nextAuthorityPublicKey
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.overlapEndsAtMilliseconds = overlapEndsAtMilliseconds
        self.previousAuthoritySignature = previousAuthoritySignature
    }
}

public extension CredentialAuthority {
    func issueRotationStatement(
        nextAuthorityPublicKey: Data,
        generation: UInt64,
        environment: String,
        overlapDuration: TimeInterval,
        now: Date = Date()
    ) throws -> AuthorityRotationStatement {
        guard generation > 0,
              !environment.isEmpty,
              overlapDuration > 0,
              overlapDuration <= AuthorityRotationVerifier.maximumOverlapDuration,
              (try? P256.Signing.PublicKey(x963Representation: nextAuthorityPublicKey)) != nil else {
            throw AuthorityRotationError.invalidStatement
        }
        let issuedAt = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        let overlapEnds = Int64(
            ((now.timeIntervalSince1970 + overlapDuration) * 1_000).rounded(.down)
        )
        let unsigned = AuthorityRotationStatement(
            generation: generation,
            environment: environment,
            previousAuthorityID: authorityID,
            nextAuthorityID: CredentialVerifier.authorityID(for: nextAuthorityPublicKey),
            nextAuthorityPublicKey: nextAuthorityPublicKey,
            issuedAtMilliseconds: issuedAt,
            overlapEndsAtMilliseconds: overlapEnds,
            previousAuthoritySignature: Data()
        )
        let key = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRepresentation)
        return AuthorityRotationStatement(
            generation: unsigned.generation,
            environment: unsigned.environment,
            previousAuthorityID: unsigned.previousAuthorityID,
            nextAuthorityID: unsigned.nextAuthorityID,
            nextAuthorityPublicKey: unsigned.nextAuthorityPublicKey,
            issuedAtMilliseconds: unsigned.issuedAtMilliseconds,
            overlapEndsAtMilliseconds: unsigned.overlapEndsAtMilliseconds,
            previousAuthoritySignature: try key.signature(
                for: AuthorityRotationTranscript.data(for: unsigned)
            ).derRepresentation
        )
    }
}

public enum AuthorityRotationVerifier {
    public static let maximumOverlapDuration: TimeInterval = 90 * 24 * 60 * 60

    public static func verify(
        _ statement: AuthorityRotationStatement,
        trustedPreviousAuthorityPublicKey: Data,
        environment: String,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 60
    ) throws {
        guard statement.version == AuthorityRotationStatement.currentVersion else {
            throw AuthorityRotationError.unsupportedVersion
        }
        guard statement.environment == environment else {
            throw AuthorityRotationError.wrongEnvironment
        }
        guard statement.previousAuthorityID == CredentialVerifier.authorityID(
            for: trustedPreviousAuthorityPublicKey
        ) else {
            throw AuthorityRotationError.wrongPreviousAuthority
        }
        guard statement.nextAuthorityID == CredentialVerifier.authorityID(
            for: statement.nextAuthorityPublicKey
        ),
              statement.nextAuthorityID != statement.previousAuthorityID,
              (try? P256.Signing.PublicKey(
                x963Representation: statement.nextAuthorityPublicKey
              )) != nil else {
            throw AuthorityRotationError.invalidNextAuthority
        }
        let overlap = statement.overlapEndsAtMilliseconds - statement.issuedAtMilliseconds
        guard statement.generation > 0,
              overlap > 0,
              overlap <= Int64(maximumOverlapDuration * 1_000) else {
            throw AuthorityRotationError.invalidStatement
        }
        let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        guard statement.issuedAtMilliseconds <= nowMilliseconds + Int64(allowedClockSkew * 1_000) else {
            throw AuthorityRotationError.issuedInFuture
        }
        guard statement.overlapEndsAtMilliseconds > nowMilliseconds - Int64(allowedClockSkew * 1_000) else {
            throw AuthorityRotationError.transitionExpired
        }
        guard let key = try? P256.Signing.PublicKey(
            x963Representation: trustedPreviousAuthorityPublicKey
        ),
              let signature = try? P256.Signing.ECDSASignature(
                derRepresentation: statement.previousAuthoritySignature
              ),
              key.isValidSignature(signature, for: AuthorityRotationTranscript.data(for: statement)) else {
            throw AuthorityRotationError.invalidSignature
        }
    }
}

public struct AuthorityTrustState: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let environment: String
    public let currentAuthorityPublicKey: Data
    public let previousAuthorityPublicKey: Data?
    public let previousAuthorityRetiresAtMilliseconds: Int64?

    public init(
        generation: UInt64 = 0,
        environment: String,
        currentAuthorityPublicKey: Data,
        previousAuthorityPublicKey: Data? = nil,
        previousAuthorityRetiresAtMilliseconds: Int64? = nil
    ) throws {
        guard !environment.isEmpty,
              (try? P256.Signing.PublicKey(x963Representation: currentAuthorityPublicKey)) != nil,
              (previousAuthorityPublicKey == nil) == (previousAuthorityRetiresAtMilliseconds == nil),
              previousAuthorityPublicKey.flatMap({ try? P256.Signing.PublicKey(x963Representation: $0) })
                != nil || previousAuthorityPublicKey == nil else {
            throw AuthorityRotationError.invalidTrustState
        }
        self.generation = generation
        self.environment = environment
        self.currentAuthorityPublicKey = currentAuthorityPublicKey
        self.previousAuthorityPublicKey = previousAuthorityPublicKey
        self.previousAuthorityRetiresAtMilliseconds = previousAuthorityRetiresAtMilliseconds
    }

    public func applying(
        _ statement: AuthorityRotationStatement,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 60
    ) throws -> AuthorityTrustState {
        guard generation < UInt64.max, statement.generation == generation + 1 else {
            throw AuthorityRotationError.nonSequentialGeneration
        }
        try AuthorityRotationVerifier.verify(
            statement,
            trustedPreviousAuthorityPublicKey: currentAuthorityPublicKey,
            environment: environment,
            now: now,
            allowedClockSkew: allowedClockSkew
        )
        return try AuthorityTrustState(
            generation: statement.generation,
            environment: environment,
            currentAuthorityPublicKey: statement.nextAuthorityPublicKey,
            previousAuthorityPublicKey: currentAuthorityPublicKey,
            previousAuthorityRetiresAtMilliseconds: statement.overlapEndsAtMilliseconds
        )
    }

    public func trustedAuthorityPublicKeys(at date: Date = Date()) -> [Data] {
        var keys = [currentAuthorityPublicKey]
        let milliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
        if let previousAuthorityPublicKey,
           let retirement = previousAuthorityRetiresAtMilliseconds,
           milliseconds < retirement {
            keys.append(previousAuthorityPublicKey)
        }
        return keys
    }

    public func publicKey(for authorityID: AuthorityID, at date: Date = Date()) -> Data? {
        trustedAuthorityPublicKeys(at: date).first {
            CredentialVerifier.authorityID(for: $0) == authorityID
        }
    }
}

public extension AuthorityTrustState {
    func verify(
        _ credential: NodeCredential,
        networkID: NetworkID,
        environment: String,
        revokedCredentialIDs: Set<UUID> = [],
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 60
    ) throws {
        guard let key = publicKey(for: credential.claims.issuerID, at: now) else {
            throw CredentialVerificationError.wrongIssuer
        }
        try CredentialVerifier.verify(
            credential,
            trustedAuthorityPublicKey: key,
            networkID: networkID,
            environment: environment,
            revokedCredentialIDs: revokedCredentialIDs,
            now: now,
            allowedClockSkew: allowedClockSkew
        )
    }

    func verify(
        _ snapshot: CredentialRevocationSnapshot,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 60
    ) throws -> Set<UUID> {
        guard let key = publicKey(for: snapshot.claims.issuerID, at: now) else {
            throw RevocationVerificationError.wrongIssuer
        }
        return try RevocationVerifier.verify(
            snapshot,
            trustedAuthorityPublicKey: key,
            now: now,
            allowedClockSkew: allowedClockSkew
        )
    }

    func verify(
        _ response: CertificateEnrollmentResponse,
        for request: CertificateEnrollmentRequest,
        at date: Date = Date()
    ) throws {
        guard let key = publicKey(for: response.authorityID, at: date) else {
            throw CertificateEnrollmentResponseError.wrongIssuer
        }
        try CertificateEnrollmentResponseVerifier.verify(
            response,
            for: request,
            trustedAuthorityPublicKey: key
        )
    }
}

public enum AuthorityRotationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case wrongEnvironment
    case wrongPreviousAuthority
    case invalidNextAuthority
    case invalidStatement
    case issuedInFuture
    case transitionExpired
    case invalidSignature
    case nonSequentialGeneration
    case invalidTrustState
}

private enum AuthorityRotationTranscript {
    private static let domain = Data("BeakrNet authority rotation v1\0".utf8)

    static func data(for statement: AuthorityRotationStatement) -> Data {
        var data = domain
        append(UInt64(statement.version), to: &data)
        append(statement.generation, to: &data)
        append(statement.environment, to: &data)
        append(statement.previousAuthorityID.rawValue.uuidString.lowercased(), to: &data)
        append(statement.nextAuthorityID.rawValue.uuidString.lowercased(), to: &data)
        append(statement.nextAuthorityPublicKey, to: &data)
        append(UInt64(bitPattern: statement.issuedAtMilliseconds), to: &data)
        append(UInt64(bitPattern: statement.overlapEndsAtMilliseconds), to: &data)
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
