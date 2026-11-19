import Foundation
import Testing
import BeakrNetCore
import BeakrNetEnrollment
import BeakrNetEnrollmentHost
import BeakrNetSecurity

@Suite("Apple enrollment cold-start resumer")
struct AppleEnrollmentColdStartResumerTests {
    @Test("Creation and joining recovery delegate without generating new state")
    func delegatesTransactionalRecovery() async throws {
        let fixture = try ResumerFixture(record: .member)

        try await fixture.resumer.resumeNetworkCreation()
        try await fixture.resumer.resumeMembershipInstallation(identity: fixture.identity)

        #expect(await fixture.events.values == [.resumeCreation, .resumeJoining])
    }

    @Test("Runtime startup rejects a mismatched restored identity")
    func rejectsMismatchedIdentity() async throws {
        let fixture = try ResumerFixture(record: .member)
        let otherIdentity = NodeIdentity()

        await #expect(throws: AppleEnrollmentColdStartResumerError.profileBindingMismatch) {
            try await fixture.resumer.startMemberRuntime(
                record: fixture.record,
                identity: otherIdentity
            )
        }
        #expect(await fixture.events.values.isEmpty)
    }

    @Test("Leave cleanup commits unconfigured only after idempotent cleanup")
    func finishesLeaveInOrder() async throws {
        let fixture = try ResumerFixture(record: .leaving)

        try await fixture.resumer.finishLeaving(record: fixture.record)

        #expect(await fixture.events.values == [.stopRuntime, .cleanProfile, .removeProfile])
        let completed = try #require(await fixture.lifecycleStore.load())
        #expect(completed.phase == .unconfigured)
        #expect(completed.revision == fixture.record.revision + 1)
    }

    @Test("A cleanup failure preserves the leaving checkpoint")
    func cleanupFailurePreservesCheckpoint() async throws {
        let fixture = try ResumerFixture(record: .leaving, failCleanup: true)

        await #expect(throws: ResumerTestError.cleanup) {
            try await fixture.resumer.finishLeaving(record: fixture.record)
        }

        #expect(await fixture.lifecycleStore.load()?.phase == .leaving)
        #expect(await fixture.events.values == [.stopRuntime, .cleanProfile])
    }
}

private enum ResumerEvent: Equatable {
    case resumeCreation
    case resumeJoining
    case startRuntime
    case stopRuntime
    case cleanProfile
    case removeProfile
}

private enum ResumerTestError: Error {
    case cleanup
}

private actor ResumerEvents {
    private(set) var values: [ResumerEvent] = []
    func append(_ event: ResumerEvent) { values.append(event) }
}

private struct ResumerFixture {
    static let profileID = NetworkProfileID(
        rawValue: UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!
    )
    static let networkID = NetworkID(
        rawValue: UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!
    )
    static let authorityID = AuthorityID(
        rawValue: UUID(uuidString: "B0000000-0000-0000-0000-000000000003")!
    )

    let identity = NodeIdentity()
    let record: EnrollmentLifecycleRecord
    let lifecycleStore: InMemoryEnrollmentLifecycleStore
    let events = ResumerEvents()
    let resumer: AppleEnrollmentColdStartResumer

    init(record phase: EnrollmentPhase, failCleanup: Bool = false) throws {
        let identity = self.identity
        let network = NetworkBinding(
            networkID: Self.networkID,
            displayName: "Family",
            environment: "test",
            authorityID: Self.authorityID,
            authorityPublicKey: Data(repeating: 9, count: 32),
            activeCredentialID: UUID(uuidString: "B0000000-0000-0000-0000-000000000004")!
        )
        record = try EnrollmentLifecycleRecord(
            installationID: UUID(uuidString: "B0000000-0000-0000-0000-000000000005")!,
            phase: phase,
            nodeID: identity.nodeID,
            network: network,
            createdAtMilliseconds: 1_000,
            updatedAtMilliseconds: 1_000
        )
        lifecycleStore = InMemoryEnrollmentLifecycleStore(record: record)
        let recovery = ResumerRecovery(events: events)
        resumer = AppleEnrollmentColdStartResumer(
            lifecycleStore: lifecycleStore,
            networkCreation: recovery,
            membershipInstallation: recovery,
            runtimeManager: ResumerRuntime(events: events),
            profileRegistry: ResumerRegistry(events: events),
            profileCleaner: ResumerCleaner(events: events, fail: failCleanup),
            profileID: Self.profileID,
            now: { Date(timeIntervalSince1970: 2) }
        )
    }
}

private actor ResumerRecovery: EnrollmentNetworkCreationResuming,
    EnrollmentMembershipInstallationResuming {
    let events: ResumerEvents
    init(events: ResumerEvents) { self.events = events }

    func resumeNetworkCreationForColdStart() async {
        await events.append(.resumeCreation)
    }

    func resumeMembershipInstallationForColdStart(identity: NodeIdentity) async {
        await events.append(.resumeJoining)
    }
}

private actor ResumerRuntime: EnrollmentMemberRuntimeManaging {
    let events: ResumerEvents
    init(events: ResumerEvents) { self.events = events }

    func startMemberRuntime(for record: EnrollmentLifecycleRecord) async {
        await events.append(.startRuntime)
    }

    func stopMemberRuntimeIfActive() async {
        await events.append(.stopRuntime)
    }
}

private actor ResumerRegistry: EnrollmentProfileDeregistering {
    let events: ResumerEvents
    init(events: ResumerEvents) { self.events = events }

    func removeProfileIfPresent(
        profileID: NetworkProfileID,
        networkID: NetworkID,
        nodeID: NodeID
    ) async {
        await events.append(.removeProfile)
    }
}

private actor ResumerCleaner: EnrollmentProfileCleaning {
    let events: ResumerEvents
    let fail: Bool
    init(events: ResumerEvents, fail: Bool) {
        self.events = events
        self.fail = fail
    }

    func removeProfileMaterial() async throws {
        await events.append(.cleanProfile)
        if fail { throw ResumerTestError.cleanup }
    }
}
