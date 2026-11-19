import Foundation
import Testing
import BeakrNetCore
@testable import BeakrNetAuthority

@Suite("Revocation snapshot refresh")
struct RevocationRefreshTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("A fetched snapshot is verified, persisted, then activated")
    func durableActivation() async throws {
        let fixture = try Fixture()
        let consumer = OrderedConsumer(events: fixture.events)
        await fixture.distributor.register(consumer)

        let outcome = await fixture.controller.refreshNow(trigger: .scheduled)

        guard case .activated(let report, let next) = outcome else {
            Issue.record("Expected activation")
            return
        }
        #expect(report.generatedAtMilliseconds == fixture.snapshot.claims.generatedAtMilliseconds)
        #expect(next == now.addingTimeInterval(60))
        #expect(fixture.events.values() == ["persist", "install"])
        #expect(fixture.store.saved() == fixture.snapshot)
    }

    @Test("A persistence failure prevents publication")
    func persistenceFailureFailsClosed() async throws {
        let fixture = try Fixture(storeFails: true)
        let consumer = OrderedConsumer(events: fixture.events)
        await fixture.distributor.register(consumer)

        let outcome = await fixture.controller.refreshNow(trigger: .pushNotification)

        guard case .failed(let retryAt, let count, _) = outcome else {
            Issue.record("Expected a scheduled retry")
            return
        }
        #expect(count == 1)
        #expect(retryAt == now.addingTimeInterval(5))
        #expect(await fixture.distributor.latestSnapshot() == nil)
        #expect(await consumer.snapshots.isEmpty)
    }

    @Test("Failures back off and a successful no-change response resets cadence")
    func retryAndUnchangedCadence() async throws {
        let authority = CredentialAuthority()
        let requester = SequenceRequester(results: [
            .failure(TestRefreshError.offline),
            .failure(TestRefreshError.offline),
            .success(nil)
        ])
        let controller = RevocationRefreshController(
            distributor: RevocationSnapshotDistributor(
                trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                now: { now }
            ),
            requester: requester,
            store: MemorySnapshotStore(events: EventRecorder()),
            policy: try RevocationRefreshPolicy(
                refreshInterval: 60,
                initialRetryDelay: 5,
                maximumRetryDelay: 20
            ),
            now: { now }
        )

        #expect(await controller.refreshNow(trigger: .manual).retryDate == now.addingTimeInterval(5))
        #expect(await controller.refreshNow(trigger: .scheduled).retryDate == now.addingTimeInterval(10))
        #expect(await controller.refreshNow(trigger: .scheduled) == .unchanged(
            nextAttemptAt: now.addingTimeInterval(60)
        ))
    }

    @Test("Startup restores durable state and catches up registered routes")
    func startupRestore() async throws {
        let fixture = try Fixture(initialSnapshot: true)
        let consumer = OrderedConsumer(events: fixture.events)
        await fixture.distributor.register(consumer)

        let report = try await fixture.controller.restorePersistedSnapshot()

        #expect(report?.generatedAtMilliseconds == fixture.snapshot.claims.generatedAtMilliseconds)
        #expect(await consumer.snapshots == [fixture.snapshot])
        #expect(await fixture.controller.nextScheduledAttempt() == now.addingTimeInterval(60))
    }

    @Test("Corrupt or wrong-authority saved revocations never reach a consumer",
          arguments: [false, true])
    func corruptPersistedRevocationsFailClosed(wrongAuthority: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("revocations.json")
        let authority = CredentialAuthority()
        if wrongAuthority {
            try CredentialFiles.saveRevocationSnapshot(
                CredentialAuthority().issueRevocationSnapshot(revocations: [], now: now), to: fileURL
            )
        } else {
            try Data("{broken".utf8).write(to: fileURL)
        }
        let original = try Data(contentsOf: fileURL)
        let distributor = RevocationSnapshotDistributor(
            trustedAuthorityPublicKey: authority.publicKeyRepresentation, now: { now }
        )
        let consumer = OrderedConsumer(events: EventRecorder())
        await distributor.register(consumer)
        let controller = RevocationRefreshController(
            distributor: distributor, requester: SequenceRequester(results: [.success(nil)]),
            store: FileRevocationSnapshotStore(fileURL: fileURL), policy: try .init(), now: { now }
        )

        await #expect(throws: (any Error).self) {
            _ = try await controller.restorePersistedSnapshot()
        }
        #expect(await distributor.latestSnapshot() == nil)
        #expect(await consumer.snapshots.isEmpty)
        #expect(try Data(contentsOf: fileURL) == original)
    }
}

private extension RevocationRefreshOutcome {
    var retryDate: Date? {
        if case .failed(let date, _, _) = self { return date }
        return nil
    }
}

private struct Fixture {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let snapshot: CredentialRevocationSnapshot
    let distributor: RevocationSnapshotDistributor
    let store: MemorySnapshotStore
    let controller: RevocationRefreshController
    let events = EventRecorder()

    init(storeFails: Bool = false, initialSnapshot: Bool = false) throws {
        let clockDate = Date(timeIntervalSince1970: 2_000_000_000)
        let authority = CredentialAuthority()
        snapshot = try authority.issueRevocationSnapshot(revocations: [], now: clockDate)
        distributor = RevocationSnapshotDistributor(
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            now: { clockDate }
        )
        store = MemorySnapshotStore(
            initial: initialSnapshot ? snapshot : nil,
            shouldFail: storeFails,
            events: events
        )
        controller = RevocationRefreshController(
            distributor: distributor,
            requester: SequenceRequester(results: [.success(snapshot)]),
            store: store,
            policy: try RevocationRefreshPolicy(
                refreshInterval: 60,
                initialRetryDelay: 5,
                maximumRetryDelay: 20
            ),
            now: { clockDate }
        )
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    func values() -> [String] { lock.withLock { storage } }
}

private final class MemorySnapshotStore: RevocationSnapshotPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: CredentialRevocationSnapshot?
    private let shouldFail: Bool
    private let events: EventRecorder

    init(
        initial: CredentialRevocationSnapshot? = nil,
        shouldFail: Bool = false,
        events: EventRecorder
    ) {
        snapshot = initial
        self.shouldFail = shouldFail
        self.events = events
    }

    func loadSnapshot() throws -> CredentialRevocationSnapshot? { lock.withLock { snapshot } }
    func saveSnapshot(_ snapshot: CredentialRevocationSnapshot) throws {
        if shouldFail { throw TestRefreshError.storage }
        lock.withLock { self.snapshot = snapshot }
        events.append("persist")
    }
    func saved() -> CredentialRevocationSnapshot? { lock.withLock { snapshot } }
}

private actor SequenceRequester: RevocationSnapshotRequesting {
    private var results: [Result<CredentialRevocationSnapshot?, Error>]
    init(results: [Result<CredentialRevocationSnapshot?, Error>]) { self.results = results }
    func fetchSnapshot(after generatedAtMilliseconds: Int64?) async throws
        -> CredentialRevocationSnapshot? {
        try results.removeFirst().get()
    }
}

private actor OrderedConsumer: RevocationSnapshotConsumer {
    nonisolated let revocationConsumerID = TransportID()
    private(set) var snapshots: [CredentialRevocationSnapshot] = []
    private let events: EventRecorder
    init(events: EventRecorder) { self.events = events }
    func installRevocationSnapshot(_ snapshot: CredentialRevocationSnapshot) async throws {
        snapshots.append(snapshot)
        events.append("install")
    }
}

private enum TestRefreshError: Error {
    case offline
    case storage
}
