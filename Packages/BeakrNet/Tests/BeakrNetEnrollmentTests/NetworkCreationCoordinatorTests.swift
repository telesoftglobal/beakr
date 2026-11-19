import Foundation
import Testing
import BeakrNetCore
import BeakrNetEnrollment
import BeakrNetSecurity

@Suite("Transactional network creation")
struct NetworkCreationCoordinatorTests {
    @Test("Network creation issues initial trust state and commits membership last")
    func createsNetwork() async throws {
        let fixture = try await CreationFixture()
        let result = try await fixture.coordinator.createNetwork(
            nodeIdentity: fixture.identity,
            displayName: "Family",
            environment: "test"
        )

        #expect(result.lifecycle.phase == .member)
        #expect(result.lifecycle.revision == 2)
        #expect(result.lifecycle.transaction == nil)
        #expect(result.credential.claims.nodeID == fixture.identity.nodeID)
        #expect(result.membership.claims.records.map(\.credential.claims.nodeID) == [fixture.identity.nodeID])
        #expect(result.revocations.claims.revocations.isEmpty)
        #expect(await fixture.nodeStore.isActive)
        #expect(await fixture.authorityStore.isActive)
        #expect(await fixture.trustStore.isActive)
    }

    @Test("A staging failure discards artifacts without advancing lifecycle")
    func stagingFailureRollsBack() async throws {
        let fixture = try await CreationFixture(failure: .trustStage)

        await #expect(throws: InjectedCreationFailure.trustStage) {
            try await fixture.coordinator.createNetwork(
                nodeIdentity: fixture.identity,
                displayName: "Family",
                environment: "test"
            )
        }

        #expect(await fixture.lifecycleStore.load()?.phase == .identityReady)
        #expect(await fixture.nodeStore.stagedCount == 0)
        #expect(await fixture.authorityStore.stagedCount == 0)
        #expect(await fixture.trustStore.stagedCount == 0)
    }

    @Test("An activation failure leaves a resumable checkpoint and does not regenerate identities")
    func activationFailureResumes() async throws {
        let fixture = try await CreationFixture(failure: .trustActivateOnce)

        await #expect(throws: InjectedCreationFailure.trustActivate) {
            try await fixture.coordinator.createNetwork(
                nodeIdentity: fixture.identity,
                displayName: "Family",
                environment: "test"
            )
        }
        let checkpoint = try #require(await fixture.lifecycleStore.load())
        let authorityID = checkpoint.authority?.authorityID
        let networkID = checkpoint.network?.networkID
        #expect(checkpoint.phase == .installingMembership)
        #expect(checkpoint.transaction?.kind == .createNetwork)

        let completed = try await fixture.coordinator.resumeNetworkCreation()

        #expect(completed.phase == .member)
        #expect(completed.authority?.authorityID == authorityID)
        #expect(completed.network?.networkID == networkID)
        #expect(completed.transaction == nil)
    }
}

private enum InjectedCreationFailure: Error {
    case trustStage
    case trustActivate
}

private enum CreationFailurePoint: Equatable {
    case none
    case trustStage
    case trustActivateOnce
}

private struct CreationFixture {
    let identity: NodeIdentity
    let lifecycleStore: InMemoryEnrollmentLifecycleStore
    let nodeStore: TestNodeIdentityStore
    let authorityStore: TestAuthorityIdentityStore
    let trustStore: TestTrustStore
    let coordinator: EnrollmentCoordinator

    init(failure: CreationFailurePoint = .none) async throws {
        identity = NodeIdentity()
        let timestamp: Int64 = 1_000
        let initial = try EnrollmentLifecycleRecord(
            installationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            phase: .identityReady,
            nodeID: identity.nodeID,
            createdAtMilliseconds: timestamp,
            updatedAtMilliseconds: timestamp
        )
        lifecycleStore = InMemoryEnrollmentLifecycleStore(record: initial)
        nodeStore = TestNodeIdentityStore()
        authorityStore = TestAuthorityIdentityStore()
        trustStore = TestTrustStore(failure: failure)
        coordinator = EnrollmentCoordinator(
            policy: try Self.policy(),
            lifecycleStore: lifecycleStore,
            nodeIdentityStore: nodeStore,
            authorityIdentityStore: authorityStore,
            trustStore: trustStore,
            now: { Date(timeIntervalSince1970: 1) },
            makeTransactionID: { UUID(uuidString: "10000000-0000-0000-0000-000000000002")! },
            makeNetworkID: { NetworkID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!) },
            makeSessionID: { SessionID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!) }
        )
    }

    private static func policy() throws -> AuthorityPolicy {
        try AuthorityPolicy(
            credentialValidity: 30 * 24 * 60 * 60,
            certificateValidity: 30 * 24 * 60 * 60,
            invitationValidity: 10 * 60,
            pendingRequestValidity: 24 * 60 * 60,
            allowedClockSkew: 60,
            maximumPendingInvitations: 32,
            maximumPendingRequests: 128,
            maximumEnrolledDevices: 1_024,
            maximumPayloadBytes: 64 * 1_024,
            credentialServiceScopes: ["relay.connect", "lan.connect"]
        )
    }
}

private actor TestNodeIdentityStore: EnrollmentNodeIdentityStore {
    private var staged: [UUID: StagedNodeIdentity] = [:]
    private(set) var isActive = false
    var stagedCount: Int { staged.count }

    func stage(_ identity: StagedNodeIdentity, transactionID: UUID) {
        staged[transactionID] = identity
    }

    func activateNodeIdentity(transactionID: UUID) throws {
        guard staged[transactionID] != nil || isActive else { throw InjectedCreationFailure.trustActivate }
        staged.removeValue(forKey: transactionID)
        isActive = true
    }

    func discardStagedNodeIdentity(transactionID: UUID) {
        staged.removeValue(forKey: transactionID)
    }
}

private actor TestAuthorityIdentityStore: EnrollmentAuthorityIdentityStore {
    private var staged: [UUID: StagedAuthorityIdentity] = [:]
    private(set) var isActive = false
    var stagedCount: Int { staged.count }

    func stage(_ identity: StagedAuthorityIdentity, transactionID: UUID) -> Data {
        staged[transactionID] = identity
        return Data(transactionID.uuidString.utf8)
    }

    func activateAuthorityIdentity(transactionID: UUID) throws {
        guard staged[transactionID] != nil || isActive else { throw InjectedCreationFailure.trustActivate }
        staged.removeValue(forKey: transactionID)
        isActive = true
    }

    func discardStagedAuthorityIdentity(transactionID: UUID) {
        staged.removeValue(forKey: transactionID)
    }
}

private actor TestTrustStore: EnrollmentTrustStore {
    private var staged: [UUID: InitialNetworkTrustArtifacts] = [:]
    private var active: InitialNetworkTrustArtifacts?
    private var failure: CreationFailurePoint

    var isActive: Bool { active != nil }
    var stagedCount: Int { staged.count }

    init(failure: CreationFailurePoint) {
        self.failure = failure
    }

    func stage(_ artifacts: InitialNetworkTrustArtifacts, transactionID: UUID) throws {
        if failure == .trustStage { throw InjectedCreationFailure.trustStage }
        staged[transactionID] = artifacts
    }

    func activateTrustArtifacts(transactionID: UUID) throws {
        if failure == .trustActivateOnce {
            failure = .none
            throw InjectedCreationFailure.trustActivate
        }
        if let artifacts = staged.removeValue(forKey: transactionID) {
            active = artifacts
        }
        guard active != nil else { throw InjectedCreationFailure.trustActivate }
    }

    func discardStagedTrustArtifacts(transactionID: UUID) {
        staged.removeValue(forKey: transactionID)
    }

    func activeInitialNetworkArtifacts() -> InitialNetworkTrustArtifacts? { active }
}
