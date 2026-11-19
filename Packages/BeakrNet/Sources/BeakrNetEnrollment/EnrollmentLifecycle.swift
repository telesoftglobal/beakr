import Foundation
import BeakrNetCore

public enum EnrollmentPhase: String, Codable, CaseIterable, Sendable {
    case unconfigured
    case identityReady
    case joining
    case installingMembership
    case member
    case leaving
    case recoveryRequired
}

public enum PendingEnrollmentStatus: String, Codable, Sendable {
    case prepared
    case submitted
    case approved
}

public enum DeviceRole: String, Codable, CaseIterable, Hashable, Sendable {
    case member
}

public enum AuthorityRole: String, Codable, Sendable {
    case primary
}

public enum EnrollmentTransactionKind: String, Codable, Sendable {
    case createNetwork
    case joinNetwork
}

public struct EnrollmentTransaction: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: EnrollmentTransactionKind

    public init(id: UUID, kind: EnrollmentTransactionKind) {
        self.id = id
        self.kind = kind
    }
}

public struct NetworkBinding: Codable, Equatable, Sendable {
    public let networkID: NetworkID
    public let displayName: String
    public let environment: String
    public let authorityID: AuthorityID
    public let authorityPublicKey: Data
    public let activeCredentialID: UUID?
    public let membershipGeneration: UInt64
    public let revocationGeneration: UInt64
    public let controlPlaneURL: URL?

    public init(
        networkID: NetworkID,
        displayName: String,
        environment: String,
        authorityID: AuthorityID,
        authorityPublicKey: Data,
        activeCredentialID: UUID? = nil,
        membershipGeneration: UInt64 = 0,
        revocationGeneration: UInt64 = 0,
        controlPlaneURL: URL? = nil
    ) {
        self.networkID = networkID
        self.displayName = displayName
        self.environment = environment
        self.authorityID = authorityID
        self.authorityPublicKey = authorityPublicKey
        self.activeCredentialID = activeCredentialID
        self.membershipGeneration = membershipGeneration
        self.revocationGeneration = revocationGeneration
        self.controlPlaneURL = controlPlaneURL
    }
}

public struct PendingEnrollment: Codable, Equatable, Sendable {
    public let invitationID: UUID
    public let requestID: UUID
    public let networkID: NetworkID
    public let expectedAuthorityID: AuthorityID
    public let localNodeID: NodeID
    public let createdAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let retryCount: Int
    public let status: PendingEnrollmentStatus

    public init(
        invitationID: UUID,
        requestID: UUID,
        networkID: NetworkID,
        expectedAuthorityID: AuthorityID,
        localNodeID: NodeID,
        createdAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        retryCount: Int = 0,
        status: PendingEnrollmentStatus
    ) {
        self.invitationID = invitationID
        self.requestID = requestID
        self.networkID = networkID
        self.expectedAuthorityID = expectedAuthorityID
        self.localNodeID = localNodeID
        self.createdAtMilliseconds = createdAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.retryCount = retryCount
        self.status = status
    }
}

public struct LocalAuthorityBinding: Codable, Equatable, Sendable {
    public let authorityID: AuthorityID
    public let role: AuthorityRole
    public let keyPersistentReference: Data
    public let authorityGeneration: UInt64
    public let membershipGeneration: UInt64
    public let revocationGeneration: UInt64

    public init(
        authorityID: AuthorityID,
        role: AuthorityRole = .primary,
        keyPersistentReference: Data,
        authorityGeneration: UInt64,
        membershipGeneration: UInt64,
        revocationGeneration: UInt64
    ) {
        self.authorityID = authorityID
        self.role = role
        self.keyPersistentReference = keyPersistentReference
        self.authorityGeneration = authorityGeneration
        self.membershipGeneration = membershipGeneration
        self.revocationGeneration = revocationGeneration
    }
}

public struct EnrollmentLifecycleRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let revision: UInt64
    public let installationID: UUID
    public let phase: EnrollmentPhase
    public let nodeID: NodeID?
    public let network: NetworkBinding?
    public let pendingEnrollment: PendingEnrollment?
    public let authority: LocalAuthorityBinding?
    public let transaction: EnrollmentTransaction?
    public let createdAtMilliseconds: Int64
    public let updatedAtMilliseconds: Int64

    public init(
        version: Int = Self.currentVersion,
        revision: UInt64 = 0,
        installationID: UUID,
        phase: EnrollmentPhase,
        nodeID: NodeID? = nil,
        network: NetworkBinding? = nil,
        pendingEnrollment: PendingEnrollment? = nil,
        authority: LocalAuthorityBinding? = nil,
        transaction: EnrollmentTransaction? = nil,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64
    ) throws {
        self.version = version
        self.revision = revision
        self.installationID = installationID
        self.phase = phase
        self.nodeID = nodeID
        self.network = network
        self.pendingEnrollment = pendingEnrollment
        self.authority = authority
        self.transaction = transaction
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
        try validate()
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw EnrollmentLifecycleError.unsupportedVersion(version)
        }
        guard updatedAtMilliseconds >= createdAtMilliseconds else {
            throw EnrollmentLifecycleError.invalidTimestamps
        }
        try validateBindings()
        try validatePhase()
    }

    public func transitioning(
        to nextPhase: EnrollmentPhase,
        at updatedAtMilliseconds: Int64,
        nodeID: NodeID? = nil,
        network: NetworkBinding? = nil,
        pendingEnrollment: PendingEnrollment? = nil,
        authority: LocalAuthorityBinding? = nil,
        transaction: EnrollmentTransaction? = nil
    ) throws -> EnrollmentLifecycleRecord {
        guard Self.allowedTransitions[phase, default: []].contains(nextPhase) else {
            throw EnrollmentLifecycleError.invalidTransition(from: phase, to: nextPhase)
        }
        guard updatedAtMilliseconds >= self.updatedAtMilliseconds else {
            throw EnrollmentLifecycleError.invalidTimestamps
        }
        guard revision < UInt64.max else {
            throw EnrollmentLifecycleError.revisionExhausted
        }
        return try EnrollmentLifecycleRecord(
            revision: revision + 1,
            installationID: installationID,
            phase: nextPhase,
            nodeID: nodeID,
            network: network,
            pendingEnrollment: pendingEnrollment,
            authority: authority,
            transaction: transaction,
            createdAtMilliseconds: createdAtMilliseconds,
            updatedAtMilliseconds: updatedAtMilliseconds
        )
    }

    private func validateBindings() throws {
        if let network {
            let name = network.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= NetworkProfile.maximumDisplayNameBytes else {
                throw EnrollmentLifecycleError.invalidNetworkBinding
            }
            guard !network.environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !network.authorityPublicKey.isEmpty,
                  network.controlPlaneURL.map({ $0.scheme?.lowercased() == "https" }) ?? true else {
                throw EnrollmentLifecycleError.invalidNetworkBinding
            }
        }
        if let pendingEnrollment {
            guard pendingEnrollment.expiresAtMilliseconds > pendingEnrollment.createdAtMilliseconds,
                  pendingEnrollment.retryCount >= 0 else {
                throw EnrollmentLifecycleError.invalidPendingEnrollment
            }
            guard pendingEnrollment.localNodeID == nodeID,
                  pendingEnrollment.networkID == network?.networkID,
                  pendingEnrollment.expectedAuthorityID == network?.authorityID else {
                throw EnrollmentLifecycleError.inconsistentBinding
            }
        }
        if let authority {
            guard !authority.keyPersistentReference.isEmpty,
                  authority.authorityID == network?.authorityID else {
                throw EnrollmentLifecycleError.inconsistentBinding
            }
        }
    }

    private func validatePhase() throws {
        let valid: Bool
        switch phase {
        case .unconfigured:
            valid = nodeID == nil && network == nil && pendingEnrollment == nil && authority == nil && transaction == nil
        case .identityReady:
            valid = nodeID != nil && network == nil && pendingEnrollment == nil && authority == nil && transaction == nil
        case .joining:
            valid = nodeID != nil && network != nil && pendingEnrollment != nil && authority == nil && transaction == nil
        case .installingMembership:
            valid = nodeID != nil && network != nil && transaction != nil && (
                transaction?.kind == .createNetwork || pendingEnrollment?.status == .approved
            )
        case .member:
            valid = nodeID != nil && network?.activeCredentialID != nil && pendingEnrollment == nil && transaction == nil
        case .leaving:
            valid = nodeID != nil && network != nil && pendingEnrollment == nil && transaction == nil
        case .recoveryRequired:
            valid = nodeID != nil || network != nil || authority != nil
        }
        guard valid else { throw EnrollmentLifecycleError.invalidState(phase) }
    }

    private static let allowedTransitions: [EnrollmentPhase: Set<EnrollmentPhase>] = [
        .unconfigured: [.identityReady, .recoveryRequired],
        .identityReady: [.joining, .installingMembership, .recoveryRequired],
        .joining: [.joining, .installingMembership, .identityReady, .recoveryRequired],
        .installingMembership: [.member, .identityReady, .recoveryRequired],
        .member: [.member, .leaving, .recoveryRequired],
        .leaving: [.unconfigured, .recoveryRequired],
        .recoveryRequired: [.identityReady, .joining, .installingMembership, .member, .leaving]
    ]
}

public enum EnrollmentLifecycleError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidTimestamps
    case invalidNetworkBinding
    case invalidPendingEnrollment
    case inconsistentBinding
    case invalidState(EnrollmentPhase)
    case invalidTransition(from: EnrollmentPhase, to: EnrollmentPhase)
    case revisionExhausted
    case recordAlreadyExists
    case revisionConflict(expected: UInt64, actual: UInt64?)
}

public protocol EnrollmentLifecycleStore: Sendable {
    func load() async throws -> EnrollmentLifecycleRecord?
    func save(_ record: EnrollmentLifecycleRecord, condition: LifecycleWriteCondition) async throws
}

public enum LifecycleWriteCondition: Equatable, Sendable {
    case create
    case revision(UInt64)
}

public actor InMemoryEnrollmentLifecycleStore: EnrollmentLifecycleStore {
    private var record: EnrollmentLifecycleRecord?

    public init(record: EnrollmentLifecycleRecord? = nil) {
        self.record = record
    }

    public func load() -> EnrollmentLifecycleRecord? { record }

    public func save(_ record: EnrollmentLifecycleRecord, condition: LifecycleWriteCondition) throws {
        try record.validate()
        switch condition {
        case .create:
            guard self.record == nil else { throw EnrollmentLifecycleError.recordAlreadyExists }
        case .revision(let expectedRevision):
            guard self.record?.revision == expectedRevision else {
                throw EnrollmentLifecycleError.revisionConflict(
                    expected: expectedRevision,
                    actual: self.record?.revision
                )
            }
        }
        self.record = record
    }
}
