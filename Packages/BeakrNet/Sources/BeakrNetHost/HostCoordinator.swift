import Foundation

public actor BeakrNetHostCoordinator {
    private let recovery: any HostRecoveryService
    private var lifecycle: HostLifecycleState = .stopped
    private var localNetwork: HostPermissionState = .unknown
    private var notifications: HostPermissionState = .unknown
    private var storage: HostStoragePressure = .normal
    private var recovered = false

    public init(recovery: any HostRecoveryService) { self.recovery = recovery }

    public func start() async throws {
        guard lifecycle == .stopped || lifecycle == .failed else { return }
        lifecycle = .starting; recovered = false
        await recovery.setRoutesPermitted(false)
        do {
            try await recovery.openRepositories()
            try await recovery.restorePendingWork()
            try await recovery.restoreTrustState()
            try await recovery.reconcileExpiredWork()
            recovered = true; lifecycle = .foreground
            await recovery.setRoutesPermitted(true)
            await applyPermissionsAndPressure()
        } catch { lifecycle = .failed; await recovery.setRoutesPermitted(false); throw error }
    }

    public func enterBackground() async throws { lifecycle = .background; try await recovery.checkpoint() }
    public func backgroundLeaseExpired() async throws {
        guard lifecycle == .background else { return }
        await recovery.setNewDurableWorkPermitted(false)
        try await recovery.checkpoint(); lifecycle = .suspended
    }
    public func enterForeground() async throws {
        guard recovered else { try await start(); return }
        lifecycle = .foreground
        await applyPermissionsAndPressure()
    }
    public func lock() async throws { lifecycle = .locked; await recovery.setRoutesPermitted(false); try await recovery.checkpoint() }
    public func unlock() async throws { guard recovered else { try await start(); return }; lifecycle = .foreground; await applyPermissionsAndPressure() }
    public func stop() async throws { lifecycle = .stopping; await recovery.setRoutesPermitted(false); try await recovery.checkpoint(); lifecycle = .stopped }

    public func setPermissions(localNetwork: HostPermissionState? = nil, notifications: HostPermissionState? = nil) async {
        if let localNetwork { self.localNetwork = localNetwork }; if let notifications { self.notifications = notifications }
        await applyPermissionsAndPressure()
    }
    public func setStoragePressure(_ pressure: HostStoragePressure) async throws {
        storage = pressure; await applyPermissionsAndPressure(); if pressure == .critical { try await recovery.checkpoint() }
    }
    public func synchronizationState() async -> HostSynchronizationState {
        .init(lifecycle: lifecycle, localNetworkPermission: localNetwork, notificationPermission: notifications,
              storagePressure: storage, pendingMessages: await recovery.pendingMessageCount(),
              activeTransfers: await recovery.activeTransferCount(), routesPermitted: recovered && lifecycle != .locked && lifecycle != .stopped && lifecycle != .failed,
              recovered: recovered)
    }
    private func applyPermissionsAndPressure() async {
        await recovery.setLANPermitted(localNetwork == .granted)
        await recovery.setNewTransfersPermitted(storage == .normal)
        await recovery.setNewDurableWorkPermitted(storage != .critical && lifecycle != .suspended)
        await recovery.setRoutesPermitted(recovered && lifecycle != .locked && lifecycle != .stopped && lifecycle != .failed)
    }
}
