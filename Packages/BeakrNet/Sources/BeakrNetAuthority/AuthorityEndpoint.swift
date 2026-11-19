import CryptoKit
import Foundation
import BeakrNetCore

/// Short-lived routing metadata. Contains no trust key or replacement CA.
public struct AuthorityEndpointClaims: Codable, Equatable, Sendable {
    public let version: Int
    public let authorityID: AuthorityID
    public let networkID: NetworkID
    public let environment: String
    public let hostname: String
    public let port: UInt16
    public let generation: UInt64
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64

    public init(
        version: Int = 1, authorityID: AuthorityID, networkID: NetworkID,
        environment: String, hostname: String, port: UInt16, generation: UInt64,
        issuedAtMilliseconds: Int64, expiresAtMilliseconds: Int64
    ) {
        self.version = version
        self.authorityID = authorityID
        self.networkID = networkID
        self.environment = environment
        self.hostname = hostname
        self.port = port
        self.generation = generation
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
    }
}

public struct SignedAuthorityEndpoint: Codable, Equatable, Sendable {
    public let claims: AuthorityEndpointClaims
    public let signature: Data

    public init(claims: AuthorityEndpointClaims, signature: Data) {
        self.claims = claims
        self.signature = signature
    }

    /// Bounds untrusted discovery input before JSON decoding.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4_096 else { throw AuthorityEndpointError.invalidRecord }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 4_096 else { throw AuthorityEndpointError.invalidRecord }
        return data
    }
}

/// Verified routing data is not proof that an endpoint is currently reachable.
/// Clients must still apply their installed CA and hostname validation over TLS.
public struct VerifiedAuthorityEndpoint: Equatable, Sendable {
    public let claims: AuthorityEndpointClaims
    public let controlPlaneURL: URL

    fileprivate init(claims: AuthorityEndpointClaims, controlPlaneURL: URL) {
        self.claims = claims
        self.controlPlaneURL = controlPlaneURL
    }
}

public enum AuthorityEndpointError: Error, Equatable, Sendable {
    case unsupportedVersion, invalidRecord, wrongAuthority, wrongNetwork, wrongEnvironment
    case invalidSignature, issuedInFuture, expired, staleGeneration
}

public extension CredentialAuthority {
    /// The host must durably advance generation when its endpoint changes.
    func issueAuthorityEndpoint(
        networkID: NetworkID, environment: String, hostname: String, port: UInt16,
        generation: UInt64, validity: TimeInterval = 120, now: Date = Date()
    ) throws -> SignedAuthorityEndpoint {
        guard validity.isFinite, validity > 0, validity <= 300,
              let duration = Int64(exactly: (validity * 1_000).rounded(.down)) else {
            throw AuthorityEndpointError.invalidRecord
        }
        let issued = try AuthorityEndpointVerifier.milliseconds(now)
        let expiration = issued.addingReportingOverflow(duration)
        guard !expiration.overflow else { throw AuthorityEndpointError.invalidRecord }
        let claims = AuthorityEndpointClaims(
            authorityID: authorityID, networkID: networkID, environment: environment,
            hostname: hostname, port: port, generation: generation,
            issuedAtMilliseconds: issued, expiresAtMilliseconds: expiration.partialValue
        )
        try AuthorityEndpointVerifier.validateShape(claims)
        return SignedAuthorityEndpoint(
            claims: claims,
            signature: try signature(forAuthorityEndpoint: AuthorityEndpointTranscript.data(claims))
        )
    }
}

public enum AuthorityEndpointVerifier {
    /// minimumGeneration is supplied from the client's trusted high-water mark.
    /// Callers must reject conflicting endpoints at the same generation and
    /// revalidate expiration whenever using a cached record.
    public static func verify(
        _ record: SignedAuthorityEndpoint, trustedAuthorityPublicKey: Data,
        networkID: NetworkID, environment: String,
        minimumGeneration: UInt64 = 0, now: Date = Date()
    ) throws -> VerifiedAuthorityEndpoint {
        let claims = record.claims
        try verifyAuthenticity(
            record, trustedAuthorityPublicKey: trustedAuthorityPublicKey,
            networkID: networkID, environment: environment
        )
        guard claims.generation >= minimumGeneration else { throw AuthorityEndpointError.staleGeneration }
        let nowMilliseconds = try milliseconds(now)
        // A small forward clock tolerance never extends the expiry deadline.
        guard Double(claims.issuedAtMilliseconds) <= Double(nowMilliseconds) + 30_000 else {
            throw AuthorityEndpointError.issuedInFuture
        }
        guard nowMilliseconds < claims.expiresAtMilliseconds else { throw AuthorityEndpointError.expired }
        var components = URLComponents()
        components.scheme = "https"
        components.host = claims.hostname
        components.port = Int(claims.port)
        guard let url = components.url else { throw AuthorityEndpointError.invalidRecord }
        return VerifiedAuthorityEndpoint(claims: claims, controlPlaneURL: url)
    }

    /// Checks persisted evidence without treating an expired record as a route.
    /// Use verify(_:...) with the current time before connecting.
    public static func verifyAuthenticity(
        _ record: SignedAuthorityEndpoint, trustedAuthorityPublicKey: Data,
        networkID: NetworkID, environment: String
    ) throws {
        let claims = record.claims
        try validateShape(claims)
        guard claims.authorityID == CredentialVerifier.authorityID(for: trustedAuthorityPublicKey) else {
            throw AuthorityEndpointError.wrongAuthority
        }
        guard claims.networkID == networkID else { throw AuthorityEndpointError.wrongNetwork }
        guard claims.environment == environment else { throw AuthorityEndpointError.wrongEnvironment }
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: trustedAuthorityPublicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: record.signature),
              publicKey.isValidSignature(signature, for: AuthorityEndpointTranscript.data(claims)) else {
            throw AuthorityEndpointError.invalidSignature
        }
    }

    fileprivate static func milliseconds(_ date: Date) throws -> Int64 {
        guard let value = Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded(.down)) else {
            throw AuthorityEndpointError.invalidRecord
        }
        return value
    }

    fileprivate static func validateShape(_ claims: AuthorityEndpointClaims) throws {
        guard claims.version == 1 else { throw AuthorityEndpointError.unsupportedVersion }
        let duration = claims.expiresAtMilliseconds.subtractingReportingOverflow(claims.issuedAtMilliseconds)
        let labels = claims.hostname.split(separator: ".", omittingEmptySubsequences: false)
        let validHostname = !claims.hostname.isEmpty && claims.hostname.utf8.count <= 253
            && claims.hostname == claims.hostname.lowercased()
            && labels.allSatisfy { label in
                !label.isEmpty && label.utf8.count <= 63
                    && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            }
        guard validHostname, claims.port != 0, claims.generation > 0,
              !claims.environment.isEmpty, claims.environment.utf8.count <= 128,
              !duration.overflow, duration.partialValue > 0, duration.partialValue <= 300_000 else {
            throw AuthorityEndpointError.invalidRecord
        }
    }
}

private enum AuthorityEndpointTranscript {
    static func data(_ claims: AuthorityEndpointClaims) -> Data {
        var data = Data("BeakrNet authority endpoint v1\0".utf8)
        append(UInt64(claims.version), to: &data)
        append(claims.authorityID.rawValue.uuidString.lowercased(), to: &data)
        append(claims.networkID.rawValue.uuidString.lowercased(), to: &data)
        append(claims.environment, to: &data)
        append(claims.hostname, to: &data)
        append(UInt64(claims.port), to: &data)
        append(claims.generation, to: &data)
        append(UInt64(bitPattern: claims.issuedAtMilliseconds), to: &data)
        append(UInt64(bitPattern: claims.expiresAtMilliseconds), to: &data)
        return data
    }

    private static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        append(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
