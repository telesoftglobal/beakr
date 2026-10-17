import Foundation
import Testing
import BeakrNetCore
@testable import BeakrNetAuthority

@Suite("Profile membership HTTPS endpoint")
struct ProfileMembershipNetworkTests {
    @Test("Canonical membership is fetched conditionally")
    func conditionalFetch() async throws {
        let snapshot = try fixture(generation: 7)
        let endpoint = ProfileMembershipHTTPEndpoint(snapshot: snapshot)
        let client = ProfileMembershipNetworkClient(transport: MembershipEndpointTransport(endpoint: endpoint))

        #expect(try await client.fetchSnapshot(after: nil) == snapshot)
        #expect(try await client.fetchSnapshot(after: 7) == nil)
    }

    @Test("Endpoint and client enforce strict bounded responses")
    func strictResponses() async throws {
        let snapshot = try fixture(generation: 2)
        let endpoint = ProfileMembershipHTTPEndpoint(snapshot: snapshot)
        #expect(await endpoint.handle(.init(method: "POST", path: ProfileMembershipHTTPEndpoint.path)).statusCode == 405)
        #expect(await endpoint.handle(.init(method: "GET", path: "/wrong")).statusCode == 404)

        let canonical = try ProfileMembershipWireCodec.encode(snapshot)
        let pretty = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: canonical),
            options: [.prettyPrinted, .sortedKeys]
        )
        let headers = [
            "content-type": ProfileMembershipHTTPEndpoint.contentType,
            "etag": ProfileMembershipHTTPEndpoint.etag(for: snapshot)
        ]
        let client = ProfileMembershipNetworkClient(
            transport: MembershipStaticTransport(response: .init(statusCode: 200, headers: headers, body: pretty))
        )
        await #expect(throws: ProfileMembershipNetworkError.nonCanonicalSnapshot) {
            try await client.fetchSnapshot(after: nil)
        }
    }

    @Test("Generation rollback, conflicts, and insecure clients fail closed")
    func monotonicityAndHTTPS() async throws {
        let endpoint = ProfileMembershipHTTPEndpoint(snapshot: try fixture(generation: 2))
        await #expect(throws: ProfileMembershipNetworkError.generationRollback) {
            try await endpoint.replaceSnapshot(try fixture(generation: 1))
        }
        await #expect(throws: ProfileMembershipNetworkError.generationConflict) {
            try await endpoint.replaceSnapshot(try fixture(generation: 2, timestamp: 2_000))
        }
        #expect(throws: CertificateEnrollmentNetworkError.insecureBaseURL) {
            _ = try ProfileMembershipNetworkClient(baseURL: URL(string: "http://example.test")!)
        }
    }

    private func fixture(generation: UInt64, timestamp: Int64 = 1_000) throws -> ProfileMembershipSnapshot {
        let authority = CredentialAuthority()
        return try ProfileMembershipAuthority(privateKeyRepresentation: authority.privateKeyRepresentation)
            .sign(.init(
                networkID: NetworkID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
                generation: generation,
                generatedAtMilliseconds: timestamp,
                records: []
            ))
    }
}

private struct MembershipEndpointTransport: CertificateEnrollmentHTTPTransport {
    let endpoint: ProfileMembershipHTTPEndpoint
    func send(_ request: CertificateEnrollmentHTTPRequest) async throws -> CertificateEnrollmentHTTPResponse {
        await endpoint.handle(request)
    }
}

private struct MembershipStaticTransport: CertificateEnrollmentHTTPTransport {
    let response: CertificateEnrollmentHTTPResponse
    func send(_ request: CertificateEnrollmentHTTPRequest) async throws -> CertificateEnrollmentHTTPResponse {
        response
    }
}
