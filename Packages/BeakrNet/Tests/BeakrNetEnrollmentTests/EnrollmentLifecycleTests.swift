import Foundation
import Testing
import BeakrNetCore
import BeakrNetEnrollment

@Suite("Release 1 enrollment lifecycle")
struct EnrollmentLifecycleTests {
    @Test("A joining record requires mutually consistent node, network, and authority bindings")
    func joiningRecordConsistency() throws {
        let fixture = Fixture()
        let pending = fixture.pending(localNodeID: NodeID())

        #expect(throws: EnrollmentLifecycleError.inconsistentBinding) {
            try fixture.record(
                phase: .joining,
                nodeID: fixture.nodeID,
                network: fixture.network(),
                pendingEnrollment: pending
            )
        }
    }

    @Test("Transition validation increments revisions and rejects skipped phases")
    func transitionValidation() throws {
        let fixture = Fixture()
        let initial = try fixture.record(phase: .unconfigured)
        let identity = try initial.transitioning(
            to: .identityReady,
            at: 2,
            nodeID: fixture.nodeID
        )

        #expect(identity.revision == 1)
        #expect(identity.phase == .identityReady)
        #expect(throws: EnrollmentLifecycleError.invalidTransition(from: .identityReady, to: .member)) {
            try identity.transitioning(
                to: .member,
                at: 3,
                nodeID: fixture.nodeID,
                network: fixture.network(credentialID: UUID())
            )
        }
    }

    @Test("A member record requires an installed credential")
    func memberRequiresCredential() {
        let fixture = Fixture()

        #expect(throws: EnrollmentLifecycleError.invalidState(.member)) {
            try fixture.record(
                phase: .member,
                nodeID: fixture.nodeID,
                network: fixture.network()
            )
        }
    }

    @Test("The lifecycle store rejects stale writers")
    func revisionConflict() async throws {
        let fixture = Fixture()
        let initial = try fixture.record(phase: .unconfigured)
        let store = InMemoryEnrollmentLifecycleStore()
        try await store.save(initial, condition: .create)
        let identity = try initial.transitioning(to: .identityReady, at: 2, nodeID: fixture.nodeID)
        try await store.save(identity, condition: .revision(0))

        await #expect(throws: EnrollmentLifecycleError.revisionConflict(expected: 0, actual: 1)) {
            try await store.save(identity, condition: .revision(0))
        }
    }

    @Test("Persisted membership derives current trust failures instead of claiming readiness")
    func derivedMembershipHealth() throws {
        let fixture = Fixture()
        let member = try fixture.record(
            phase: .member,
            nodeID: fixture.nodeID,
            network: fixture.network(credentialID: UUID())
        )
        let stale = EnrollmentStateDeriver.derive(
            record: member,
            facts: EnrollmentRuntimeFacts(
                nodeKeyAvailable: true,
                credentialHealth: .valid,
                trustStateHealth: .stale,
                certificateHealth: .valid
            )
        )
        let ready = EnrollmentStateDeriver.derive(
            record: member,
            facts: EnrollmentRuntimeFacts(
                nodeKeyAvailable: true,
                credentialHealth: .valid,
                trustStateHealth: .valid,
                certificateHealth: .valid
            )
        )

        #expect(stale.node == .trustStateStale)
        #expect(ready.node == .ready)
    }

    @Test("Locked secure storage masks node and authority readiness")
    func lockedStorage() throws {
        let fixture = Fixture()
        let member = try fixture.record(
            phase: .member,
            nodeID: fixture.nodeID,
            network: fixture.network(credentialID: UUID()),
            authority: fixture.authority()
        )
        let state = EnrollmentStateDeriver.derive(
            record: member,
            facts: EnrollmentRuntimeFacts(
                nodeKeyAvailable: true,
                credentialHealth: .valid,
                trustStateHealth: .valid,
                certificateHealth: .valid,
                authorityKeyAvailable: true,
                secureStorageLocked: true
            )
        )

        #expect(state == DerivedEnrollmentState(node: .locked, authority: .locked))
    }
}

@Suite("Release 1 authority policy")
struct AuthorityPolicyTests {
    @Test("A bounded member-only policy validates")
    func validPolicy() throws {
        _ = try policy()
    }

    @Test("Unbounded resources and optional local authorization fail closed")
    func unsafePolicy() {
        #expect(throws: AuthorityPolicyError.invalidResourceBounds) {
            try policy(maximumPayloadBytes: AuthorityPolicy.maximumWirePayloadBytes + 1)
        }
        #expect(throws: AuthorityPolicyError.localAuthorizationRequired) {
            try policy(requiresLocalAuthorizationForApproval: false)
        }
    }

    @Test("Credential scopes must be explicit and normalized")
    func scopePolicy() {
        #expect(throws: AuthorityPolicyError.invalidServiceScopes) {
            try policy(credentialServiceScopes: [])
        }
        #expect(throws: AuthorityPolicyError.invalidServiceScopes) {
            try policy(credentialServiceScopes: [" relay.connect"])
        }
    }

    private func policy(
        maximumPayloadBytes: Int = 64 * 1_024,
        credentialServiceScopes: Set<String> = ["relay.connect", "lan.connect"],
        requiresLocalAuthorizationForApproval: Bool = true
    ) throws -> AuthorityPolicy {
        try AuthorityPolicy(
            credentialValidity: 30 * 24 * 60 * 60,
            certificateValidity: 30 * 24 * 60 * 60,
            invitationValidity: 10 * 60,
            pendingRequestValidity: 24 * 60 * 60,
            allowedClockSkew: 60,
            maximumPendingInvitations: 32,
            maximumPendingRequests: 128,
            maximumEnrolledDevices: 1_024,
            maximumPayloadBytes: maximumPayloadBytes,
            credentialServiceScopes: credentialServiceScopes,
            requiresLocalAuthorizationForApproval: requiresLocalAuthorizationForApproval
        )
    }
}

private struct Fixture {
    let nodeID = NodeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let networkID = NetworkID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let authorityID = AuthorityID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

    func network(credentialID: UUID? = nil) -> NetworkBinding {
        NetworkBinding(
            networkID: networkID,
            displayName: "Test Network",
            environment: "test",
            authorityID: authorityID,
            authorityPublicKey: Data(repeating: 7, count: 65),
            activeCredentialID: credentialID
        )
    }

    func pending(localNodeID: NodeID? = nil) -> PendingEnrollment {
        PendingEnrollment(
            invitationID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            networkID: networkID,
            expectedAuthorityID: authorityID,
            localNodeID: localNodeID ?? nodeID,
            createdAtMilliseconds: 1,
            expiresAtMilliseconds: 10,
            status: .submitted
        )
    }

    func authority() -> LocalAuthorityBinding {
        LocalAuthorityBinding(
            authorityID: authorityID,
            keyPersistentReference: Data([1, 2, 3]),
            authorityGeneration: 1,
            membershipGeneration: 1,
            revocationGeneration: 1
        )
    }

    func record(
        phase: EnrollmentPhase,
        nodeID: NodeID? = nil,
        network: NetworkBinding? = nil,
        pendingEnrollment: PendingEnrollment? = nil,
        authority: LocalAuthorityBinding? = nil,
        transaction: EnrollmentTransaction? = nil
    ) throws -> EnrollmentLifecycleRecord {
        try EnrollmentLifecycleRecord(
            installationID: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
            phase: phase,
            nodeID: nodeID,
            network: network,
            pendingEnrollment: pendingEnrollment,
            authority: authority,
            transaction: transaction,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        )
    }
}
