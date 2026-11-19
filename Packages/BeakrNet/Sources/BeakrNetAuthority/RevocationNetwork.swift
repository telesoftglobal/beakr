import Foundation
import BeakrNetCore

public actor RevocationSnapshotHTTPEndpoint {
    public static let path = "/v1/credential-revocations"
    public static let contentType = "application/vnd.beakrnet.credential-revocations+json"
    public static let maximumBodySize = 1_048_576

    private var snapshot: CredentialRevocationSnapshot
    private var snapshotProvider: (@Sendable (Date) async throws -> CredentialRevocationSnapshot)?

    func setSnapshotProvider(
        _ provider: @escaping @Sendable (Date) async throws -> CredentialRevocationSnapshot
    ) {
        snapshotProvider = provider
    }

    public init(snapshot: CredentialRevocationSnapshot) {
        self.snapshot = snapshot
    }

    public func replaceSnapshot(_ snapshot: CredentialRevocationSnapshot) throws {
        let incoming = snapshot.claims.generatedAtMilliseconds
        let current = self.snapshot.claims.generatedAtMilliseconds
        guard incoming >= current else { throw RevocationDistributionError.staleSnapshot }
        if incoming == current, snapshot != self.snapshot {
            throw RevocationDistributionError.conflictingSnapshot
        }
        self.snapshot = snapshot
    }

    public func handle(
        _ request: CertificateEnrollmentHTTPRequest,
        now: Date = Date()
    ) async -> CertificateEnrollmentHTTPResponse {
        guard request.path == Self.path else { return response(status: 404) }
        guard request.method == "GET" else {
            return response(status: 405, headers: ["allow": "GET"])
        }
        guard request.body.isEmpty else { return response(status: 400) }

        let responseSnapshot: CredentialRevocationSnapshot
        if let snapshotProvider {
            do {
                // The coordinator is the durable source of truth. Keep one
                // immutable snapshot for this response across actor suspension.
                responseSnapshot = try await snapshotProvider(now)
            } catch {
                // Do not disguise failed durable renewal as a successful 304.
                return response(status: 503)
            }
        } else {
            responseSnapshot = snapshot
        }

        let etag = Self.etag(for: responseSnapshot)
        if let condition = header("if-none-match", in: request.headers) {
            guard condition == etag else {
                return response(status: 200, body: encodedSnapshot(responseSnapshot), etag: etag)
            }
            return response(status: 304, etag: etag)
        }
        return response(status: 200, body: encodedSnapshot(responseSnapshot), etag: etag)
    }

    public static func etag(for snapshot: CredentialRevocationSnapshot) -> String {
        "\"beakrnet-revocations-\(snapshot.claims.generatedAtMilliseconds)\""
    }

    private func encodedSnapshot(_ snapshot: CredentialRevocationSnapshot) -> Data {
        // A valid snapshot is always encodable. Return an empty body only if a
        // future model change violates that invariant; the client fails closed.
        (try? RevocationSnapshotWireCodec.encode(snapshot)) ?? Data()
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
        return CertificateEnrollmentHTTPResponse(statusCode: status, headers: values, body: body)
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.lowercased() == name }?.value
    }
}

public actor RevocationSnapshotNetworkClient: RevocationSnapshotRequesting {
    private let transport: any CertificateEnrollmentHTTPTransport

    public init(transport: any CertificateEnrollmentHTTPTransport) {
        self.transport = transport
    }

    public init(baseURL: URL, session: URLSession = .shared) throws {
        transport = try URLSessionCertificateEnrollmentTransport(
            baseURL: baseURL,
            session: session
        )
    }

    public func fetchSnapshot(
        after generatedAtMilliseconds: Int64?
    ) async throws -> CredentialRevocationSnapshot? {
        var headers: [String: String] = ["accept": RevocationSnapshotHTTPEndpoint.contentType]
        if let generatedAtMilliseconds {
            headers["if-none-match"] = "\"beakrnet-revocations-\(generatedAtMilliseconds)\""
        }
        let response = try await transport.send(CertificateEnrollmentHTTPRequest(
            method: "GET",
            path: RevocationSnapshotHTTPEndpoint.path,
            headers: headers
        ))
        if response.statusCode == 304 {
            guard response.body.isEmpty else { throw RevocationNetworkError.invalidResponse }
            return nil
        }
        guard response.statusCode == 200 else {
            throw RevocationNetworkError.serverRejected(response.statusCode)
        }
        guard response.body.count <= RevocationSnapshotHTTPEndpoint.maximumBodySize else {
            throw RevocationNetworkError.responseTooLarge
        }
        guard header("content-type", in: response.headers)?.lowercased()
                == RevocationSnapshotHTTPEndpoint.contentType else {
            throw RevocationNetworkError.invalidContentType
        }
        let snapshot = try RevocationSnapshotWireCodec.decode(response.body)
        if let generatedAtMilliseconds,
           snapshot.claims.generatedAtMilliseconds <= generatedAtMilliseconds {
            throw RevocationNetworkError.nonAdvancingSnapshot
        }
        guard header("etag", in: response.headers)
                == RevocationSnapshotHTTPEndpoint.etag(for: snapshot) else {
            throw RevocationNetworkError.invalidETag
        }
        return snapshot
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.lowercased() == name }?.value
    }
}

public enum RevocationSnapshotWireCodec {
    public static func encode(_ snapshot: CredentialRevocationSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }

    public static func decode(_ data: Data) throws -> CredentialRevocationSnapshot {
        let snapshot: CredentialRevocationSnapshot
        do {
            snapshot = try JSONDecoder().decode(CredentialRevocationSnapshot.self, from: data)
        } catch {
            throw RevocationNetworkError.malformedSnapshot
        }
        guard try encode(snapshot) == data else {
            throw RevocationNetworkError.nonCanonicalSnapshot
        }
        return snapshot
    }
}

public enum RevocationNetworkError: Error, Equatable, Sendable {
    case invalidResponse
    case invalidContentType
    case invalidETag
    case responseTooLarge
    case nonAdvancingSnapshot
    case malformedSnapshot
    case nonCanonicalSnapshot
    case serverRejected(Int)
}
