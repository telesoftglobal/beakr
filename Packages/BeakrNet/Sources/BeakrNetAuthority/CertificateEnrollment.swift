import CryptoKit
import Foundation
import BeakrNetCore
import BeakrNetSecurity

public struct CertificateEnrollmentChallenge: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let challengeID: UUID
    public let authorityID: AuthorityID
    public let environment: String
    public let nonce: Data
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64

    public init(
        version: Int = Self.currentVersion,
        challengeID: UUID = UUID(),
        authorityID: AuthorityID,
        environment: String,
        nonce: Data,
        issuedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64
    ) {
        self.version = version
        self.challengeID = challengeID
        self.authorityID = authorityID
        self.environment = environment
        self.nonce = nonce
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
    }
}

public struct CertificateEnrollmentRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let requestID: UUID
    public let nodeID: NodeID
    public let nodePublicKey: Data
    public let certificateSigningRequestDER: Data
    public let credential: NodeCredential
    public let environment: String
    public let challenge: CertificateEnrollmentChallenge
    public let requestedValiditySeconds: UInt64
    public let signature: Data

    public init(
        version: Int = Self.currentVersion,
        requestID: UUID = UUID(),
        nodeID: NodeID,
        nodePublicKey: Data,
        certificateSigningRequestDER: Data = Data(),
        credential: NodeCredential,
        environment: String,
        challenge: CertificateEnrollmentChallenge,
        requestedValiditySeconds: UInt64,
        signature: Data
    ) {
        self.version = version
        self.requestID = requestID
        self.nodeID = nodeID
        self.nodePublicKey = nodePublicKey
        self.certificateSigningRequestDER = certificateSigningRequestDER
        self.credential = credential
        self.environment = environment
        self.challenge = challenge
        self.requestedValiditySeconds = requestedValiditySeconds
        self.signature = signature
    }

    public static func signed(
        requestID: UUID = UUID(),
        identity: NodeIdentity,
        credential: NodeCredential,
        environment: String,
        challenge: CertificateEnrollmentChallenge,
        requestedValidity: TimeInterval
    ) throws -> CertificateEnrollmentRequest {
        guard requestedValidity > 0, requestedValidity <= TimeInterval(UInt64.max) else {
            throw CertificateEnrollmentError.invalidRequestedValidity
        }
        let seconds = UInt64(requestedValidity.rounded(.down))
        let unsigned = CertificateEnrollmentRequest(
            requestID: requestID,
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            certificateSigningRequestDER: try identity.certificateSigningRequest(
                commonName: "BeakrNet Node \(identity.nodeID.rawValue.uuidString.lowercased())"
            ),
            credential: credential,
            environment: environment,
            challenge: challenge,
            requestedValiditySeconds: seconds,
            signature: Data()
        )
        return CertificateEnrollmentRequest(
            requestID: requestID,
            nodeID: unsigned.nodeID,
            nodePublicKey: unsigned.nodePublicKey,
            certificateSigningRequestDER: unsigned.certificateSigningRequestDER,
            credential: credential,
            environment: environment,
            challenge: challenge,
            requestedValiditySeconds: seconds,
            signature: try identity.signature(
                forCertificateEnrollmentTranscript: CertificateEnrollmentTranscript.data(for: unsigned)
            )
        )
    }
}

public struct ValidatedCertificateEnrollment: Equatable, Sendable {
    public let requestID: UUID
    public let nodeID: NodeID
    public let nodePublicKey: Data
    public let certificateSigningRequestDER: Data
    public let validity: TimeInterval

    public init(
        requestID: UUID,
        nodeID: NodeID,
        nodePublicKey: Data,
        certificateSigningRequestDER: Data,
        validity: TimeInterval
    ) {
        self.requestID = requestID
        self.nodeID = nodeID
        self.nodePublicKey = nodePublicKey
        self.certificateSigningRequestDER = certificateSigningRequestDER
        self.validity = validity
    }
}

public struct IssuedCertificateMaterial: Equatable, Sendable {
    public let leafCertificateDER: Data
    public let certificateChainDER: [Data]

    public init(leafCertificateDER: Data, certificateChainDER: [Data]) {
        self.leafCertificateDER = leafCertificateDER
        self.certificateChainDER = certificateChainDER
    }
}

public protocol CertificateMaterialIssuing: Sendable {
    func issueCertificate(
        nodeID: NodeID,
        nodePublicKey: Data,
        certificateSigningRequestDER: Data,
        validity: TimeInterval,
        now: Date
    ) async throws -> IssuedCertificateMaterial
}

public actor CertificateEnrollmentService {
    private let validator: CertificateEnrollmentValidator
    private let authority: CredentialAuthority
    private let issuer: any CertificateMaterialIssuing

    public init(
        validator: CertificateEnrollmentValidator,
        authority: CredentialAuthority,
        issuer: any CertificateMaterialIssuing
    ) {
        self.validator = validator
        self.authority = authority
        self.issuer = issuer
    }

    public func enroll(
        _ request: CertificateEnrollmentRequest,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 60
    ) async throws -> CertificateEnrollmentResponse {
        let enrollment = try await validator.validate(
            request,
            now: now,
            allowedClockSkew: allowedClockSkew
        )
        let material = try await issuer.issueCertificate(
            nodeID: enrollment.nodeID,
            nodePublicKey: enrollment.nodePublicKey,
            certificateSigningRequestDER: enrollment.certificateSigningRequestDER,
            validity: enrollment.validity,
            now: now
        )
        return try authority.issueCertificateEnrollmentResponse(
            for: enrollment,
            leafCertificateDER: material.leafCertificateDER,
            certificateChainDER: material.certificateChainDER,
            now: now
        )
    }
}

public struct CertificateEnrollmentResponse: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let requestID: UUID
    public let authorityID: AuthorityID
    public let nodeID: NodeID
    public let nodePublicKey: Data
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let leafCertificateDER: Data
    public let certificateChainDER: [Data]
    public let authoritySignature: Data

    public init(
        version: Int = Self.currentVersion,
        requestID: UUID,
        authorityID: AuthorityID,
        nodeID: NodeID,
        nodePublicKey: Data,
        issuedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        leafCertificateDER: Data,
        certificateChainDER: [Data],
        authoritySignature: Data
    ) {
        self.version = version
        self.requestID = requestID
        self.authorityID = authorityID
        self.nodeID = nodeID
        self.nodePublicKey = nodePublicKey
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.leafCertificateDER = leafCertificateDER
        self.certificateChainDER = certificateChainDER
        self.authoritySignature = authoritySignature
    }
}

public extension CredentialAuthority {
    func issueCertificateEnrollmentResponse(
        for enrollment: ValidatedCertificateEnrollment,
        leafCertificateDER: Data,
        certificateChainDER: [Data],
        now: Date = Date()
    ) throws -> CertificateEnrollmentResponse {
        guard !leafCertificateDER.isEmpty else {
            throw CertificateEnrollmentResponseError.missingLeafCertificate
        }
        guard certificateChainDER.allSatisfy({ !$0.isEmpty }) else {
            throw CertificateEnrollmentResponseError.invalidCertificateChain
        }
        let issuedAt = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        let expiresAt = Int64(
            ((now.timeIntervalSince1970 + enrollment.validity) * 1_000).rounded(.down)
        )
        let unsigned = CertificateEnrollmentResponse(
            requestID: enrollment.requestID,
            authorityID: authorityID,
            nodeID: enrollment.nodeID,
            nodePublicKey: enrollment.nodePublicKey,
            issuedAtMilliseconds: issuedAt,
            expiresAtMilliseconds: expiresAt,
            leafCertificateDER: leafCertificateDER,
            certificateChainDER: certificateChainDER,
            authoritySignature: Data()
        )
        return CertificateEnrollmentResponse(
            requestID: unsigned.requestID,
            authorityID: unsigned.authorityID,
            nodeID: unsigned.nodeID,
            nodePublicKey: unsigned.nodePublicKey,
            issuedAtMilliseconds: unsigned.issuedAtMilliseconds,
            expiresAtMilliseconds: unsigned.expiresAtMilliseconds,
            leafCertificateDER: unsigned.leafCertificateDER,
            certificateChainDER: unsigned.certificateChainDER,
            authoritySignature: try signature(
                forCertificateEnrollmentResponse: CertificateEnrollmentResponseTranscript.data(
                    for: unsigned
                )
            )
        )
    }
}

public enum CertificateEnrollmentResponseError: Error, Equatable, Sendable {
    case unsupportedVersion
    case wrongIssuer
    case wrongRequest
    case nodeIdentityMismatch
    case invalidValidityWindow
    case excessiveValidity
    case missingLeafCertificate
    case invalidCertificateChain
    case invalidSignature
}

public enum CertificateEnrollmentResponseVerifier {
    public static func verify(
        _ response: CertificateEnrollmentResponse,
        for request: CertificateEnrollmentRequest,
        trustedAuthorityPublicKey: Data
    ) throws {
        guard response.version == CertificateEnrollmentResponse.currentVersion else {
            throw CertificateEnrollmentResponseError.unsupportedVersion
        }
        guard response.authorityID == CredentialVerifier.authorityID(
            for: trustedAuthorityPublicKey
        ) else {
            throw CertificateEnrollmentResponseError.wrongIssuer
        }
        guard response.requestID == request.requestID else {
            throw CertificateEnrollmentResponseError.wrongRequest
        }
        guard response.nodeID == request.nodeID,
              response.nodePublicKey == request.nodePublicKey,
              NodeIdentity.nodeID(forPublicKeyRepresentation: response.nodePublicKey)
                == response.nodeID else {
            throw CertificateEnrollmentResponseError.nodeIdentityMismatch
        }
        guard response.expiresAtMilliseconds > response.issuedAtMilliseconds else {
            throw CertificateEnrollmentResponseError.invalidValidityWindow
        }
        let validity = response.expiresAtMilliseconds - response.issuedAtMilliseconds
        guard request.requestedValiditySeconds <= UInt64(Int64.max / 1_000),
              validity <= Int64(request.requestedValiditySeconds) * 1_000 else {
            throw CertificateEnrollmentResponseError.excessiveValidity
        }
        guard !response.leafCertificateDER.isEmpty else {
            throw CertificateEnrollmentResponseError.missingLeafCertificate
        }
        guard response.certificateChainDER.allSatisfy({ !$0.isEmpty }) else {
            throw CertificateEnrollmentResponseError.invalidCertificateChain
        }
        guard let publicKey = try? P256.Signing.PublicKey(
            x963Representation: trustedAuthorityPublicKey
        ),
              let signature = try? P256.Signing.ECDSASignature(
                derRepresentation: response.authoritySignature
              ),
              publicKey.isValidSignature(
                signature,
                for: CertificateEnrollmentResponseTranscript.data(for: response)
              ) else {
            throw CertificateEnrollmentResponseError.invalidSignature
        }
    }
}

public enum CertificateEnrollmentWireError: Error, Equatable, Sendable {
    case malformedRequest
    case nonCanonicalRequest
}

public enum CertificateEnrollmentWireCodec {
    public static func encode(_ request: CertificateEnrollmentRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }

    public static func decode(_ data: Data) throws -> CertificateEnrollmentRequest {
        guard let request = try? JSONDecoder().decode(
            CertificateEnrollmentRequest.self,
            from: data
        ) else {
            throw CertificateEnrollmentWireError.malformedRequest
        }
        guard try encode(request) == data else {
            throw CertificateEnrollmentWireError.nonCanonicalRequest
        }
        return request
    }
}

public enum CertificateEnrollmentResponseWireCodec {
    public static func encode(_ response: CertificateEnrollmentResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(response)
    }

    public static func decode(_ data: Data) throws -> CertificateEnrollmentResponse {
        guard let response = try? JSONDecoder().decode(
            CertificateEnrollmentResponse.self,
            from: data
        ) else {
            throw CertificateEnrollmentWireError.malformedRequest
        }
        guard try encode(response) == data else {
            throw CertificateEnrollmentWireError.nonCanonicalRequest
        }
        return response
    }
}

public enum CertificateEnrollmentError: Error, Equatable, Sendable {
    case unsupportedVersion
    case wrongAuthority
    case wrongEnvironment
    case invalidChallenge
    case challengeIssuedInFuture
    case expiredChallenge
    case replayedChallenge
    case invalidCredential
    case missingLANScope
    case nodeIdentityMismatch
    case invalidRequestedValidity
    case invalidSignature
}

public actor CertificateEnrollmentValidator {
    public static let maximumCertificateValidity: TimeInterval = 30 * 24 * 60 * 60
    public static let maximumChallengeLifetime: TimeInterval = 5 * 60

    private let authorityID: AuthorityID
    private let trustedAuthorityPublicKey: Data
    private let networkID: NetworkID
    private let environment: String
    private var consumedChallengeIDs: Set<UUID> = []

    public init(
        trustedAuthorityPublicKey: Data,
        networkID: NetworkID,
        environment: String
    ) {
        self.trustedAuthorityPublicKey = trustedAuthorityPublicKey
        self.authorityID = CredentialVerifier.authorityID(for: trustedAuthorityPublicKey)
        self.networkID = networkID
        self.environment = environment
    }

    public func validate(
        _ request: CertificateEnrollmentRequest,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 60
    ) throws -> ValidatedCertificateEnrollment {
        guard request.version == CertificateEnrollmentRequest.currentVersion,
              request.challenge.version == CertificateEnrollmentChallenge.currentVersion else {
            throw CertificateEnrollmentError.unsupportedVersion
        }
        guard request.challenge.authorityID == authorityID else {
            throw CertificateEnrollmentError.wrongAuthority
        }
        guard request.environment == environment,
              request.challenge.environment == environment else {
            throw CertificateEnrollmentError.wrongEnvironment
        }
        guard request.challenge.nonce.count == 32,
              request.challenge.nonce.contains(where: { $0 != 0 }),
              request.challenge.expiresAtMilliseconds > request.challenge.issuedAtMilliseconds,
              request.challenge.expiresAtMilliseconds - request.challenge.issuedAtMilliseconds
                <= Int64(Self.maximumChallengeLifetime * 1_000) else {
            throw CertificateEnrollmentError.invalidChallenge
        }

        let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        let skewMilliseconds = Int64(allowedClockSkew * 1_000)
        guard request.challenge.issuedAtMilliseconds <= nowMilliseconds + skewMilliseconds else {
            throw CertificateEnrollmentError.challengeIssuedInFuture
        }
        guard request.challenge.expiresAtMilliseconds > nowMilliseconds - skewMilliseconds else {
            throw CertificateEnrollmentError.expiredChallenge
        }
        guard !consumedChallengeIDs.contains(request.challenge.challengeID) else {
            throw CertificateEnrollmentError.replayedChallenge
        }

        do {
            try CredentialVerifier.verify(
                request.credential,
                trustedAuthorityPublicKey: trustedAuthorityPublicKey,
                networkID: networkID,
                environment: environment,
                now: now,
                allowedClockSkew: allowedClockSkew
            )
        } catch {
            throw CertificateEnrollmentError.invalidCredential
        }
        guard request.credential.claims.serviceScopes.contains("lan") else {
            throw CertificateEnrollmentError.missingLANScope
        }
        guard request.nodeID == request.credential.claims.nodeID,
              request.nodePublicKey == request.credential.claims.nodePublicKey,
              !request.certificateSigningRequestDER.isEmpty,
              NodeIdentity.nodeID(forPublicKeyRepresentation: request.nodePublicKey) == request.nodeID else {
            throw CertificateEnrollmentError.nodeIdentityMismatch
        }
        guard request.requestedValiditySeconds > 0,
              request.requestedValiditySeconds <= UInt64(Self.maximumCertificateValidity) else {
            throw CertificateEnrollmentError.invalidRequestedValidity
        }
        guard NodeIdentity.verifyCertificateEnrollmentSignature(
            publicKeyRepresentation: request.nodePublicKey,
            transcript: CertificateEnrollmentTranscript.data(for: request),
            signature: request.signature
        ) else {
            throw CertificateEnrollmentError.invalidSignature
        }

        consumedChallengeIDs.insert(request.challenge.challengeID)
        return ValidatedCertificateEnrollment(
            requestID: request.requestID,
            nodeID: request.nodeID,
            nodePublicKey: request.nodePublicKey,
            certificateSigningRequestDER: request.certificateSigningRequestDER,
            validity: TimeInterval(request.requestedValiditySeconds)
        )
    }
}

private enum CertificateEnrollmentTranscript {
    private static let domain = Data("BeakrNet certificate enrollment v1\0".utf8)

    static func data(for request: CertificateEnrollmentRequest) -> Data {
        var data = domain
        append(UInt64(request.version), to: &data)
        append(request.requestID.uuidString.lowercased(), to: &data)
        append(request.nodeID.rawValue.uuidString.lowercased(), to: &data)
        append(request.nodePublicKey, to: &data)
        append(request.certificateSigningRequestDER, to: &data)
        append(request.credential.claims.credentialID.uuidString.lowercased(), to: &data)
        append(request.environment, to: &data)
        append(UInt64(request.challenge.version), to: &data)
        append(request.challenge.challengeID.uuidString.lowercased(), to: &data)
        append(request.challenge.authorityID.rawValue.uuidString.lowercased(), to: &data)
        append(request.challenge.environment, to: &data)
        append(request.challenge.nonce, to: &data)
        append(UInt64(bitPattern: request.challenge.issuedAtMilliseconds), to: &data)
        append(UInt64(bitPattern: request.challenge.expiresAtMilliseconds), to: &data)
        append(request.requestedValiditySeconds, to: &data)
        return data
    }

    private static func append(_ value: String, to data: inout Data) {
        append(Data(value.utf8), to: &data)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var value = value.bigEndian
        data.append(withUnsafeBytes(of: &value) { Data($0) })
    }

    private static func append(_ value: Data, to data: inout Data) {
        append(UInt64(value.count), to: &data)
        data.append(value)
    }
}

private enum CertificateEnrollmentResponseTranscript {
    private static let domain = Data("BeakrNet certificate enrollment response v1\0".utf8)

    static func data(for response: CertificateEnrollmentResponse) -> Data {
        var data = domain
        append(UInt64(response.version), to: &data)
        append(response.requestID.uuidString.lowercased(), to: &data)
        append(response.authorityID.rawValue.uuidString.lowercased(), to: &data)
        append(response.nodeID.rawValue.uuidString.lowercased(), to: &data)
        append(response.nodePublicKey, to: &data)
        append(UInt64(bitPattern: response.issuedAtMilliseconds), to: &data)
        append(UInt64(bitPattern: response.expiresAtMilliseconds), to: &data)
        append(response.leafCertificateDER, to: &data)
        append(UInt64(response.certificateChainDER.count), to: &data)
        response.certificateChainDER.forEach { append($0, to: &data) }
        return data
    }

    private static func append(_ value: String, to data: inout Data) {
        append(Data(value.utf8), to: &data)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var value = value.bigEndian
        data.append(withUnsafeBytes(of: &value) { Data($0) })
    }

    private static func append(_ value: Data, to data: inout Data) {
        append(UInt64(value.count), to: &data)
        data.append(value)
    }
}
