import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

@Suite("Authority rotation")
struct AuthorityRotationTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("A signed transition overlaps trust and retires the previous authority on time")
    func overlapAndRetirement() throws {
        let old = CredentialAuthority()
        let next = CredentialAuthority()
        let statement = try old.issueRotationStatement(
            nextAuthorityPublicKey: next.publicKeyRepresentation,
            generation: 1,
            environment: "production",
            overlapDuration: 3_600,
            now: now
        )
        let initial = try AuthorityTrustState(
            environment: "production",
            currentAuthorityPublicKey: old.publicKeyRepresentation
        )
        let rotated = try initial.applying(statement, now: now)

        #expect(rotated.generation == 1)
        #expect(rotated.trustedAuthorityPublicKeys(at: now) == [
            next.publicKeyRepresentation,
            old.publicKeyRepresentation
        ])
        #expect(rotated.publicKey(for: old.authorityID, at: now) == old.publicKeyRepresentation)
        #expect(rotated.trustedAuthorityPublicKeys(at: now.addingTimeInterval(3_600)) == [
            next.publicKeyRepresentation
        ])
        #expect(rotated.publicKey(for: old.authorityID, at: now.addingTimeInterval(3_600)) == nil)
    }

    @Test("Tampering with rotation metadata invalidates the signature")
    func tampering() throws {
        let old = CredentialAuthority()
        let next = CredentialAuthority()
        let valid = try old.issueRotationStatement(
            nextAuthorityPublicKey: next.publicKeyRepresentation,
            generation: 1,
            environment: "production",
            overlapDuration: 3_600,
            now: now
        )
        let altered = AuthorityRotationStatement(
            generation: valid.generation,
            environment: valid.environment,
            previousAuthorityID: valid.previousAuthorityID,
            nextAuthorityID: valid.nextAuthorityID,
            nextAuthorityPublicKey: valid.nextAuthorityPublicKey,
            issuedAtMilliseconds: valid.issuedAtMilliseconds,
            overlapEndsAtMilliseconds: valid.overlapEndsAtMilliseconds + 1_000,
            previousAuthoritySignature: valid.previousAuthoritySignature
        )
        #expect(throws: AuthorityRotationError.invalidSignature) {
            try AuthorityRotationVerifier.verify(
                altered,
                trustedPreviousAuthorityPublicKey: old.publicKeyRepresentation,
                environment: "production",
                now: now
            )
        }
    }

    @Test("Another authority cannot introduce a replacement")
    func wrongSigner() throws {
        let trusted = CredentialAuthority()
        let attacker = CredentialAuthority()
        let next = CredentialAuthority()
        let statement = try attacker.issueRotationStatement(
            nextAuthorityPublicKey: next.publicKeyRepresentation,
            generation: 1,
            environment: "production",
            overlapDuration: 3_600,
            now: now
        )
        #expect(throws: AuthorityRotationError.wrongPreviousAuthority) {
            try AuthorityRotationVerifier.verify(
                statement,
                trustedPreviousAuthorityPublicKey: trusted.publicKeyRepresentation,
                environment: "production",
                now: now
            )
        }
    }

    @Test("A device that missed the overlap cannot trust a stale transition")
    func expiredTransition() throws {
        let old = CredentialAuthority()
        let statement = try old.issueRotationStatement(
            nextAuthorityPublicKey: CredentialAuthority().publicKeyRepresentation,
            generation: 1,
            environment: "production",
            overlapDuration: 3_600,
            now: now
        )
        #expect(throws: AuthorityRotationError.transitionExpired) {
            try AuthorityRotationVerifier.verify(
                statement,
                trustedPreviousAuthorityPublicKey: old.publicKeyRepresentation,
                environment: "production",
                now: now.addingTimeInterval(3_661)
            )
        }
    }

    @Test("Generation must advance exactly once and prevents replay or skipped state")
    func rollbackProtection() throws {
        let old = CredentialAuthority()
        let next = CredentialAuthority()
        let initial = try AuthorityTrustState(
            environment: "production",
            currentAuthorityPublicKey: old.publicKeyRepresentation
        )
        let first = try old.issueRotationStatement(
            nextAuthorityPublicKey: next.publicKeyRepresentation,
            generation: 1,
            environment: "production",
            overlapDuration: 3_600,
            now: now
        )
        let rotated = try initial.applying(first, now: now)
        #expect(throws: AuthorityRotationError.nonSequentialGeneration) {
            try rotated.applying(first, now: now)
        }
        let skipped = try next.issueRotationStatement(
            nextAuthorityPublicKey: CredentialAuthority().publicKeyRepresentation,
            generation: 3,
            environment: "production",
            overlapDuration: 3_600,
            now: now
        )
        #expect(throws: AuthorityRotationError.nonSequentialGeneration) {
            try rotated.applying(skipped, now: now)
        }
    }

    @Test("A subsequent transition is authorized by the current authority and persists canonically")
    func chainedRotationAndPersistence() throws {
        let first = CredentialAuthority()
        let second = CredentialAuthority()
        let third = CredentialAuthority()
        let initial = try AuthorityTrustState(
            environment: "production",
            currentAuthorityPublicKey: first.publicKeyRepresentation
        )
        let state1 = try initial.applying(
            first.issueRotationStatement(
                nextAuthorityPublicKey: second.publicKeyRepresentation,
                generation: 1,
                environment: "production",
                overlapDuration: 3_600,
                now: now
            ),
            now: now
        )
        let state2 = try state1.applying(
            second.issueRotationStatement(
                nextAuthorityPublicKey: third.publicKeyRepresentation,
                generation: 2,
                environment: "production",
                overlapDuration: 7_200,
                now: now.addingTimeInterval(60)
            ),
            now: now.addingTimeInterval(60)
        )

        #expect(state2.trustedAuthorityPublicKeys(at: now.addingTimeInterval(60)) == [
            third.publicKeyRepresentation,
            second.publicKeyRepresentation
        ])
        #expect(state2.publicKey(for: first.authorityID, at: now.addingTimeInterval(60)) == nil)
        let encoded = try JSONEncoder().encode(state2)
        #expect(try JSONDecoder().decode(AuthorityTrustState.self, from: encoded) == state2)
    }

    @Test("Credentials from both authorities verify only during the overlap")
    func credentialOverlap() throws {
        let old = CredentialAuthority()
        let next = CredentialAuthority()
        let identity = NodeIdentity()
        let oldCredential = try old.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: .test,
            environment: "production",
            validity: 7_200,
            now: now
        )
        let nextCredential = try next.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: .test,
            environment: "production",
            validity: 7_200,
            now: now
        )
        let initial = try AuthorityTrustState(
            environment: "production",
            currentAuthorityPublicKey: old.publicKeyRepresentation
        )
        let rotated = try initial.applying(
            old.issueRotationStatement(
                nextAuthorityPublicKey: next.publicKeyRepresentation,
                generation: 1,
                environment: "production",
                overlapDuration: 3_600,
                now: now
            ),
            now: now
        )

        try rotated.verify(oldCredential, networkID: .test, environment: "production", now: now)
        try rotated.verify(nextCredential, networkID: .test, environment: "production", now: now)
        #expect(throws: CredentialVerificationError.wrongIssuer) {
            try rotated.verify(
                oldCredential,
                networkID: .test,
                environment: "production",
                now: now.addingTimeInterval(3_600)
            )
        }
        try rotated.verify(
            nextCredential,
            networkID: .test,
            environment: "production",
            now: now.addingTimeInterval(3_600)
        )
    }
}
