import Foundation
import BeakrNetCore

public struct BlackboardPolicy: Equatable, Sendable {
    public let maximumSpaces: Int
    public let maximumMembersPerSpace: Int
    public let maximumRecordsPerSpace: Int
    public let maximumVersionsPerRecord: Int
    public let maximumJournalOperations: Int
    public let maximumValueBytes: Int
    public let maximumAttachmentsPerValue: Int
    public let maximumSubscriptions: Int

    public init(
        maximumSpaces: Int = 64,
        maximumMembersPerSpace: Int = 256,
        maximumRecordsPerSpace: Int = 10_000,
        maximumVersionsPerRecord: Int = 16,
        maximumJournalOperations: Int = 100_000,
        maximumValueBytes: Int = 256 * 1_024,
        maximumAttachmentsPerValue: Int = 32,
        maximumSubscriptions: Int = 1_024
    ) {
        precondition([maximumSpaces, maximumMembersPerSpace, maximumRecordsPerSpace,
                      maximumVersionsPerRecord, maximumJournalOperations, maximumValueBytes,
                      maximumAttachmentsPerValue, maximumSubscriptions].allSatisfy { $0 > 0 })
        self.maximumSpaces = maximumSpaces
        self.maximumMembersPerSpace = maximumMembersPerSpace
        self.maximumRecordsPerSpace = maximumRecordsPerSpace
        self.maximumVersionsPerRecord = maximumVersionsPerRecord
        self.maximumJournalOperations = maximumJournalOperations
        self.maximumValueBytes = maximumValueBytes
        self.maximumAttachmentsPerValue = maximumAttachmentsPerValue
        self.maximumSubscriptions = maximumSubscriptions
    }
}

public enum BlackboardRepositoryError: Error, Equatable, Sendable {
    case unknownSpace
    case unauthorized
    case invalidName
    case invalidOperation
    case unsupportedVersion(UInt16)
    case duplicateOperation
    case missingCausalDependency
    case causalRollback
    case conflictResolutionMismatch
    case membershipRollback
    case resourceLimit
    case compactionBoundaryMismatch
}

public enum BlackboardApplyResult: Equatable, Sendable {
    case applied(record: BlackboardRecord, cursor: BlackboardCursor)
    case duplicate
}

public struct BlackboardSpaceSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion: UInt16 = 1
    public let version: UInt16
    public let spaceID: BlackboardSpaceID
    public let name: String
    public let membershipRevision: UInt64
    public let members: [BlackboardMember]
    public let compactionGeneration: UInt64
    public let frontier: BlackboardFrontier
    public let records: [BlackboardRecord]
    public let journalOffset: UInt64

    public init(
        version: UInt16 = Self.currentVersion,
        spaceID: BlackboardSpaceID,
        name: String,
        membershipRevision: UInt64,
        members: [BlackboardMember],
        compactionGeneration: UInt64,
        frontier: BlackboardFrontier,
        records: [BlackboardRecord],
        journalOffset: UInt64
    ) {
        self.version = version
        self.spaceID = spaceID
        self.name = name
        self.membershipRevision = membershipRevision
        self.members = members
        self.compactionGeneration = compactionGeneration
        self.frontier = frontier
        self.records = records
        self.journalOffset = journalOffset
    }
}

public struct BlackboardIncrementalResult: Equatable, Sendable {
    public let operations: [BlackboardOperation]
    public let cursor: BlackboardCursor
}

public struct BlackboardChange: Equatable, Sendable {
    public let spaceID: BlackboardSpaceID
    public let recordID: BlackboardRecordID
    public let operationID: BlackboardOperationID
    public let cursor: BlackboardCursor
}

public struct BlackboardPersistedSpace: Codable, Equatable, Sendable {
    public let spaceID: BlackboardSpaceID
    public let name: String
    public let membershipRevision: UInt64
    public let members: [BlackboardMember]
    public let compactionGeneration: UInt64
    public let compactedFrontier: BlackboardFrontier
    public let frontier: BlackboardFrontier
    public let records: [BlackboardRecord]
    public let journal: [BlackboardOperation]
}

public struct BlackboardRepositoryState: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public let formatVersion: Int
    public let spaces: [BlackboardPersistedSpace]

    public init(formatVersion: Int = Self.currentFormatVersion, spaces: [BlackboardPersistedSpace]) {
        self.formatVersion = formatVersion
        self.spaces = spaces
    }
}

public actor BlackboardRepository {
    public typealias Subscriber = @Sendable (BlackboardChange) -> Void

    private struct SpaceState: Sendable {
        var name: String
        var membershipRevision: UInt64
        var members: [NodeID: BlackboardMemberRole]
        var compactionGeneration: UInt64 = 0
        var compactedFrontier = BlackboardFrontier()
        var frontier = BlackboardFrontier()
        var records: [BlackboardRecordID: [BlackboardRecordVersion]] = [:]
        var journal: [BlackboardOperation] = []
        var operationIDs: Set<BlackboardOperationID> = []
    }

    private struct Subscription: Sendable {
        let spaceID: BlackboardSpaceID
        let callback: Subscriber
    }

    public let policy: BlackboardPolicy
    private var spaces: [BlackboardSpaceID: SpaceState] = [:]
    private var subscriptions: [BlackboardSubscriptionID: Subscription] = [:]

    public init(policy: BlackboardPolicy = BlackboardPolicy()) { self.policy = policy }

    public init(restoring state: BlackboardRepositoryState, policy: BlackboardPolicy = BlackboardPolicy()) throws {
        guard state.formatVersion == BlackboardRepositoryState.currentFormatVersion else {
            throw BlackboardRepositoryError.unsupportedVersion(UInt16(clamping: state.formatVersion))
        }
        guard state.spaces.count <= policy.maximumSpaces else { throw BlackboardRepositoryError.resourceLimit }
        self.policy = policy
        for persisted in state.spaces {
            guard !persisted.name.isEmpty, persisted.members.count <= policy.maximumMembersPerSpace,
                  persisted.records.count <= policy.maximumRecordsPerSpace,
                  persisted.journal.count <= policy.maximumJournalOperations,
                  persisted.frontier.dominates(persisted.compactedFrontier) else {
                throw BlackboardRepositoryError.invalidOperation
            }
            let members = Dictionary(uniqueKeysWithValues: persisted.members.map { ($0.nodeID, $0.role) })
            guard members.count == persisted.members.count, members.values.contains(.owner) else {
                throw BlackboardRepositoryError.invalidOperation
            }
            let records = Dictionary(uniqueKeysWithValues: persisted.records.map { ($0.recordID, $0.versions) })
            guard records.count == persisted.records.count else { throw BlackboardRepositoryError.invalidOperation }
            spaces[persisted.spaceID] = SpaceState(
                name: persisted.name, membershipRevision: persisted.membershipRevision, members: members,
                compactionGeneration: persisted.compactionGeneration,
                compactedFrontier: persisted.compactedFrontier, frontier: persisted.frontier,
                records: records, journal: persisted.journal,
                operationIDs: Set(persisted.journal.map(\.operationID)).union(records.values.flatMap { $0.map(\.operationID) })
            )
        }
    }

    public func createSpace(id: BlackboardSpaceID = BlackboardSpaceID(), name: String, owner: NodeID) throws {
        guard !name.isEmpty, name.utf8.count <= 128 else { throw BlackboardRepositoryError.invalidName }
        guard spaces[id] == nil, spaces.count < policy.maximumSpaces else { throw BlackboardRepositoryError.resourceLimit }
        spaces[id] = SpaceState(name: name, membershipRevision: 1, members: [owner: .owner])
    }

    public func updateMembers(
        spaceID: BlackboardSpaceID,
        revision: UInt64,
        members: [BlackboardMember],
        authorizedNodeID: NodeID
    ) throws {
        guard var space = spaces[spaceID] else { throw BlackboardRepositoryError.unknownSpace }
        guard space.members[authorizedNodeID] == .owner else { throw BlackboardRepositoryError.unauthorized }
        guard revision > space.membershipRevision else { throw BlackboardRepositoryError.membershipRollback }
        guard !members.isEmpty, members.count <= policy.maximumMembersPerSpace else { throw BlackboardRepositoryError.resourceLimit }
        let mapped = Dictionary(uniqueKeysWithValues: members.map { ($0.nodeID, $0.role) })
        guard mapped.count == members.count, mapped.values.contains(.owner) else { throw BlackboardRepositoryError.invalidOperation }
        space.membershipRevision = revision
        space.members = mapped
        spaces[spaceID] = space
    }

    public func apply(_ operation: BlackboardOperation, authorizedNodeID: NodeID) throws -> BlackboardApplyResult {
        guard var space = spaces[operation.spaceID] else { throw BlackboardRepositoryError.unknownSpace }
        guard let role = space.members[authorizedNodeID], role >= .writer else { throw BlackboardRepositoryError.unauthorized }
        let (result, change) = try apply(operation, to: &space)
        spaces[operation.spaceID] = space
        if let change { notify(change) }
        return result
    }

    public func applyBatch(_ operations: [BlackboardOperation], authorizedNodeID: NodeID) throws -> [BlackboardApplyResult] {
        guard let spaceID = operations.first?.spaceID, operations.allSatisfy({ $0.spaceID == spaceID }) else {
            throw BlackboardRepositoryError.invalidOperation
        }
        guard var tentative = spaces[spaceID] else { throw BlackboardRepositoryError.unknownSpace }
        guard let role = tentative.members[authorizedNodeID], role >= .writer else { throw BlackboardRepositoryError.unauthorized }
        var results: [BlackboardApplyResult] = []
        var changes: [BlackboardChange] = []
        for operation in operations {
            let (result, change) = try apply(operation, to: &tentative)
            results.append(result)
            if let change { changes.append(change) }
        }
        spaces[spaceID] = tentative
        changes.forEach(notify)
        return results
    }

    public func snapshot(spaceID: BlackboardSpaceID, authorizedNodeID: NodeID) throws -> BlackboardSpaceSnapshot {
        let space = try readableSpace(spaceID, nodeID: authorizedNodeID)
        return BlackboardSpaceSnapshot(
            version: BlackboardSpaceSnapshot.currentVersion,
            spaceID: spaceID,
            name: space.name,
            membershipRevision: space.membershipRevision,
            members: space.members.map { BlackboardMember(nodeID: $0.key, role: $0.value) }
                .sorted { $0.nodeID.rawValue.uuidString < $1.nodeID.rawValue.uuidString },
            compactionGeneration: space.compactionGeneration,
            frontier: space.frontier,
            records: space.records.map { BlackboardRecord(recordID: $0.key, versions: $0.value) }
                .sorted { $0.recordID < $1.recordID },
            journalOffset: UInt64(space.journal.count)
        )
    }

    public func incremental(
        spaceID: BlackboardSpaceID,
        after cursor: BlackboardCursor,
        limit: Int,
        authorizedNodeID: NodeID
    ) throws -> BlackboardIncrementalResult {
        let space = try readableSpace(spaceID, nodeID: authorizedNodeID)
        guard cursor.compactionGeneration == space.compactionGeneration,
              cursor.journalOffset <= UInt64(space.journal.count), limit > 0 else {
            throw BlackboardRepositoryError.compactionBoundaryMismatch
        }
        let end = min(space.journal.count, Int(cursor.journalOffset) + limit)
        let operations = Array(space.journal[Int(cursor.journalOffset)..<end])
        return BlackboardIncrementalResult(
            operations: operations,
            cursor: BlackboardCursor(compactionGeneration: space.compactionGeneration, journalOffset: UInt64(end))
        )
    }

    public func subscribe(
        id: BlackboardSubscriptionID = BlackboardSubscriptionID(),
        spaceID: BlackboardSpaceID,
        authorizedNodeID: NodeID,
        callback: @escaping Subscriber
    ) throws -> BlackboardSubscriptionID {
        _ = try readableSpace(spaceID, nodeID: authorizedNodeID)
        guard subscriptions.count < policy.maximumSubscriptions else { throw BlackboardRepositoryError.resourceLimit }
        subscriptions[id] = Subscription(spaceID: spaceID, callback: callback)
        return id
    }

    public func cancelSubscription(_ id: BlackboardSubscriptionID) { subscriptions.removeValue(forKey: id) }

    public func compact(
        spaceID: BlackboardSpaceID,
        through frontier: BlackboardFrontier,
        authorizedNodeID: NodeID
    ) throws {
        guard var space = spaces[spaceID] else { throw BlackboardRepositoryError.unknownSpace }
        guard space.members[authorizedNodeID] == .owner else { throw BlackboardRepositoryError.unauthorized }
        guard frontier.dominates(space.compactedFrontier), space.frontier.dominates(frontier) else {
            throw BlackboardRepositoryError.compactionBoundaryMismatch
        }
        space.journal.removeAll { frontier.observes($0.dot) }
        space.records = space.records.filter { _, versions in
            !(versions.count == 1 && versions[0].isTombstone && frontier.observes(versions[0].dot))
        }
        space.compactedFrontier = frontier
        space.compactionGeneration += 1
        spaces[spaceID] = space
    }

    public func exportState() -> BlackboardRepositoryState {
        BlackboardRepositoryState(spaces: spaces.map { spaceID, space in
            BlackboardPersistedSpace(
                spaceID: spaceID, name: space.name, membershipRevision: space.membershipRevision,
                members: space.members.map { .init(nodeID: $0.key, role: $0.value) }
                    .sorted { $0.nodeID.rawValue.uuidString < $1.nodeID.rawValue.uuidString },
                compactionGeneration: space.compactionGeneration,
                compactedFrontier: space.compactedFrontier, frontier: space.frontier,
                records: space.records.map { .init(recordID: $0.key, versions: $0.value) }.sorted { $0.recordID < $1.recordID },
                journal: space.journal
            )
        }.sorted { $0.spaceID < $1.spaceID })
    }

    private func readableSpace(_ id: BlackboardSpaceID, nodeID: NodeID) throws -> SpaceState {
        guard let space = spaces[id] else { throw BlackboardRepositoryError.unknownSpace }
        guard space.members[nodeID] != nil else { throw BlackboardRepositoryError.unauthorized }
        return space
    }

    private func apply(
        _ operation: BlackboardOperation,
        to space: inout SpaceState
    ) throws -> (BlackboardApplyResult, BlackboardChange?) {
        if space.operationIDs.contains(operation.operationID) { return (.duplicate, nil) }
        try validate(operation, in: space)
        var versions = space.records[operation.recordID] ?? []
        if versions.isEmpty, space.records.count >= policy.maximumRecordsPerSpace { throw BlackboardRepositoryError.resourceLimit }
        if operation.kind == .resolve {
            guard Set(operation.resolves) == Set(versions.map(\.operationID)), versions.count > 1,
                  versions.allSatisfy({ operation.context.observes($0.dot) }) else {
                throw BlackboardRepositoryError.conflictResolutionMismatch
            }
        }
        versions.removeAll { operation.context.observes($0.dot) }
        versions.append(.init(operationID: operation.operationID, dot: operation.dot, context: operation.context,
                              value: operation.value, authoredAt: operation.authoredAt))
        versions.sort { $0.operationID < $1.operationID }
        guard versions.count <= policy.maximumVersionsPerRecord,
              space.journal.count < policy.maximumJournalOperations else { throw BlackboardRepositoryError.resourceLimit }
        space.records[operation.recordID] = versions
        space.frontier = space.frontier.advancing(operation.dot)
        space.journal.append(operation)
        space.operationIDs.insert(operation.operationID)
        let cursor = BlackboardCursor(compactionGeneration: space.compactionGeneration, journalOffset: UInt64(space.journal.count))
        let record = BlackboardRecord(recordID: operation.recordID, versions: versions)
        let change = BlackboardChange(spaceID: operation.spaceID, recordID: operation.recordID,
                                      operationID: operation.operationID, cursor: cursor)
        return (.applied(record: record, cursor: cursor), change)
    }

    private func validate(_ operation: BlackboardOperation, in space: SpaceState) throws {
        guard operation.version == BlackboardOperation.currentVersion else {
            throw BlackboardRepositoryError.unsupportedVersion(operation.version)
        }
        guard operation.dot.counter > 0,
              operation.context.entries == operation.context.entries.sorted(by: { $0.replicaID < $1.replicaID }),
              Set(operation.context.entries.map(\.replicaID)).count == operation.context.entries.count,
              operation.resolves == operation.resolves.sorted(),
              Set(operation.resolves).count == operation.resolves.count else {
            throw BlackboardRepositoryError.invalidOperation
        }
        guard space.frontier.dominates(operation.context) else { throw BlackboardRepositoryError.missingCausalDependency }
        guard operation.dot.counter == space.frontier.counter(for: operation.dot.replicaID) + 1 else {
            throw BlackboardRepositoryError.causalRollback
        }
        switch operation.kind {
        case .write:
            guard operation.value != nil, operation.resolves.isEmpty else { throw BlackboardRepositoryError.invalidOperation }
        case .delete:
            guard operation.value == nil, operation.resolves.isEmpty else { throw BlackboardRepositoryError.invalidOperation }
        case .resolve:
            guard !operation.resolves.isEmpty else { throw BlackboardRepositoryError.invalidOperation }
        }
        if let value = operation.value {
            guard !value.schema.isEmpty, value.schema.utf8.count <= 128, value.schemaVersion > 0,
                  value.bytes.count <= policy.maximumValueBytes,
                  value.attachments.count <= policy.maximumAttachmentsPerValue,
                  value.attachments.allSatisfy({ $0.digest.count == 32 }) else {
                throw BlackboardRepositoryError.resourceLimit
            }
        }
    }

    private func notify(_ change: BlackboardChange) {
        for subscription in subscriptions.values where subscription.spaceID == change.spaceID {
            subscription.callback(change)
        }
    }
}
