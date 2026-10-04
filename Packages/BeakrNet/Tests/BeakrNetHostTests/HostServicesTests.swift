import Foundation
import Testing
import BeakrNetHost

@Suite("Host protocol service integration")
struct HostServicesTests {
    @Test("Queued work survives credential renewal and revocation refresh before routes open")
    func maintenanceWithQueuedWork() async throws {
        let log = ServiceLog()
        let data = DataService(log: log, pending: 3)
        let composite = CompositeHostRecoveryService(
            data: data, blackboard: BlackboardService(log: log), transfers: TransferService(log: log),
            trust: TrustService(log: log), routes: RouteSink(log: log)
        )
        let host = BeakrNetHostCoordinator(recovery: composite)
        try await host.start()
        #expect(await data.pendingCount() == 3)
        let events = await log.events
        let renewal = try #require(events.firstIndex(of: "trust.renew"))
        let revocation = try #require(events.firstIndex(of: "trust.revocation"))
        let routes = try #require(events.lastIndex(of: "routes.true"))
        #expect(renewal < revocation && revocation < routes)
    }

    @Test("Repository-open failure prevents trust maintenance and route eligibility")
    func recoveryFailure() async {
        let log = ServiceLog()
        let composite = CompositeHostRecoveryService(
            data: DataService(log: log, pending: 1, failsOpen: true), blackboard: BlackboardService(log: log),
            transfers: TransferService(log: log), trust: TrustService(log: log), routes: RouteSink(log: log)
        )
        let host = BeakrNetHostCoordinator(recovery: composite)
        await #expect(throws: ServiceFailure.failed) { try await host.start() }
        #expect(await host.synchronizationState().lifecycle == .failed)
        #expect(!(await log.events).contains("trust.restore"))
    }
}

private enum ServiceFailure: Error { case failed }
private actor ServiceLog { var events: [String] = []; func add(_ value: String) { events.append(value) } }
private actor DataService: HostDataLifecycleService {
    let log: ServiceLog; let pending: Int; let failsOpen: Bool
    init(log: ServiceLog, pending: Int, failsOpen: Bool = false) { self.log = log; self.pending = pending; self.failsOpen = failsOpen }
    func open() async throws { await log.add("data.open"); if failsOpen { throw ServiceFailure.failed } }
    func restorePending() async { await log.add("data.restore") }; func reconcileExpired() async { await log.add("data.expire") }
    func checkpoint() async { await log.add("data.checkpoint") }; func setAdmissionPermitted(_ permitted: Bool) async { await log.add("data.admit.\(permitted)") }
    func pendingCount() -> Int { pending }
}
private actor BlackboardService: HostBlackboardLifecycleService {
    let log: ServiceLog; init(log: ServiceLog) { self.log = log }
    func open() async { await log.add("blackboard.open") }; func checkpoint() async { await log.add("blackboard.checkpoint") }
}
private actor TransferService: HostTransferLifecycleService {
    let log: ServiceLog; init(log: ServiceLog) { self.log = log }
    func open() async { await log.add("transfer.open") }; func garbageCollectExpired() async { await log.add("transfer.gc") }
    func checkpoint() async { await log.add("transfer.checkpoint") }; func setAdmissionPermitted(_ permitted: Bool) async { await log.add("transfer.admit.\(permitted)") }
    func activeCount() -> Int { 0 }
}
private actor TrustService: HostTrustLifecycleService {
    let log: ServiceLog; init(log: ServiceLog) { self.log = log }
    func restore() async { await log.add("trust.restore") }; func renewCredentialIfNeeded() async { await log.add("trust.renew") }
    func refreshRevocations() async { await log.add("trust.revocation") }; func checkpoint() async { await log.add("trust.checkpoint") }
}
private actor RouteSink: HostRoutePolicySink {
    let log: ServiceLog; init(log: ServiceLog) { self.log = log }
    func setAllRoutesPermitted(_ permitted: Bool) async { await log.add("routes.\(permitted)") }
    func setLANPermitted(_ permitted: Bool) async { await log.add("lan.\(permitted)") }
}
