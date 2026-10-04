import Foundation

/// An authenticated transport or session boundary that can atomically install
/// authority-issued credential revocation state.
public protocol RevocationSnapshotConsumer: Actor {
    nonisolated var revocationConsumerID: TransportID { get }

    func installRevocationSnapshot(
        _ snapshot: CredentialRevocationSnapshot
    ) async throws
}
