import Foundation
import Testing
import BeakrNetCore
import BeakrNetSecurity
@testable import BeakrNetAuthority

@Suite("Certificate renewal scheduling")
struct CertificateRenewalTests {
    @Test("Renewal uses the signed validity window and bounded jitter")
    func schedule() throws {
        let fixture = try RenewalFixture()
        let policy = try CertificateRenewalPolicy(
            renewalFraction: 0.5,
            scheduleJitterFraction: 0.1,
            expirySafetyMargin: 600
        )
        let issued = fixture.now
        #expect(policy.scheduledRenewalDate(for: fixture.current, jitterUnit: -1) == issued.addingTimeInterval(34_560))
        #expect(policy.scheduledRenewalDate(for: fixture.current, jitterUnit: 0) == issued.addingTimeInterval(43_200))
        #expect(policy.scheduledRenewalDate(for: fixture.current, jitterUnit: 1) == issued.addingTimeInterval(51_840))
    }

    @Test("Retry backoff is exponential, jittered, capped, and never crosses the safety margin")
    func retryBackoff() throws {
        let policy = try CertificateRenewalPolicy(
            initialRetryDelay: 10,
            maximumRetryDelay: 40,
            retryJitterFraction: 0.25,
            expirySafetyMargin: 30
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let expiry = now.addingTimeInterval(100)
        #expect(policy.retryDate(after: 1, now: now, expiresAt: expiry, jitterUnit: -1) == now.addingTimeInterval(7.5))
        #expect(policy.retryDate(after: 3, now: now, expiresAt: expiry, jitterUnit: 0) == now.addingTimeInterval(40))
        #expect(policy.retryDate(after: 20, now: now, expiresAt: expiry, jitterUnit: 1) == now.addingTimeInterval(50))
        #expect(policy.retryDate(after: 3, now: now, expiresAt: now.addingTimeInterval(20), jitterUnit: 0) == now)
    }

    @Test("A verified renewal installs and becomes the active schedule")
    func successfulRenewal() async throws {
        let fixture = try RenewalFixture()
        let requester = StubRenewalRequester(results: [.success(fixture.exchange)])
        let installer = RecordingCertificateInstaller()
        let scheduler = CertificateRenewalScheduler(
            currentResponse: fixture.current,
            nodeIdentity: fixture.identity,
            trustedAuthorityPublicKey: fixture.authority.publicKeyRepresentation,
            requester: requester,
            installer: installer,
            policy: try CertificateRenewalPolicy()
        )

        let outcome = await scheduler.attemptRenewal(now: fixture.now)
        #expect(outcome == .installed(expiresAt: fixture.now.addingTimeInterval(172_800)))
        #expect(await scheduler.activeResponse() == fixture.exchange.response)
        #expect(installer.installedLeaf() == fixture.exchange.response.leafCertificateDER)
    }

    @Test("A failed or untrusted renewal keeps the current identity and schedules retry")
    func failedRenewal() async throws {
        let fixture = try RenewalFixture()
        var altered = fixture.exchange.response
        altered = CertificateEnrollmentResponse(
            requestID: altered.requestID,
            authorityID: altered.authorityID,
            nodeID: altered.nodeID,
            nodePublicKey: altered.nodePublicKey,
            issuedAtMilliseconds: altered.issuedAtMilliseconds,
            expiresAtMilliseconds: altered.expiresAtMilliseconds,
            leafCertificateDER: Data("tampered".utf8),
            certificateChainDER: altered.certificateChainDER,
            authoritySignature: altered.authoritySignature
        )
        let requester = StubRenewalRequester(results: [
            .failure(TestRenewalError.offline),
            .success(CertificateRenewalExchange(request: fixture.exchange.request, response: altered))
        ])
        let installer = RecordingCertificateInstaller()
        let scheduler = CertificateRenewalScheduler(
            currentResponse: fixture.current,
            nodeIdentity: fixture.identity,
            trustedAuthorityPublicKey: fixture.authority.publicKeyRepresentation,
            requester: requester,
            installer: installer,
            policy: try CertificateRenewalPolicy(initialRetryDelay: 10)
        )

        #expect(await scheduler.attemptRenewal(now: fixture.now) == .retryScheduled(
            at: fixture.now.addingTimeInterval(10),
            failureCount: 1
        ))
        #expect(await scheduler.attemptRenewal(now: fixture.now) == .retryScheduled(
            at: fixture.now.addingTimeInterval(20),
            failureCount: 2
        ))
        #expect(await scheduler.activeResponse() == fixture.current)
        #expect(installer.installedLeaf() == nil)
    }
}

private struct RenewalFixture {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let authority = CredentialAuthority()
    let identity = NodeIdentity()
    let current: CertificateEnrollmentResponse
    let exchange: CertificateRenewalExchange

    init() throws {
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            environment: "development",
            validity: 604_800,
            serviceScopes: ["lan"],
            now: now
        )
        let currentRequest = try Self.request(
            at: now,
            requestID: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
            authority: authority,
            identity: identity,
            credential: credential
        )
        current = try Self.response(
            for: currentRequest,
            at: now,
            leaf: "current",
            authority: authority,
            identity: identity
        )
        let renewalDate = now.addingTimeInterval(86_400)
        let renewalRequest = try Self.request(
            at: renewalDate,
            requestID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            authority: authority,
            identity: identity,
            credential: credential
        )
        exchange = CertificateRenewalExchange(
            request: renewalRequest,
            response: try Self.response(
                for: renewalRequest,
                at: renewalDate,
                leaf: "renewed",
                authority: authority,
                identity: identity
            )
        )
    }

    private static func request(
        at date: Date,
        requestID: UUID,
        authority: CredentialAuthority,
        identity: NodeIdentity,
        credential: NodeCredential
    ) throws -> CertificateEnrollmentRequest {
        let milliseconds = Int64(date.timeIntervalSince1970 * 1_000)
        return try CertificateEnrollmentRequest.signed(
            requestID: requestID,
            identity: identity,
            credential: credential,
            environment: "development",
            challenge: CertificateEnrollmentChallenge(
                authorityID: authority.authorityID,
                environment: "development",
                nonce: Data(repeating: 7, count: 32),
                issuedAtMilliseconds: milliseconds,
                expiresAtMilliseconds: milliseconds + 300_000
            ),
            requestedValidity: 86_400
        )
    }

    private static func response(
        for request: CertificateEnrollmentRequest,
        at date: Date,
        leaf: String,
        authority: CredentialAuthority,
        identity: NodeIdentity
    ) throws -> CertificateEnrollmentResponse {
        try authority.issueCertificateEnrollmentResponse(
            for: ValidatedCertificateEnrollment(
                requestID: request.requestID,
                nodeID: identity.nodeID,
                nodePublicKey: identity.publicKeyRepresentation,
                validity: 86_400
            ),
            leafCertificateDER: Data(leaf.utf8),
            certificateChainDER: [Data("authority".utf8)],
            now: date
        )
    }
}

private actor StubRenewalRequester: CertificateRenewalRequesting {
    private var results: [Result<CertificateRenewalExchange, Error>]

    init(results: [Result<CertificateRenewalExchange, Error>]) {
        self.results = results
    }

    func renewCertificate() async throws -> CertificateRenewalExchange {
        try results.removeFirst().get()
    }
}

private final class RecordingCertificateInstaller: CertificateIdentityInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var leaf: Data?

    func install(response: CertificateEnrollmentResponse, nodeIdentity: NodeIdentity) throws {
        lock.withLock { leaf = response.leafCertificateDER }
    }

    func installedLeaf() -> Data? {
        lock.withLock { leaf }
    }
}

private enum TestRenewalError: Error {
    case offline
}
