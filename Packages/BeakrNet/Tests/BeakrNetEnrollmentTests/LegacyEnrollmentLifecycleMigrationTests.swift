import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetEnrollment
import BeakrNetSecurity

@Suite("Legacy enrollment lifecycle migration")
struct LegacyEnrollmentLifecycleMigrationTests {
    @Test("Verified legacy trust state creates one member checkpoint")
    func migratesVerifiedMember() async throws {
        let fixture = try LegacyMigrationFixture()
        let result = try await fixture.migrator.migrate(legacy: fixture.input)
        guard case .migrated(let record) = result else {
            Issue.record("Expected a migrated lifecycle")
            return
        }
        #expect(record.phase == .member)
        #expect(record.installationID == fixture.input.profile.id.rawValue)
        #expect(record.network?.activeCredentialID == fixture.input.credential.claims.credentialID)
        #expect(record.network?.membershipGeneration == fixture.input.membership.claims.generation)
    }

    @Test("Repeated migration returns the exact durable record")
    func isIdempotent() async throws {
        let fixture = try LegacyMigrationFixture()
        let first = try await fixture.migrator.migrate(legacy: fixture.input)
        let second = try await fixture.migrator.migrate(legacy: fixture.input)
        guard case .migrated(let migrated) = first,
              case .existing(let existing) = second else {
            Issue.record("Expected migrated then existing")
            return
        }
        #expect(existing == migrated)
    }

    @Test("A missing identity binding cannot be migrated")
    func rejectsIdentityMismatch() async throws {
        let fixture = try LegacyMigrationFixture(identity: NodeIdentity())
        await #expect(throws: LegacyEnrollmentMigrationError.identityMismatch) {
            try await fixture.migrator.migrate(legacy: fixture.input)
        }
        #expect(await fixture.store.load() == nil)
    }

    @Test("Stale revocation state cannot become a member checkpoint")
    func rejectsStaleRevocations() async throws {
        let fixture = try LegacyMigrationFixture(now: Date(timeIntervalSince1970: 200_000))
        await #expect(throws: LegacyEnrollmentMigrationError.staleRevocationState) {
            try await fixture.migrator.migrate(legacy: fixture.input)
        }
        #expect(await fixture.store.load() == nil)
    }

    @Test("No legacy profile leaves lifecycle storage untouched")
    func noLegacyProfile() async throws {
        let fixture = try LegacyMigrationFixture()
        #expect(try await fixture.migrator.migrate(legacy: nil) == .noLegacyProfile)
        #expect(await fixture.store.load() == nil)
    }
}

private struct LegacyMigrationFixture {
    let input: LegacyEnrollmentMigrationInput
    let store = InMemoryEnrollmentLifecycleStore()
    let migrator: LegacyEnrollmentLifecycleMigrator

    init(identity suppliedIdentity: NodeIdentity? = nil, now: Date = Date(timeIntervalSince1970: 2_000)) throws {
        let authority = CredentialAuthority()
        let enrolledIdentity = NodeIdentity()
        let identity = suppliedIdentity ?? enrolledIdentity
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: enrolledIdentity.nodeID,
            nodePublicKey: enrolledIdentity.publicKeyRepresentation,
            networkID: networkID,
            environment: "production",
            validity: 300_000,
            serviceScopes: ["lan"],
            now: Date(timeIntervalSince1970: 1_000)
        )
        let membership = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        ).sign(ProfileMembershipClaims(
            networkID: networkID,
            networkDisplayName: "Family",
            generation: 7,
            generatedAtMilliseconds: 1_000_000,
            records: [ProfileMembershipRecord(
                credential: credential,
                certificatePublicKey: enrolledIdentity.publicKeyRepresentation,
                sessionID: SessionID()
            )]
        ))
        let revocations = try authority.issueRevocationSnapshot(
            revocations: [],
            now: Date(timeIntervalSince1970: 1_000)
        )
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: enrolledIdentity.nodeID,
            displayName: "Family",
            createdAt: Date(timeIntervalSince1970: 900)
        )
        input = LegacyEnrollmentMigrationInput(
            profile: profile,
            environment: "production",
            authorityPublicKey: authority.publicKeyRepresentation,
            controlPlaneURL: URL(string: "https://authority.example"),
            identity: identity,
            credential: credential,
            membership: membership,
            revocations: revocations
        )
        migrator = try LegacyEnrollmentLifecycleMigrator(
            lifecycleStore: store,
            maximumRevocationAge: 24 * 60 * 60,
            now: { now }
        )
    }
}
