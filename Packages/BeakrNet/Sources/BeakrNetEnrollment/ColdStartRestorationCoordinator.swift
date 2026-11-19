import Foundation
import BeakrNetCore
import BeakrNetSecurity

public protocol EnrollmentIdentityRestoring: Sendable {
    func restoreNodeIdentity(nodeID: NodeID) async throws -> NodeIdentity?
}

public protocol EnrollmentRuntimeInspecting: Sendable {
    func runtimeFacts(for record: EnrollmentLifecycleRecord) async throws -> EnrollmentRuntimeFacts
}

public protocol EnrollmentColdStartResuming: Sendable {
    func resumeNetworkCreation() async throws
    func resumeMembershipInstallation(identity: NodeIdentity) async throws
    func finishLeaving(record: EnrollmentLifecycleRecord) async throws
    func startMemberRuntime(record: EnrollmentLifecycleRecord, identity: NodeIdentity) async throws
}

public enum EnrollmentColdStartRecoveryReason: Equatable, Sendable {
    case lifecycleRequiresRecovery
    case missingNodeIdentifier
    case missingNodeIdentity
    case invalidRestoredState(NodeLifecycleState)
}

public enum EnrollmentColdStartResult: Equatable, Sendable {
    case unconfigured
    case restored(DerivedEnrollmentState)
    case waitingForAdministrator(requestID: UUID, state: DerivedEnrollmentState)
    case memberRuntimeStarted(DerivedEnrollmentState)
    case leaveCompleted
    case recoveryRequired(EnrollmentColdStartRecoveryReason)
}

public actor EnrollmentColdStartRestorationCoordinator {
    private let lifecycleStore: any EnrollmentLifecycleStore
    private let identityRestorer: any EnrollmentIdentityRestoring
    private let runtimeInspector: any EnrollmentRuntimeInspecting
    private let resumer: any EnrollmentColdStartResuming

    public init(
        lifecycleStore: any EnrollmentLifecycleStore,
        identityRestorer: any EnrollmentIdentityRestoring,
        runtimeInspector: any EnrollmentRuntimeInspecting,
        resumer: any EnrollmentColdStartResuming
    ) {
        self.lifecycleStore = lifecycleStore
        self.identityRestorer = identityRestorer
        self.runtimeInspector = runtimeInspector
        self.resumer = resumer
    }

    public func restore() async throws -> EnrollmentColdStartResult {
        let record = try await lifecycleStore.load()
        switch EnrollmentColdStartPlanner.action(for: record) {
        case .showUnconfigured:
            return .unconfigured
        case .restoreIdentity:
            guard let record else { return .unconfigured }
            guard try await restoreIdentity(for: record) != nil else {
                return .recoveryRequired(missingIdentityReason(for: record))
            }
            return .restored(try await derivedState(for: record))
        case .waitForAdministrator(let requestID):
            guard let record else { return .unconfigured }
            guard try await restoreIdentity(for: record) != nil else {
                return .recoveryRequired(missingIdentityReason(for: record))
            }
            return .waitingForAdministrator(
                requestID: requestID,
                state: try await derivedState(for: record)
            )
        case .resumeNetworkCreation:
            try await resumer.resumeNetworkCreation()
            return try await startRestoredMemberRuntime()
        case .resumeMembershipInstallation:
            guard let record else { return .unconfigured }
            guard let identity = try await restoreIdentity(for: record) else {
                return .recoveryRequired(missingIdentityReason(for: record))
            }
            try await resumer.resumeMembershipInstallation(identity: identity)
            return try await startRestoredMemberRuntime(identity: identity)
        case .startMemberRuntime:
            return try await startRestoredMemberRuntime()
        case .finishLeaving:
            guard let record else { return .unconfigured }
            try await resumer.finishLeaving(record: record)
            guard EnrollmentColdStartPlanner.action(for: try await lifecycleStore.load()) == .showUnconfigured else {
                return .recoveryRequired(.invalidRestoredState(.leaving))
            }
            return .leaveCompleted
        case .requireRecovery:
            return .recoveryRequired(.lifecycleRequiresRecovery)
        }
    }

    private func startRestoredMemberRuntime(
        identity suppliedIdentity: NodeIdentity? = nil
    ) async throws -> EnrollmentColdStartResult {
        guard let record = try await lifecycleStore.load(), record.phase == .member else {
            return .recoveryRequired(.lifecycleRequiresRecovery)
        }
        let identity: NodeIdentity?
        if let suppliedIdentity {
            identity = suppliedIdentity
        } else {
            identity = try await restoreIdentity(for: record)
        }
        guard let identity else {
            return .recoveryRequired(missingIdentityReason(for: record))
        }
        let state = try await derivedState(for: record)
        guard state.node == .ready else {
            return state.node == .recoveryRequired
                ? .recoveryRequired(.invalidRestoredState(state.node))
                : .restored(state)
        }
        try await resumer.startMemberRuntime(record: record, identity: identity)
        return .memberRuntimeStarted(state)
    }

    private func restoreIdentity(for record: EnrollmentLifecycleRecord) async throws -> NodeIdentity? {
        guard let nodeID = record.nodeID else { return nil }
        guard let identity = try await identityRestorer.restoreNodeIdentity(nodeID: nodeID),
              identity.nodeID == nodeID else {
            return nil
        }
        return identity
    }

    private func derivedState(for record: EnrollmentLifecycleRecord) async throws -> DerivedEnrollmentState {
        let facts = try await runtimeInspector.runtimeFacts(for: record)
        return EnrollmentStateDeriver.derive(record: record, facts: facts)
    }

    private func missingIdentityReason(
        for record: EnrollmentLifecycleRecord
    ) -> EnrollmentColdStartRecoveryReason {
        record.nodeID == nil ? .missingNodeIdentifier : .missingNodeIdentity
    }
}
