import Foundation
import Testing
import BeakrNetCore
import BeakrNetEnrollment
import BeakrNetSecurity

@Suite("Cold-start restoration")
struct ColdStartRestorationCoordinatorTests {
    @Test("An absent lifecycle remains unconfigured")
    func unconfigured() async throws {
        let fixture = try ColdStartFixture(record: nil)
        #expect(try await fixture.coordinator.restore() == .unconfigured)
        #expect(await fixture.resumer.events.isEmpty)
    }

    @Test("Identity-ready and joining records restore without starting runtime", arguments: [
        ColdStartPhase.identityReady,
        ColdStartPhase.joining
    ])
    fileprivate func restoresNonmemberState(phase: ColdStartPhase) async throws {
        let fixture = try ColdStartFixture(record: phase.record)
        let result = try await fixture.coordinator.restore()

        switch (phase, result) {
        case (.identityReady, .restored(let state)):
            #expect(state.node == .identityReady)
        case (.joining, .waitingForAdministrator(let requestID, let state)):
            #expect(requestID == ColdStartFixture.requestID)
            #expect(state.node == .waitingForAdministrator)
        default:
            Issue.record("Unexpected restoration result: \(result)")
        }
        #expect(await fixture.resumer.events.isEmpty)
    }

    @Test("Interrupted creation resumes before starting runtime")
    func resumesCreation() async throws {
        let fixture = try ColdStartFixture(record: ColdStartPhase.creating.record)
        await fixture.resumer.setCompletionRecord(try ColdStartPhase.member.record)

        #expect(
            try await fixture.coordinator.restore()
                == .memberRuntimeStarted(DerivedEnrollmentState(node: .ready, authority: .unavailable))
        )
        #expect(await fixture.resumer.events == [.resumeCreation, .startRuntime])
    }

    @Test("Interrupted joining resumes with the restored identity")
    func resumesJoining() async throws {
        let fixture = try ColdStartFixture(record: ColdStartPhase.installing.record)
        await fixture.resumer.setCompletionRecord(try ColdStartPhase.member.record)

        #expect(
            try await fixture.coordinator.restore()
                == .memberRuntimeStarted(DerivedEnrollmentState(node: .ready, authority: .unavailable))
        )
        #expect(await fixture.resumer.events == [.resumeJoining, .startRuntime])
    }

    @Test("Member runtime starts only when trust is ready")
    func gatesMemberRuntimeOnTrust() async throws {
        let fixture = try ColdStartFixture(
            record: ColdStartPhase.member.record,
            facts: EnrollmentRuntimeFacts(
                nodeKeyAvailable: true,
                credentialHealth: .valid,
                trustStateHealth: .stale,
                certificateHealth: .valid
            )
        )

        #expect(
            try await fixture.coordinator.restore()
                == .restored(DerivedEnrollmentState(node: .trustStateStale, authority: .unavailable))
        )
        #expect(await fixture.resumer.events.isEmpty)
    }

    @Test("A missing persisted identity fails closed")
    func missingIdentityRequiresRecovery() async throws {
        let fixture = try ColdStartFixture(record: ColdStartPhase.member.record, identityAvailable: false)
        #expect(try await fixture.coordinator.restore() == .recoveryRequired(.missingNodeIdentity))
        #expect(await fixture.resumer.events.isEmpty)
    }

    @Test("Leaving completes cleanup and verifies the resulting lifecycle")
    func finishesLeaving() async throws {
        let fixture = try ColdStartFixture(record: ColdStartPhase.leaving.record)
        await fixture.resumer.setCompletionRecord(nil)

        #expect(try await fixture.coordinator.restore() == .leaveCompleted)
        #expect(await fixture.resumer.events == [.finishLeaving])
    }

    @Test("Recovery checkpoints never trigger automatic repair")
    func preservesRecoveryCheckpoint() async throws {
        let fixture = try ColdStartFixture(record: ColdStartPhase.recovery.record)
        #expect(try await fixture.coordinator.restore() == .recoveryRequired(.lifecycleRequiresRecovery))
        #expect(await fixture.resumer.events.isEmpty)
    }
}

private enum ColdStartPhase {
    case identityReady
    case joining
    case creating
    case installing
    case member
    case leaving
    case recovery

    var record: EnrollmentLifecycleRecord {
        get throws {
            let nodeID = ColdStartFixture.identity.nodeID
            switch self {
            case .identityReady:
                return try ColdStartFixture.makeRecord(phase: .identityReady, nodeID: nodeID)
            case .joining:
                return try ColdStartFixture.makeRecord(
                    phase: .joining,
                    nodeID: nodeID,
                    network: ColdStartFixture.network,
                    pending: ColdStartFixture.pending
                )
            case .creating:
                return try ColdStartFixture.makeRecord(
                    phase: .installingMembership,
                    nodeID: nodeID,
                    network: ColdStartFixture.network,
                    transaction: EnrollmentTransaction(id: ColdStartFixture.transactionID, kind: .createNetwork)
                )
            case .installing:
                return try ColdStartFixture.makeRecord(
                    phase: .installingMembership,
                    nodeID: nodeID,
                    network: ColdStartFixture.network,
                    pending: ColdStartFixture.approvedPending,
                    transaction: EnrollmentTransaction(id: ColdStartFixture.transactionID, kind: .joinNetwork)
                )
            case .member:
                return try ColdStartFixture.makeRecord(
                    phase: .member,
                    nodeID: nodeID,
                    network: ColdStartFixture.memberNetwork
                )
            case .leaving:
                return try ColdStartFixture.makeRecord(phase: .leaving, nodeID: nodeID, network: ColdStartFixture.network)
            case .recovery:
                return try ColdStartFixture.makeRecord(phase: .recoveryRequired, nodeID: nodeID)
            }
        }
    }
}

private struct ColdStartFixture {
    static let identity = NodeIdentity()
    static let requestID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    static let invitationID = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
    static let transactionID = UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!
    static let authorityID = AuthorityID(
        rawValue: UUID(uuidString: "A0000000-0000-0000-0000-000000000006")!
    )
    static let networkID = NetworkID()
    static let network = NetworkBinding(
        networkID: networkID,
        displayName: "Family",
        environment: "test",
        authorityID: authorityID,
        authorityPublicKey: Data(repeating: 7, count: 32)
    )
    static let memberNetwork = NetworkBinding(
        networkID: networkID,
        displayName: "Family",
        environment: "test",
        authorityID: authorityID,
        authorityPublicKey: Data(repeating: 7, count: 32),
        activeCredentialID: UUID(uuidString: "A0000000-0000-0000-0000-000000000004")!
    )
    static let pending = PendingEnrollment(
        invitationID: invitationID,
        requestID: requestID,
        networkID: networkID,
        expectedAuthorityID: authorityID,
        localNodeID: identity.nodeID,
        createdAtMilliseconds: 1_000,
        expiresAtMilliseconds: 2_000,
        status: .submitted
    )
    static let approvedPending = PendingEnrollment(
        invitationID: invitationID,
        requestID: requestID,
        networkID: networkID,
        expectedAuthorityID: authorityID,
        localNodeID: identity.nodeID,
        createdAtMilliseconds: 1_000,
        expiresAtMilliseconds: 2_000,
        status: .approved
    )

    let coordinator: EnrollmentColdStartRestorationCoordinator
    let resumer: ColdStartResumer

    init(
        record: EnrollmentLifecycleRecord?,
        facts: EnrollmentRuntimeFacts = .ready,
        identityAvailable: Bool = true
    ) throws {
        let lifecycleStore = InMemoryEnrollmentLifecycleStore(record: record)
        resumer = ColdStartResumer(lifecycleStore: lifecycleStore)
        coordinator = EnrollmentColdStartRestorationCoordinator(
            lifecycleStore: lifecycleStore,
            identityRestorer: ColdStartIdentityRestorer(identity: identityAvailable ? Self.identity : nil),
            runtimeInspector: ColdStartRuntimeInspector(facts: facts),
            resumer: resumer
        )
    }

    static func makeRecord(
        phase: EnrollmentPhase,
        nodeID: NodeID? = nil,
        network: NetworkBinding? = nil,
        pending: PendingEnrollment? = nil,
        transaction: EnrollmentTransaction? = nil
    ) throws -> EnrollmentLifecycleRecord {
        try EnrollmentLifecycleRecord(
            installationID: UUID(uuidString: "A0000000-0000-0000-0000-000000000005")!,
            phase: phase,
            nodeID: nodeID,
            network: network,
            pendingEnrollment: pending,
            transaction: transaction,
            createdAtMilliseconds: 1_000,
            updatedAtMilliseconds: 1_000
        )
    }
}

private extension EnrollmentRuntimeFacts {
    static let ready = EnrollmentRuntimeFacts(
        nodeKeyAvailable: true,
        credentialHealth: .valid,
        trustStateHealth: .valid,
        certificateHealth: .valid
    )
}

private struct ColdStartIdentityRestorer: EnrollmentIdentityRestoring {
    let identity: NodeIdentity?

    func restoreNodeIdentity(nodeID: NodeID) -> NodeIdentity? {
        identity?.nodeID == nodeID ? identity : nil
    }
}

private struct ColdStartRuntimeInspector: EnrollmentRuntimeInspecting {
    let facts: EnrollmentRuntimeFacts

    func runtimeFacts(for record: EnrollmentLifecycleRecord) -> EnrollmentRuntimeFacts { facts }
}

private enum ColdStartEvent: Equatable {
    case resumeCreation
    case resumeJoining
    case finishLeaving
    case startRuntime
}

private actor ColdStartResumer: EnrollmentColdStartResuming {
    private let lifecycleStore: InMemoryEnrollmentLifecycleStore
    private var completionRecord: EnrollmentLifecycleRecord??
    private(set) var events: [ColdStartEvent] = []

    init(lifecycleStore: InMemoryEnrollmentLifecycleStore) {
        self.lifecycleStore = lifecycleStore
    }

    func setCompletionRecord(_ record: EnrollmentLifecycleRecord?) {
        completionRecord = .some(record)
    }

    func resumeNetworkCreation() async throws {
        events.append(.resumeCreation)
        try await applyCompletionRecord()
    }

    func resumeMembershipInstallation(identity: NodeIdentity) async throws {
        events.append(.resumeJoining)
        try await applyCompletionRecord()
    }

    func finishLeaving(record: EnrollmentLifecycleRecord) async throws {
        events.append(.finishLeaving)
        try await applyCompletionRecord()
    }

    func startMemberRuntime(record: EnrollmentLifecycleRecord, identity: NodeIdentity) {
        events.append(.startRuntime)
    }

    private func applyCompletionRecord() async throws {
        guard let completionRecord else { return }
        guard let current = await lifecycleStore.load() else { return }
        if let completionRecord {
            try await lifecycleStore.save(completionRecord, condition: .revision(current.revision))
        } else {
            // The production leave implementation owns deletion. The test store models it
            // with a fresh empty store, so a nil completion is observed through this adapter.
            try await lifecycleStore.save(
                try EnrollmentLifecycleRecord(
                    revision: current.revision + 1,
                    installationID: current.installationID,
                    phase: .unconfigured,
                    createdAtMilliseconds: current.createdAtMilliseconds,
                    updatedAtMilliseconds: current.updatedAtMilliseconds
                ),
                condition: .revision(current.revision)
            )
        }
    }
}
