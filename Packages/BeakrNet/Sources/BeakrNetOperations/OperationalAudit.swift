import Foundation

public enum OperationalAuditOutcome: String, Codable, Sendable { case accepted, rejected, failed }
public enum OperationalAuditReason: String, Codable, Sendable {
    case authorized, unauthorized, malformed, overloaded, staleRevocation = "stale-revocation"
    case keyUnavailable = "key-unavailable", backupVerified = "backup-verified"
    case restoreRejected = "restore-rejected", rolloutRolledBack = "rollout-rolled-back"
}
public struct OperationalAuditEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let endpoint: OperationalEndpoint
    public let outcome: OperationalAuditOutcome
    public let reason: OperationalAuditReason
    public let correlationID: UUID
    public let count: UInt64?
    public init(timestamp: Date, endpoint: OperationalEndpoint, outcome: OperationalAuditOutcome,
                reason: OperationalAuditReason, correlationID: UUID, count: UInt64? = nil) {
        self.timestamp = timestamp; self.endpoint = endpoint; self.outcome = outcome
        self.reason = reason; self.correlationID = correlationID; self.count = count
    }
}

public actor OperationalAuditJournal {
    private let maximumEvents: Int
    private let retention: TimeInterval
    private var events: [OperationalAuditEvent] = []
    public init(maximumEvents: Int, retention: TimeInterval) {
        precondition(maximumEvents > 0 && retention > 0); self.maximumEvents = maximumEvents; self.retention = retention
    }
    public func record(_ event: OperationalAuditEvent, now: Date) {
        events.removeAll { now.timeIntervalSince($0.timestamp) > retention }
        events.append(event)
        if events.count > maximumEvents { events.removeFirst(events.count - maximumEvents) }
    }
    public func snapshot(now: Date) -> [OperationalAuditEvent] {
        events.filter { now.timeIntervalSince($0.timestamp) <= retention }
    }
}

public enum OperationalMetric: String, CaseIterable, Codable, Sendable {
    case admitted
    case rejected
    case keyUnavailable = "key-unavailable"
    case staleRevocation = "stale-revocation"
    case restoreRejected = "restore-rejected"
    case rolloutRetained = "rollout-retained"
}

public actor OperationalTelemetry {
    private var counts: [OperationalMetric: UInt64] = [:]

    public init() {}

    public func increment(_ metric: OperationalMetric, by amount: UInt64 = 1) {
        let (sum, overflow) = counts[metric, default: 0].addingReportingOverflow(amount)
        counts[metric] = overflow ? .max : sum
    }

    public func snapshot() -> [OperationalMetric: UInt64] {
        counts
    }
}
