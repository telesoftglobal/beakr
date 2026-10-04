import Foundation
import BeakrNetCore

public enum RevocationDistributionError: Error, Equatable, Sendable {
    case staleSnapshot
    case conflictingSnapshot
}

public enum RevocationConsumerOutcome: Equatable, Sendable {
    case installed
    case failed(String)
}

public struct RevocationDistributionReport: Equatable, Sendable {
    public let generatedAtMilliseconds: Int64
    public let outcomes: [TransportID: RevocationConsumerOutcome]

    public init(
        generatedAtMilliseconds: Int64,
        outcomes: [TransportID: RevocationConsumerOutcome]
    ) {
        self.generatedAtMilliseconds = generatedAtMilliseconds
        self.outcomes = outcomes
    }
}

/// Owns the latest verified snapshot and fans it out to every active transport.
/// Registering a route after publication immediately catches it up before the
/// caller can consider revocation state synchronized.
public actor RevocationSnapshotDistributor {
    public typealias Verifier = @Sendable (
        CredentialRevocationSnapshot,
        Date
    ) throws -> Void

    private let verifier: Verifier
    private let now: @Sendable () -> Date
    private var consumers: [TransportID: any RevocationSnapshotConsumer] = [:]
    private var currentSnapshot: CredentialRevocationSnapshot?

    public init(
        trustedAuthorityPublicKey: Data,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.now = now
        verifier = { snapshot, date in
            _ = try RevocationVerifier.verify(
                snapshot,
                trustedAuthorityPublicKey: trustedAuthorityPublicKey,
                now: date
            )
        }
    }

    public init(
        now: @escaping @Sendable () -> Date = Date.init,
        verifier: @escaping Verifier
    ) {
        self.now = now
        self.verifier = verifier
    }

    @discardableResult
    public func register(
        _ consumer: any RevocationSnapshotConsumer
    ) async -> RevocationConsumerOutcome? {
        let identifier = consumer.revocationConsumerID
        consumers[identifier] = consumer
        guard let currentSnapshot else { return nil }
        return await install(currentSnapshot, on: consumer)
    }

    public func unregister(consumerID: TransportID) {
        consumers.removeValue(forKey: consumerID)
    }

    public func publish(
        _ snapshot: CredentialRevocationSnapshot
    ) async throws -> RevocationDistributionReport {
        try validateForPublication(snapshot)
        currentSnapshot = snapshot
        var outcomes: [TransportID: RevocationConsumerOutcome] = [:]
        for (identifier, consumer) in consumers {
            outcomes[identifier] = await install(snapshot, on: consumer)
        }
        return RevocationDistributionReport(
            generatedAtMilliseconds: snapshot.claims.generatedAtMilliseconds,
            outcomes: outcomes
        )
    }

    /// Validates a candidate without activating it. Hosts use this before an
    /// atomic durable write, then call `publish` with the same snapshot.
    public func validateForPublication(
        _ snapshot: CredentialRevocationSnapshot
    ) throws {
        try verifier(snapshot, now())
        if let currentSnapshot {
            let incoming = snapshot.claims.generatedAtMilliseconds
            let current = currentSnapshot.claims.generatedAtMilliseconds
            guard incoming >= current else {
                throw RevocationDistributionError.staleSnapshot
            }
            if incoming == current {
                guard snapshot == currentSnapshot else {
                    throw RevocationDistributionError.conflictingSnapshot
                }
            }
        }
    }

    public func latestSnapshot() -> CredentialRevocationSnapshot? {
        currentSnapshot
    }

    private func install(
        _ snapshot: CredentialRevocationSnapshot,
        on consumer: any RevocationSnapshotConsumer
    ) async -> RevocationConsumerOutcome {
        do {
            try await consumer.installRevocationSnapshot(snapshot)
            return .installed
        } catch {
            return .failed(String(describing: error))
        }
    }
}
