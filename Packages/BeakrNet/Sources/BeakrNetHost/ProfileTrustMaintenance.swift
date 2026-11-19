import Foundation
import BeakrNetAuthority
import BeakrNetCore

public struct ProfileTrustMaintenanceReport: Equatable, Sendable {
    public let revocations: RevocationRefreshOutcome
    public let membership: ProfileMembershipRefreshOutcome
    public let revokedCredentialCount: Int

    public init(
        revocations: RevocationRefreshOutcome,
        membership: ProfileMembershipRefreshOutcome,
        revokedCredentialCount: Int
    ) {
        self.revocations = revocations
        self.membership = membership
        self.revokedCredentialCount = revokedCredentialCount
    }
}

/// Refreshes trust state in dependency order. Revocations are activated first,
/// then membership lookups immediately adopt the latest revoked credential set,
/// and only then may a newer membership generation become visible.
public actor ProfileTrustMaintenanceController {
    private let revocationRefresh: RevocationRefreshController
    private let revocations: RevocationSnapshotDistributor
    private let membershipDirectory: ProfileMembershipDirectory
    private let membershipRefresh: ProfileMembershipRefreshController
    private var peerRecoveryTask: Task<Void, Never>?
    private var nextPeerRecovery = ContinuousClock.now
    private var peerRecoveryDelay: Duration = .seconds(2)

    /// Unknown peers are hints to fetch signed state, never evidence of membership.
    /// Coalesce concurrent misses and bound authority traffic even for hostile hints.
    public func recoverUnknownPeer() async {
        if let peerRecoveryTask {
            await peerRecoveryTask.value
            return
        }
        guard ContinuousClock.now >= nextPeerRecovery else { return }
        let task = Task {
            let previousGeneration = await membershipDirectory.generation()
            _ = await refreshNow(revocationTrigger: .scheduled, membershipTrigger: .scheduled)
            let progressed = await membershipDirectory.generation() != previousGeneration
            nextPeerRecovery = .now.advanced(by: peerRecoveryDelay)
            peerRecoveryDelay = progressed ? .seconds(2) : min(.seconds(30), peerRecoveryDelay * 2)
        }
        peerRecoveryTask = task
        await task.value
        peerRecoveryTask = nil
    }

    public func connectionSessionID(localNodeID: NodeID, peerNodeID: NodeID) async -> SessionID? {
        if let session = await membershipDirectory.connectionSessionID(localNodeID: localNodeID, peerNodeID: peerNodeID) {
            return session
        }
        await recoverUnknownPeer()
        return await membershipDirectory.connectionSessionID(localNodeID: localNodeID, peerNodeID: peerNodeID)
    }

    public init(
        revocationRefresh: RevocationRefreshController,
        revocations: RevocationSnapshotDistributor,
        membershipDirectory: ProfileMembershipDirectory,
        membershipRefresh: ProfileMembershipRefreshController
    ) {
        self.revocationRefresh = revocationRefresh
        self.revocations = revocations
        self.membershipDirectory = membershipDirectory
        self.membershipRefresh = membershipRefresh
    }

    public func nextScheduledAttempt() async -> Date {
        let revocationDate = await revocationRefresh.nextScheduledAttempt()
        let membershipDate = await membershipRefresh.nextScheduledAttempt()
        return [revocationDate, membershipDate].compactMap { $0 }.min() ?? Date()
    }

    @discardableResult
    public func refreshNow(
        revocationTrigger: RevocationRefreshTrigger,
        membershipTrigger: ProfileMembershipRefreshTrigger
    ) async -> ProfileTrustMaintenanceReport {
        let revocationOutcome = await revocationRefresh.refreshNow(trigger: revocationTrigger)
        let revokedIDs = await revocations.latestSnapshot()?.claims.revocations.reduce(into: Set<UUID>()) {
            $0.insert($1.credentialID)
        } ?? []
        await membershipDirectory.updateRevokedCredentialIDs(revokedIDs)
        let membershipOutcome = await membershipRefresh.refreshNow(trigger: membershipTrigger)
        return ProfileTrustMaintenanceReport(
            revocations: revocationOutcome,
            membership: membershipOutcome,
            revokedCredentialCount: revokedIDs.count
        )
    }
}
