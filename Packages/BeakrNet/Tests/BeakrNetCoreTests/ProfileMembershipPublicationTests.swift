import Foundation
import Testing
import BeakrNetCore
import BeakrNetSecurity
@testable import BeakrNetAuthority

@Suite("Authority membership publication")
struct ProfileMembershipPublicationTests {
    @Test("Enrollment, renewal, removal, and restart advance durable signed state")
    func mutationLifecycle() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let identity = NodeIdentity()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "test",
            validity: 3_600,
            serviceScopes: ["lan"],
            now: now
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakr-membership-publisher-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("membership.json")
        let publisher = try await ProfileMembershipPublisher.open(
            networkID: networkID,
            environment: "test",
            fileURL: fileURL,
            authorityPrivateKey: authority.privateKeyRepresentation,
            authorityPublicKey: authority.publicKeyRepresentation,
            now: now
        )
        let exchange = enrollmentFixture(
            authority: authority,
            identity: identity,
            credential: credential,
            now: now
        )

        try await publisher.publishEnrollment(request: exchange.0, response: exchange.1, now: now)
        let enrolled = await publisher.latestSnapshot()
        #expect(enrolled.claims.generation == 1)
        #expect(enrolled.claims.records.count == 1)
        let stableSession = try #require(enrolled.claims.records.first?.sessionID)

        try await publisher.publishEnrollment(
            request: exchange.0,
            response: exchange.1,
            now: now.addingTimeInterval(1)
        )
        let renewed = await publisher.latestSnapshot()
        #expect(renewed.claims.generation == 2)
        #expect(renewed.claims.records.first?.sessionID == stableSession)
        let renewedRecord = try #require(renewed.claims.records.first)
        await #expect(throws: ProfileMembershipVerificationError.duplicateNode) {
            try await publisher.replaceAll(
                records: [renewedRecord, renewedRecord],
                now: now.addingTimeInterval(2)
            )
        }
        #expect(await publisher.latestSnapshot().claims.generation == 2)

        try await publisher.remove(nodeID: identity.nodeID, now: now.addingTimeInterval(3))
        #expect(await publisher.latestSnapshot().claims.generation == 3)
        #expect(await publisher.latestSnapshot().claims.records.isEmpty)

        let reopened = try await ProfileMembershipPublisher.open(
            networkID: networkID,
            environment: "test",
            fileURL: fileURL,
            authorityPrivateKey: authority.privateKeyRepresentation,
            authorityPublicKey: authority.publicKeyRepresentation,
            now: now.addingTimeInterval(3)
        )
        #expect(await reopened.latestSnapshot().claims.generation == 3)
        let response = await reopened.endpoint.handle(.init(
            method: "GET",
            path: ProfileMembershipHTTPEndpoint.path
        ))
        #expect(response.statusCode == 200)
        #expect(try ProfileMembershipWireCodec.decode(response.body).claims.generation == 3)
    }

    private func enrollmentFixture(
        authority: CredentialAuthority,
        identity: NodeIdentity,
        credential: NodeCredential,
        now: Date
    ) -> (CertificateEnrollmentRequest, CertificateEnrollmentResponse) {
        let requestID = UUID()
        let request = CertificateEnrollmentRequest(
            requestID: requestID,
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            credential: credential,
            environment: "test",
            challenge: .init(
                authorityID: authority.authorityID,
                environment: "test",
                nonce: Data(repeating: 1, count: 32),
                issuedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
                expiresAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000) + 60_000
            ),
            requestedValiditySeconds: 3_600,
            signature: Data([1])
        )
        let response = CertificateEnrollmentResponse(
            requestID: requestID,
            authorityID: authority.authorityID,
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            issuedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            expiresAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000) + 3_600_000,
            leafCertificateDER: Data([1]),
            certificateChainDER: [],
            authoritySignature: Data([1])
        )
        return (request, response)
    }
}
