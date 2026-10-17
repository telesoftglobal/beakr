import Foundation

public enum HostDiagnosticSubsystem: String, Codable, Sendable {
    case lifecycle, delivery, blackboard, transfer, credential, revocation, permission, storage
}

public enum HostDiagnosticReason: String, Codable, Sendable {
    case started, stopped, recovered, checkpointed, denied, restricted, expired, cancelled
    case retryScheduled = "retry-scheduled"
    case resourceLimit = "resource-limit"
    case integrityFailure = "integrity-failure"
    case authorizationFailure = "authorization-failure"
    case persistenceFailure = "persistence-failure"
}

public struct HostDiagnosticEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let subsystem: HostDiagnosticSubsystem
    public let reason: HostDiagnosticReason
    public let identifier: UUID?
    public let count: UInt64?

    public init(timestamp: Date, subsystem: HostDiagnosticSubsystem, reason: HostDiagnosticReason,
                identifier: UUID? = nil, count: UInt64? = nil) {
        self.timestamp = timestamp; self.subsystem = subsystem; self.reason = reason
        self.identifier = identifier; self.count = count
    }
}

public struct HostDiagnosticPolicy: Equatable, Sendable {
    public let maximumEvents: Int
    public let maximumExportBytes: Int
    public init(maximumEvents: Int = 1_024, maximumExportBytes: Int = 256 * 1_024) {
        precondition(maximumEvents > 0 && maximumExportBytes > 0)
        self.maximumEvents = maximumEvents; self.maximumExportBytes = maximumExportBytes
    }
}

public actor HostDiagnosticJournal {
    private struct Export: Codable { let version: Int; let events: [HostDiagnosticEvent] }
    public let policy: HostDiagnosticPolicy
    private var events: [HostDiagnosticEvent] = []
    public init(policy: HostDiagnosticPolicy = HostDiagnosticPolicy()) { self.policy = policy }

    public func record(_ event: HostDiagnosticEvent) {
        events.append(event)
        if events.count > policy.maximumEvents { events.removeFirst(events.count - policy.maximumEvents) }
    }

    public func snapshot() -> [HostDiagnosticEvent] { events }

    public func export() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var selected = events
        while true {
            let data = try encoder.encode(Export(version: 1, events: selected))
            if data.count <= policy.maximumExportBytes { return data }
            guard !selected.isEmpty else { throw CocoaError(.fileWriteOutOfSpace) }
            selected.removeFirst()
        }
    }
}

public enum PersistentHostDiagnosticError: Error, Equatable, Sendable {
    case unsupportedFormat(Int)
    case eventLimitExceeded
    case noncanonicalSnapshot
}

/// A restart-safe, bounded diagnostic journal containing structured fields only.
public actor PersistentHostDiagnosticJournal {
    private struct Snapshot: Codable, Equatable {
        static let currentVersion = 1
        let version: Int
        let events: [HostDiagnosticEvent]
    }

    public let fileURL: URL
    public let policy: HostDiagnosticPolicy
    private var events: [HostDiagnosticEvent]

    private init(fileURL: URL, policy: HostDiagnosticPolicy, events: [HostDiagnosticEvent]) {
        self.fileURL = fileURL
        self.policy = policy
        self.events = events
    }

    public static func open(
        fileURL: URL,
        policy: HostDiagnosticPolicy = HostDiagnosticPolicy()
    ) throws -> PersistentHostDiagnosticJournal {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PersistentHostDiagnosticJournal(fileURL: fileURL, policy: policy, events: [])
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        guard snapshot.version == Snapshot.currentVersion else {
            throw PersistentHostDiagnosticError.unsupportedFormat(snapshot.version)
        }
        guard snapshot.events.count <= policy.maximumEvents else {
            throw PersistentHostDiagnosticError.eventLimitExceeded
        }
        guard try encode(snapshot) == data else {
            throw PersistentHostDiagnosticError.noncanonicalSnapshot
        }
        return PersistentHostDiagnosticJournal(
            fileURL: fileURL,
            policy: policy,
            events: snapshot.events
        )
    }

    public func record(_ event: HostDiagnosticEvent) throws {
        let previous = events
        events.append(event)
        if events.count > policy.maximumEvents {
            events.removeFirst(events.count - policy.maximumEvents)
        }
        do { try persist() }
        catch { events = previous; throw error }
    }

    public func snapshot() -> [HostDiagnosticEvent] { events }

    public func export() throws -> Data {
        var selected = events
        while true {
            let data = try Self.encode(Snapshot(version: Snapshot.currentVersion, events: selected))
            if data.count <= policy.maximumExportBytes { return data }
            guard !selected.isEmpty else { throw CocoaError(.fileWriteOutOfSpace) }
            selected.removeFirst()
        }
    }

    private func persist() throws {
        let data = try Self.encode(Snapshot(version: Snapshot.currentVersion, events: events))
        guard data.count <= policy.maximumExportBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private static func encode(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(snapshot)
    }
}
