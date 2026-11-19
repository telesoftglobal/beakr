import Foundation
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

public struct LegacyEnrollmentMigrationInput: Sendable {
    public let profile: NetworkProfile
    public let environment: String
    public let authorityPublicKey: Data
    public let controlPlaneURL: URL?
    public let identity: NodeIdentity
    public let credential: NodeCredential
    public let membership: ProfileMembershipSnapshot
    public let revocations: CredentialRevocationSnapshot
    public let localAuthority: LocalAuthorityBinding?

    public init(
        profile: NetworkProfile,
        environment: String,
        authorityPublicKey: Data,
        controlPlaneURL: URL?,
        identity: NodeIdentity,
        credential: NodeCredential,
        membership: ProfileMembershipSnapshot,
        revocations: CredentialRevocationSnapshot,
        localAuthority: LocalAuthorityBinding? = nil
    ) {
        self.profile = profile
        self.environment = environment
        self.authorityPublicKey = authorityPublicKey
        self.controlPlaneURL = controlPlaneURL
        self.identity = identity
        self.credential = credential
        self.membership = membership
        self.revocations = revocations
        self.localAuthority = localAuthority
    }
}

public enum LegacyEnrollmentMigrationResult: Equatable, Sendable {
    case noLegacyProfile
    case existing(EnrollmentLifecycleRecord)
    case migrated(EnrollmentLifecycleRecord)
}

public enum LegacyEnrollmentMigrationError: Error, Equatable, Sendable {
    case invalidPolicy
    case identityMismatch
    case credentialNotInMembership
    case staleRevocationState
    case invalidRevocationGeneration
    case conflictingLifecycle
}

public actor LegacyEnrollmentLifecycleMigrator {
    private let lifecycleStore: any EnrollmentLifecycleStore
    private let maximumRevocationAge: TimeInterval
    private let allowedClockSkew: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        lifecycleStore: any EnrollmentLifecycleStore,
        maximumRevocationAge: TimeInterval = 24 * 60 * 60,
        allowedClockSkew: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard maximumRevocationAge > 0, allowedClockSkew >= 0 else {
            throw LegacyEnrollmentMigrationError.invalidPolicy
        }
        self.lifecycleStore = lifecycleStore
        self.maximumRevocationAge = maximumRevocationAge
        self.allowedClockSkew = allowedClockSkew
        self.now = now
    }

    public func migrate(
        legacy input: LegacyEnrollmentMigrationInput?
    ) async throws -> LegacyEnrollmentMigrationResult {
        if let existing = try await lifecycleStore.load() {
            guard input.map({ Self.matches(existing, input: $0) }) ?? true else {
                throw LegacyEnrollmentMigrationError.conflictingLifecycle
            }
            return .existing(existing)
        }
        guard let input else { return .noLegacyProfile }

        let record = try makeRecord(input: input)
        do {
            try await lifecycleStore.save(record, condition: .create)
            return .migrated(record)
        } catch EnrollmentLifecycleError.recordAlreadyExists {
            guard let existing = try await lifecycleStore.load(),
                  Self.matches(existing, input: input) else {
                throw LegacyEnrollmentMigrationError.conflictingLifecycle
            }
            return .existing(existing)
        }
    }

    private func makeRecord(
        input: LegacyEnrollmentMigrationInput
    ) throws -> EnrollmentLifecycleRecord {
        guard input.identity.nodeID == input.profile.localNodeID,
              input.credential.claims.nodeID == input.identity.nodeID,
              input.credential.claims.nodePublicKey == input.identity.publicKeyRepresentation else {
            throw LegacyEnrollmentMigrationError.identityMismatch
        }
        let date = now()
        let revoked = try RevocationVerifier.verify(
            input.revocations,
            trustedAuthorityPublicKey: input.authorityPublicKey,
            now: date,
            allowedClockSkew: allowedClockSkew
        )
        let nowMilliseconds = Self.milliseconds(date)
        let maximumAgeMilliseconds = Int64(maximumRevocationAge * 1_000)
        guard input.revocations.claims.generatedAtMilliseconds >= 0 else {
            throw LegacyEnrollmentMigrationError.invalidRevocationGeneration
        }
        guard nowMilliseconds - input.revocations.claims.generatedAtMilliseconds
                <= maximumAgeMilliseconds + Int64(allowedClockSkew * 1_000) else {
            throw LegacyEnrollmentMigrationError.staleRevocationState
        }
        try CredentialVerifier.verify(
            input.credential,
            trustedAuthorityPublicKey: input.authorityPublicKey,
            networkID: input.profile.networkID,
            environment: input.environment,
            revokedCredentialIDs: revoked,
            now: date,
            allowedClockSkew: allowedClockSkew
        )
        try ProfileMembershipVerifier.verify(
            input.membership,
            networkID: input.profile.networkID,
            environment: input.environment,
            trustedAuthorityPublicKey: input.authorityPublicKey,
            revokedCredentialIDs: revoked,
            now: date,
            allowedClockSkew: allowedClockSkew
        )
        guard input.membership.claims.records.contains(where: {
            $0.credential == input.credential
                && $0.certificatePublicKey == input.identity.publicKeyRepresentation
        }) else {
            throw LegacyEnrollmentMigrationError.credentialNotInMembership
        }

        let binding = NetworkBinding(
            networkID: input.profile.networkID,
            displayName: input.profile.displayName,
            environment: input.environment,
            authorityID: CredentialVerifier.authorityID(for: input.authorityPublicKey),
            authorityPublicKey: input.authorityPublicKey,
            activeCredentialID: input.credential.claims.credentialID,
            membershipGeneration: input.membership.claims.generation,
            revocationGeneration: UInt64(input.revocations.claims.generatedAtMilliseconds),
            controlPlaneURL: input.controlPlaneURL
        )
        return try EnrollmentLifecycleRecord(
            installationID: input.profile.id.rawValue,
            phase: .member,
            nodeID: input.identity.nodeID,
            network: binding,
            authority: input.localAuthority,
            createdAtMilliseconds: Self.milliseconds(input.profile.createdAt),
            updatedAtMilliseconds: nowMilliseconds
        )
    }

    private static func matches(
        _ record: EnrollmentLifecycleRecord,
        input: LegacyEnrollmentMigrationInput
    ) -> Bool {
        record.installationID == input.profile.id.rawValue
            && record.nodeID == input.profile.localNodeID
            && record.network?.networkID == input.profile.networkID
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}
