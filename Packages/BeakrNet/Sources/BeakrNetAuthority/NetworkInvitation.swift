import CryptoKit
import Foundation
import BeakrNetCore
import BeakrNetSecurity

/// Public trust material that can be transferred to a device joining a network.
/// The authority signature prevents any field from being substituted in transit.
public struct NetworkInvitation: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let invitationID: UUID
    public let authorityID: AuthorityID
    public let networkID: NetworkID
    public let networkDisplayName: String
    public let environment: String
    public let controlPlaneURL: URL
    public let authorityPublicKey: Data
    public let authorityCertificateDER: Data
    public let serviceScopes: [String]
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let authoritySignature: Data

    public init(
        version: Int = Self.currentVersion,
        invitationID: UUID = UUID(),
        authorityID: AuthorityID,
        networkID: NetworkID,
        networkDisplayName: String = "Beakr Network",
        environment: String,
        controlPlaneURL: URL,
        authorityPublicKey: Data,
        authorityCertificateDER: Data,
        serviceScopes: [String],
        issuedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        authoritySignature: Data
    ) {
        self.version = version
        self.invitationID = invitationID
        self.authorityID = authorityID
        self.networkID = networkID
        self.networkDisplayName = networkDisplayName
        self.environment = environment
        self.controlPlaneURL = controlPlaneURL
        self.authorityPublicKey = authorityPublicKey
        self.authorityCertificateDER = authorityCertificateDER
        self.serviceScopes = serviceScopes
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.authoritySignature = authoritySignature
    }
}

public struct NetworkJoinRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let requestID: UUID
    public let invitation: NetworkInvitation
    public let nodeID: NodeID
    public let nodePublicKey: Data
    public let signature: Data

    public init(
        version: Int = Self.currentVersion,
        requestID: UUID = UUID(),
        invitation: NetworkInvitation,
        nodeID: NodeID,
        nodePublicKey: Data,
        signature: Data
    ) {
        self.version = version
        self.requestID = requestID
        self.invitation = invitation
        self.nodeID = nodeID
        self.nodePublicKey = nodePublicKey
        self.signature = signature
    }

    public static func signed(
        requestID: UUID = UUID(),
        invitation: NetworkInvitation,
        identity: NodeIdentity
    ) throws -> NetworkJoinRequest {
        let unsigned = NetworkJoinRequest(
            requestID: requestID,
            invitation: invitation,
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            signature: Data()
        )
        return NetworkJoinRequest(
            requestID: requestID,
            invitation: invitation,
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            signature: try identity.signature(
                forCertificateEnrollmentTranscript: NetworkJoinRequestTranscript.data(for: unsigned)
            )
        )
    }
}

public enum NetworkInvitationError: Error, Equatable, Sendable {
    case invalidValidity
    case invalidConfiguration
    case unsupportedVersion
    case wrongAuthority
    case invalidAuthoritySignature
    case issuedInFuture
    case expired
    case alreadyConsumed
    case nodeIdentityMismatch
    case invalidNodeSignature
}

public extension CredentialAuthority {
    func issueNetworkInvitation(
        networkID: NetworkID,
        networkDisplayName: String = "Beakr Network",
        environment: String,
        controlPlaneURL: URL,
        authorityCertificateDER: Data,
        serviceScopes: [String] = ["lan"],
        validity: TimeInterval = 15 * 60,
        now: Date = Date()
    ) throws -> NetworkInvitation {
        let displayName = networkDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = environment.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopes = serviceScopes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard controlPlaneURL.scheme?.lowercased() == "https",
              controlPlaneURL.host != nil,
              !displayName.isEmpty,
              !environment.isEmpty,
              !authorityCertificateDER.isEmpty,
              !scopes.isEmpty,
              scopes.allSatisfy({ !$0.isEmpty }),
              Set(scopes).count == scopes.count else {
            throw NetworkInvitationError.invalidConfiguration
        }
        guard validity > 0, validity <= 24 * 60 * 60 else {
            throw NetworkInvitationError.invalidValidity
        }
        let issuedAt = milliseconds(now)
        let unsigned = NetworkInvitation(
            authorityID: authorityID,
            networkID: networkID,
            networkDisplayName: displayName,
            environment: environment,
            controlPlaneURL: controlPlaneURL,
            authorityPublicKey: publicKeyRepresentation,
            authorityCertificateDER: authorityCertificateDER,
            serviceScopes: scopes.sorted(),
            issuedAtMilliseconds: issuedAt,
            expiresAtMilliseconds: issuedAt + Int64(validity * 1_000),
            authoritySignature: Data()
        )
        return NetworkInvitation(
            invitationID: unsigned.invitationID,
            authorityID: unsigned.authorityID,
            networkID: unsigned.networkID,
            networkDisplayName: unsigned.networkDisplayName,
            environment: unsigned.environment,
            controlPlaneURL: unsigned.controlPlaneURL,
            authorityPublicKey: unsigned.authorityPublicKey,
            authorityCertificateDER: unsigned.authorityCertificateDER,
            serviceScopes: unsigned.serviceScopes,
            issuedAtMilliseconds: unsigned.issuedAtMilliseconds,
            expiresAtMilliseconds: unsigned.expiresAtMilliseconds,
            authoritySignature: try signature(forNetworkInvitation: NetworkInvitationTranscript.data(for: unsigned))
        )
    }
}

/// Validates and consumes invitations before issuing the joining node's credential.
/// Consumption occurs only after both authority and node signatures pass.
public actor NetworkInvitationService {
    private struct ConsumptionLedger: Codable {
        let formatVersion: Int
        let invitationIDs: [UUID]
    }

    private let authority: CredentialAuthority
    private let networkID: NetworkID
    private let environment: String
    private let credentialValidity: TimeInterval
    private let consumptionLedgerURL: URL?
    private var consumedInvitationIDs: Set<UUID>

    public init(
        authority: CredentialAuthority,
        networkID: NetworkID,
        environment: String,
        credentialValidity: TimeInterval = 30 * 24 * 60 * 60,
        consumptionLedgerURL: URL? = nil
    ) throws {
        guard credentialValidity > 0 else { throw NetworkInvitationError.invalidValidity }
        self.authority = authority
        self.networkID = networkID
        self.environment = environment
        self.credentialValidity = credentialValidity
        self.consumptionLedgerURL = consumptionLedgerURL
        if let consumptionLedgerURL,
           FileManager.default.fileExists(atPath: consumptionLedgerURL.path) {
            let data = try Data(contentsOf: consumptionLedgerURL)
            guard data.count <= 4_194_304,
                  let ledger = try? JSONDecoder().decode(ConsumptionLedger.self, from: data),
                  ledger.formatVersion == 1,
                  try Self.encode(ledger) == data else {
                throw NetworkInvitationError.invalidConfiguration
            }
            consumedInvitationIDs = Set(ledger.invitationIDs)
        } else {
            consumedInvitationIDs = []
        }
    }

    public func join(
        _ request: NetworkJoinRequest,
        now: Date = Date(),
        allowedClockSkew: TimeInterval = 60
    ) throws -> NodeCredential {
        let invitation = request.invitation
        guard request.version == NetworkJoinRequest.currentVersion,
              invitation.version == NetworkInvitation.currentVersion else {
            throw NetworkInvitationError.unsupportedVersion
        }
        guard invitation.authorityID == authority.authorityID,
              invitation.networkID == networkID,
              invitation.environment == environment,
              invitation.authorityPublicKey == authority.publicKeyRepresentation else {
            throw NetworkInvitationError.wrongAuthority
        }
        guard Self.verifyAuthoritySignature(invitation) else {
            throw NetworkInvitationError.invalidAuthoritySignature
        }
        let nowMilliseconds = Self.milliseconds(now)
        let skewMilliseconds = Int64(allowedClockSkew * 1_000)
        guard invitation.issuedAtMilliseconds <= nowMilliseconds + skewMilliseconds else {
            throw NetworkInvitationError.issuedInFuture
        }
        guard invitation.expiresAtMilliseconds > invitation.issuedAtMilliseconds,
              invitation.expiresAtMilliseconds > nowMilliseconds - skewMilliseconds else {
            throw NetworkInvitationError.expired
        }
        guard !consumedInvitationIDs.contains(invitation.invitationID) else {
            throw NetworkInvitationError.alreadyConsumed
        }
        guard request.nodeID == NodeIdentity.nodeID(forPublicKeyRepresentation: request.nodePublicKey) else {
            throw NetworkInvitationError.nodeIdentityMismatch
        }
        guard NodeIdentity.verifyCertificateEnrollmentSignature(
            publicKeyRepresentation: request.nodePublicKey,
            transcript: NetworkJoinRequestTranscript.data(for: request),
            signature: request.signature
        ) else {
            throw NetworkInvitationError.invalidNodeSignature
        }

        let credential = try authority.issue(
            nodeID: request.nodeID,
            nodePublicKey: request.nodePublicKey,
            networkID: networkID,
            environment: environment,
            validity: credentialValidity,
            serviceScopes: invitation.serviceScopes,
            now: now
        )
        var consumed = consumedInvitationIDs
        consumed.insert(invitation.invitationID)
        try persist(consumed)
        consumedInvitationIDs = consumed
        return credential
    }

    private static func verifyAuthoritySignature(_ invitation: NetworkInvitation) -> Bool {
        guard let publicKey = try? P256.Signing.PublicKey(
            x963Representation: invitation.authorityPublicKey
        ), let signature = try? P256.Signing.ECDSASignature(
            derRepresentation: invitation.authoritySignature
        ) else { return false }
        return publicKey.isValidSignature(signature, for: NetworkInvitationTranscript.data(for: invitation))
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }

    private func persist(_ invitationIDs: Set<UUID>) throws {
        guard let consumptionLedgerURL else { return }
        let ledger = ConsumptionLedger(
            formatVersion: 1,
            invitationIDs: invitationIDs.sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
        )
        let data = try Self.encode(ledger)
        try FileManager.default.createDirectory(
            at: consumptionLedgerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: consumptionLedgerURL, options: .atomic)
    }

    private static func encode(_ ledger: ConsumptionLedger) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ledger)
    }
}

public enum NetworkInvitationWireCodec {
    public static func encode(_ invitation: NetworkInvitation) throws -> Data {
        try canonicalEncoder().encode(invitation)
    }

    public static func decode(_ data: Data) throws -> NetworkInvitation {
        let invitation = try JSONDecoder().decode(NetworkInvitation.self, from: data)
        guard try encode(invitation) == data else { throw NetworkInvitationError.invalidConfiguration }
        return invitation
    }

    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private enum NetworkInvitationTranscript {
    static func data(for invitation: NetworkInvitation) -> Data {
        var data = Data("BeakrNet network invitation v1\0".utf8)
        append(UInt64(invitation.version), to: &data)
        append(invitation.invitationID.uuidString.lowercased(), to: &data)
        append(invitation.authorityID.rawValue.uuidString.lowercased(), to: &data)
        append(invitation.networkID.rawValue.uuidString.lowercased(), to: &data)
        append(invitation.networkDisplayName, to: &data)
        append(invitation.environment, to: &data)
        append(invitation.controlPlaneURL.absoluteString, to: &data)
        append(invitation.authorityPublicKey, to: &data)
        append(invitation.authorityCertificateDER, to: &data)
        append(UInt64(invitation.serviceScopes.count), to: &data)
        for scope in invitation.serviceScopes { append(scope, to: &data) }
        append(UInt64(bitPattern: invitation.issuedAtMilliseconds), to: &data)
        append(UInt64(bitPattern: invitation.expiresAtMilliseconds), to: &data)
        return data
    }
}

public enum NetworkJoinRequestWireCodec {
    public static func encode(_ request: NetworkJoinRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }

    public static func decode(_ data: Data) throws -> NetworkJoinRequest {
        let request = try JSONDecoder().decode(NetworkJoinRequest.self, from: data)
        guard try encode(request) == data else { throw NetworkInvitationError.invalidConfiguration }
        return request
    }
}

public enum NetworkJoinCredentialWireCodec {
    public static func encode(_ credential: NodeCredential) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(credential)
    }

    public static func decode(_ data: Data) throws -> NodeCredential {
        let credential = try JSONDecoder().decode(NodeCredential.self, from: data)
        guard try encode(credential) == data else { throw NetworkInvitationError.invalidConfiguration }
        return credential
    }
}

public actor NetworkInvitationHTTPEndpoint {
    public static let joinPath = "/v1/network-join"
    public static let contentType = "application/vnd.beakrnet.network-join+json"
    public static let maximumBodySize = 256 * 1_024

    private let service: NetworkInvitationService
    private let now: @Sendable () -> Date

    public init(service: NetworkInvitationService, now: @escaping @Sendable () -> Date = Date.init) {
        self.service = service
        self.now = now
    }

    public func handle(_ request: CertificateEnrollmentHTTPRequest) async
        -> CertificateEnrollmentHTTPResponse {
        guard request.path == Self.joinPath else { return response(status: 404) }
        guard request.method == "POST" else { return response(status: 405) }
        let contentType = request.headers.first { $0.key.lowercased() == "content-type" }?.value
        guard contentType?.lowercased() == Self.contentType else { return response(status: 415) }
        guard request.body.count <= Self.maximumBodySize else { return response(status: 413) }
        do {
            let join = try NetworkJoinRequestWireCodec.decode(request.body)
            let credential = try await service.join(join, now: now())
            return response(status: 200, body: try NetworkJoinCredentialWireCodec.encode(credential))
        } catch let error as NetworkInvitationError {
            switch error {
            case .invalidConfiguration, .unsupportedVersion, .nodeIdentityMismatch:
                return response(status: 400, invitationError: error)
            default:
                return response(status: 403, invitationError: error)
            }
        } catch {
            return response(status: 500)
        }
    }

    private func response(
        status: Int,
        body: Data = Data(),
        invitationError: NetworkInvitationError? = nil
    ) -> CertificateEnrollmentHTTPResponse {
        var headers = ["content-type": Self.contentType, "cache-control": "no-store"]
        if let invitationError {
            headers["x-beakr-invitation-error"] = invitationError.wireValue
        }
        return .init(
            statusCode: status,
            headers: headers,
            body: body
        )
    }
}

public struct NetworkJoinResult: Equatable, Sendable {
    public let request: NetworkJoinRequest
    public let credential: NodeCredential

    public init(request: NetworkJoinRequest, credential: NodeCredential) {
        self.request = request
        self.credential = credential
    }
}

public struct NetworkInvitationClient: Sendable {
    private let transport: any CertificateEnrollmentHTTPTransport

    public init(transport: any CertificateEnrollmentHTTPTransport) {
        self.transport = transport
    }

    public func join(invitation: NetworkInvitation, identity: NodeIdentity) async throws
        -> NodeCredential {
        try await joinResult(invitation: invitation, identity: identity).credential
    }

    /// Returns the exact signed request accepted by the authority together with
    /// its credential. Callers that persist enrollment state must retain this
    /// request ID instead of inventing a local surrogate after the join.
    public func joinResult(invitation: NetworkInvitation, identity: NodeIdentity) async throws
        -> NetworkJoinResult {
        let request = try NetworkJoinRequest.signed(invitation: invitation, identity: identity)
        let response = try await transport.send(.init(
            method: "POST",
            path: NetworkInvitationHTTPEndpoint.joinPath,
            headers: ["content-type": NetworkInvitationHTTPEndpoint.contentType],
            body: try NetworkJoinRequestWireCodec.encode(request)
        ))
        guard response.statusCode == 200 else {
            if let value = response.headers.first(where: {
                $0.key.lowercased() == "x-beakr-invitation-error"
            })?.value,
               let invitationError = NetworkInvitationError(wireValue: value) {
                throw invitationError
            }
            throw NetworkInvitationError.invalidConfiguration
        }
        guard response.body.count <= NetworkInvitationHTTPEndpoint.maximumBodySize else {
            throw NetworkInvitationError.invalidConfiguration
        }
        let credential = try NetworkJoinCredentialWireCodec.decode(response.body)
        try CredentialVerifier.verify(
            credential,
            trustedAuthorityPublicKey: invitation.authorityPublicKey,
            networkID: invitation.networkID,
            environment: invitation.environment
        )
        guard credential.claims.nodeID == identity.nodeID,
              credential.claims.nodePublicKey == identity.publicKeyRepresentation,
              credential.claims.serviceScopes == invitation.serviceScopes else {
            throw NetworkInvitationError.nodeIdentityMismatch
        }
        return NetworkJoinResult(request: request, credential: credential)
    }
}

private extension NetworkInvitationError {
    var wireValue: String {
        switch self {
        case .invalidValidity: "invalid-validity"
        case .invalidConfiguration: "invalid-configuration"
        case .unsupportedVersion: "unsupported-version"
        case .wrongAuthority: "wrong-authority"
        case .invalidAuthoritySignature: "invalid-authority-signature"
        case .issuedInFuture: "issued-in-future"
        case .expired: "expired"
        case .alreadyConsumed: "already-consumed"
        case .nodeIdentityMismatch: "node-identity-mismatch"
        case .invalidNodeSignature: "invalid-node-signature"
        }
    }

    init?(wireValue: String) {
        switch wireValue {
        case "invalid-validity": self = .invalidValidity
        case "invalid-configuration": self = .invalidConfiguration
        case "unsupported-version": self = .unsupportedVersion
        case "wrong-authority": self = .wrongAuthority
        case "invalid-authority-signature": self = .invalidAuthoritySignature
        case "issued-in-future": self = .issuedInFuture
        case "expired": self = .expired
        case "already-consumed": self = .alreadyConsumed
        case "node-identity-mismatch": self = .nodeIdentityMismatch
        case "invalid-node-signature": self = .invalidNodeSignature
        default: return nil
        }
    }
}

private enum NetworkJoinRequestTranscript {
    static func data(for request: NetworkJoinRequest) -> Data {
        var data = Data("BeakrNet network join request v1\0".utf8)
        append(UInt64(request.version), to: &data)
        append(request.requestID.uuidString.lowercased(), to: &data)
        append(NetworkInvitationTranscript.data(for: request.invitation), to: &data)
        append(request.invitation.authoritySignature, to: &data)
        append(request.nodeID.rawValue.uuidString.lowercased(), to: &data)
        append(request.nodePublicKey, to: &data)
        return data
    }
}

private func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
}

private func append(_ string: String, to data: inout Data) { append(Data(string.utf8), to: &data) }

private func append(_ value: UInt64, to data: inout Data) {
    var bigEndian = value.bigEndian
    data.append(withUnsafeBytes(of: &bigEndian) { Data($0) })
}

private func append(_ value: Data, to data: inout Data) {
    append(UInt64(value.count), to: &data)
    data.append(value)
}
