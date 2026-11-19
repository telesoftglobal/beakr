import Foundation
import BeakrNetCore
import BeakrNetSecurity

public protocol JoiningEnrollmentStore: Sendable {
    func stageRequest(_ request: EnrollmentRequest) async throws
    func request(id: UUID) async -> EnrollmentRequest?
    func discardRequest(id: UUID) async throws
    func stageApproval(_ approval: EnrollmentApproval, transactionID: UUID) async throws
    func stagedApproval(transactionID: UUID) async -> EnrollmentApproval?
    func activateApproval(transactionID: UUID) async throws
    func discardStagedApproval(transactionID: UUID) async throws
    func stageConfirmation(_ confirmation: EnrollmentConfirmation) async throws
    func pendingConfirmations() async -> [EnrollmentConfirmation]
    func discardConfirmation(requestID: UUID) async throws
}

/// Installs approval material into application-owned secure storage and trust
/// files. Implementations must be idempotent for an identical approval because
/// recovery can replay this operation after any later crash.
public protocol JoiningMembershipInstalling: Sendable {
    func installMembership(
        from approval: EnrollmentApproval,
        identity: NodeIdentity
    ) async throws
}

public actor InMemoryJoiningEnrollmentStore: JoiningEnrollmentStore {
    private var requests: [UUID: EnrollmentRequest] = [:]
    private var approvals: [UUID: EnrollmentApproval] = [:]
    private var activeApprovals: [UUID: EnrollmentApproval] = [:]
    private var confirmations: [UUID: EnrollmentConfirmation] = [:]

    public init() {}

    public func stageRequest(_ request: EnrollmentRequest) throws {
        if let existing = requests[request.requestID], existing != request {
            throw JoiningEnrollmentError.conflictingRequest
        }
        requests[request.requestID] = request
    }

    public func request(id: UUID) -> EnrollmentRequest? { requests[id] }

    public func discardRequest(id: UUID) {
        requests.removeValue(forKey: id)
    }

    public func stageApproval(_ approval: EnrollmentApproval, transactionID: UUID) throws {
        if let existing = approvals[transactionID], existing != approval {
            throw JoiningEnrollmentError.conflictingApproval
        }
        approvals[transactionID] = approval
    }

    public func stagedApproval(transactionID: UUID) -> EnrollmentApproval? {
        approvals[transactionID] ?? activeApprovals[transactionID]
    }

    public func activateApproval(transactionID: UUID) throws {
        if let approval = approvals.removeValue(forKey: transactionID) {
            activeApprovals[transactionID] = approval
            return
        }
        guard activeApprovals[transactionID] != nil else { throw JoiningEnrollmentError.missingStagedApproval }
    }

    public func discardStagedApproval(transactionID: UUID) {
        approvals.removeValue(forKey: transactionID)
    }

    public func stageConfirmation(_ confirmation: EnrollmentConfirmation) throws {
        if let existing = confirmations[confirmation.requestID], existing != confirmation {
            throw JoiningEnrollmentError.conflictingApproval
        }
        confirmations[confirmation.requestID] = confirmation
    }

    public func pendingConfirmations() -> [EnrollmentConfirmation] {
        confirmations.values.sorted { $0.requestID.uuidString < $1.requestID.uuidString }
    }

    public func discardConfirmation(requestID: UUID) {
        confirmations.removeValue(forKey: requestID)
    }
}

public struct JoinedNetworkState: Sendable {
    public let lifecycle: EnrollmentLifecycleRecord
    public let approval: EnrollmentApproval
    public let confirmation: EnrollmentConfirmation

    public init(
        lifecycle: EnrollmentLifecycleRecord,
        approval: EnrollmentApproval,
        confirmation: EnrollmentConfirmation
    ) {
        self.lifecycle = lifecycle
        self.approval = approval
        self.confirmation = confirmation
    }
}

public enum JoiningEnrollmentError: Error, Equatable, Sendable {
    case lifecycleRecordMissing
    case invalidStartingPhase(EnrollmentPhase)
    case nodeIdentityMismatch
    case requestMissing
    case requestMismatch
    case conflictingRequest
    case conflictingApproval
    case missingStagedApproval
    case invalidRecoveryCheckpoint
}

public actor JoiningEnrollmentCoordinator {
    private let lifecycleStore: any EnrollmentLifecycleStore
    private let enrollmentStore: any JoiningEnrollmentStore
    private let membershipInstaller: any JoiningMembershipInstalling
    private let allowedClockSkew: TimeInterval
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID
    private let makeNonce: @Sendable () -> Data

    public init(
        lifecycleStore: any EnrollmentLifecycleStore,
        enrollmentStore: any JoiningEnrollmentStore,
        membershipInstaller: any JoiningMembershipInstalling,
        allowedClockSkew: TimeInterval,
        now: @escaping @Sendable () -> Date = Date.init,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        makeNonce: @escaping @Sendable () -> Data
    ) {
        self.lifecycleStore = lifecycleStore
        self.enrollmentStore = enrollmentStore
        self.membershipInstaller = membershipInstaller
        self.allowedClockSkew = allowedClockSkew
        self.now = now
        self.makeUUID = makeUUID
        self.makeNonce = makeNonce
    }

    public func beginJoining(
        invitation: EnrollmentInvitation,
        identity: NodeIdentity,
        deviceDisplayName: String? = nil
    ) async throws -> EnrollmentRequest {
        guard let current = try await lifecycleStore.load() else {
            throw JoiningEnrollmentError.lifecycleRecordMissing
        }
        guard current.phase == .identityReady else {
            throw JoiningEnrollmentError.invalidStartingPhase(current.phase)
        }
        guard current.nodeID == identity.nodeID else {
            throw JoiningEnrollmentError.nodeIdentityMismatch
        }
        try EnrollmentWireVerifier.verifyInvitation(
            invitation,
            now: now(),
            allowedClockSkew: allowedClockSkew
        )
        let request = try EnrollmentWireSigner.request(
            invitation: invitation,
            identity: identity,
            deviceDisplayName: deviceDisplayName,
            requestID: makeUUID(),
            requestNonce: makeNonce()
        )
        let network = NetworkBinding(
            networkID: invitation.networkID,
            displayName: invitation.networkDisplayName,
            environment: invitation.environment,
            authorityID: invitation.authorityID,
            authorityPublicKey: invitation.authorityPublicKey,
            controlPlaneURL: invitation.controlPlaneURL
        )
        let pending = PendingEnrollment(
            invitationID: invitation.invitationID,
            requestID: request.requestID,
            networkID: invitation.networkID,
            expectedAuthorityID: invitation.authorityID,
            localNodeID: identity.nodeID,
            createdAtMilliseconds: Self.milliseconds(now()),
            expiresAtMilliseconds: invitation.expiresAtMilliseconds,
            status: .submitted
        )
        do {
            try await enrollmentStore.stageRequest(request)
            let joining = try current.transitioning(
                to: .joining,
                at: Self.milliseconds(now()),
                nodeID: identity.nodeID,
                network: network,
                pendingEnrollment: pending
            )
            try await lifecycleStore.save(joining, condition: .revision(current.revision))
        } catch {
            try? await enrollmentStore.discardRequest(id: request.requestID)
            throw error
        }
        return request
    }

    public func pendingRequest() async throws -> EnrollmentRequest? {
        guard let record = try await lifecycleStore.load() else { return nil }
        guard record.phase == .joining, let requestID = record.pendingEnrollment?.requestID else { return nil }
        return await enrollmentStore.request(id: requestID)
    }

    public func receiveApproval(
        _ approval: EnrollmentApproval,
        identity: NodeIdentity
    ) async throws -> JoinedNetworkState {
        guard let current = try await lifecycleStore.load() else {
            throw JoiningEnrollmentError.lifecycleRecordMissing
        }
        guard current.phase == .joining else {
            throw JoiningEnrollmentError.invalidStartingPhase(current.phase)
        }
        guard current.nodeID == identity.nodeID else {
            throw JoiningEnrollmentError.nodeIdentityMismatch
        }
        guard let requestID = current.pendingEnrollment?.requestID,
              let request = await enrollmentStore.request(id: requestID) else {
            throw JoiningEnrollmentError.requestMissing
        }
        try EnrollmentWireVerifier.verifyApproval(
            approval,
            for: request,
            now: now(),
            allowedClockSkew: allowedClockSkew
        )
        let transactionID = makeUUID()
        let network = NetworkBinding(
            networkID: approval.networkID,
            displayName: current.network?.displayName ?? request.invitation.networkDisplayName,
            environment: request.invitation.environment,
            authorityID: approval.authorityID,
            authorityPublicKey: request.invitation.authorityPublicKey,
            activeCredentialID: approval.credential.claims.credentialID,
            membershipGeneration: approval.membership.claims.generation,
            revocationGeneration: Self.revocationGeneration(approval.revocations),
            controlPlaneURL: request.invitation.controlPlaneURL
        )
        let pending = PendingEnrollment(
            invitationID: request.invitation.invitationID,
            requestID: request.requestID,
            networkID: request.invitation.networkID,
            expectedAuthorityID: request.invitation.authorityID,
            localNodeID: request.nodeID,
            createdAtMilliseconds: current.pendingEnrollment?.createdAtMilliseconds ?? Self.milliseconds(now()),
            expiresAtMilliseconds: request.invitation.expiresAtMilliseconds,
            retryCount: current.pendingEnrollment?.retryCount ?? 0,
            status: .approved
        )
        do {
            try await enrollmentStore.stageApproval(approval, transactionID: transactionID)
            let installing = try current.transitioning(
                to: .installingMembership,
                at: Self.milliseconds(now()),
                nodeID: identity.nodeID,
                network: network,
                pendingEnrollment: pending,
                transaction: EnrollmentTransaction(id: transactionID, kind: .joinNetwork)
            )
            try await lifecycleStore.save(installing, condition: .revision(current.revision))
            return try await complete(checkpoint: installing, approval: approval, identity: identity)
        } catch {
            if try await lifecycleStore.load()?.transaction?.id != transactionID {
                try? await enrollmentStore.discardStagedApproval(transactionID: transactionID)
            }
            throw error
        }
    }

    /// Retire a pending request only after its authority accepts cancellation.
    /// Importing the same invitation resumes the exact saved request instead.
    public func prepareReplacementInvitation(
        _ invitation: EnrollmentInvitation,
        identity: NodeIdentity,
        cancelRequest: @Sendable (EnrollmentCancellation) async throws -> Void
    ) async throws -> Bool {
        guard let request = try await pendingRequest() else {
            throw JoiningEnrollmentError.requestMissing
        }
        guard invitation.invitationID != request.invitation.invitationID else { return false }
        try EnrollmentWireVerifier.verifyInvitation(invitation, now: now(), allowedClockSkew: allowedClockSkew)
        guard invitation.networkID == request.invitation.networkID,
              invitation.authorityID == request.invitation.authorityID,
              invitation.authorityPublicKey == request.invitation.authorityPublicKey,
              identity.nodeID == request.nodeID else {
            throw JoiningEnrollmentError.requestMismatch
        }
        let cancellation = try EnrollmentWireSigner.cancellation(request: request, identity: identity)
        try await cancelRequest(cancellation)
        // An approval or another lifecycle transition may have won while awaiting I/O.
        guard try await pendingRequest() == request else {
            throw JoiningEnrollmentError.invalidRecoveryCheckpoint
        }
        try await cancelJoining()
        return true
    }

    public func cancelJoining() async throws {
        guard let current = try await lifecycleStore.load() else {
            throw JoiningEnrollmentError.lifecycleRecordMissing
        }
        guard current.phase == .joining else {
            throw JoiningEnrollmentError.invalidStartingPhase(current.phase)
        }
        guard let requestID = current.pendingEnrollment?.requestID else {
            throw JoiningEnrollmentError.requestMissing
        }
        let identityReady = try current.transitioning(
            to: .identityReady,
            at: Self.milliseconds(now()),
            nodeID: current.nodeID
        )
        try await lifecycleStore.save(identityReady, condition: .revision(current.revision))
        try await enrollmentStore.discardRequest(id: requestID)
    }

    public func receiveRejection(_ rejection: EnrollmentRejection) async throws {
        guard let current = try await lifecycleStore.load() else {
            throw JoiningEnrollmentError.lifecycleRecordMissing
        }
        guard current.phase == .joining,
              let requestID = current.pendingEnrollment?.requestID,
              let request = await enrollmentStore.request(id: requestID) else {
            throw JoiningEnrollmentError.requestMissing
        }
        try EnrollmentWireVerifier.verifyRejection(rejection, for: request)
        let identityReady = try current.transitioning(
            to: .identityReady,
            at: Self.milliseconds(now()),
            nodeID: current.nodeID
        )
        try await lifecycleStore.save(identityReady, condition: .revision(current.revision))
        try await enrollmentStore.discardRequest(id: requestID)
    }

    public func pendingConfirmations() async -> [EnrollmentConfirmation] {
        await enrollmentStore.pendingConfirmations()
    }

    public func acknowledgeConfirmation(requestID: UUID) async throws {
        try await enrollmentStore.discardConfirmation(requestID: requestID)
    }

    public func resumeMembershipInstallation(identity: NodeIdentity) async throws -> JoinedNetworkState {
        guard let checkpoint = try await lifecycleStore.load() else {
            throw JoiningEnrollmentError.lifecycleRecordMissing
        }
        guard checkpoint.phase == .installingMembership,
              checkpoint.transaction?.kind == .joinNetwork,
              checkpoint.nodeID == identity.nodeID,
              let transactionID = checkpoint.transaction?.id,
              let approval = await enrollmentStore.stagedApproval(transactionID: transactionID) else {
            throw JoiningEnrollmentError.invalidRecoveryCheckpoint
        }
        return try await complete(checkpoint: checkpoint, approval: approval, identity: identity)
    }

    private func complete(
        checkpoint: EnrollmentLifecycleRecord,
        approval: EnrollmentApproval,
        identity: NodeIdentity
    ) async throws -> JoinedNetworkState {
        guard let transactionID = checkpoint.transaction?.id,
              checkpoint.transaction?.kind == .joinNetwork,
              let requestID = checkpoint.pendingEnrollment?.requestID,
              let request = await enrollmentStore.request(id: requestID) else {
            throw JoiningEnrollmentError.invalidRecoveryCheckpoint
        }
        try EnrollmentWireVerifier.verifyApproval(
            approval,
            for: request,
            now: now(),
            allowedClockSkew: allowedClockSkew
        )
        try await membershipInstaller.installMembership(from: approval, identity: identity)
        try await enrollmentStore.activateApproval(transactionID: transactionID)
        let confirmation: EnrollmentConfirmation
        if let existing = await enrollmentStore.pendingConfirmations().first(where: {
            $0.requestID == approval.requestID
        }) {
            confirmation = existing
        } else {
            confirmation = try EnrollmentWireSigner.confirmation(
                approval: approval,
                identity: identity,
                confirmationID: makeUUID()
            )
            try await enrollmentStore.stageConfirmation(confirmation)
        }
        let member = try checkpoint.transitioning(
            to: .member,
            at: max(checkpoint.updatedAtMilliseconds, Self.milliseconds(now())),
            nodeID: checkpoint.nodeID,
            network: checkpoint.network
        )
        try await lifecycleStore.save(member, condition: .revision(checkpoint.revision))
        try await enrollmentStore.discardRequest(id: approval.requestID)
        return JoinedNetworkState(lifecycle: member, approval: approval, confirmation: confirmation)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }

    private static func revocationGeneration(_ snapshot: CredentialRevocationSnapshot) -> UInt64 {
        UInt64(max(0, snapshot.claims.generatedAtMilliseconds))
    }
}
