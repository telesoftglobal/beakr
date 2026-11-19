import Foundation
import Testing
import BeakrNetCore
import BeakrNetHost

@Suite("Independent authority lifecycle")
struct AuthorityHostingCoordinatorTests {
    private func profile() throws -> NetworkProfile {
        try NetworkProfile(networkID: NetworkID(), localNodeID: NodeID(), displayName: "Disposable")
    }

    @Test("Duplicate starts share a listener and stopping one authority preserves another")
    func independentAuthorities() async throws {
        let a = try profile()
        let b = try profile()
        let fixture = AuthorityFixture(blocked: a.id)
        let manager = fixture.manager()
        let first = Task { try await manager.start(profile: a) }
        await fixture.entered.wait()
        let duplicate = Task { try await manager.start(profile: a) }
        let bHandle = try await manager.start(profile: b)
        #expect(await manager.state(for: b.id) == .running)
        await fixture.release.open()
        let aHandle = try await first.value
        #expect(try await duplicate.value == aHandle)
        #expect(await fixture.startCount(a.id) == 1)
        try await manager.stop(profile: a)
        #expect(await fixture.isRunning(bHandle))
        #expect(!(await fixture.isRunning(aHandle)))
        await manager.shutdown()
        #expect(await fixture.liveCount == 0)
    }

    @Test("A stop queued during start drains the late listener before completing")
    func stopDuringStart() async throws {
        let a = try profile()
        let fixture = AuthorityFixture(blocked: a.id)
        let manager = fixture.manager()
        let start = Task { try await manager.start(profile: a) }
        await fixture.entered.wait()
        let stop = Task { try await manager.stop(profile: a) }
        try await waitFor(.stopping, manager: manager, profile: a)
        await fixture.release.open()
        _ = try await start.value
        try await stop.value
        #expect(await manager.state(for: a.id) == .stopped)
        #expect(await fixture.liveCount == 0)
        #expect(await fixture.stopCount == 1)
        await manager.shutdown()
    }

    @Test("Start-stop-start serializes replacement without overlapping listeners")
    func replacement() async throws {
        let a = try profile()
        let fixture = AuthorityFixture(blocked: a.id)
        let manager = fixture.manager()
        let first = Task { try await manager.start(profile: a) }
        await fixture.entered.wait()
        let stop = Task { try await manager.stop(profile: a) }
        try await waitFor(.stopping, manager: manager, profile: a)
        let replacement = Task { try await manager.start(profile: a) }
        try await waitFor(.starting, manager: manager, profile: a)
        await fixture.release.open()
        let firstHandle = try await first.value
        try await stop.value
        let nextHandle = try await replacement.value
        #expect(firstHandle != nextHandle)
        #expect(await fixture.maximumLivePerProfile == 1)
        #expect(await fixture.startCount(a.id) == 2)
        #expect(await manager.state(for: a.id) == .running)
        await manager.shutdown()
        #expect(await fixture.liveCount == 0)
    }

    @Test("Failure is isolated and bindings cannot be reassigned")
    func failureAndBinding() async throws {
        let a = try profile()
        let b = try profile()
        let fixture = AuthorityFixture(failing: a.id)
        let manager = fixture.manager()
        await #expect(throws: FixtureError.failed) { try await manager.start(profile: a) }
        #expect(await manager.state(for: a.id) == .failed)
        _ = try await manager.start(profile: b)
        let changed = try NetworkProfile(
            id: b.id, networkID: NetworkID(), localNodeID: b.localNodeID, displayName: "Wrong binding"
        )
        await #expect(throws: AuthorityHostingError.profileBindingMismatch) {
            try await manager.start(profile: changed)
        }
        await #expect(throws: AuthorityHostingError.profileBindingMismatch) {
            try await manager.stop(profile: changed)
        }
        #expect(await manager.state(for: b.id) == .running)
        await fixture.allowFailureRecovery()
        _ = try await manager.start(profile: a)
        #expect(await fixture.liveCount == 2)
        await manager.shutdown()
    }

    @Test("Shutdown drains a pending start and permanently closes start admission")
    func shutdownDuringStart() async throws {
        let a = try profile()
        let fixture = AuthorityFixture(blocked: a.id)
        let manager = fixture.manager()
        let start = Task { try await manager.start(profile: a) }
        await fixture.entered.wait()
        let shutdown = Task { await manager.shutdown() }
        try await waitFor(.stopping, manager: manager, profile: a)
        await #expect(throws: AuthorityHostingError.shutDown) {
            try await manager.start(profile: a)
        }
        await fixture.release.open()
        _ = try await start.value
        await shutdown.value
        await manager.shutdown()
        #expect(await fixture.liveCount == 0)
        #expect(await fixture.stopCount == 1)
    }

    @Test("Pending transitions and authority entries have explicit capacity limits")
    func capacity() async throws {
        let a = try profile()
        let b = try profile()
        let fixture = AuthorityFixture(blocked: a.id)
        let manager = fixture.manager(maximumAuthorities: 1, maximumPendingOperations: 2)
        let start = Task { try await manager.start(profile: a) }
        await fixture.entered.wait()
        await #expect(throws: AuthorityHostingError.capacityExceeded) {
            try await manager.start(profile: b)
        }
        let stop = Task { try await manager.stop(profile: a) }
        try await waitFor(.stopping, manager: manager, profile: a)
        await #expect(throws: AuthorityHostingError.operationLimitExceeded) {
            try await manager.start(profile: a)
        }
        await fixture.release.open()
        _ = try await start.value
        try await stop.value
        await manager.shutdown()
        #expect(await fixture.liveCount == 0)
    }

    private func waitFor(
        _ state: AuthorityHostingState,
        manager: AuthorityHostingCoordinator<UUID>,
        profile: NetworkProfile
    ) async throws {
        for _ in 0..<1_000 {
            if await manager.state(for: profile.id) == state { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw FixtureError.timedOut
    }
}

private enum FixtureError: Error { case failed, timedOut }

private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor AuthorityFixture {
    let entered = TestGate()
    let release = TestGate()
    private let blocked: NetworkProfileID?
    private var failing: NetworkProfileID?
    private var starts: [NetworkProfileID: Int] = [:]
    private var running: [UUID: NetworkProfileID] = [:]
    private(set) var stopCount = 0
    private(set) var maximumLivePerProfile = 0
    var liveCount: Int { running.count }

    init(blocked: NetworkProfileID? = nil, failing: NetworkProfileID? = nil) {
        self.blocked = blocked
        self.failing = failing
    }

    nonisolated func manager(
        maximumAuthorities: Int = 8, maximumPendingOperations: Int = 16
    ) -> AuthorityHostingCoordinator<UUID> {
        AuthorityHostingCoordinator(
            maximumAuthorities: maximumAuthorities,
            maximumPendingOperations: maximumPendingOperations,
            start: { try await self.start($0) },
            stop: { await self.stop($0) }
        )
    }

    func start(_ profile: NetworkProfile) async throws -> UUID {
        starts[profile.id, default: 0] += 1
        if profile.id == blocked {
            await entered.open()
            await release.wait()
        }
        if profile.id == failing { throw FixtureError.failed }
        let handle = UUID()
        running[handle] = profile.id
        maximumLivePerProfile = max(
            maximumLivePerProfile, running.values.filter { $0 == profile.id }.count
        )
        return handle
    }

    func stop(_ handle: UUID) {
        running.removeValue(forKey: handle)
        stopCount += 1
    }

    func startCount(_ id: NetworkProfileID) -> Int { starts[id, default: 0] }
    func isRunning(_ handle: UUID) -> Bool { running[handle] != nil }
    func allowFailureRecovery() { failing = nil }
}
