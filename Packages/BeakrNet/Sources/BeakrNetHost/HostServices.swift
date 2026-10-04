import Foundation

public protocol HostDataLifecycleService: Sendable {
    func open() async throws
    func restorePending() async throws
    func reconcileExpired() async throws
    func checkpoint() async throws
    func setAdmissionPermitted(_ permitted: Bool) async
    func pendingCount() async -> Int
}

public protocol HostBlackboardLifecycleService: Sendable {
    func open() async throws
    func checkpoint() async throws
}

public protocol HostTransferLifecycleService: Sendable {
    func open() async throws
    func garbageCollectExpired() async throws
    func checkpoint() async throws
    func setAdmissionPermitted(_ permitted: Bool) async
    func activeCount() async -> Int
}

public protocol HostTrustLifecycleService: Sendable {
    func restore() async throws
    func renewCredentialIfNeeded() async throws
    func refreshRevocations() async throws
    func checkpoint() async throws
}

public protocol HostRoutePolicySink: Sendable {
    func setAllRoutesPermitted(_ permitted: Bool) async
    func setLANPermitted(_ permitted: Bool) async
}

/// Composes protocol-specific authorities without making any repository subordinate to a UI lifecycle.
public actor CompositeHostRecoveryService: HostRecoveryService {
    private let data: any HostDataLifecycleService
    private let blackboard: any HostBlackboardLifecycleService
    private let transfers: any HostTransferLifecycleService
    private let trust: any HostTrustLifecycleService
    private let routes: any HostRoutePolicySink

    public init(data: any HostDataLifecycleService, blackboard: any HostBlackboardLifecycleService,
                transfers: any HostTransferLifecycleService, trust: any HostTrustLifecycleService,
                routes: any HostRoutePolicySink) {
        self.data = data; self.blackboard = blackboard; self.transfers = transfers
        self.trust = trust; self.routes = routes
    }

    public func openRepositories() async throws {
        try await data.open(); try await blackboard.open(); try await transfers.open()
    }
    public func restorePendingWork() async throws { try await data.restorePending() }
    public func restoreTrustState() async throws {
        try await trust.restore()
        try await trust.renewCredentialIfNeeded()
        try await trust.refreshRevocations()
    }
    public func reconcileExpiredWork() async throws {
        try await data.reconcileExpired(); try await transfers.garbageCollectExpired()
    }
    public func checkpoint() async throws {
        try await data.checkpoint(); try await blackboard.checkpoint()
        try await transfers.checkpoint(); try await trust.checkpoint()
    }
    public func setRoutesPermitted(_ permitted: Bool) async { await routes.setAllRoutesPermitted(permitted) }
    public func setLANPermitted(_ permitted: Bool) async { await routes.setLANPermitted(permitted) }
    public func setNewDurableWorkPermitted(_ permitted: Bool) async { await data.setAdmissionPermitted(permitted) }
    public func setNewTransfersPermitted(_ permitted: Bool) async { await transfers.setAdmissionPermitted(permitted) }
    public func pendingMessageCount() async -> Int { await data.pendingCount() }
    public func activeTransferCount() async -> Int { await transfers.activeCount() }
}
