import Foundation
import BeakrNetCore

public protocol ProfileMembershipSnapshotRequesting: Sendable {
    func fetchSnapshot(after generation: UInt64?) async throws -> ProfileMembershipSnapshot?
}

public actor ProfileMembershipHTTPEndpoint {
    public static let path = "/v1/profile-membership"
    public static let contentType = "application/vnd.beakrnet.profile-membership+json"
    public static let maximumBodySize = 2_097_152

    private var snapshot: ProfileMembershipSnapshot

    public init(snapshot: ProfileMembershipSnapshot) {
        self.snapshot = snapshot
    }

    public func replaceSnapshot(_ proposed: ProfileMembershipSnapshot) throws {
        let incoming = proposed.claims.generation
        let current = snapshot.claims.generation
        guard incoming >= current else { throw ProfileMembershipNetworkError.generationRollback }
        if incoming == current, proposed != snapshot {
            throw ProfileMembershipNetworkError.generationConflict
        }
        snapshot = proposed
    }

    public func handle(_ request: CertificateEnrollmentHTTPRequest) -> CertificateEnrollmentHTTPResponse {
        guard request.path == Self.path else { return response(status: 404) }
        guard request.method == "GET" else {
            return response(status: 405, headers: ["allow": "GET"])
        }
        guard request.body.isEmpty else { return response(status: 400) }
        let tag = Self.etag(for: snapshot)
        if header("if-none-match", in: request.headers) == tag {
            return response(status: 304, etag: tag)
        }
        return response(status: 200, body: encodedSnapshot(), etag: tag)
    }

    public static func etag(for snapshot: ProfileMembershipSnapshot) -> String {
        "\"beakrnet-membership-\(snapshot.claims.generation)\""
    }

    private func encodedSnapshot() -> Data {
        (try? ProfileMembershipWireCodec.encode(snapshot)) ?? Data()
    }

    private func response(
        status: Int,
        headers: [String: String] = [:],
        body: Data = Data(),
        etag: String? = nil
    ) -> CertificateEnrollmentHTTPResponse {
        var values = headers
        values["content-type"] = Self.contentType
        values["cache-control"] = "private, no-cache"
        if let etag { values["etag"] = etag }
        return .init(statusCode: status, headers: values, body: body)
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.lowercased() == name }?.value
    }
}

public actor ProfileMembershipNetworkClient: ProfileMembershipSnapshotRequesting {
    private let transport: any CertificateEnrollmentHTTPTransport

    public init(transport: any CertificateEnrollmentHTTPTransport) {
        self.transport = transport
    }

    public init(baseURL: URL, session: URLSession = .shared) throws {
        transport = try URLSessionCertificateEnrollmentTransport(baseURL: baseURL, session: session)
    }

    public func fetchSnapshot(after generation: UInt64?) async throws -> ProfileMembershipSnapshot? {
        var headers = ["accept": ProfileMembershipHTTPEndpoint.contentType]
        if let generation {
            headers["if-none-match"] = "\"beakrnet-membership-\(generation)\""
        }
        let result = try await transport.send(.init(
            method: "GET",
            path: ProfileMembershipHTTPEndpoint.path,
            headers: headers
        ))
        if result.statusCode == 304 {
            guard result.body.isEmpty else { throw ProfileMembershipNetworkError.invalidResponse }
            return nil
        }
        guard result.statusCode == 200 else {
            throw ProfileMembershipNetworkError.serverRejected(result.statusCode)
        }
        guard result.body.count <= ProfileMembershipHTTPEndpoint.maximumBodySize else {
            throw ProfileMembershipNetworkError.responseTooLarge
        }
        guard header("content-type", in: result.headers)?.lowercased()
                == ProfileMembershipHTTPEndpoint.contentType else {
            throw ProfileMembershipNetworkError.invalidContentType
        }
        let snapshot = try ProfileMembershipWireCodec.decode(result.body)
        if let generation, snapshot.claims.generation <= generation {
            throw ProfileMembershipNetworkError.nonAdvancingSnapshot
        }
        guard header("etag", in: result.headers) == ProfileMembershipHTTPEndpoint.etag(for: snapshot) else {
            throw ProfileMembershipNetworkError.invalidETag
        }
        return snapshot
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.lowercased() == name }?.value
    }
}

public enum ProfileMembershipWireCodec {
    public static func encode(_ snapshot: ProfileMembershipSnapshot) throws -> Data {
        try ProfileMembershipAuthority.canonicalEncoder().encode(snapshot)
    }

    public static func decode(_ data: Data) throws -> ProfileMembershipSnapshot {
        let snapshot: ProfileMembershipSnapshot
        do {
            snapshot = try JSONDecoder().decode(ProfileMembershipSnapshot.self, from: data)
        } catch {
            throw ProfileMembershipNetworkError.malformedSnapshot
        }
        guard try encode(snapshot) == data else {
            throw ProfileMembershipNetworkError.nonCanonicalSnapshot
        }
        return snapshot
    }
}

public enum ProfileMembershipNetworkError: Error, Equatable, Sendable {
    case invalidResponse
    case invalidContentType
    case invalidETag
    case responseTooLarge
    case nonAdvancingSnapshot
    case malformedSnapshot
    case nonCanonicalSnapshot
    case generationRollback
    case generationConflict
    case serverRejected(Int)
}
