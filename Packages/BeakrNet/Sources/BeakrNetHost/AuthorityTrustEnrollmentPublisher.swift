import Foundation
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetEnrollment
import BeakrNetSecurity

public actor AuthorityTrustEnrollmentPublisher: AuthorityMembershipPublishing {
    private struct Entry: Codable {
        let transactionID: UUID
        let membership: ProfileMembershipSnapshot
    }

    private struct Snapshot: Codable {
        static let currentVersion = 1

        let version: Int
        let staged: [Entry]
        let activatedTransactionIDs: [UUID]
    }

    public let fileURL: URL
    private let trust: AuthorityTrustStateCoordinator
    private let now: @Sendable () -> Date
    private var staged: [UUID: ProfileMembershipSnapshot]
    private var activatedTransactionIDs: Set<UUID>

    private init(
        fileURL: URL,
        trust: AuthorityTrustStateCoordinator,
        now: @escaping @Sendable () -> Date,
        snapshot: Snapshot
    ) {
        self.fileURL = fileURL
        self.trust = trust
        self.now = now
        staged = Dictionary(uniqueKeysWithValues: snapshot.staged.map {
            ($0.transactionID, $0.membership)
        })
        activatedTransactionIDs = Set(snapshot.activatedTransactionIDs)
    }

    public static func open(
        fileURL: URL,
        trust: AuthorityTrustStateCoordinator,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws -> AuthorityTrustEnrollmentPublisher {
        let snapshot: Snapshot
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= AuthorityTrustStateCoordinator.maximumLedgerBytes,
                  let decoded = try? JSONDecoder().decode(Snapshot.self, from: data),
                  try encode(decoded) == data else {
                throw AuthorityTrustEnrollmentPublisherError.invalidSnapshot
            }
            snapshot = decoded
        } else {
            snapshot = Snapshot(version: Snapshot.currentVersion, staged: [], activatedTransactionIDs: [])
        }
        guard snapshot.version == Snapshot.currentVersion,
              Set(snapshot.staged.map(\.transactionID)).count == snapshot.staged.count,
              Set(snapshot.activatedTransactionIDs).count == snapshot.activatedTransactionIDs.count,
              Set(snapshot.staged.map(\.transactionID)).isDisjoint(
                with: Set(snapshot.activatedTransactionIDs)
              ) else {
            throw AuthorityTrustEnrollmentPublisherError.invalidSnapshot
        }
        return AuthorityTrustEnrollmentPublisher(
            fileURL: fileURL,
            trust: trust,
            now: now,
            snapshot: snapshot
        )
    }

    public func currentMembership() async -> ProfileMembershipSnapshot {
        await trust.membershipSnapshot()
    }

    public func currentRevocations() async -> CredentialRevocationSnapshot {
        await trust.revocationSnapshot()
    }

    public func stageMembership(
        _ membership: ProfileMembershipSnapshot,
        transactionID: UUID
    ) async throws {
        if let existing = staged[transactionID] {
            guard existing == membership else { throw AuthorityEnrollmentError.approvalConflict }
            return
        }
        let currentGeneration = await trust.membershipSnapshot().claims.generation
        guard !activatedTransactionIDs.contains(transactionID),
              membership.claims.generation == currentGeneration + 1 else {
            throw AuthorityTrustEnrollmentPublisherError.invalidTransaction
        }
        let previous = snapshot()
        staged[transactionID] = membership
        try persistOrRestore(previous)
    }

    public func activateMembership(transactionID: UUID) async throws {
        if activatedTransactionIDs.contains(transactionID) { return }
        guard let membership = staged[transactionID] else {
            throw AuthorityTrustEnrollmentPublisherError.invalidTransaction
        }

        // The ledger commit precedes transaction finalization. If the process
        // stops between them, replay observes the same membership and completes.
        try await trust.installMembershipSnapshot(membership, now: now())
        let previous = snapshot()
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
            staged: staged.map { Entry(transactionID: $0.key, membership: $0.value) }
                .sorted { $0.transactionID.uuidString < $1.transactionID.uuidString },
            activatedTransactionIDs: activatedTransactionIDs.sorted {
                $0.uuidString < $1.uuidString
            }
        )
    }

    private func persistOrRestore(_ previous: Snapshot) throws {
        do { try Self.persist(snapshot(), to: fileURL) }
        catch { restore(previous); throw error }
    }

    private func restore(_ snapshot: Snapshot) {
        staged = Dictionary(uniqueKeysWithValues: snapshot.staged.map {
            ($0.transactionID, $0.membership)
        })
        activatedTransactionIDs = Set(snapshot.activatedTransactionIDs)
    }

    private static func persist(_ snapshot: Snapshot, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encode(snapshot).write(to: fileURL, options: .atomic)
    }

    private static func encode(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }
}

public enum AuthorityTrustEnrollmentPublisherError: Error, Equatable, Sendable {
    case invalidSnapshot
    case invalidTransaction
}
