import Foundation
import BeakrNetCore

public struct BlackboardSpaceID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
}

public struct BlackboardRecordID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
}

public struct BlackboardReplicaID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
}

public struct BlackboardOperationID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
}

public struct BlackboardSubscriptionID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
}

public struct BlackboardCausalEntry: Codable, Equatable, Hashable, Sendable {
    public let replicaID: BlackboardReplicaID
    public let counter: UInt64

    public init(replicaID: BlackboardReplicaID, counter: UInt64) {
        self.replicaID = replicaID
        self.counter = counter
    }
}

public struct BlackboardFrontier: Codable, Equatable, Hashable, Sendable {
    public let entries: [BlackboardCausalEntry]

    public init(entries: [BlackboardCausalEntry] = []) {
        self.entries = entries.sorted { $0.replicaID < $1.replicaID }
    }

    public func counter(for replicaID: BlackboardReplicaID) -> UInt64 {
        entries.first { $0.replicaID == replicaID }?.counter ?? 0
    }

    public func observes(_ dot: BlackboardDot) -> Bool { counter(for: dot.replicaID) >= dot.counter }

    public func dominates(_ other: BlackboardFrontier) -> Bool {
        other.entries.allSatisfy { counter(for: $0.replicaID) >= $0.counter }
    }

    public func advancing(_ dot: BlackboardDot) -> BlackboardFrontier {
        var counters = Dictionary(uniqueKeysWithValues: entries.map { ($0.replicaID, $0.counter) })
        counters[dot.replicaID] = max(counters[dot.replicaID] ?? 0, dot.counter)
        return BlackboardFrontier(entries: counters.map(BlackboardCausalEntry.init))
    }
}

public struct BlackboardDot: Codable, Equatable, Hashable, Sendable {
    public let replicaID: BlackboardReplicaID
    public let counter: UInt64

    public init(replicaID: BlackboardReplicaID, counter: UInt64) {
        self.replicaID = replicaID
        self.counter = counter
    }
}

public struct BlackboardAttachmentReference: Codable, Equatable, Hashable, Sendable {
    public let transferID: UUID
    public let byteCount: UInt64
    public let digest: Data

    public init(transferID: UUID, byteCount: UInt64, digest: Data) {
        self.transferID = transferID
        self.byteCount = byteCount
        self.digest = digest
    }
}

public struct BlackboardValue: Codable, Equatable, Hashable, Sendable {
    public let schema: String
    public let schemaVersion: UInt16
    public let bytes: Data
    public let attachments: [BlackboardAttachmentReference]

    public init(schema: String, schemaVersion: UInt16, bytes: Data, attachments: [BlackboardAttachmentReference] = []) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.bytes = bytes
        self.attachments = attachments
    }
}

public enum BlackboardOperationKind: String, Codable, Sendable {
    case write
    case delete
    case resolve
}

public struct BlackboardOperation: Codable, Equatable, Sendable {
    public static let currentVersion: UInt16 = 1
    public let version: UInt16
    public let operationID: BlackboardOperationID
    public let spaceID: BlackboardSpaceID
    public let recordID: BlackboardRecordID
    public let dot: BlackboardDot
    public let context: BlackboardFrontier
    public let kind: BlackboardOperationKind
    public let value: BlackboardValue?
    public let resolves: [BlackboardOperationID]
    public let authoredAt: Date

    public init(
        version: UInt16 = Self.currentVersion,
        operationID: BlackboardOperationID = BlackboardOperationID(),
        spaceID: BlackboardSpaceID,
        recordID: BlackboardRecordID,
        dot: BlackboardDot,
        context: BlackboardFrontier,
        kind: BlackboardOperationKind,
        value: BlackboardValue?,
        resolves: [BlackboardOperationID] = [],
        authoredAt: Date
    ) {
        self.version = version
        self.operationID = operationID
        self.spaceID = spaceID
        self.recordID = recordID
        self.dot = dot
        self.context = context
        self.kind = kind
        self.value = value
        self.resolves = resolves.sorted()
        self.authoredAt = authoredAt
    }
}

public struct BlackboardRecordVersion: Codable, Equatable, Sendable {
    public let operationID: BlackboardOperationID
    public let dot: BlackboardDot
    public let context: BlackboardFrontier
    public let value: BlackboardValue?
    public let authoredAt: Date

    public var isTombstone: Bool { value == nil }
}

public struct BlackboardRecord: Codable, Equatable, Sendable {
    public let recordID: BlackboardRecordID
    public let versions: [BlackboardRecordVersion]
    public var hasConflict: Bool { versions.count > 1 }
}

public enum BlackboardMemberRole: String, Codable, Comparable, Sendable {
    case reader
    case writer
    case owner

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let rank: [Self: Int] = [.reader: 0, .writer: 1, .owner: 2]
        return rank[lhs, default: 0] < rank[rhs, default: 0]
    }
}

public struct BlackboardMember: Codable, Equatable, Sendable {
    public let nodeID: NodeID
    public let role: BlackboardMemberRole
}

public struct BlackboardCursor: Codable, Equatable, Sendable {
    public let compactionGeneration: UInt64
    public let journalOffset: UInt64

    public init(compactionGeneration: UInt64, journalOffset: UInt64) {
        self.compactionGeneration = compactionGeneration
        self.journalOffset = journalOffset
    }
}
