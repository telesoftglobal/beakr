import Foundation
import BeakrNetCore
import BeakrNetAuthority

public actor PersistentAuthorityMembershipPublisher: AuthorityMembershipPublishing {
    private struct MembershipEntry: Codable {
        let transactionID: UUID
        let membership: ProfileMembershipSnapshot
    }

    private struct Snapshot: Codable {
        static let currentVersion = 1

        let version: Int
        let membership: ProfileMembershipSnapshot
        let revocations: CredentialRevocationSnapshot
        let stagedMemberships: [MembershipEntry]
        let activatedTransactionIDs: [UUID]
    }

    public let fileURL: URL
    private var membership: ProfileMembershipSnapshot
    private var revocations: CredentialRevocationSnapshot
    private var staged: [UUID: ProfileMembershipSnapshot]
    private var activatedTransactionIDs: Set<UUID>

    private init(fileURL: URL, snapshot: Snapshot) {
        self.fileURL = fileURL
        membership = snapshot.membership
        revocations = snapshot.revocations
        staged = Dictionary(uniqueKeysWithValues: snapshot.stagedMemberships.map {
            ($0.transactionID, $0.membership)
        })
        activatedTransactionIDs = Set(snapshot.activatedTransactionIDs)
    }

    public static func open(
        fileURL: URL,
        initialMembership: ProfileMembershipSnapshot? = nil,
        initialRevocations: CredentialRevocationSnapshot? = nil
    ) throws -> PersistentAuthorityMembershipPublisher {
        let snapshot: Snapshot
        if let existing = try EnrollmentPersistence.load(Snapshot.self, from: fileURL) {
            snapshot = existing
        } else {
            guard let initialMembership, let initialRevocations else {
                throw EnrollmentPersistenceError.missingInitialState
            }
            snapshot = Snapshot(
                version: Snapshot.currentVersion,
                membership: initialMembership,
                revocations: initialRevocations,
                stagedMemberships: [],
                activatedTransactionIDs: []
            )
            try EnrollmentPersistence.persist(snapshot, to: fileURL)
        }
        try validate(snapshot)
        return PersistentAuthorityMembershipPublisher(fileURL: fileURL, snapshot: snapshot)
    }

    public func currentMembership() -> ProfileMembershipSnapshot { membership }
    public func currentRevocations() -> CredentialRevocationSnapshot { revocations }

    public func stageMembership(_ membership: ProfileMembershipSnapshot, transactionID: UUID) throws {
        if let existing = staged[transactionID] {
            guard existing == membership else { throw AuthorityEnrollmentError.approvalConflict }
            return
        }
        guard membership.claims.networkID == self.membership.claims.networkID,
              membership.claims.generation == self.membership.claims.generation + 1 else {
            throw EnrollmentPersistenceError.invalidSnapshot
        }
        let previous = snapshot()
        staged[transactionID] = membership
        try persistOrRestore(previous)
    }

    public func activateMembership(transactionID: UUID) throws {
        guard let proposed = staged[transactionID] else {
            if activatedTransactionIDs.contains(transactionID) { return }
            throw AuthorityEnrollmentError.invalidApprovalTransaction
        }
        guard proposed.claims.generation == membership.claims.generation + 1 else {
            if proposed == membership {
                staged.removeValue(forKey: transactionID)
                return
            }
            throw EnrollmentPersistenceError.invalidSnapshot
        }
        let previous = snapshot()
        membership = proposed
        staged.removeValue(forKey: transactionID)
        activatedTransactionIDs.insert(transactionID)
        try persistOrRestore(previous)
    }

    public func discardStagedMembership(transactionID: UUID) throws {
        guard staged[transactionID] != nil else { return }
        let previous = snapshot()
        staged.removeValue(forKey: transactionID)
        try persistOrRestore(previous)
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            version: Snapshot.currentVersion,
            membership: membership,
            revocations: revocations,
            stagedMemberships: staged.map { MembershipEntry(transactionID: $0.key, membership: $0.value) }
                .sorted { $0.transactionID.uuidString < $1.transactionID.uuidString },
            activatedTransactionIDs: activatedTransactionIDs.sorted { $0.uuidString < $1.uuidString }
        )
    }

    private func persistOrRestore(_ previous: Snapshot) throws {
        do { try EnrollmentPersistence.persist(snapshot(), to: fileURL) }
        catch { restore(previous); throw error }
    }

    private func restore(_ snapshot: Snapshot) {
        membership = snapshot.membership
        revocations = snapshot.revocations
        staged = Dictionary(uniqueKeysWithValues: snapshot.stagedMemberships.map {
            ($0.transactionID, $0.membership)
        })
        activatedTransactionIDs = Set(snapshot.activatedTransactionIDs)
    }

    private static func validate(_ snapshot: Snapshot) throws {
        guard snapshot.version == Snapshot.currentVersion else {
            throw EnrollmentPersistenceError.unsupportedVersion(snapshot.version)
        }
        guard snapshot.stagedMemberships.count <= AuthorityPolicy.maximumCollectionCapacity,
              Set(snapshot.stagedMemberships.map(\.transactionID)).count == snapshot.stagedMemberships.count,
              Set(snapshot.activatedTransactionIDs).count == snapshot.activatedTransactionIDs.count,
              Set(snapshot.stagedMemberships.map(\.transactionID)).isDisjoint(
                with: Set(snapshot.activatedTransactionIDs)
              ),
              snapshot.stagedMemberships.allSatisfy({
                  $0.membership.claims.networkID == snapshot.membership.claims.networkID &&
                  $0.membership.claims.generation == snapshot.membership.claims.generation + 1
              }) else {
            throw EnrollmentPersistenceError.invalidSnapshot
        }
    }
}
