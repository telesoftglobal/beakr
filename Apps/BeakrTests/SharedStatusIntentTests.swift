import Foundation
import Testing
import BeakrNetCore
import BeakrNetData
@testable import Beakr

private actor IntentStatusFixtureRuntime: StatusIntentRuntime {
    let bindingID = UUID()
    let reply: SharedStatusResult
    var error: SharedStatusError?
    var beforeReply: (@Sendable () async -> Void)?
    var waitsForCancellation = false
    private var availabilityChecks = 0
    private var unavailableChecks = 0
    private(set) var reads = 0
    private(set) var submittedBinding: UUID?
    nonisolated let started: AsyncStream<Void>
    private let startSink: AsyncStream<Void>.Continuation

    init(reply: SharedStatusResult) {
        self.reply = reply
        let stream = AsyncStream<Void>.makeStream()
        started = stream.stream
        startSink = stream.continuation
    }
    func configure(error: SharedStatusError? = nil, waits: Bool = false,
                   beforeReply: (@Sendable () async -> Void)? = nil) {
        self.error = error; waitsForCancellation = waits; self.beforeReply = beforeReply
    }
    func delayAvailability(checks: Int) { unavailableChecks = checks }
    func availability(for peer: NodeID) -> SharedStatusAvailability {
        availabilityChecks += 1
        return SharedStatusAvailability(bindingID: availabilityChecks <= unavailableChecks ? nil : bindingID, sharing: false)
    }
    func request(peer: NodeID, bindingID: UUID) async throws -> SharedStatusResult {
        reads += 1; submittedBinding = bindingID; startSink.yield(())
        if let beforeReply { await beforeReply() }
        if waitsForCancellation { try await Task.sleep(for: .seconds(30)) }
        if let error { throw error }
        return reply
    }
}

@MainActor
private final class IntentStatusFixture {
    let network = NetworkID()
    let local = NodeID()
    let peer = NodeID()
    let profile = NetworkProfileID()
    let runtime: IntentStatusFixtureRuntime
    var selection: StatusIntentSelection?
    var readinessTimeout: Duration = .zero
    var readyOnResolve: Int?
    var onResolve: (() -> Void)?
    var runtimeAvailable = true
    var changeOnResolve = false
    var resolves = 0
    let device: StatusDeviceEntity
    lazy var adapter = StatusIntentAdapter(readinessTimeout: readinessTimeout, selection: { [unowned self] in selection }, runtime: { [unowned self] _ in
        resolves += 1
        onResolve?()
        if let readyOnResolve, resolves >= readyOnResolve { runtimeAvailable = true }
        if changeOnResolve { selection = nil }
        return runtimeAvailable ? runtime : nil
    })

    init() {
        device = StatusDeviceEntity(networkID: network, nodeID: peer, name: "Mac", networkName: "Test")
        selection = StatusIntentSelection(profileID: profile, networkID: network, localNodeID: local, devices: [device])
        runtime = IntentStatusFixtureRuntime(reply: SharedStatusResult(
            snapshot: SharedStatusSnapshot(schemaVersion: 1, sampledAt: Date(), applicationVersion: "fixture",
                                           runtimeState: .running, authenticatedPeerCount: 1),
            binding: SharedStatusBinding(runtimeID: UUID(), networkID: network, localNodeID: local,
                                         peerNodeID: peer, sessionID: SessionID()),
            correlationID: DataCorrelationID(), receivedAt: Date(), elapsed: .milliseconds(4)
        ))
    }
}

@MainActor
struct SharedStatusIntentTests {
    @Test func waitsForRuntimeAndPeerThenSendsOnce() async throws {
        let fixture = IntentStatusFixture()
        fixture.readinessTimeout = .seconds(2)
        fixture.runtimeAvailable = false
        fixture.readyOnResolve = 2
        await fixture.runtime.delayAvailability(checks: 1)
        let (_, reply) = try await fixture.adapter.request(id: fixture.device.id)
        #expect(reply.snapshot.applicationVersion == "fixture")
        #expect(fixture.resolves == 3)
        #expect(await fixture.runtime.reads == 1)
    }

    @Test func readinessDeadlineDoesNotSend() async {
        let fixture = IntentStatusFixture()
        fixture.readinessTimeout = .milliseconds(20)
        await fixture.runtime.delayAvailability(checks: 100)
        await #expect(throws: StatusIntentError.notReady) { try await fixture.adapter.request(id: fixture.device.id) }
        #expect(await fixture.runtime.reads == 0)
    }

    @Test func cancellationDuringReadinessDoesNotSend() async {
        let fixture = IntentStatusFixture()
        fixture.readinessTimeout = .seconds(5)
        fixture.runtimeAvailable = false
        let signal = AsyncStream<Void>.makeStream()
        fixture.onResolve = { signal.continuation.yield(()) }
        let task = Task { try await fixture.adapter.request(id: fixture.device.id) }
        for await _ in signal.stream { break }
        task.cancel()
        await #expect(throws: StatusIntentError.service(.cancelled)) { try await task.value }
        #expect(await fixture.runtime.reads == 0)
    }

    @Test func selectionChangeDuringReadinessDoesNotSend() async {
        let fixture = IntentStatusFixture()
        fixture.readinessTimeout = .seconds(2)
        fixture.runtimeAvailable = false
        fixture.onResolve = { [weak fixture] in
            if fixture?.resolves == 2 { fixture?.selection = nil }
        }
        await #expect(throws: StatusIntentError.selectionChanged) { try await fixture.adapter.request(id: fixture.device.id) }
        #expect(await fixture.runtime.reads == 0)
    }

    @Test func discoveryDoesNotResolveRuntime() async throws {
        let fixture = IntentStatusFixture()
        #expect(try fixture.adapter.devices().map(\.id) == [fixture.device.id])
        #expect(fixture.resolves == 0)
        #expect(await fixture.runtime.reads == 0)
        let renamed = StatusDeviceEntity(networkID: fixture.network, nodeID: fixture.peer, name: "Renamed", networkName: "Renamed network")
        #expect(renamed.id == fixture.device.id)
    }

    @Test func pickerUsesSavedMembershipWithoutLivePeers() {
        let savedPeer = NetworkMemberSummary(id: UUID(), displayName: "Saved Mac", isPlaceholderName: false, lastSeen: nil)
        let livePeer = NetworkMemberSummary(id: UUID(), displayName: "Live Mac", isPlaceholderName: false, lastSeen: nil)
        let saved = SavedNetworkMembership(members: [savedPeer], state: .saved, recordedAt: Date())
        #expect(StatusIntentAdapter.pickerMembers(live: [], saved: saved) == [savedPeer])
        #expect(StatusIntentAdapter.pickerMembers(live: [livePeer], saved: saved) == [livePeer])
        #expect(StatusIntentAdapter.pickerMembers(live: [], saved: .unavailable).isEmpty)
        let stale = SavedNetworkMembership(members: [savedPeer], state: .stale, recordedAt: Date())
        #expect(StatusIntentAdapter.pickerMembers(live: [], saved: stale) == [savedPeer])
    }

    @Test func unloadedPickerExplainsNotReady() {
        let fixture = IntentStatusFixture()
        fixture.selection = nil
        #expect(throws: StatusIntentError.notReady) { try fixture.adapter.devices() }
        #expect(fixture.resolves == 0)
    }

    @Test func rejectsInvalidTargetsBeforeRuntime() async {
        let fixture = IntentStatusFixture()
        let targets = ["malformed", "\(NetworkID().rawValue)/\(fixture.peer.rawValue)",
                       "\(fixture.network.rawValue)/\(fixture.local.rawValue)",
                       "\(fixture.network.rawValue)/\(UUID())"]
        for id in targets {
            await #expect(throws: StatusIntentError.invalidTarget) { try await fixture.adapter.request(id: id) }
        }
        #expect(fixture.resolves == 0)
        #expect(await fixture.runtime.reads == 0)
    }

    @Test func unreadyDoesNotRequest() async {
        let fixture = IntentStatusFixture()
        fixture.runtimeAvailable = false
        await #expect(throws: StatusIntentError.notReady) { try await fixture.adapter.request(id: fixture.device.id) }
        fixture.selection = nil
        await #expect(throws: StatusIntentError.notReady) { try await fixture.adapter.request(id: fixture.device.id) }
        #expect(await fixture.runtime.reads == 0)
    }

    @Test func readsWithLocalSharingOff() async throws {
        let fixture = IntentStatusFixture()
        let (device, result) = try await fixture.adapter.request(id: fixture.device.id)
        #expect(device.id == fixture.device.id)
        #expect(result.binding.peerNodeID == fixture.peer)
        #expect(result.snapshot.applicationVersion == "fixture")
        #expect(await fixture.runtime.reads == 1)
        #expect(await fixture.runtime.submittedBinding == fixture.runtime.bindingID)
    }

    @Test func preservesServiceFailures() async {
        let fixture = IntentStatusFixture()
        for error in [SharedStatusError.remote(.unauthorized), .busy, .timedOut, .invalidated, .unavailable] {
            await fixture.runtime.configure(error: error)
            await #expect(throws: StatusIntentError.service(error)) { try await fixture.adapter.request(id: fixture.device.id) }
        }
    }

    @Test func selectionChangeBeforeSend() async {
        let fixture = IntentStatusFixture()
        fixture.changeOnResolve = true
        await #expect(throws: StatusIntentError.selectionChanged) { try await fixture.adapter.request(id: fixture.device.id) }
        #expect(await fixture.runtime.reads == 0)
    }

    @Test func selectionChangeSuppressesResult() async {
        let fixture = IntentStatusFixture()
        await fixture.runtime.configure(beforeReply: { await MainActor.run { fixture.selection = nil } })
        await #expect(throws: StatusIntentError.selectionChanged) { try await fixture.adapter.request(id: fixture.device.id) }
        #expect(await fixture.runtime.reads == 1)
    }

    @Test func cancellationReachesRequest() async {
        let fixture = IntentStatusFixture()
        await fixture.runtime.configure(waits: true)
        let task = Task { try await fixture.adapter.request(id: fixture.device.id) }
        for await _ in fixture.runtime.started { break }
        task.cancel()
        await #expect(throws: StatusIntentError.service(.cancelled)) { try await task.value }
    }
}
