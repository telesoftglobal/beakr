import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetOperations

@Suite("Authority control-plane router")
struct AuthorityControlPlaneRouterTests {
    @Test("Membership and revocation reads route through bounded admission and audit")
    func routesReads() async throws {
        let fixture = try RouterFixture(sourceCapacity: 10)
        let membership = await fixture.router.handle(.init(
            method: "GET", path: ProfileMembershipHTTPEndpoint.path
        ), source: "source-a")
        let revocations = await fixture.router.handle(.init(
            method: "GET", path: RevocationSnapshotHTTPEndpoint.path
        ), source: "source-a")

        #expect(membership.statusCode == 200)
        #expect(revocations.statusCode == 200)
        let events = await fixture.audit.snapshot(now: fixture.now)
        #expect(events.map(\.endpoint) == [.membershipRead, .revocationRead])
        #expect(events.allSatisfy { $0.outcome == .accepted && $0.reason == .authorized })
    }

    @Test("Header and source bounds reject before endpoint work")
    func boundedAdmission() async throws {
        let fixture = try RouterFixture(sourceCapacity: 1)
        let oversized = await fixture.router.handle(.init(
            method: "GET",
            path: ProfileMembershipHTTPEndpoint.path,
            headers: ["x-large": String(repeating: "x", count: 65)]
        ), source: "source-a")
        #expect(oversized.statusCode == 431)

        #expect(await fixture.router.handle(.init(
            method: "GET", path: ProfileMembershipHTTPEndpoint.path
        ), source: "source-b").statusCode == 200)
        let overloaded = await fixture.router.handle(.init(
            method: "GET", path: ProfileMembershipHTTPEndpoint.path
        ), source: "source-b")
        #expect(overloaded.statusCode == 429)
        #expect(overloaded.headers["retry-after"] == "1")
    }
}

private struct RouterFixture {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let audit: OperationalAuditJournal
    let router: AuthorityControlPlaneRouter

    init(sourceCapacity: Int) throws {
        let fixedNow = now
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let membership = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        ).sign(.init(
            networkID: networkID,
            generation: 0,
            generatedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            records: []
        ))
        let validator = CertificateEnrollmentValidator(
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: networkID,
            environment: "test"
        )
        let enrollment = CertificateEnrollmentHTTPEndpoint(
            challenges: try .init(authorityID: authority.authorityID, environment: "test"),
            enrollment: .init(
                validator: validator,
                authority: authority,
                issuer: RouterCertificateIssuer()
            ),
            now: { fixedNow }
        )
        let profile = BeakrNetProductionProfile(
            environment: "production",
            enrollmentURL: URL(string: "https://authority.example/enrollment")!,
            revocationURL: URL(string: "https://authority.example/revocations")!,
            keyCustody: .externalKMS(provider: "kms", keyIdentifier: "key"),
            serviceAuthentication: .mutualTLS,
            perSourceLimit: .init(capacity: sourceCapacity, refillPerSecond: 1),
            perIdentityLimit: .init(capacity: 10, refillPerSecond: 1),
            globalLimit: .init(capacity: 100, refillPerSecond: 1),
            maximumTrackedLimiters: 100,
            offlineRevocationGrace: 60,
            auditRetention: 60,
            maximumAuditEvents: 100,
            backup: .init(retentionCount: 1, maximumAge: 60, encryptionProvider: "kms")
        )
        let admission = try OperationalAdmissionController(
            profile: profile,
            operationLimit: .init(capacity: 100, refillPerSecond: 100),
            clock: { fixedNow }
        )
        audit = .init(maximumEvents: 100, retention: 60)
        router = AuthorityControlPlaneRouter(
            enrollment: enrollment,
            membership: .init(snapshot: membership),
            revocations: .init(snapshot: try authority.issueRevocationSnapshot(revocations: [], now: now)),
            admission: admission,
            audit: audit,
            policy: .init(maximumConcurrentRequests: 4, maximumHeaderCount: 4, maximumHeaderBytes: 64),
            now: { fixedNow }
        )
    }
}

private actor RouterCertificateIssuer: CertificateMaterialIssuing {
    func issueCertificate(
        nodeID: NodeID,
        nodePublicKey: Data,
        certificateSigningRequestDER: Data,
        validity: TimeInterval,
        now: Date
    ) async throws -> IssuedCertificateMaterial {
        .init(leafCertificateDER: Data([1]), certificateChainDER: [])
    }
}
