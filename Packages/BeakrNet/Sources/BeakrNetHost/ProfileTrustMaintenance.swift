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
