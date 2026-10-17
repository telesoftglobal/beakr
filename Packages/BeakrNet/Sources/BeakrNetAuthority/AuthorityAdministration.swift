import Foundation
import BeakrNetCore
import BeakrNetSecurity

public struct AuthorityInvitationRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let requestID: UUID
    public let credential: NodeCredential
    public let validitySeconds: UInt64
    public let issuedAtMilliseconds: Int64
    public let nodeSignature: Data

    public init(version: Int = Self.currentVersion, requestID: UUID = UUID(), credential: NodeCredential, validitySeconds: UInt64, issuedAtMilliseconds: Int64, nodeSignature: Data) {
        self.version = version
        self.requestID = requestID
        self.credential = credential
        self.validitySeconds = validitySeconds
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.nodeSignature = nodeSignature
    }

    public static func signed(credential: NodeCredential, identity: NodeIdentity, validity: TimeInterval, now: Date = Date()) throws -> Self {
        guard validity > 0, validity <= 24 * 60 * 60 else { throw AuthorityAdministrationError.invalidRequest }
        let unsigned = Self(
            credential: credential,
            validitySeconds: UInt64(validity),
            issuedAtMilliseconds: Int64((now.timeIntervalSince1970 * 1_000).rounded(.down)),
            nodeSignature: Data()
        )
        return Self(
            requestID: unsigned.requestID,
            credential: credential,
            validitySeconds: unsigned.validitySeconds,
            issuedAtMilliseconds: unsigned.issuedAtMilliseconds,
            nodeSignature: try identity.signature(forCertificateEnrollmentTranscript: AuthorityInvitationRequestTranscript.data(for: unsigned))
        )
    }
}

public enum AuthorityAdministrationError: Error, Equatable, Sendable {
    case invalidRequest
    case unauthorized
    case replayedRequest
    case staleRequest
    case invalidResponse
}

public actor AuthorityAdministrationService {
    private let authorityPublicKey: Data
    private let networkID: NetworkID
    private let environment: String
    private let issueInvitation: @Sendable (TimeInterval) throws -> NetworkInvitation
    private var consumedRequestIDs: Set<UUID> = []

    public init(authorityPublicKey: Data, networkID: NetworkID, environment: String, issueInvitation: @escaping @Sendable (TimeInterval) throws -> NetworkInvitation) {
        self.authorityPublicKey = authorityPublicKey
        self.networkID = networkID
        self.environment = environment
        self.issueInvitation = issueInvitation
    }

    public func createInvitation(_ request: AuthorityInvitationRequest, now: Date = Date()) throws -> NetworkInvitation {
        guard request.version == AuthorityInvitationRequest.currentVersion,
              request.validitySeconds > 0,
              request.validitySeconds <= 24 * 60 * 60 else { throw AuthorityAdministrationError.invalidRequest }
        guard !consumedRequestIDs.contains(request.requestID) else { throw AuthorityAdministrationError.replayedRequest }
        let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        guard abs(nowMilliseconds - request.issuedAtMilliseconds) <= 5 * 60 * 1_000 else { throw AuthorityAdministrationError.staleRequest }
        do {
            try CredentialVerifier.verify(
                request.credential,
                trustedAuthorityPublicKey: authorityPublicKey,
                networkID: networkID,
                environment: environment,
                now: now
            )
        } catch {
            throw AuthorityAdministrationError.unauthorized
        }
        let claims = request.credential.claims
        guard claims.serviceScopes.contains("admin"),
              NodeIdentity.verifyCertificateEnrollmentSignature(
                publicKeyRepresentation: claims.nodePublicKey,
                transcript: AuthorityInvitationRequestTranscript.data(for: request),
                signature: request.nodeSignature
              ) else { throw AuthorityAdministrationError.unauthorized }
        let invitation = try issueInvitation(TimeInterval(request.validitySeconds))
        consumedRequestIDs.insert(request.requestID)
        return invitation
    }
}

public actor AuthorityAdministrationHTTPEndpoint {
    public static let invitationPath = "/v1/administration/invitations"
    public static let contentType = "application/vnd.beakrnet.authority-invitation+json"
    public static let maximumBodySize = 256 * 1_024
    private let service: AuthorityAdministrationService
    private let now: @Sendable () -> Date

    public init(service: AuthorityAdministrationService, now: @escaping @Sendable () -> Date = Date.init) {
        self.service = service
        self.now = now
    }

    public func handle(_ request: CertificateEnrollmentHTTPRequest) async -> CertificateEnrollmentHTTPResponse {
        guard request.path == Self.invitationPath else { return response(status: 404) }
        guard request.method == "POST" else { return response(status: 405) }
        guard request.headers.first(where: { $0.key.lowercased() == "content-type" })?.value.lowercased() == Self.contentType else { return response(status: 415) }
        guard request.body.count <= Self.maximumBodySize else { return response(status: 413) }
        do {
            let invitationRequest = try AuthorityInvitationRequestWireCodec.decode(request.body)
            let invitation = try await service.createInvitation(invitationRequest, now: now())
            return response(status: 200, body: try NetworkInvitationWireCodec.encode(invitation))
        } catch let error as AuthorityAdministrationError {
            switch error {
            case .invalidRequest: return response(status: 400)
            case .unauthorized, .replayedRequest, .staleRequest: return response(status: 403)
            case .invalidResponse: return response(status: 500)
            }
        } catch {
            return response(status: 500)
        }
    }

    private func response(status: Int, body: Data = Data()) -> CertificateEnrollmentHTTPResponse {
        .init(statusCode: status, headers: ["content-type": Self.contentType, "cache-control": "no-store"], body: body)
    }
}

public struct AuthorityAdministrationClient: Sendable {
    private let transport: any CertificateEnrollmentHTTPTransport
    public init(transport: any CertificateEnrollmentHTTPTransport) { self.transport = transport }

    public func createInvitation(credential: NodeCredential, identity: NodeIdentity, validity: TimeInterval) async throws -> NetworkInvitation {
        let request = try AuthorityInvitationRequest.signed(credential: credential, identity: identity, validity: validity)
        let response = try await transport.send(.init(
            method: "POST",
            path: AuthorityAdministrationHTTPEndpoint.invitationPath,
            headers: ["content-type": AuthorityAdministrationHTTPEndpoint.contentType],
            body: try AuthorityInvitationRequestWireCodec.encode(request)
        ))
        guard response.statusCode == 200, response.body.count <= AuthorityAdministrationHTTPEndpoint.maximumBodySize else {
            throw AuthorityAdministrationError.invalidResponse
        }
        return try NetworkInvitationWireCodec.decode(response.body)
    }
}

public enum AuthorityInvitationRequestWireCodec {
    public static func encode(_ request: AuthorityInvitationRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }

    public static func decode(_ data: Data) throws -> AuthorityInvitationRequest {
        let request = try JSONDecoder().decode(AuthorityInvitationRequest.self, from: data)
        guard try encode(request) == data else { throw AuthorityAdministrationError.invalidRequest }
        return request
    }
}

private enum AuthorityInvitationRequestTranscript {
    static func data(for request: AuthorityInvitationRequest) -> Data {
        var data = Data("BeakrNet authority invitation request v1\0".utf8)
        append(UInt64(request.version), to: &data)
        append(Data(request.requestID.uuidString.lowercased().utf8), to: &data)
        append(Data(request.credential.claims.credentialID.uuidString.lowercased().utf8), to: &data)
        append(request.credential.issuerSignature, to: &data)
        append(request.validitySeconds, to: &data)
        append(UInt64(bitPattern: request.issuedAtMilliseconds), to: &data)
        return data
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        append(Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size), to: &data)
    }

    private static func append(_ value: Data, to data: inout Data) {
        var count = UInt64(value.count).bigEndian
        data.append(Data(bytes: &count, count: MemoryLayout<UInt64>.size))
        data.append(value)
    }
}
