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
