import Foundation
import BeakrNetCore

public protocol RevocationSnapshotRequesting: Sendable {
    func fetchSnapshot(after generatedAtMilliseconds: Int64?) async throws
        -> CredentialRevocationSnapshot?
}

public protocol RevocationSnapshotPersisting: Sendable {
    func loadSnapshot() throws -> CredentialRevocationSnapshot?
    func saveSnapshot(_ snapshot: CredentialRevocationSnapshot) throws
}

public struct FileRevocationSnapshotStore: RevocationSnapshotPersisting, Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadSnapshot() throws -> CredentialRevocationSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try CredentialFiles.loadRevocationSnapshot(from: fileURL)
    }

    public func saveSnapshot(_ snapshot: CredentialRevocationSnapshot) throws {
        try CredentialFiles.saveRevocationSnapshot(snapshot, to: fileURL)
    }
}

public struct RevocationRefreshPolicy: Equatable, Sendable {
    public let refreshInterval: TimeInterval
    public let initialRetryDelay: TimeInterval
    public let maximumRetryDelay: TimeInterval

    public init(
        refreshInterval: TimeInterval = 15 * 60,
        initialRetryDelay: TimeInterval = 30,
        maximumRetryDelay: TimeInterval = 15 * 60
    ) throws {
        guard refreshInterval > 0,
              initialRetryDelay > 0,
              maximumRetryDelay >= initialRetryDelay else {
            throw RevocationRefreshError.invalidPolicy
        }
        self.refreshInterval = refreshInterval
        self.initialRetryDelay = initialRetryDelay
        self.maximumRetryDelay = maximumRetryDelay
    }

    public func retryDelay(after failureCount: Int) -> TimeInterval {
        let exponent = min(max(0, failureCount - 1), 30)
        return min(maximumRetryDelay, initialRetryDelay * pow(2, Double(exponent)))
    }
}

public enum RevocationRefreshTrigger: String, Equatable, Sendable {
    case startup
    case scheduled
    case pushNotification
    case manual
}

public enum RevocationRefreshOutcome: Equatable, Sendable {
    case unchanged(nextAttemptAt: Date)
    case activated(RevocationDistributionReport, nextAttemptAt: Date)
    case failed(nextAttemptAt: Date, failureCount: Int, reason: String)
}

public enum RevocationRefreshDiagnostic: Equatable, Sendable {
    case started(RevocationRefreshTrigger)
    case persisted(generatedAtMilliseconds: Int64)
    case activated(generatedAtMilliseconds: Int64, failedConsumers: Int)
    case unchanged
    case failed(String, retryAt: Date)
}

public enum RevocationRefreshError: Error, Equatable, Sendable {
    case invalidPolicy
}

/// Host-facing control-plane boundary. A candidate is verified before it is
/// atomically persisted, and it is published to active routes only after that
/// durable write succeeds.
public actor RevocationRefreshController {
    public typealias EventSink = @Sendable (RevocationRefreshDiagnostic) -> Void

    private let distributor: RevocationSnapshotDistributor
    private let requester: any RevocationSnapshotRequesting
    private let store: any RevocationSnapshotPersisting
    private let policy: RevocationRefreshPolicy
    private let now: @Sendable () -> Date
    private let eventSink: EventSink
    private var failureCount = 0
    private var nextAttemptAt: Date?

    public private(set) var diagnosticHistory: [RevocationRefreshDiagnostic] = []

    public init(
        distributor: RevocationSnapshotDistributor,
        requester: any RevocationSnapshotRequesting,
        store: any RevocationSnapshotPersisting,
        policy: RevocationRefreshPolicy,
        now: @escaping @Sendable () -> Date = Date.init,
        eventSink: @escaping EventSink = { _ in }
    ) {
        self.distributor = distributor
        self.requester = requester
        self.store = store
        self.policy = policy
        self.now = now
        self.eventSink = eventSink
    }

    @discardableResult
    public func restorePersistedSnapshot() async throws
        -> RevocationDistributionReport? {
        guard let snapshot = try store.loadSnapshot() else { return nil }
        let report = try await distributor.publish(snapshot)
        nextAttemptAt = now().addingTimeInterval(policy.refreshInterval)
        return report
    }

    public func nextScheduledAttempt() -> Date? {
        nextAttemptAt
    }

    @discardableResult
    public func refreshNow(
        trigger: RevocationRefreshTrigger
    ) async -> RevocationRefreshOutcome {
        emit(.started(trigger))
        let attemptDate = now()
        do {
            let generation = await distributor.latestSnapshot()?.claims.generatedAtMilliseconds
            guard let snapshot = try await requester.fetchSnapshot(after: generation) else {
                failureCount = 0
                let next = attemptDate.addingTimeInterval(policy.refreshInterval)
                nextAttemptAt = next
                emit(.unchanged)
                return .unchanged(nextAttemptAt: next)
            }

            try await distributor.validateForPublication(snapshot)
            try store.saveSnapshot(snapshot)
            emit(.persisted(generatedAtMilliseconds: snapshot.claims.generatedAtMilliseconds))
            let report = try await distributor.publish(snapshot)
            failureCount = 0
            let next = attemptDate.addingTimeInterval(policy.refreshInterval)
            nextAttemptAt = next
            let failures = report.outcomes.values.reduce(into: 0) { count, outcome in
                if case .failed = outcome { count += 1 }
            }
            emit(.activated(
                generatedAtMilliseconds: report.generatedAtMilliseconds,
                failedConsumers: failures
            ))
            return .activated(report, nextAttemptAt: next)
        } catch {
            failureCount += 1
            let next = attemptDate.addingTimeInterval(
                policy.retryDelay(after: failureCount)
            )
            nextAttemptAt = next
            let reason = String(describing: error)
            emit(.failed(reason, retryAt: next))
            return .failed(
                nextAttemptAt: next,
                failureCount: failureCount,
                reason: reason
            )
        }
    }

    private func emit(_ event: RevocationRefreshDiagnostic) {
        diagnosticHistory.append(event)
        eventSink(event)
    }
}
