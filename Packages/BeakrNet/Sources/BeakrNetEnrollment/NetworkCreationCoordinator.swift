import Foundation
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

public struct StagedNodeIdentity: Sendable {
    public let nodeID: NodeID
    public let privateKeyRepresentation: Data

    public init(nodeID: NodeID, privateKeyRepresentation: Data) {
        self.nodeID = nodeID
        self.privateKeyRepresentation = privateKeyRepresentation
    }
}

public struct StagedAuthorityIdentity: Sendable {
    public let authorityID: AuthorityID
    public let privateKeyRepresentation: Data

    public init(authorityID: AuthorityID, privateKeyRepresentation: Data) {
        self.authorityID = authorityID
        self.privateKeyRepresentation = privateKeyRepresentation
    }
}

public struct InitialNetworkTrustArtifacts: Sendable {
    public let credential: NodeCredential
    public let membership: ProfileMembershipSnapshot
    public let revocations: CredentialRevocationSnapshot

    public init(
        credential: NodeCredential,
        membership: ProfileMembershipSnapshot,
        revocations: CredentialRevocationSnapshot
    ) {
        self.credential = credential
        self.membership = membership
        self.revocations = revocations
    }
}

public protocol EnrollmentNodeIdentityStore: Sendable {
    func stage(_ identity: StagedNodeIdentity, transactionID: UUID) async throws
    func activateNodeIdentity(transactionID: UUID) async throws
    func discardStagedNodeIdentity(transactionID: UUID) async throws
}

public protocol EnrollmentAuthorityIdentityStore: Sendable {
    func stage(_ identity: StagedAuthorityIdentity, transactionID: UUID) async throws -> Data
    func activateAuthorityIdentity(transactionID: UUID) async throws
    func discardStagedAuthorityIdentity(transactionID: UUID) async throws
}

public protocol EnrollmentTrustStore: Sendable {
    func stage(_ artifacts: InitialNetworkTrustArtifacts, transactionID: UUID) async throws
    func activateTrustArtifacts(transactionID: UUID) async throws
    func discardStagedTrustArtifacts(transactionID: UUID) async throws
    func activeInitialNetworkArtifacts() async throws -> InitialNetworkTrustArtifacts?
}

public struct InitialNetworkState: Sendable {
    public let lifecycle: EnrollmentLifecycleRecord
    public let credential: NodeCredential
    public let membership: ProfileMembershipSnapshot
    public let revocations: CredentialRevocationSnapshot

    public init(
        lifecycle: EnrollmentLifecycleRecord,
        credential: NodeCredential,
        membership: ProfileMembershipSnapshot,
        revocations: CredentialRevocationSnapshot
    ) {
        self.lifecycle = lifecycle
        self.credential = credential
        self.membership = membership
        self.revocations = revocations
    }
}

public enum NetworkCreationError: Error, Equatable, Sendable {
    case lifecycleRecordMissing
    case invalidStartingPhase(EnrollmentPhase)
    case nodeIdentityMismatch
    case invalidRecoveryCheckpoint
}

public actor EnrollmentCoordinator {
    private let policy: AuthorityPolicy
    private let lifecycleStore: any EnrollmentLifecycleStore
    private let nodeIdentityStore: any EnrollmentNodeIdentityStore
    private let authorityIdentityStore: any EnrollmentAuthorityIdentityStore
    private let trustStore: any EnrollmentTrustStore
    private let now: @Sendable () -> Date
    private let makeTransactionID: @Sendable () -> UUID
    private let makeNetworkID: @Sendable () -> NetworkID
    private let makeSessionID: @Sendable () -> SessionID
    private let makeAuthority: @Sendable () -> CredentialAuthority

    public init(
        policy: AuthorityPolicy,
        lifecycleStore: any EnrollmentLifecycleStore,
        nodeIdentityStore: any EnrollmentNodeIdentityStore,
        authorityIdentityStore: any EnrollmentAuthorityIdentityStore,
        trustStore: any EnrollmentTrustStore,
        now: @escaping @Sendable () -> Date = Date.init,
        makeTransactionID: @escaping @Sendable () -> UUID = UUID.init,
        makeNetworkID: @escaping @Sendable () -> NetworkID = { NetworkID() },
        makeSessionID: @escaping @Sendable () -> SessionID = { SessionID() },
        makeAuthority: @escaping @Sendable () -> CredentialAuthority = CredentialAuthority.init
    ) {
        self.policy = policy
        self.lifecycleStore = lifecycleStore
        self.nodeIdentityStore = nodeIdentityStore
        self.authorityIdentityStore = authorityIdentityStore
        self.trustStore = trustStore
        self.now = now
        self.makeTransactionID = makeTransactionID
        self.makeNetworkID = makeNetworkID
        self.makeSessionID = makeSessionID
        self.makeAuthority = makeAuthority
    }

    public func createNetwork(
        nodeIdentity: NodeIdentity,
        displayName: String,
        environment: String,
        controlPlaneURL: URL? = nil
    ) async throws -> InitialNetworkState {
        guard let current = try await lifecycleStore.load() else {
            throw NetworkCreationError.lifecycleRecordMissing
        }
        guard current.phase == .identityReady else {
            throw NetworkCreationError.invalidStartingPhase(current.phase)
        }
        guard current.nodeID == nodeIdentity.nodeID else {
            throw NetworkCreationError.nodeIdentityMismatch
        }

        let transactionID = makeTransactionID()
        let authority = makeAuthority()
        let networkID = makeNetworkID()
        let timestamp = now()
        let milliseconds = Self.milliseconds(timestamp)
        let credential = try authority.issue(
            nodeID: nodeIdentity.nodeID,
            nodePublicKey: nodeIdentity.publicKeyRepresentation,
            networkID: networkID,
            environment: environment,
            validity: policy.credentialValidity,
            serviceScopes: policy.credentialServiceScopes.sorted(),
            now: timestamp
        )
        let membership = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        ).sign(ProfileMembershipClaims(
            networkID: networkID,
            networkDisplayName: displayName,
            generation: 0,
            generatedAtMilliseconds: milliseconds,
            records: [ProfileMembershipRecord(
                credential: credential,
                certificatePublicKey: nodeIdentity.publicKeyRepresentation,
                sessionID: makeSessionID()
            )]
        ))
        let revocations = try authority.issueRevocationSnapshot(revocations: [], now: timestamp)
        let artifacts = InitialNetworkTrustArtifacts(
            credential: credential,
            membership: membership,
            revocations: revocations
        )

        do {
            try await nodeIdentityStore.stage(
                StagedNodeIdentity(
                    nodeID: nodeIdentity.nodeID,
                    privateKeyRepresentation: nodeIdentity.privateKeyRepresentation
                ),
                transactionID: transactionID
            )
            let authorityReference = try await authorityIdentityStore.stage(
                StagedAuthorityIdentity(
                    authorityID: authority.authorityID,
                    privateKeyRepresentation: authority.privateKeyRepresentation
                ),
                transactionID: transactionID
            )
            try await trustStore.stage(artifacts, transactionID: transactionID)

            let network = NetworkBinding(
                networkID: networkID,
                displayName: displayName,
                environment: environment,
                authorityID: authority.authorityID,
                authorityPublicKey: authority.publicKeyRepresentation,
                activeCredentialID: credential.claims.credentialID,
                membershipGeneration: membership.claims.generation,
                revocationGeneration: 0,
                controlPlaneURL: controlPlaneURL
            )
            let authorityBinding = LocalAuthorityBinding(
                authorityID: authority.authorityID,
                keyPersistentReference: authorityReference,
                authorityGeneration: 0,
                membershipGeneration: membership.claims.generation,
                revocationGeneration: 0
            )
            let checkpoint = try current.transitioning(
                to: .installingMembership,
                at: milliseconds,
                nodeID: nodeIdentity.nodeID,
                network: network,
                authority: authorityBinding,
                transaction: EnrollmentTransaction(id: transactionID, kind: .createNetwork)
            )
            try await lifecycleStore.save(checkpoint, condition: .revision(current.revision))
            return try await finishNetworkCreation(checkpoint: checkpoint, artifacts: artifacts)
        } catch {
            if try await lifecycleStore.load()?.transaction?.id != transactionID {
                await discardStagedArtifacts(transactionID: transactionID)
            }
            throw error
        }
    }

    public func resumeNetworkCreation() async throws -> EnrollmentLifecycleRecord {
        guard let checkpoint = try await lifecycleStore.load() else {
            throw NetworkCreationError.lifecycleRecordMissing
        }
        guard checkpoint.phase == .installingMembership,
              checkpoint.transaction?.kind == .createNetwork else {
            throw NetworkCreationError.invalidRecoveryCheckpoint
        }
        return try await finishNetworkCreation(checkpoint: checkpoint, artifacts: nil).lifecycle
    }

    private func finishNetworkCreation(
        checkpoint: EnrollmentLifecycleRecord,
        artifacts: InitialNetworkTrustArtifacts?
    ) async throws -> InitialNetworkState {
        guard let transactionID = checkpoint.transaction?.id,
              checkpoint.transaction?.kind == .createNetwork else {
            throw NetworkCreationError.invalidRecoveryCheckpoint
        }
        try await nodeIdentityStore.activateNodeIdentity(transactionID: transactionID)
        try await authorityIdentityStore.activateAuthorityIdentity(transactionID: transactionID)
        try await trustStore.activateTrustArtifacts(transactionID: transactionID)

        let completed = try checkpoint.transitioning(
            to: .member,
            at: max(checkpoint.updatedAtMilliseconds, Self.milliseconds(now())),
            nodeID: checkpoint.nodeID,
            network: checkpoint.network,
            authority: checkpoint.authority
        )
        try await lifecycleStore.save(completed, condition: .revision(checkpoint.revision))

        if let artifacts {
            return InitialNetworkState(
                lifecycle: completed,
                credential: artifacts.credential,
                membership: artifacts.membership,
                revocations: artifacts.revocations
            )
        }
        guard let restored = try await trustStore.activeInitialNetworkArtifacts() else {
            throw NetworkCreationError.invalidRecoveryCheckpoint
        }
        return InitialNetworkState(
            lifecycle: completed,
            credential: restored.credential,
            membership: restored.membership,
            revocations: restored.revocations
        )
    }

    private func discardStagedArtifacts(transactionID: UUID) async {
        try? await trustStore.discardStagedTrustArtifacts(transactionID: transactionID)
        try? await authorityIdentityStore.discardStagedAuthorityIdentity(transactionID: transactionID)
        try? await nodeIdentityStore.discardStagedNodeIdentity(transactionID: transactionID)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}

public extension EnrollmentTrustStore {
    func activeInitialNetworkArtifacts() async throws -> InitialNetworkTrustArtifacts? { nil }
}
