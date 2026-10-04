import Foundation
import Testing
import BeakrNetAuthority

@Suite("Authority recovery")
struct AuthorityRecoveryTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("An explicitly applied offline recovery package replaces stale trust")
    func recovery() throws {
        let stale = CredentialAuthority()
        let replacement = CredentialAuthority()
        let recovery = AuthorityRecoverySigner()
        let state = try AuthorityTrustState(
            generation: 2,
            environment: "production",
            currentAuthorityPublicKey: stale.publicKeyRepresentation
        )
        let package = try recovery.issueRecoveryPackage(
            replacementAuthorityPublicKey: replacement.publicKeyRepresentation,
            targetGeneration: 7,
            environment: "production",
            now: now
        )
        let recovered = try state.recovering(
            with: package,
            trustedRecoveryPublicKey: recovery.publicKeyRepresentation,
            now: now
        )

        #expect(recovered.generation == 7)
        #expect(recovered.currentAuthorityPublicKey == replacement.publicKeyRepresentation)
        #expect(recovered.previousAuthorityPublicKey == nil)
        #expect(recovered.publicKey(for: stale.authorityID, at: now) == nil)
    }

    @Test("A recovery package from an unpinned key is rejected")
    func wrongRecoveryKey() throws {
        let trusted = AuthorityRecoverySigner()
        let attacker = AuthorityRecoverySigner()
        let package = try attacker.issueRecoveryPackage(
            replacementAuthorityPublicKey: CredentialAuthority().publicKeyRepresentation,
            targetGeneration: 2,
            environment: "production",
            now: now
        )
        #expect(throws: AuthorityRecoveryError.wrongRecoveryKey) {
            try AuthorityRecoveryVerifier.verify(
                package,
                trustedRecoveryPublicKey: trusted.publicKeyRepresentation,
                environment: "production",
                now: now
            )
        }
    }

    @Test("Expired and future recovery packages fail closed")
    func timeBounds() throws {
        let recovery = AuthorityRecoverySigner()
        let package = try recovery.issueRecoveryPackage(
            replacementAuthorityPublicKey: CredentialAuthority().publicKeyRepresentation,
            targetGeneration: 2,
            environment: "production",
            validity: 300,
            now: now
        )
        #expect(throws: AuthorityRecoveryError.expired) {
            try AuthorityRecoveryVerifier.verify(
                package,
                trustedRecoveryPublicKey: recovery.publicKeyRepresentation,
                environment: "production",
                now: now.addingTimeInterval(361)
            )
        }
        #expect(throws: AuthorityRecoveryError.issuedInFuture) {
            try AuthorityRecoveryVerifier.verify(
                package,
                trustedRecoveryPublicKey: recovery.publicKeyRepresentation,
                environment: "production",
                now: now.addingTimeInterval(-61)
            )
        }
    }

    @Test("Recovery generations cannot replay or roll trust backward")
    func generationRollback() throws {
        let recovery = AuthorityRecoverySigner()
        let state = try AuthorityTrustState(
            generation: 5,
            environment: "production",
            currentAuthorityPublicKey: CredentialAuthority().publicKeyRepresentation
        )
        let package = try recovery.issueRecoveryPackage(
            replacementAuthorityPublicKey: CredentialAuthority().publicKeyRepresentation,
            targetGeneration: 5,
            environment: "production",
            now: now
        )
        #expect(throws: AuthorityRecoveryError.nonIncreasingGeneration) {
            try state.recovering(
                with: package,
                trustedRecoveryPublicKey: recovery.publicKeyRepresentation,
                now: now
            )
        }
    }

    @Test("Tampering with the replacement or generation invalidates recovery")
    func tampering() throws {
        let recovery = AuthorityRecoverySigner()
        let package = try recovery.issueRecoveryPackage(
            replacementAuthorityPublicKey: CredentialAuthority().publicKeyRepresentation,
            targetGeneration: 3,
            environment: "production",
            now: now
        )
        let altered = AuthorityRecoveryPackage(
            targetGeneration: 4,
            environment: package.environment,
            recoveryKeyID: package.recoveryKeyID,
            replacementAuthorityID: package.replacementAuthorityID,
            replacementAuthorityPublicKey: package.replacementAuthorityPublicKey,
            issuedAtMilliseconds: package.issuedAtMilliseconds,
            expiresAtMilliseconds: package.expiresAtMilliseconds,
            recoverySignature: package.recoverySignature
        )
        #expect(throws: AuthorityRecoveryError.invalidSignature) {
            try AuthorityRecoveryVerifier.verify(
                altered,
                trustedRecoveryPublicKey: recovery.publicKeyRepresentation,
                environment: "production",
                now: now
            )
        }
    }
}
