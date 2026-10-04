import Foundation
import Testing
import BeakrNetCore
@testable import BeakrNetAuthority

@Suite("Revocation HTTPS endpoint")
struct RevocationNetworkTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("The client fetches canonical state and conditionally receives no change")
    func conditionalFetch() async throws {
        let snapshot = try makeSnapshot()
        let endpoint = RevocationSnapshotHTTPEndpoint(snapshot: snapshot)
        let client = RevocationSnapshotNetworkClient(
            transport: EndpointTransport(endpoint: endpoint)
        )

        #expect(try await client.fetchSnapshot(after: nil) == snapshot)
        #expect(try await client.fetchSnapshot(
            after: snapshot.claims.generatedAtMilliseconds
        ) == nil)
    }

    @Test("The endpoint rejects wrong paths, methods, and request bodies")
    func strictEndpoint() async throws {
        let endpoint = RevocationSnapshotHTTPEndpoint(snapshot: try makeSnapshot())

        #expect(await endpoint.handle(.init(method: "GET", path: "/wrong")).statusCode == 404)
        #expect(await endpoint.handle(.init(
            method: "POST",
            path: RevocationSnapshotHTTPEndpoint.path
        )).statusCode == 405)
        #expect(await endpoint.handle(.init(
            method: "GET",
            path: RevocationSnapshotHTTPEndpoint.path,
            body: Data([1])
        )).statusCode == 400)
    }

    @Test("The client rejects noncanonical, stale, and mismatched responses")
    func rejectsInvalidResponses() async throws {
        let snapshot = try makeSnapshot()
        let canonical = try RevocationSnapshotWireCodec.encode(snapshot)
        let pretty = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: canonical),
            options: [.prettyPrinted, .sortedKeys]
        )
        let baseHeaders = [
            "content-type": RevocationSnapshotHTTPEndpoint.contentType,
            "etag": RevocationSnapshotHTTPEndpoint.etag(for: snapshot)
        ]
        let noncanonical = RevocationSnapshotNetworkClient(transport: StaticHTTPTransport(
            response: .init(statusCode: 200, headers: baseHeaders, body: pretty)
        ))
        await #expect(throws: RevocationNetworkError.nonCanonicalSnapshot) {
            try await noncanonical.fetchSnapshot(after: nil)
        }

        let stale = RevocationSnapshotNetworkClient(transport: StaticHTTPTransport(
            response: .init(statusCode: 200, headers: baseHeaders, body: canonical)
        ))
        await #expect(throws: RevocationNetworkError.nonAdvancingSnapshot) {
            try await stale.fetchSnapshot(after: snapshot.claims.generatedAtMilliseconds)
        }

        var wrongHeaders = baseHeaders
        wrongHeaders["etag"] = "\"wrong\""
        let wrongETag = RevocationSnapshotNetworkClient(transport: StaticHTTPTransport(
            response: .init(statusCode: 200, headers: wrongHeaders, body: canonical)
        ))
        await #expect(throws: RevocationNetworkError.invalidETag) {
            try await wrongETag.fetchSnapshot(after: nil)
        }
    }

    @Test("The concrete client requires HTTPS")
    func requiresHTTPS() throws {
        #expect(throws: CertificateEnrollmentNetworkError.insecureBaseURL) {
            _ = try RevocationSnapshotNetworkClient(
                baseURL: URL(string: "http://example.test")!
            )
        }
    }

    @Test("Endpoint replacement rejects rollback and timestamp conflicts")
    func replacementMonotonicity() async throws {
        let authority = CredentialAuthority()
        let current = try authority.issueRevocationSnapshot(revocations: [], now: now)
        let endpoint = RevocationSnapshotHTTPEndpoint(snapshot: current)
        let stale = try authority.issueRevocationSnapshot(
            revocations: [],
            now: now.addingTimeInterval(-1)
        )
        let conflict = try authority.issueRevocationSnapshot(
            revocations: [CredentialRevocation(
                credentialID: UUID(),
                revokedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
                reason: "test"
            )],
            now: now
        )

        await #expect(throws: RevocationDistributionError.staleSnapshot) {
            try await endpoint.replaceSnapshot(stale)
        }
        await #expect(throws: RevocationDistributionError.conflictingSnapshot) {
            try await endpoint.replaceSnapshot(conflict)
        }
    }

    private func makeSnapshot() throws -> CredentialRevocationSnapshot {
        try CredentialAuthority().issueRevocationSnapshot(revocations: [], now: now)
    }
}

private struct EndpointTransport: CertificateEnrollmentHTTPTransport {
    let endpoint: RevocationSnapshotHTTPEndpoint
    func send(_ request: CertificateEnrollmentHTTPRequest) async throws
        -> CertificateEnrollmentHTTPResponse {
        await endpoint.handle(request)
    }
}

private struct StaticHTTPTransport: CertificateEnrollmentHTTPTransport {
    let response: CertificateEnrollmentHTTPResponse
    func send(_ request: CertificateEnrollmentHTTPRequest) async throws
        -> CertificateEnrollmentHTTPResponse {
        response
    }
}
