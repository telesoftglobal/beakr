import Testing
import BeakrNetHost

@Suite("Host lifecycle coordinator")
struct HostCoordinatorTests {
    @Test("Recovery completes in order before routes become eligible")
    func recoveryOrdering() async throws {
        let service = RecordingRecovery()
        let host = BeakrNetHostCoordinator(recovery: service)
        try await host.start()
        #expect(await service.events.prefix(6) == ["routes:false", "open", "pending", "trust", "expiry", "routes:true"])
        let state = await host.synchronizationState()
        #expect(state.lifecycle == .foreground)
        #expect(state.recovered)
    }

    @Test("Permission denial degrades LAN while critical pressure checkpoints durable work")
    func degradation() async throws {
        let service = RecordingRecovery()
        let host = BeakrNetHostCoordinator(recovery: service)
        try await host.start()
        await host.setPermissions(localNetwork: .denied, notifications: .denied)
        try await host.setStoragePressure(.critical)
        #expect(await service.events.contains("lan:false"))
        #expect(await service.events.contains("durable:false"))
        #expect(await service.events.contains("transfers:false"))
        #expect(await service.events.last == "checkpoint")
    }

    @Test("Lock and background expiration preserve work and disable routes")
    func lifecycleBoundaries() async throws {
        let service = RecordingRecovery()
        let host = BeakrNetHostCoordinator(recovery: service)
        try await host.start(); try await host.enterBackground(); try await host.backgroundLeaseExpired()
        #expect(await host.synchronizationState().lifecycle == .suspended)
        try await host.enterForeground(); try await host.lock()
        #expect(await host.synchronizationState().lifecycle == .locked)
        #expect(await service.events.contains("routes:false"))
    }
}

private actor RecordingRecovery: HostRecoveryService {
    private(set) var events: [String] = []
    func openRepositories() { events.append("open") }
    func restorePendingWork() { events.append("pending") }
    func restoreTrustState() { events.append("trust") }
    func reconcileExpiredWork() { events.append("expiry") }
    func checkpoint() { events.append("checkpoint") }
    func setRoutesPermitted(_ permitted: Bool) { events.append("routes:\(permitted)") }
    func setLANPermitted(_ permitted: Bool) { events.append("lan:\(permitted)") }
    func setNewDurableWorkPermitted(_ permitted: Bool) { events.append("durable:\(permitted)") }
    func setNewTransfersPermitted(_ permitted: Bool) { events.append("transfers:\(permitted)") }
    func pendingMessageCount() -> Int { 2 }
    func activeTransferCount() -> Int { 1 }
}
