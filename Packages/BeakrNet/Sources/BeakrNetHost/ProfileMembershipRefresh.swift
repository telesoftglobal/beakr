import Foundation
import BeakrNetAuthority

public struct ProfileMembershipRefreshPolicy: Equatable, Sendable {
    public let refreshInterval: TimeInterval
    public let initialRetryDelay: TimeInterval
    public let maximumRetryDelay: TimeInterval

    public init(
        refreshInterval: TimeInterval = 15 * 60,
        initialRetryDelay: TimeInterval = 30,
        maximumRetryDelay: TimeInterval = 15 * 60
    ) throws {
        guard refreshInterval > 0, initialRetryDelay > 0,
              maximumRetryDelay >= initialRetryDelay else {
            throw ProfileMembershipRefreshError.invalidPolicy
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

public enum ProfileMembershipRefreshTrigger: String, Equatable, Sendable {
    case startup
    case scheduled
    case pushNotification
    case manual
}

public enum ProfileMembershipRefreshOutcome: Equatable, Sendable {
    case unchanged(nextAttemptAt: Date)
    case activated(generation: UInt64, nextAttemptAt: Date)
    case failed(nextAttemptAt: Date, failureCount: Int, reason: String)
}

public enum ProfileMembershipRefreshDiagnostic: Equatable, Sendable {
    case started(ProfileMembershipRefreshTrigger)
    case activated(generation: UInt64)
    case unchanged
    case failed(String, retryAt: Date)
}

public enum ProfileMembershipRefreshError: Error, Equatable, Sendable {
    case invalidPolicy
}

/// Fetches authority-signed membership state and activates it only after the
/// directory has verified and atomically persisted the candidate snapshot.
public actor ProfileMembershipRefreshController {
    public typealias EventSink = @Sendable (ProfileMembershipRefreshDiagnostic) -> Void

    private let directory: ProfileMembershipDirectory
    private let requester: any ProfileMembershipSnapshotRequesting
    private let policy: ProfileMembershipRefreshPolicy
    private let now: @Sendable () -> Date
    private let eventSink: EventSink
    private var failureCount = 0
    private var nextAttemptAt: Date?
    public private(set) var diagnosticHistory: [ProfileMembershipRefreshDiagnostic] = []

    public init(
        directory: ProfileMembershipDirectory,
        requester: any ProfileMembershipSnapshotRequesting,
        policy: ProfileMembershipRefreshPolicy,
        now: @escaping @Sendable () -> Date = Date.init,
        eventSink: @escaping EventSink = { _ in }
    ) {
        self.directory = directory
        self.requester = requester
        self.policy = policy
        self.now = now
        self.eventSink = eventSink
    }

    public func nextScheduledAttempt() -> Date? { nextAttemptAt }

    @discardableResult
    public func refreshNow(trigger: ProfileMembershipRefreshTrigger) async -> ProfileMembershipRefreshOutcome {
        emit(.started(trigger))
        let attemptDate = now()
        do {
            let generation = await directory.generation()
            guard let snapshot = try await requester.fetchSnapshot(after: generation) else {
                failureCount = 0
                let next = attemptDate.addingTimeInterval(policy.refreshInterval)
                nextAttemptAt = next
                emit(.unchanged)
                return .unchanged(nextAttemptAt: next)
            }
            try await directory.activate(snapshot)
            failureCount = 0
            let next = attemptDate.addingTimeInterval(policy.refreshInterval)
            nextAttemptAt = next
            emit(.activated(generation: snapshot.claims.generation))
            return .activated(generation: snapshot.claims.generation, nextAttemptAt: next)
        } catch {
            failureCount += 1
            let next = attemptDate.addingTimeInterval(policy.retryDelay(after: failureCount))
            nextAttemptAt = next
            let reason = String(describing: error)
            emit(.failed(reason, retryAt: next))
            return .failed(nextAttemptAt: next, failureCount: failureCount, reason: reason)
        }
    }

    private func emit(_ diagnostic: ProfileMembershipRefreshDiagnostic) {
        diagnosticHistory.append(diagnostic)
        eventSink(diagnostic)
    }
}
