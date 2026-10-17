import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

@Suite("Certificate enrollment network endpoint")
struct CertificateEnrollmentNetworkTests {
    @Test("The client completes a challenge and enrollment exchange")
    func completeExchange() async throws {
        let fixture = try NetworkEnrollmentFixture()
        let exchange = try await fixture.client.renewCertificate()

        try CertificateEnrollmentResponseVerifier.verify(
            exchange.response,
            for: exchange.request,
            trustedAuthorityPublicKey: fixture.authority.publicKeyRepresentation
        )
        #expect(exchange.request.challenge.environment == "development")
        #expect(exchange.response.leafCertificateDER == Data("network-leaf".utf8))
        #expect(await fixture.transport.requests().map(\.path) == [
            CertificateEnrollmentHTTPEndpoint.challengePath,
            CertificateEnrollmentHTTPEndpoint.enrollmentPath
        ])
    }

    @Test("A successful enrollment publishes membership before returning")
    func publishesMembership() async throws {
        let publisher = RecordingMembershipPublisher()
        let fixture = try NetworkEnrollmentFixture(membershipPublisher: publisher)

        let exchange = try await fixture.client.renewCertificate()

        #expect(await publisher.publications == 1)
        #expect(await publisher.lastNodeID == exchange.request.nodeID)
    }

    @Test("A challenge is single-use through the endpoint")
    func replayRejected() async throws {
        let fixture = try NetworkEnrollmentFixture()
        let exchange = try await fixture.client.renewCertificate()
        let replay = await fixture.endpoint.handle(CertificateEnrollmentHTTPRequest(
            method: "POST",
            path: CertificateEnrollmentHTTPEndpoint.enrollmentPath,
            headers: ["content-type": CertificateEnrollmentHTTPEndpoint.contentType],
            body: try CertificateEnrollmentWireCodec.encode(exchange.request)
        ))
        #expect(replay.statusCode == 403)
        #expect(replay.body.isEmpty)
    }

    @Test("A locally forged challenge is rejected even when the node signs it")
    func forgedChallengeRejected() async throws {
        let fixture = try NetworkEnrollmentFixture()
        let milliseconds = Int64(fixture.now.timeIntervalSince1970 * 1_000)
        let forged = CertificateEnrollmentChallenge(
            authorityID: fixture.authority.authorityID,
            environment: "development",
            nonce: Data(repeating: 9, count: 32),
            issuedAtMilliseconds: milliseconds,
            expiresAtMilliseconds: milliseconds + 120_000
        )
        let request = try CertificateEnrollmentRequest.signed(
            identity: fixture.identity,
            credential: fixture.credential,
            environment: "development",
            challenge: forged,
            requestedValidity: 86_400
        )
        let response = await fixture.endpoint.handle(CertificateEnrollmentHTTPRequest(
            method: "POST",
            path: CertificateEnrollmentHTTPEndpoint.enrollmentPath,
            headers: ["Content-Type": CertificateEnrollmentHTTPEndpoint.contentType],
            body: try CertificateEnrollmentWireCodec.encode(request)
        ))
        #expect(response.statusCode == 403)
    }

    @Test("The endpoint rejects method, media type, noncanonical JSON, and oversized bodies")
    func requestBoundaries() async throws {
        let fixture = try NetworkEnrollmentFixture()
        let method = await fixture.endpoint.handle(CertificateEnrollmentHTTPRequest(
            method: "GET",
            path: CertificateEnrollmentHTTPEndpoint.challengePath
        ))
        #expect(method.statusCode == 405)

        let mediaType = await fixture.endpoint.handle(CertificateEnrollmentHTTPRequest(
            method: "POST",
            path: CertificateEnrollmentHTTPEndpoint.challengePath,
            body: Data("{}".utf8)
        ))
        #expect(mediaType.statusCode == 415)

        let noncanonical = await fixture.endpoint.handle(CertificateEnrollmentHTTPRequest(
            method: "POST",
            path: CertificateEnrollmentHTTPEndpoint.challengePath,
            headers: ["content-type": CertificateEnrollmentHTTPEndpoint.contentType],
            body: Data("{ \"environment\" : \"development\", \"version\" : 1 }".utf8)
        ))
        #expect(noncanonical.statusCode == 400)

        let oversized = await fixture.endpoint.handle(CertificateEnrollmentHTTPRequest(
            method: "POST",
            path: CertificateEnrollmentHTTPEndpoint.enrollmentPath,
            headers: ["content-type": CertificateEnrollmentHTTPEndpoint.contentType],
            body: Data(repeating: 0, count: CertificateEnrollmentHTTPEndpoint.maximumEnrollmentBodySize + 1)
        ))
        #expect(oversized.statusCode == 413)
        #expect(oversized.headers["cache-control"] == "no-store")
    }

    @Test("The production transport requires HTTPS")
    func httpsRequired() {
        #expect(throws: CertificateEnrollmentNetworkError.insecureBaseURL) {
            try URLSessionCertificateEnrollmentTransport(
                baseURL: URL(string: "http://127.0.0.1:8080")!
            )
        }
    }

    @Test("Pinned transport rejects a malformed authority certificate")
    func malformedTrustAnchor() {
        #expect(throws: CertificateEnrollmentNetworkError.invalidTrustAnchor) {
            try URLSessionCertificateEnrollmentTransport(
                baseURL: URL(string: "https://authority.example")!,
                trustedAuthorityCertificateDER: Data("not-a-certificate".utf8)
            )
        }
    }
}

private struct NetworkEnrollmentFixture {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let authority = CredentialAuthority()
    let identity = NodeIdentity()
    let credential: NodeCredential
    let endpoint: CertificateEnrollmentHTTPEndpoint
    let transport: LoopbackEnrollmentTransport
    let client: CertificateEnrollmentNetworkClient

    init(membershipPublisher: (any CertificateEnrollmentMembershipPublishing)? = nil) throws {
        credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: .test,
            environment: "development",
            validity: 604_800,
            serviceScopes: ["lan"],
            now: now
        )
        let validator = CertificateEnrollmentValidator(
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: .test,
            environment: "development"
        )
        let challengeService = try CertificateEnrollmentChallengeService(
            authorityID: authority.authorityID,
            environment: "development"
        )
        let enrollment = CertificateEnrollmentService(
            validator: validator,
            authority: authority,
            issuer: NetworkTestCertificateIssuer()
        )
        let fixedNow = now
        endpoint = CertificateEnrollmentHTTPEndpoint(
            challenges: challengeService,
            enrollment: enrollment,
            membershipPublisher: membershipPublisher,
            now: { fixedNow }
        )
        transport = LoopbackEnrollmentTransport(endpoint: endpoint)
        client = try CertificateEnrollmentNetworkClient(
            transport: transport,
            identity: identity,
            credential: credential,
            environment: "development",
            requestedValidity: 86_400
        )
    }
}

private actor RecordingMembershipPublisher: CertificateEnrollmentMembershipPublishing {
    private(set) var publications = 0
    private(set) var lastNodeID: NodeID?

    func publishEnrollment(
        request: CertificateEnrollmentRequest,
        response: CertificateEnrollmentResponse,
        now: Date
    ) async throws {
        publications += 1
        lastNodeID = request.nodeID
    }
}

private actor LoopbackEnrollmentTransport: CertificateEnrollmentHTTPTransport {
    private let endpoint: CertificateEnrollmentHTTPEndpoint
    private var history: [CertificateEnrollmentHTTPRequest] = []

    init(endpoint: CertificateEnrollmentHTTPEndpoint) {
        self.endpoint = endpoint
    }

    func send(_ request: CertificateEnrollmentHTTPRequest) async throws
        -> CertificateEnrollmentHTTPResponse {
        history.append(request)
        return await endpoint.handle(request)
    }

    func requests() -> [CertificateEnrollmentHTTPRequest] {
        history
    }
}

private actor NetworkTestCertificateIssuer: CertificateMaterialIssuing {
    func issueCertificate(
        nodeID: NodeID,
        nodePublicKey: Data,
        certificateSigningRequestDER: Data,
        validity: TimeInterval,
        now: Date
    ) async throws -> IssuedCertificateMaterial {
        IssuedCertificateMaterial(
            leafCertificateDER: Data("network-leaf".utf8),
            certificateChainDER: [Data("network-authority".utf8)]
        )
    }
}
