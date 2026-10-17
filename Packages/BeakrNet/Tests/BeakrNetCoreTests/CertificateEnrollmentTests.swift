import Foundation
import Testing
import BeakrNetCore
import BeakrNetSecurity
@testable import BeakrNetAuthority

@Suite("Certificate enrollment contract")
struct CertificateEnrollmentTests {
    @Test("A node-signed request validates once")
    func validRequest() async throws {
        let fixture = try Fixture()
        let result = try await fixture.validator.validate(fixture.request, now: fixture.now)
        #expect(result.nodeID == fixture.identity.nodeID)
        #expect(result.nodePublicKey == fixture.identity.publicKeyRepresentation)
        #expect(result.validity == 86_400)
    }

    @Test("An accepted challenge cannot be replayed")
    func replay() async throws {
        let fixture = try Fixture()
        _ = try await fixture.validator.validate(fixture.request, now: fixture.now)
        await #expect(throws: CertificateEnrollmentError.replayedChallenge) {
            try await fixture.validator.validate(fixture.request, now: fixture.now)
        }
    }

    @Test("An expired challenge is rejected")
    func expiredChallenge() async throws {
        let fixture = try Fixture(challengeOffset: -600)
        await #expect(throws: CertificateEnrollmentError.expiredChallenge) {
            try await fixture.validator.validate(
                fixture.request,
                now: fixture.now,
                allowedClockSkew: 0
            )
        }
    }

    @Test("A request for another environment is rejected")
    func wrongEnvironment() async throws {
        let fixture = try Fixture(requestEnvironment: "production")
        await #expect(throws: CertificateEnrollmentError.wrongEnvironment) {
            try await fixture.validator.validate(fixture.request, now: fixture.now)
        }
    }

    @Test("A credential without LAN scope is rejected")
    func missingScope() async throws {
        let fixture = try Fixture(scopes: ["relay"])
        await #expect(throws: CertificateEnrollmentError.missingLANScope) {
            try await fixture.validator.validate(fixture.request, now: fixture.now)
        }
    }

    @Test("A signature not made by the enrolled node is rejected")
    func wrongKey() async throws {
        let fixture = try Fixture()
        let request = CertificateEnrollmentRequest(
            requestID: fixture.request.requestID,
            nodeID: fixture.request.nodeID,
            nodePublicKey: fixture.request.nodePublicKey,
            credential: fixture.request.credential,
            environment: fixture.request.environment,
            challenge: fixture.request.challenge,
            requestedValiditySeconds: fixture.request.requestedValiditySeconds,
            signature: Data(repeating: 0, count: 64)
        )
        await #expect(throws: CertificateEnrollmentError.invalidSignature) {
            try await fixture.validator.validate(request, now: fixture.now)
        }
    }

    @Test("Certificate validity is capped at 30 days")
    func excessiveValidity() async throws {
        let fixture = try Fixture(requestedValidity: 30 * 24 * 60 * 60 + 1)
        await #expect(throws: CertificateEnrollmentError.invalidRequestedValidity) {
            try await fixture.validator.validate(fixture.request, now: fixture.now)
        }
    }

    @Test("Enrollment service issues for the exact validated node key")
    func serviceIssuesExactKey() async throws {
        let fixture = try Fixture()
        let issuer = RecordingCertificateIssuer()
        let service = CertificateEnrollmentService(
            validator: fixture.validator,
            authority: fixture.authority,
            issuer: issuer
        )

        let response = try await service.enroll(fixture.request, now: fixture.now)
        let invocation = await issuer.invocation
        #expect(invocation?.nodeID == fixture.identity.nodeID)
        #expect(invocation?.nodePublicKey == fixture.identity.publicKeyRepresentation)
        #expect(invocation?.validity == 86_400)
        #expect(response.leafCertificateDER == Data("issued-leaf".utf8))
        try CertificateEnrollmentResponseVerifier.verify(
            response,
            for: fixture.request,
            trustedAuthorityPublicKey: fixture.authority.publicKeyRepresentation
        )
    }

    @Test("An authority-signed certificate response verifies and round trips")
    func validResponse() async throws {
        let fixture = try Fixture()
        let enrollment = try await fixture.validator.validate(fixture.request, now: fixture.now)
        let response = try fixture.authority.issueCertificateEnrollmentResponse(
            for: enrollment,
            leafCertificateDER: Data("leaf".utf8),
            certificateChainDER: [Data("authority".utf8)],
            now: fixture.now
        )

        try CertificateEnrollmentResponseVerifier.verify(
            response,
            for: fixture.request,
            trustedAuthorityPublicKey: fixture.authority.publicKeyRepresentation
        )
        let encoded = try CertificateEnrollmentResponseWireCodec.encode(response)
        #expect(try CertificateEnrollmentResponseWireCodec.decode(encoded) == response)
    }

    @Test("Changing issued certificate bytes invalidates the response")
    func tamperedResponse() async throws {
        let fixture = try Fixture()
        let enrollment = try await fixture.validator.validate(fixture.request, now: fixture.now)
        let response = try fixture.authority.issueCertificateEnrollmentResponse(
            for: enrollment,
            leafCertificateDER: Data("leaf".utf8),
            certificateChainDER: [],
            now: fixture.now
        )
        let tampered = CertificateEnrollmentResponse(
            requestID: response.requestID,
            authorityID: response.authorityID,
            nodeID: response.nodeID,
            nodePublicKey: response.nodePublicKey,
            issuedAtMilliseconds: response.issuedAtMilliseconds,
            expiresAtMilliseconds: response.expiresAtMilliseconds,
            leafCertificateDER: Data("different-leaf".utf8),
            certificateChainDER: response.certificateChainDER,
            authoritySignature: response.authoritySignature
        )
        #expect(throws: CertificateEnrollmentResponseError.invalidSignature) {
            try CertificateEnrollmentResponseVerifier.verify(
                tampered,
                for: fixture.request,
                trustedAuthorityPublicKey: fixture.authority.publicKeyRepresentation
            )
        }
    }

    @Test("A response cannot be substituted onto another request")
    func wrongResponseRequest() async throws {
        let fixture = try Fixture()
        let enrollment = try await fixture.validator.validate(fixture.request, now: fixture.now)
        let response = try fixture.authority.issueCertificateEnrollmentResponse(
            for: enrollment,
            leafCertificateDER: Data("leaf".utf8),
            certificateChainDER: [],
            now: fixture.now
        )
        let other = try Fixture(requestID: UUID()).request
        #expect(throws: CertificateEnrollmentResponseError.wrongRequest) {
            try CertificateEnrollmentResponseVerifier.verify(
                response,
                for: other,
                trustedAuthorityPublicKey: fixture.authority.publicKeyRepresentation
            )
        }
    }

    @Test("Canonical enrollment wire bytes round trip and reject alternate encoding")
    func canonicalWireEncoding() throws {
        let fixture = try Fixture()
        let encoded = try CertificateEnrollmentWireCodec.encode(fixture.request)
        #expect(try CertificateEnrollmentWireCodec.decode(encoded) == fixture.request)
        #expect(throws: CertificateEnrollmentWireError.nonCanonicalRequest) {
            try CertificateEnrollmentWireCodec.decode(Data(" \n".utf8) + encoded)
        }
        #expect(throws: CertificateEnrollmentWireError.malformedRequest) {
            try CertificateEnrollmentWireCodec.decode(Data("{}".utf8))
        }
    }
}

private actor RecordingCertificateIssuer: CertificateMaterialIssuing {
    struct Invocation: Sendable {
        let nodeID: NodeID
        let nodePublicKey: Data
        let validity: TimeInterval
    }

    private(set) var invocation: Invocation?

    func issueCertificate(
        nodeID: NodeID,
        nodePublicKey: Data,
        certificateSigningRequestDER: Data,
        validity: TimeInterval,
        now: Date
    ) async throws -> IssuedCertificateMaterial {
        invocation = Invocation(
            nodeID: nodeID,
            nodePublicKey: nodePublicKey,
            validity: validity
        )
        return IssuedCertificateMaterial(
            leafCertificateDER: Data("issued-leaf".utf8),
            certificateChainDER: [Data("issued-authority".utf8)]
        )
    }
}

private struct Fixture {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let environment = "development"
    let authority = CredentialAuthority()
    let identity = NodeIdentity()
    let validator: CertificateEnrollmentValidator
    let request: CertificateEnrollmentRequest

    init(
        requestID: UUID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
        challengeOffset: TimeInterval = 0,
        requestEnvironment: String? = nil,
        scopes: [String] = ["lan"],
        requestedValidity: TimeInterval = 86_400
    ) throws {
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: .test,
            environment: environment,
            validity: 3_600,
            serviceScopes: scopes,
            now: now
        )
        let issued = now.addingTimeInterval(challengeOffset)
        let challenge = CertificateEnrollmentChallenge(
            challengeID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            authorityID: authority.authorityID,
            environment: environment,
            nonce: Data(repeating: 0xa5, count: 32),
            issuedAtMilliseconds: Int64(issued.timeIntervalSince1970 * 1_000),
            expiresAtMilliseconds: Int64(issued.addingTimeInterval(300).timeIntervalSince1970 * 1_000)
        )
        request = try CertificateEnrollmentRequest.signed(
            requestID: requestID,
            identity: identity,
            credential: credential,
            environment: requestEnvironment ?? environment,
            challenge: challenge,
            requestedValidity: requestedValidity
        )
        validator = CertificateEnrollmentValidator(
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: .test,
            environment: environment
        )
    }
}
