import Foundation
import BeakrNetCore
import BeakrNetEnrollment
import BeakrNetHost
import BeakrNetSecurity

public protocol EnrollmentNetworkCreationResuming: Sendable {
    func resumeNetworkCreationForColdStart() async throws
}

public protocol EnrollmentMembershipInstallationResuming: Sendable {
    func resumeMembershipInstallationForColdStart(identity: NodeIdentity) async throws
}

public protocol EnrollmentMemberRuntimeManaging: Sendable {
    func startMemberRuntime(for record: EnrollmentLifecycleRecord) async throws
    func stopMemberRuntimeIfActive() async throws
}

public protocol EnrollmentProfileDeregistering: Sendable {
    func removeProfileIfPresent(
        profileID: NetworkProfileID,
        networkID: NetworkID,
        nodeID: NodeID
    ) async throws
}

public protocol EnrollmentProfileCleaning: Sendable {
    func removeProfileMaterial() async throws
}

extension EnrollmentCoordinator: EnrollmentNetworkCreationResuming {
    public func resumeNetworkCreationForColdStart() async throws {
        _ = try await resumeNetworkCreation()
    }
}

extension JoiningEnrollmentCoordinator: EnrollmentMembershipInstallationResuming {
    public func resumeMembershipInstallationForColdStart(identity: NodeIdentity) async throws {
        _ = try await resumeMembershipInstallation(identity: identity)
    }
}

public enum AppleEnrollmentColdStartResumerError: Error, Equatable, Sendable {
    case lifecycleRecordMissing
    case invalidLeavingRecord
    case profileBindingMismatch
}

public actor AppleEnrollmentColdStartResumer: EnrollmentColdStartResuming {
    private let lifecycleStore: any EnrollmentLifecycleStore
    private let networkCreation: any EnrollmentNetworkCreationResuming
    private let membershipInstallation: any EnrollmentMembershipInstallationResuming
    private let runtimeManager: any EnrollmentMemberRuntimeManaging
    private let profileRegistry: any EnrollmentProfileDeregistering
    private let profileCleaner: any EnrollmentProfileCleaning
    private let profileID: NetworkProfileID
    private let now: @Sendable () -> Date

    public init(
        lifecycleStore: any EnrollmentLifecycleStore,
        networkCreation: any EnrollmentNetworkCreationResuming,
        membershipInstallation: any EnrollmentMembershipInstallationResuming,
        runtimeManager: any EnrollmentMemberRuntimeManaging,
        profileRegistry: any EnrollmentProfileDeregistering,
        profileCleaner: any EnrollmentProfileCleaning,
        profileID: NetworkProfileID,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.lifecycleStore = lifecycleStore
        self.networkCreation = networkCreation
        self.membershipInstallation = membershipInstallation
        self.runtimeManager = runtimeManager
        self.profileRegistry = profileRegistry
        self.profileCleaner = profileCleaner
        self.profileID = profileID
        self.now = now
    }

    public func resumeNetworkCreation() async throws {
        try await networkCreation.resumeNetworkCreationForColdStart()
    }

    public func resumeMembershipInstallation(identity: NodeIdentity) async throws {
        try await membershipInstallation.resumeMembershipInstallationForColdStart(identity: identity)
    }

    public func startMemberRuntime(
        record: EnrollmentLifecycleRecord,
        identity: NodeIdentity
    ) async throws {
        guard record.phase == .member, record.nodeID == identity.nodeID else {
            throw AppleEnrollmentColdStartResumerError.profileBindingMismatch
        }
        try await runtimeManager.startMemberRuntime(for: record)
    }

    public func finishLeaving(record: EnrollmentLifecycleRecord) async throws {
        guard record.phase == .leaving,
              let network = record.network,
              let nodeID = record.nodeID else {
            throw AppleEnrollmentColdStartResumerError.invalidLeavingRecord
        }

        // Every operation before the lifecycle commit is idempotent. A crash can
        // therefore restart this sequence without recreating or retaining secrets.
        try await runtimeManager.stopMemberRuntimeIfActive()
        try await profileCleaner.removeProfileMaterial()
        try await profileRegistry.removeProfileIfPresent(
            profileID: profileID,
            networkID: network.networkID,
            nodeID: nodeID
        )

        guard let current = try await lifecycleStore.load() else {
            throw AppleEnrollmentColdStartResumerError.lifecycleRecordMissing
        }
        guard current.phase == .leaving,
              current.installationID == record.installationID else {
            throw AppleEnrollmentColdStartResumerError.invalidLeavingRecord
        }
        let completed = try current.transitioning(
            to: .unconfigured,
            at: max(current.updatedAtMilliseconds, Self.milliseconds(now()))
        )
        try await lifecycleStore.save(completed, condition: .revision(current.revision))
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}

extension ActiveProfileRuntimeManager: EnrollmentMemberRuntimeManaging {
    public func startMemberRuntime(for record: EnrollmentLifecycleRecord) async throws {
        if let active = activeProfile() {
            guard active.networkID == record.network?.networkID,
                  active.localNodeID == record.nodeID else {
                throw AppleEnrollmentColdStartResumerError.profileBindingMismatch
            }
            return
        }
        let runtime = try await start()
        guard runtime.profile.networkID == record.network?.networkID,
              runtime.profile.localNodeID == record.nodeID else {
            try? await stop()
            throw AppleEnrollmentColdStartResumerError.profileBindingMismatch
        }
    }

    public func stopMemberRuntimeIfActive() async throws {
        guard activeProfile() != nil else { return }
        try await stop()
    }
}

extension PersistentNetworkProfileRegistry: EnrollmentProfileDeregistering {
    public func removeProfileIfPresent(
        profileID: NetworkProfileID,
        networkID: NetworkID,
        nodeID: NodeID
    ) throws {
        guard let profile = profile(id: profileID) else { return }
        guard profile.networkID == networkID, profile.localNodeID == nodeID else {
            throw AppleEnrollmentColdStartResumerError.profileBindingMismatch
        }
        try removeActive(profileID)
    }
}

public struct AppleEnrollmentProfileCleaner: EnrollmentProfileCleaning {
    public let namespace: ProfileKeychainNamespace
    public let profileRootURL: URL

    public init(namespace: ProfileKeychainNamespace, profileRootURL: URL) {
        self.namespace = namespace
        self.profileRootURL = profileRootURL.standardizedFileURL
    }

    public func removeProfileMaterial() throws {
        try KeychainLANTLSIdentityStore(namespace: namespace).delete()
        try KeychainNodeCredentialStore(namespace: namespace).delete()
        try KeychainNodeIdentityStore(namespace: namespace).delete()
        if FileManager.default.fileExists(atPath: profileRootURL.path) {
            try FileManager.default.removeItem(at: profileRootURL)
        }
    }
}
