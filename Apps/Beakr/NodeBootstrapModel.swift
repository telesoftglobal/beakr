import Foundation
import Observation
import LocalAuthentication
#if os(macOS)
import AppKit
import SystemConfiguration
#endif
import Security
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetControl
import BeakrNetData
import BeakrNetEnrollment
import BeakrNetHost
import BeakrNetSecurity
#if canImport(UIKit)
import UIKit
#endif

enum NodeBootstrapState: Equatable {
    case starting
    case needsConfiguration
    case creatingNetwork
    case joiningNetwork
    case identityReady
    case securing
    case ready
    case failed
}

nonisolated struct AuthorityAdministrationSnapshot {
    var invitationJSON = ""
    var requests: [EnrollmentRequest] = []
    var records: [EnrollmentAuditRecord] = []
    var message: String?
}

nonisolated struct DevelopmentAuthorityConfiguration: Equatable, Sendable {
    let controlPlaneURL: URL
    let networkID: NetworkID
    let authorityPublicKey: Data
    let authorityCertificateDER: Data?
    let credential: NodeCredential

    init(
        controlPlaneURL: URL,
        networkID: NetworkID,
        authorityPublicKey: Data,
        authorityCertificateDER: Data? = nil,
        credential: NodeCredential
    ) {
        self.controlPlaneURL = controlPlaneURL
        self.networkID = networkID
        self.authorityPublicKey = authorityPublicKey
        self.authorityCertificateDER = authorityCertificateDER
        self.credential = credential
    }

    func makeTransport(profileID: NetworkProfileID, requestTimeout: TimeInterval = 15) throws -> AuthorityDiscoveryHTTPTransport {
        try makeAuthorityDiscoveryTransport(
            profileID: profileID, networkID: networkID, publicKey: authorityPublicKey,
            environment: credential.claims.environment, certificate: authorityCertificateDER,
            requestTimeout: requestTimeout
        )
    }

}

protocol NodeIdentityLoading: Sendable {
    func loadNodeID(profileID: NetworkProfileID) throws -> NodeID?
    func loadOrCreateNodeID(profileID: NetworkProfileID) throws -> NodeID
}

private nonisolated let applicationAuthorityEndpointCaches = AuthorityEndpointCacheRegistry()

nonisolated private func makeAuthorityDiscoveryTransport(
    profileID: NetworkProfileID, networkID: NetworkID, publicKey: Data,
    environment: String, certificate: Data?, requestTimeout: TimeInterval = 15
) throws -> AuthorityDiscoveryHTTPTransport {
    guard let certificate,
          let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        throw CertificateEnrollmentNetworkError.invalidTrustAnchor
    }
    let authorityID = CredentialVerifier.authorityID(for: publicKey)
    let cacheURL = support.appendingPathComponent("Beakr/AuthorityEndpoints")
        .appendingPathComponent(profileID.rawValue.uuidString)
        .appendingPathComponent(networkID.rawValue.uuidString)
        .appendingPathComponent(authorityID.rawValue.uuidString + ".json")
    return try AuthorityDiscoveryHTTPTransport(
        registry: applicationAuthorityEndpointCaches, cacheURL: cacheURL, publicKey: publicKey,
        networkID: networkID, environment: environment, certificate: certificate,
        requestTimeout: requestTimeout
    )
}

nonisolated protocol DevelopmentAuthorityConfigurationStoring: Sendable {
    func load(profile: NetworkProfile) throws -> DevelopmentAuthorityConfiguration?
    func save(_ configuration: DevelopmentAuthorityConfiguration, profile: NetworkProfile) throws
    func delete(profile: NetworkProfile) throws
}

protocol NodeTrustBootstrapping: Sendable {
    func enrollAndRecover(
        using configuration: DevelopmentAuthorityConfiguration,
        profile: NetworkProfile,
        revocationSnapshotURL: URL
    ) async throws
}

protocol ApplicationLifecycleMigrating: Sendable {
    func migrate(
        profile: NetworkProfile,
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime
    ) async throws
}

protocol ApplicationEnrollmentRouting: Sendable {
    func hasLifecycleRecord(runtime: ApplicationProfileRuntime) async throws -> Bool
    func lifecycleRecord(profile: NetworkProfile) async throws -> EnrollmentLifecycleRecord?
    func route(runtime: ApplicationProfileRuntime) async throws -> EnrollmentApplicationRoute
    func prepareMembershipInstallation(
        profile: NetworkProfile,
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime,
        kind: EnrollmentTransactionKind,
        pendingEnrollment: PendingEnrollment?
    ) async throws
    func prepareNetworkCreation(profile: NetworkProfile, configuration: DevelopmentAuthorityConfiguration,
                                paths: ProfileRuntimePaths) async throws
    func prepareToLeave(profile: NetworkProfile) async throws
}

extension ApplicationEnrollmentRouting {
    func hasLifecycleRecord(runtime: ApplicationProfileRuntime) async throws -> Bool { false }
    func lifecycleRecord(profile: NetworkProfile) async throws -> EnrollmentLifecycleRecord? { nil }

    func prepareMembershipInstallation(
        profile: NetworkProfile,
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime,
        kind: EnrollmentTransactionKind,
        pendingEnrollment: PendingEnrollment?
    ) async throws {}

    func prepareNetworkCreation(profile: NetworkProfile, configuration: DevelopmentAuthorityConfiguration,
                                paths: ProfileRuntimePaths) async throws {}

    func prepareToLeave(profile: NetworkProfile) async throws {}
}

nonisolated struct ApplicationProfileRuntime: Sendable {
    let profile: NetworkProfile
    let contextID: ContextID?
    let messageStoreID: StoreID?
    let mailboxMetadataURL: URL?
    let paths: ProfileRuntimePaths
    let dataState: PersistentDataState

    init(
        profile: NetworkProfile,
        contextID: ContextID? = nil,
        messageStoreID: StoreID? = nil,
        mailboxMetadataURL: URL? = nil,
        paths: ProfileRuntimePaths,
        dataState: PersistentDataState
    ) {
        self.profile = profile
        self.contextID = contextID
        self.messageStoreID = messageStoreID
        self.mailboxMetadataURL = mailboxMetadataURL
        self.paths = paths
        self.dataState = dataState
    }
}

nonisolated enum ApplicationContextDeletionError: Error, Equatable, Sendable {
    case contextStillAttached(ContextID)
}

nonisolated protocol ApplicationProfileRuntimeManaging: Sendable {
    func activeProfile() async throws -> NetworkProfile?
    func profiles() async throws -> [NetworkProfile]
    func contexts() async throws -> [ContextRecord]
    func context(networkID: NetworkID) async throws -> ContextRecord?
    func incomingMessages(contextID: ContextID) async throws -> [IncomingMessage]
    func mailboxMetadata(contextID: ContextID) async throws -> ContextMailboxMetadata
    func deleteContext(_ contextID: ContextID) async throws
    func activate(_ profileID: NetworkProfileID) async throws
    func add(_ profile: NetworkProfile) async throws
    func addAndActivate(_ profile: NetworkProfile) async throws
    func rename(_ profileID: NetworkProfileID, to displayName: String) async throws
    func runtimePaths(for profile: NetworkProfile) async throws -> ProfileRuntimePaths
    func memberMetadata(for profile: NetworkProfile) async throws -> [UUID: NetworkMemberMetadata]
    func start(profile: NetworkProfile) async throws -> ApplicationProfileRuntime
    func checkpoint(lifecycle: HostLifecycleState) async throws
    func stop() async throws
    func forget(profile: NetworkProfile) async throws
    func forget(profile: NetworkProfile, reason: ContextArchiveReason?) async throws
    func delete(profile: NetworkProfile) async throws
}

extension ApplicationProfileRuntimeManaging {
    func memberMetadata(for profile: NetworkProfile) async throws -> [UUID: NetworkMemberMetadata] { [:] }

    func runtimePaths(for profile: NetworkProfile) async throws -> ProfileRuntimePaths {
        ProfileRuntimePaths(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(profile.id.rawValue.uuidString, isDirectory: true)
        )
    }
    func contexts() async throws -> [ContextRecord] { [] }
    func context(networkID: NetworkID) async throws -> ContextRecord? { nil }
    func incomingMessages(contextID: ContextID) async throws -> [IncomingMessage] { [] }
    func mailboxMetadata(contextID: ContextID) async throws -> ContextMailboxMetadata { .empty }
    func deleteContext(_ contextID: ContextID) async throws {
        throw ContextRegistryError.unknownContext(contextID)
    }

    func forget(profile: NetworkProfile) async throws {
        try await delete(profile: profile)
    }

    func forget(profile: NetworkProfile, reason: ContextArchiveReason?) async throws {
        try await forget(profile: profile)
    }
}

nonisolated protocol ApplicationLANRuntimeManaging: Sendable {
    func sharedStatusRuntime(profileID: UUID) async -> SharedStatusRuntime?
    func start(
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime,
        displayName: String
    ) async throws
    func memberSummaries() async -> [NetworkMemberSummary]
    func refreshMemberSummaries() async -> [NetworkMemberSummary]
    func networkDisplayName() async -> String?
    func authenticatedPeerIDs() async -> Set<UUID>
    func authenticatedPeerIDUpdates() async -> AsyncStream<Set<UUID>>
    func localNetworkAvailable() async -> Bool
    func localNetworkAvailabilityUpdates() async -> AsyncStream<Bool>
    func peerTLSFailureUpdates() async -> AsyncStream<Int>
    func localNetworkPermissionDenied() async -> Bool
    func localNetworkPermissionUpdates() async -> AsyncStream<Bool>
    func setRemembersPreviouslyConnectedDevices(_ enabled: Bool) async
    func forgetRememberedDevice(_ id: UUID) async -> Bool
    func stop() async
    func stop(reason: PeerLifecycleReason) async
}

extension ApplicationLANRuntimeManaging {
    func sharedStatusRuntime(profileID: UUID) async -> SharedStatusRuntime? { nil }
    func stop(reason: PeerLifecycleReason) async { await stop() }
    func memberSummaries() async -> [NetworkMemberSummary] { [] }
    func refreshMemberSummaries() async -> [NetworkMemberSummary] { await memberSummaries() }
    func networkDisplayName() async -> String? { nil }
    func authenticatedPeerIDs() async -> Set<UUID> { [] }
    func authenticatedPeerIDUpdates() async -> AsyncStream<Set<UUID>> {
        let peerIDs = await authenticatedPeerIDs()
        return AsyncStream { continuation in
            continuation.yield(peerIDs)
            continuation.finish()
        }
    }
    func peerTLSFailureUpdates() async -> AsyncStream<Int> { AsyncStream { $0.finish() } }
    func localNetworkPermissionDenied() async -> Bool { false }
    func localNetworkPermissionUpdates() async -> AsyncStream<Bool> {
        AsyncStream { $0.finish() }
    }
    func localNetworkAvailable() async -> Bool { true }
    func localNetworkAvailabilityUpdates() async -> AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(true)
            continuation.finish()
        }
    }
    func setRemembersPreviouslyConnectedDevices(_ enabled: Bool) async {}
    func forgetRememberedDevice(_ id: UUID) async -> Bool { false }
}

struct KeychainNodeIdentityLoader: NodeIdentityLoading {
    func loadNodeID(profileID: NetworkProfileID) throws -> NodeID? {
        let namespace = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profileID)
        return try KeychainNodeIdentityStore(namespace: namespace).load()?.nodeID
    }

    func loadOrCreateNodeID(profileID: NetworkProfileID) throws -> NodeID {
        let namespace = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profileID)
        return try KeychainNodeIdentityStore(namespace: namespace).loadOrCreate().nodeID
    }
}

struct DevelopmentAuthorityConfigurationStore: DevelopmentAuthorityConfigurationStoring, @unchecked Sendable {
    private let defaults = UserDefaults.standard

    func load(profile: NetworkProfile) throws -> DevelopmentAuthorityConfiguration? {
        let prefix = keyPrefix(profile.id)
        guard let urlString = defaults.string(forKey: "\(prefix).controlPlaneURL"),
              let controlPlaneURL = URL(string: urlString),
              let networkIDString = defaults.string(forKey: "\(prefix).networkID"),
              let networkUUID = UUID(uuidString: networkIDString),
              let authorityKeyString = defaults.string(forKey: "\(prefix).authorityPublicKey"),
              let authorityPublicKey = Data(base64Encoded: authorityKeyString),
              let credential = try KeychainNodeCredentialStore(namespace: namespace(profile.id)).load(for: profile)
        else { return nil }
        return DevelopmentAuthorityConfiguration(
            controlPlaneURL: controlPlaneURL,
            networkID: NetworkID(rawValue: networkUUID),
            authorityPublicKey: authorityPublicKey,
            authorityCertificateDER: defaults.string(forKey: "\(prefix).authorityCertificate")
                .flatMap { Data(base64Encoded: $0) },
            credential: credential
        )
    }

    func save(_ configuration: DevelopmentAuthorityConfiguration, profile: NetworkProfile) throws {
        try KeychainNodeCredentialStore(namespace: namespace(profile.id)).save(configuration.credential, for: profile)
        let prefix = keyPrefix(profile.id)
        defaults.set(configuration.controlPlaneURL.absoluteString, forKey: "\(prefix).controlPlaneURL")
        defaults.set(configuration.networkID.rawValue.uuidString, forKey: "\(prefix).networkID")
        defaults.set(configuration.authorityPublicKey.base64EncodedString(), forKey: "\(prefix).authorityPublicKey")
        if let authorityCertificateDER = configuration.authorityCertificateDER {
            defaults.set(authorityCertificateDER.base64EncodedString(), forKey: "\(prefix).authorityCertificate")
        } else {
            defaults.removeObject(forKey: "\(prefix).authorityCertificate")
        }
    }

    func delete(profile: NetworkProfile) throws {
        let namespace = namespace(profile.id)
        try KeychainNodeCredentialStore(namespace: namespace).delete()
        try KeychainLANTLSIdentityStore(namespace: namespace).delete()
        try KeychainNodeIdentityStore(namespace: namespace).delete()
        let prefix = keyPrefix(profile.id)
        for suffix in ["controlPlaneURL", "networkID", "authorityPublicKey", "authorityCertificate"] {
            defaults.removeObject(forKey: "\(prefix).\(suffix)")
        }
    }

    private func namespace(_ profileID: NetworkProfileID) -> ProfileKeychainNamespace {
        ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profileID)
    }

    private func keyPrefix(_ profileID: NetworkProfileID) -> String {
        "net.beakr.app.profile.\(profileID.rawValue.uuidString.lowercased()).development-authority"
    }
}

struct ApplicationJoiningMembershipInstaller: JoiningMembershipInstalling {
    let profile: NetworkProfile
    let paths: ProfileRuntimePaths
    let controlPlaneURL: URL
    let authorityPublicKey: Data
    let authorityCertificateDER: Data?
    let configurationStore: any DevelopmentAuthorityConfigurationStoring

    func installMembership(
        from approval: EnrollmentApproval,
        identity: NodeIdentity
    ) async throws {
        guard identity.nodeID == profile.localNodeID,
              approval.nodeID == profile.localNodeID,
              approval.networkID == profile.networkID,
              approval.authorityID == CredentialVerifier.authorityID(for: authorityPublicKey),
              approval.credential.claims.nodePublicKey == identity.publicKeyRepresentation else {
            throw ApplicationEnrollmentInstallationError.bindingMismatch
        }
        let revoked = try RevocationVerifier.verify(
            approval.revocations,
            trustedAuthorityPublicKey: authorityPublicKey
        )
        try CredentialVerifier.verify(
            approval.credential,
            trustedAuthorityPublicKey: authorityPublicKey,
            networkID: profile.networkID,
            environment: approval.credential.claims.environment,
            revokedCredentialIDs: revoked
        )
        try ProfileMembershipVerifier.verify(
            approval.membership,
            networkID: profile.networkID,
            environment: approval.credential.claims.environment,
            trustedAuthorityPublicKey: authorityPublicKey,
            revokedCredentialIDs: revoked
        )
        guard approval.membership.claims.records.contains(where: {
            $0.credential == approval.credential
                && $0.certificatePublicKey == identity.publicKeyRepresentation
        }) else {
            throw ApplicationEnrollmentInstallationError.membershipMissingNode
        }

        try FileManager.default.createDirectory(
            at: paths.membershipSnapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ProfileMembershipWireCodec.encode(approval.membership).write(
            to: paths.membershipSnapshotURL,
            options: .atomic
        )
        try CredentialFiles.saveRevocationSnapshot(
            approval.revocations,
            to: paths.revocationSnapshotURL
        )
        try configurationStore.save(
            DevelopmentAuthorityConfiguration(
                controlPlaneURL: controlPlaneURL,
                networkID: profile.networkID,
                authorityPublicKey: authorityPublicKey,
                authorityCertificateDER: authorityCertificateDER,
                credential: approval.credential
            ),
            profile: profile
        )
    }
}

enum ApplicationEnrollmentInstallationError: Error, Equatable {
    case bindingMismatch
    case membershipMissingNode
}

struct DevelopmentNodeTrustBootstrapper: NodeTrustBootstrapping {
    func enrollAndRecover(
        using configuration: DevelopmentAuthorityConfiguration,
        profile: NetworkProfile,
        revocationSnapshotURL: URL
    ) async throws {
        let namespace = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profile.id)
        let identity = try KeychainNodeIdentityStore(namespace: namespace).loadOrCreate()
        guard identity.nodeID == configuration.credential.claims.nodeID,
              identity.publicKeyRepresentation == configuration.credential.claims.nodePublicKey else {
            throw NodeBootstrapError.credentialIdentityMismatch
        }

        let transport = try configuration.makeTransport(profileID: profile.id)
        let tlsIdentityStore = KeychainLANTLSIdentityStore(namespace: namespace)
        let storedIdentity = try tlsIdentityStore.load()
        let certificateExpired = storedIdentity.flatMap {
            SecCertificateCopyNotValidAfterDate($0.leafCertificate) as Date?
        }.map { $0 <= Date() } ?? false
        if storedIdentity == nil || certificateExpired {
            let client = try CertificateEnrollmentNetworkClient(
                transport: transport,
                identity: identity,
                credential: configuration.credential,
                environment: configuration.credential.claims.environment,
                requestedValidity: CertificateEnrollmentValidator.maximumCertificateValidity
            )
            let exchange = try await client.renewCertificate()
            try CertificateEnrollmentResponseVerifier.verify(
                exchange.response,
                for: exchange.request,
                trustedAuthorityPublicKey: configuration.authorityPublicKey
            )
            try tlsIdentityStore.install(
                response: exchange.response,
                nodeIdentity: identity
            )
        }

        try await Self.recoverRevocations(
            trustedAuthorityPublicKey: configuration.authorityPublicKey,
            revocationSnapshotURL: revocationSnapshotURL,
            requester: RevocationSnapshotNetworkClient(
                transport: try configuration.makeTransport(profileID: profile.id, requestTimeout: 5)
            )
        )
    }

    /// A valid signature alone does not make cached evidence fresh enough for
    /// admission. Preserve the verified generation while fetching its successor.
    static func recoverRevocations(
        trustedAuthorityPublicKey: Data,
        revocationSnapshotURL: URL,
        requester: any RevocationSnapshotRequesting,
        now: @escaping @Sendable () -> Date = Date.init
    ) async throws {
        let distributor = RevocationSnapshotDistributor(
            trustedAuthorityPublicKey: trustedAuthorityPublicKey,
            now: now
        )
        let controller = RevocationRefreshController(
            distributor: distributor,
            requester: requester,
            store: FileRevocationSnapshotStore(fileURL: revocationSnapshotURL),
            policy: try RevocationRefreshPolicy(),
            now: now
        )
        _ = try await controller.restorePersistedSnapshot()
        if let cached = await distributor.latestSnapshot() {
            do {
                _ = try LANHandshakeAuthenticator.validatedRevokedCredentialIDs(
                    in: cached, trustedAuthorityPublicKey: trustedAuthorityPublicKey, now: now()
                )
                return
            } catch LANHandshakeError.staleRevocationSnapshot {
                // Keep the cache as rollback protection, but require fresh
                // signed evidence before starting routes.
            }
        }
        _ = await controller.refreshNow(trigger: .startup)
        guard let snapshot = await distributor.latestSnapshot() else {
            throw NodeBootstrapError.noTrustedRevocationState
        }
        _ = try LANHandshakeAuthenticator.validatedRevokedCredentialIDs(
            in: snapshot, trustedAuthorityPublicKey: trustedAuthorityPublicKey, now: now()
        )
    }

}

nonisolated struct ApplicationLifecycleMigrator: ApplicationLifecycleMigrating {
    func migrate(
        profile: NetworkProfile,
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime
    ) async throws {
        let lifecycleStore = try PersistentEnrollmentLifecycleStore.open(
            fileURL: runtime.paths.rootURL.appendingPathComponent(
                "enrollment/lifecycle.json"
            )
        )
        guard await lifecycleStore.load() == nil else { return }
        let namespace = ProfileKeychainNamespace(
            baseService: "net.beakr.app",
            profileID: profile.id
        )
        guard let identity = try KeychainNodeIdentityStore(namespace: namespace).load() else {
            throw NodeBootstrapError.profileIdentityMismatch
        }
        let membership = try ProfileMembershipWireCodec.decode(
            Data(contentsOf: runtime.paths.membershipSnapshotURL)
        )
        let revocations = try CredentialFiles.loadRevocationSnapshot(
            from: runtime.paths.revocationSnapshotURL
        )
        let migrator = try LegacyEnrollmentLifecycleMigrator(
            lifecycleStore: lifecycleStore
        )
        _ = try await migrator.migrate(legacy: LegacyEnrollmentMigrationInput(
            profile: profile,
            environment: configuration.credential.claims.environment,
            authorityPublicKey: configuration.authorityPublicKey,
            controlPlaneURL: configuration.controlPlaneURL,
            identity: identity,
            credential: configuration.credential,
            membership: membership,
            revocations: revocations
        ))
    }
}

nonisolated struct NoopApplicationLifecycleMigrator: ApplicationLifecycleMigrating {
    func migrate(
        profile: NetworkProfile,
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime
    ) async throws {}
}

nonisolated struct ApplicationEnrollmentRouter: ApplicationEnrollmentRouting {
    let profileRuntimeManager: any ApplicationProfileRuntimeManaging
    let configurationStore: any DevelopmentAuthorityConfigurationStoring

    func hasLifecycleRecord(runtime: ApplicationProfileRuntime) async throws -> Bool {
        let store = try PersistentEnrollmentLifecycleStore.open(
            fileURL: runtime.paths.rootURL.appendingPathComponent("enrollment/lifecycle.json")
        )
        return await store.load() != nil
    }

    func lifecycleRecord(profile: NetworkProfile) async throws -> EnrollmentLifecycleRecord? {
        let paths = try await profileRuntimeManager.runtimePaths(for: profile)
        let store = try PersistentEnrollmentLifecycleStore.open(
            fileURL: paths.rootURL.appendingPathComponent("enrollment/lifecycle.json")
        )
        return await store.load()
    }

    func route(runtime: ApplicationProfileRuntime) async throws -> EnrollmentApplicationRoute {
        let store = try PersistentEnrollmentLifecycleStore.open(
            fileURL: runtime.paths.rootURL.appendingPathComponent("enrollment/lifecycle.json")
        )
        let namespace = ProfileKeychainNamespace(
            baseService: "net.beakr.app",
            profileID: runtime.profile.id
        )
        let inspector = AppleEnrollmentRuntimeInspector(
            namespace: namespace,
            revokedCredentialIDs: {
                guard let record = await store.load(),
                      let network = record.network else { return [] }
                let snapshot = try CredentialFiles.loadRevocationSnapshot(
                    from: runtime.paths.revocationSnapshotURL
                )
                return try RevocationVerifier.verify(
                    snapshot,
                    trustedAuthorityPublicKey: network.authorityPublicKey
                )
            },
            trustStateInspector: { record in
                guard let network = record.network else { return .missing }
                guard FileManager.default.fileExists(
                    atPath: runtime.paths.membershipSnapshotURL.path
                ), FileManager.default.fileExists(
                    atPath: runtime.paths.revocationSnapshotURL.path
                ) else { return .missing }
                do {
                    let revocations = try CredentialFiles.loadRevocationSnapshot(
                        from: runtime.paths.revocationSnapshotURL
                    )
                    let revoked = try RevocationVerifier.verify(
                        revocations,
                        trustedAuthorityPublicKey: network.authorityPublicKey
                    )
                    let membership = try ProfileMembershipWireCodec.decode(
                        Data(contentsOf: runtime.paths.membershipSnapshotURL)
                    )
                    try ProfileMembershipVerifier.verify(
                        membership,
                        networkID: network.networkID,
                        environment: network.environment,
                        trustedAuthorityPublicKey: network.authorityPublicKey,
                        revokedCredentialIDs: revoked
                    )
                    let nowMilliseconds = Int64(
                        (Date().timeIntervalSince1970 * 1_000).rounded(.down)
                    )
                    guard revocations.claims.generatedAtMilliseconds >= 0 else { return .invalid }
                    guard nowMilliseconds - revocations.claims.generatedAtMilliseconds
                            <= Int64((24 * 60 * 60 + 60) * 1_000) else { return .stale }
                    guard
                          membership.claims.generation >= network.membershipGeneration,
                          UInt64(revocations.claims.generatedAtMilliseconds)
                            >= network.revocationGeneration else { return .stale }
                    return .valid
                } catch {
                    return .invalid
                }
            }
        )
        let restoration = EnrollmentColdStartRestorationCoordinator(
            lifecycleStore: store,
            identityRestorer: AppleEnrollmentIdentityRestorer(namespace: namespace),
            runtimeInspector: inspector,
            resumer: ApplicationEnrollmentColdStartResumer(
                lifecycleStore: store,
                runtime: runtime,
                namespace: namespace,
                profileRuntimeManager: profileRuntimeManager,
                configurationStore: configurationStore
            )
        )
        return try await ApplicationEnrollmentBootstrapService(
            restoration: restoration
        ).start()
    }

    func prepareToLeave(profile: NetworkProfile) async throws {
        let paths = try await profileRuntimeManager.runtimePaths(for: profile)
        let store = try PersistentEnrollmentLifecycleStore.open(
            fileURL: paths.rootURL.appendingPathComponent("enrollment/lifecycle.json")
        )
        guard let record = await store.load(),
              record.phase == .member,
              record.nodeID == profile.localNodeID,
              record.network?.networkID == profile.networkID else {
            throw ApplicationEnrollmentColdStartError.unsupportedTransitionalResume
        }
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let leaving = try record.transitioning(
            to: .leaving,
            at: max(record.updatedAtMilliseconds, now),
            nodeID: record.nodeID,
            network: record.network,
            authority: record.authority
        )
        try await store.save(leaving, condition: .revision(record.revision))
    }

    func prepareMembershipInstallation(
        profile: NetworkProfile,
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime,
        kind: EnrollmentTransactionKind,
        pendingEnrollment: PendingEnrollment?
    ) async throws {
        try await prepareInstallation(profile: profile, configuration: configuration,
                                      paths: runtime.paths, kind: kind, pendingEnrollment: pendingEnrollment)
    }

    func prepareNetworkCreation(profile: NetworkProfile, configuration: DevelopmentAuthorityConfiguration,
                                paths: ProfileRuntimePaths) async throws {
        try await prepareInstallation(profile: profile, configuration: configuration,
                                      paths: paths, kind: .createNetwork, pendingEnrollment: nil)
    }

    private func prepareInstallation(profile: NetworkProfile, configuration: DevelopmentAuthorityConfiguration,
                                     paths: ProfileRuntimePaths, kind: EnrollmentTransactionKind,
                                     pendingEnrollment: PendingEnrollment?) async throws {
        let store = try PersistentEnrollmentLifecycleStore.open(
            fileURL: paths.rootURL.appendingPathComponent("enrollment/lifecycle.json")
        )
        if let existing = await store.load() {
            guard existing.installationID == profile.id.rawValue,
                  existing.phase == .installingMembership,
                  existing.transaction?.kind == kind else {
                throw ApplicationEnrollmentColdStartError.unsupportedTransitionalResume
            }
            return
        }
        let network = NetworkBinding(
            networkID: profile.networkID,
            displayName: profile.displayName,
            environment: configuration.credential.claims.environment,
            authorityID: CredentialVerifier.authorityID(for: configuration.authorityPublicKey),
            authorityPublicKey: configuration.authorityPublicKey,
            activeCredentialID: configuration.credential.claims.credentialID,
            controlPlaneURL: configuration.controlPlaneURL
        )
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let record = try EnrollmentLifecycleRecord(
            installationID: profile.id.rawValue,
            phase: .installingMembership,
            nodeID: profile.localNodeID,
            network: network,
            pendingEnrollment: pendingEnrollment,
            transaction: EnrollmentTransaction(id: UUID(), kind: kind),
            createdAtMilliseconds: min(
                Int64((profile.createdAt.timeIntervalSince1970 * 1_000).rounded(.down)),
                now
            ),
            updatedAtMilliseconds: now
        )
        try await store.save(record, condition: .create)
    }
}

enum ApplicationEnrollmentColdStartError: Error {
    case unsupportedTransitionalResume
}

struct ApplicationEnrollmentColdStartResumer: EnrollmentColdStartResuming {
    let lifecycleStore: any EnrollmentLifecycleStore
    let runtime: ApplicationProfileRuntime
    let namespace: ProfileKeychainNamespace
    let profileRuntimeManager: any ApplicationProfileRuntimeManaging
    let configurationStore: any DevelopmentAuthorityConfigurationStoring

    func resumeNetworkCreation() async throws {
        try await finishMembershipInstallation(expectedKind: .createNetwork, identity: nil)
    }

    func resumeMembershipInstallation(identity: NodeIdentity) async throws {
        guard let record = try await lifecycleStore.load(),
              record.phase == .installingMembership,
              record.transaction?.kind == .joinNetwork,
              let transactionID = record.transaction?.id else {
            throw ApplicationEnrollmentColdStartError.unsupportedTransitionalResume
        }
        let enrollmentStore = try PersistentJoiningEnrollmentStore.open(
            fileURL: runtime.paths.rootURL.appendingPathComponent("enrollment/joining.json")
        )
        if let approval = await enrollmentStore.stagedApproval(transactionID: transactionID),
           let request = await enrollmentStore.request(id: approval.requestID),
           let controlPlaneURL = request.invitation.controlPlaneURL {
            let coordinator = JoiningEnrollmentCoordinator(
                lifecycleStore: lifecycleStore,
                enrollmentStore: enrollmentStore,
                membershipInstaller: ApplicationJoiningMembershipInstaller(
                    profile: runtime.profile,
                    paths: runtime.paths,
                    controlPlaneURL: controlPlaneURL,
                    authorityPublicKey: request.invitation.authorityPublicKey,
                    authorityCertificateDER: request.invitation.authorityCertificateDER,
                    configurationStore: configurationStore
                ),
                allowedClockSkew: 60,
                makeNonce: { Data(repeating: 1, count: 32) }
            )
            _ = try await coordinator.resumeMembershipInstallation(identity: identity)
            return
        }
        // Compatibility for checkpoints created by the credential-only join
        // bridge before Release 1 staged signed approvals were introduced.
        try await finishMembershipInstallation(expectedKind: .joinNetwork, identity: identity)
    }

    func finishLeaving(record: EnrollmentLifecycleRecord) async throws {
        guard record.phase == .leaving,
              record.nodeID == runtime.profile.localNodeID,
              record.network?.networkID == runtime.profile.networkID else {
            throw ApplicationEnrollmentColdStartError.unsupportedTransitionalResume
        }
        try configurationStore.delete(profile: runtime.profile)
        if try await profileRuntimeManager.profiles().contains(where: { $0.id == runtime.profile.id }) {
            try await profileRuntimeManager.delete(profile: runtime.profile)
        }
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let completed = try record.transitioning(
            to: .unconfigured,
            at: max(record.updatedAtMilliseconds, now)
        )
        try await lifecycleStore.save(completed, condition: .revision(record.revision))
    }

    func startMemberRuntime(record: EnrollmentLifecycleRecord, identity: NodeIdentity) async throws {}

    private func finishMembershipInstallation(
        expectedKind: EnrollmentTransactionKind,
        identity suppliedIdentity: NodeIdentity?
    ) async throws {
        guard let record = try await lifecycleStore.load(),
              record.phase == .installingMembership,
              record.transaction?.kind == expectedKind,
              let network = record.network,
              let nodeID = record.nodeID else {
            throw ApplicationEnrollmentColdStartError.unsupportedTransitionalResume
        }
        let identity = try suppliedIdentity
            ?? KeychainNodeIdentityStore(namespace: namespace).load()
        guard let identity, identity.nodeID == nodeID,
              let credential = try KeychainNodeCredentialStore(namespace: namespace)
                .load(for: runtime.profile) else {
            throw ApplicationEnrollmentColdStartError.unsupportedTransitionalResume
        }
        let revocations = try CredentialFiles.loadRevocationSnapshot(
            from: runtime.paths.revocationSnapshotURL
        )
        let revoked = try RevocationVerifier.verify(
            revocations,
            trustedAuthorityPublicKey: network.authorityPublicKey
        )
        let now = Date()
        let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        guard revocations.claims.generatedAtMilliseconds >= 0,
              nowMilliseconds - revocations.claims.generatedAtMilliseconds
                <= Int64((24 * 60 * 60 + 60) * 1_000) else {
            throw ApplicationEnrollmentColdStartError.unsupportedTransitionalResume
        }
        let membership = try ProfileMembershipWireCodec.decode(
            Data(contentsOf: runtime.paths.membershipSnapshotURL)
        )
        try ProfileMembershipVerifier.verify(
            membership,
            networkID: network.networkID,
            environment: network.environment,
            trustedAuthorityPublicKey: network.authorityPublicKey,
            revokedCredentialIDs: revoked
        )
        guard membership.claims.records.contains(where: {
            $0.credential == credential
                && $0.certificatePublicKey == identity.publicKeyRepresentation
        }) else {
            throw ApplicationEnrollmentColdStartError.unsupportedTransitionalResume
        }
        let completedNetwork = NetworkBinding(
            networkID: network.networkID,
            displayName: membership.claims.networkDisplayName,
            environment: network.environment,
            authorityID: network.authorityID,
            authorityPublicKey: network.authorityPublicKey,
            activeCredentialID: credential.claims.credentialID,
            membershipGeneration: membership.claims.generation,
            revocationGeneration: UInt64(revocations.claims.generatedAtMilliseconds),
            controlPlaneURL: network.controlPlaneURL
        )
        let completionMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let completed = try record.transitioning(
            to: .member,
            at: max(record.updatedAtMilliseconds, completionMilliseconds),
            nodeID: nodeID,
            network: completedNetwork,
            authority: record.authority
        )
        try await lifecycleStore.save(completed, condition: .revision(record.revision))
    }
}

nonisolated struct MemberApplicationEnrollmentRouter: ApplicationEnrollmentRouting {
    func route(runtime: ApplicationProfileRuntime) async throws -> EnrollmentApplicationRoute { .member }
}

actor ApplicationProfileRuntimeManager: ApplicationProfileRuntimeManaging {
    private var manager: ActiveProfileRuntimeManager?
    private var contextRegistry: PersistentContextRegistry?
    private let applicationRootOverride: URL?

    init(applicationRoot: URL? = nil) {
        applicationRootOverride = applicationRoot
    }

    func activeProfile() async throws -> NetworkProfile? {
        try await openRegistry().activeProfile()
    }

    func profiles() async throws -> [NetworkProfile] {
        try await openRegistry().profiles()
    }

    func contexts() async throws -> [ContextRecord] {
        let registry = try openContextRegistry(applicationRoot: applicationRoot())
        return await registry.contexts()
    }

    func context(networkID: NetworkID) async throws -> ContextRecord? {
        let registry = try openContextRegistry(applicationRoot: applicationRoot())
        return await registry.context(networkID: networkID)
    }

    func incomingMessages(contextID: ContextID) async throws -> [IncomingMessage] {
        let registry = try openContextRegistry(applicationRoot: applicationRoot())
        guard let context = await registry.context(id: contextID) else {
            throw ContextRegistryError.unknownContext(contextID)
        }
        let results = try PersistentDataState.readRecordedResults(
            fileURL: await registry.messageStoreURL(for: context)
        )
        return results.compactMap { result in
            guard let message = result.response,
                  message.operation.namespace == "beakr",
                  message.operation.name == "text-message",
                  let body = String(data: message.body, encoding: .utf8) else { return nil }
            let provenance = result.applicationMetadata.flatMap {
                try? JSONDecoder().decode(MessageProvenance.self, from: $0)
            }
            return IncomingMessage(
                id: message.correlationID.rawValue,
                source: provenance?.sourceDeviceID,
                body: body,
                receivedAt: result.completedAt,
                isRestored: true,
                provenance: provenance
            )
        }.sorted { $0.receivedAt > $1.receivedAt }
    }

    func memberMetadata(for profile: NetworkProfile) async throws -> [UUID: NetworkMemberMetadata] {
        let registry = try openContextRegistry(applicationRoot: applicationRoot())
        guard let context = await registry.context(networkID: profile.networkID) else { return [:] }
        let url = await registry.mailboxMetadataURL(for: context)
            .deletingLastPathComponent().appendingPathComponent("network-members.json")
        return try NetworkMemberMetadataStore.load(from: url)
    }

    func mailboxMetadata(contextID: ContextID) async throws -> ContextMailboxMetadata {
        let registry = try openContextRegistry(applicationRoot: applicationRoot())
        guard let context = await registry.context(id: contextID) else {
            throw ContextRegistryError.unknownContext(contextID)
        }
        return try ContextMailboxMetadataStore.load(from: await registry.mailboxMetadataURL(for: context))
    }

    func deleteContext(_ contextID: ContextID) async throws {
        let registry = try openContextRegistry(applicationRoot: applicationRoot())
        guard let context = await registry.context(id: contextID) else {
            throw ContextRegistryError.unknownContext(contextID)
        }
        guard context.attachedProfileIDs.isEmpty else {
            throw ApplicationContextDeletionError.contextStillAttached(contextID)
        }

        let fileManager = FileManager.default
        let contextRoot = await registry.storageRoot(for: contextID)
        let stagedRoot = contextRoot.deletingLastPathComponent().appendingPathComponent(
            ".deleting-\(contextID.rawValue.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let hasStoredData = fileManager.fileExists(atPath: contextRoot.path)
        if hasStoredData {
            try fileManager.moveItem(at: contextRoot, to: stagedRoot)
        }
        do {
            try await registry.remove(contextID)
        } catch {
            if hasStoredData {
                try? fileManager.moveItem(at: stagedRoot, to: contextRoot)
            }
            throw error
        }
        if hasStoredData {
            try fileManager.removeItem(at: stagedRoot)
        }
    }

    func activate(_ profileID: NetworkProfileID) async throws {
        guard manager == nil else {
            throw ActiveProfileRuntimeError.runtimeAlreadyActive(profileID)
        }
        try await openRegistry().activate(profileID)
    }

    func add(_ profile: NetworkProfile) async throws {
        // Register an inactive network without touching the running profile.
        try await openRegistry().add(profile, activate: false)
    }

    func addAndActivate(_ profile: NetworkProfile) async throws {
        guard manager == nil else {
            throw ActiveProfileRuntimeError.runtimeAlreadyActive(profile.id)
        }
        try await openRegistry().add(profile, activate: true)
    }

    func rename(_ profileID: NetworkProfileID, to displayName: String) async throws {
        try await openRegistry().rename(profileID, to: displayName)
    }

    func runtimePaths(for profile: NetworkProfile) async throws -> ProfileRuntimePaths {
        let root = try await openRegistry().storageRoot(for: profile.id)
        return ProfileRuntimePaths(rootURL: root)
    }

    func start(profile proposedProfile: NetworkProfile) async throws -> ApplicationProfileRuntime {
        if let manager, let profile = await manager.activeProfile() {
            guard profile.id == proposedProfile.id,
                  profile.networkID == proposedProfile.networkID,
                  profile.localNodeID == proposedProfile.localNodeID else {
                throw NodeBootstrapError.activeProfileMismatch
            }
            throw ActiveProfileRuntimeError.runtimeAlreadyActive(profile.id)
        }

        let registry = try openRegistry()
        let profile: NetworkProfile
        if let active = await registry.activeProfile() {
            guard active.id == proposedProfile.id,
                  active.networkID == proposedProfile.networkID,
                  active.localNodeID == proposedProfile.localNodeID else {
                throw NodeBootstrapError.activeProfileMismatch
            }
            profile = active
        } else {
            profile = proposedProfile
            try await registry.add(profile, activate: true)
        }

        let applicationRoot = try applicationRoot()
        let contextRegistry = try openContextRegistry(applicationRoot: applicationRoot)
        let context = try await contextRegistry.resolve(for: profile)
        let messageStoreURL = await contextRegistry.messageStoreURL(for: context)
        let mailboxMetadataURL = await contextRegistry.mailboxMetadataURL(for: context)
        let profileRoot = try await registry.storageRoot(for: profile.id)
        let legacyDataStateURL = ProfileRuntimePaths(rootURL: profileRoot).dataStateURL
        let migratedLegacyData = try Self.migrateLegacyDataStateIfNeeded(
            from: legacyDataStateURL,
            to: messageStoreURL
        )

        let runtimeManager = ActiveProfileRuntimeManager(
            registry: registry,
            policy: ProfileRuntimePolicy(relayQueue: RelayQueuePolicy(
                maximumMessagesPerNode: 256,
                maximumTotalMessages: 2_048,
                reservedControlMessagesPerNode: 16,
                reservedControlMessagesTotal: 128,
                messageTimeToLive: 24 * 60 * 60
            )),
            dataStateURL: messageStoreURL
        )
        let runtime = try await runtimeManager.start()
        if migratedLegacyData {
            try? FileManager.default.removeItem(at: legacyDataStateURL)
        }
        try await runtime.diagnosticJournal.record(.init(
            timestamp: Date(),
            subsystem: .lifecycle,
            reason: .started
        ))
        manager = runtimeManager
        return ApplicationProfileRuntime(
            profile: profile,
            contextID: context.id,
            messageStoreID: context.messageStoreID,
            mailboxMetadataURL: mailboxMetadataURL,
            paths: runtime.paths,
            dataState: runtime.dataState
        )
    }

    private func openRegistry() throws -> PersistentNetworkProfileRegistry {
        let applicationRoot = try applicationRoot()
        return try PersistentNetworkProfileRegistry.open(
            fileURL: applicationRoot.appendingPathComponent("profiles.json"),
            profilesRootURL: applicationRoot.appendingPathComponent("Profiles", isDirectory: true),
            maximumProfiles: 8
        )
    }

    private func applicationRoot() throws -> URL {
        if let applicationRootOverride { return applicationRootOverride }
        return try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Beakr", isDirectory: true)
    }

    private func openContextRegistry(applicationRoot: URL) throws -> PersistentContextRegistry {
        if let contextRegistry { return contextRegistry }
        let registry = try PersistentContextRegistry.open(
            fileURL: applicationRoot.appendingPathComponent("contexts.json"),
            contextsRootURL: applicationRoot.appendingPathComponent("Contexts", isDirectory: true)
        )
        contextRegistry = registry
        return registry
    }

    func stop() async throws {
        guard let manager else { throw ActiveProfileRuntimeError.runtimeNotActive }
        try await manager.stop()
        self.manager = nil
    }

    func delete(profile: NetworkProfile) async throws {
        let registry = try openRegistry()
        let storageRoot = try await registry.storageRoot(for: profile.id)
        let contexts = try openContextRegistry(applicationRoot: applicationRoot())
        let context = await contexts.context(profileID: profile.id)
        if let manager, await manager.activeProfile()?.id == profile.id {
            try await manager.stop()
            self.manager = nil
        }
        try await registry.removeActive(profile.id)
        let profileRoot = storageRoot.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: profileRoot.path) {
            try FileManager.default.removeItem(at: profileRoot)
        }
        if let context {
            let contextRoot = await contexts.storageRoot(for: context.id)
            try await contexts.remove(context.id)
            if FileManager.default.fileExists(atPath: contextRoot.path) {
                try FileManager.default.removeItem(at: contextRoot)
            }
        }
    }

    func forget(profile: NetworkProfile) async throws {
        try await forget(profile: profile, reason: nil)
    }

    func forget(profile: NetworkProfile, reason: ContextArchiveReason?) async throws {
        let registry = try openRegistry()
        let storageRoot = try await registry.storageRoot(for: profile.id)
        if let manager, await manager.activeProfile()?.id == profile.id {
            try await manager.stop()
            self.manager = nil
        }
        try await registry.removeActive(profile.id)
        let contexts = try openContextRegistry(applicationRoot: applicationRoot())
        try await contexts.detach(profile.id, reason: reason)
        let profileRoot = storageRoot.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: profileRoot.path) {
            try FileManager.default.removeItem(at: profileRoot)
        }
    }

    func checkpoint(lifecycle: HostLifecycleState) async throws {
        guard let manager else { throw ActiveProfileRuntimeError.runtimeNotActive }
        try await manager.checkpoint(lifecycle: lifecycle)
    }

    private static func migrateLegacyDataStateIfNeeded(from source: URL, to destination: URL) throws -> Bool {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path),
              fileManager.fileExists(atPath: source.path) else { return false }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".messages-migration-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        try fileManager.moveItem(at: temporary, to: destination)
        return true
    }
}

enum NodeBootstrapError: Error {
    case invalidURL
    case invalidNetworkID
    case invalidAuthorityKey
    case invalidCredential
    case credentialIdentityMismatch
    case profileIdentityMismatch
    case activeProfileMismatch
    case noTrustedRevocationState
    case invitationAuthorityMismatch
    case keychain(OSStatus)
}

enum ForgottenNetworkDataDisposition: Equatable, Sendable {
    case keepLocalData
    case deleteLocalData
}

struct OwnedNetworkSummary: Identifiable, Equatable, Sendable {
    let id: NetworkProfileID
    let displayName: String
    let isActive: Bool
}

struct NetworkCapabilities: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let manageNetwork = NetworkCapabilities(rawValue: 1 << 0)
    static let hostAuthority = NetworkCapabilities(rawValue: 1 << 1)
    static let exchangeMessages = NetworkCapabilities(rawValue: 1 << 2)
}

struct NetworkAuthorization: Equatable, Sendable {
    let networkID: NetworkID
    let nodeID: NodeID
    let authorityID: AuthorityID
    let credentialID: UUID
    let capabilities: NetworkCapabilities
}

enum NetworkCredentialStatus: String, Equatable, Sendable {
    case preparing, waitingForAuthority, authorityStopped, authorityFailed, expired, revoked, invalid

    var title: LocalizedStringResource {
        switch self {
        case .preparing: "Preparing Messaging…"
        case .waitingForAuthority: "Waiting for Network Authority"
        case .authorityStopped: "Network Authority Stopped"
        case .authorityFailed: "Authority Couldn’t Start"
        case .expired: "Device Access Expired"
        case .revoked: "Access Removed"
        case .invalid: "Network Credentials Need Attention"
        }
    }

    var retriesAutomatically: Bool {
        self == .waitingForAuthority || self == .authorityFailed
    }
}

struct NetworkCredentialDetails: Equatable, Sendable {
    var accessExpiresAt: Date?
    var certificateExpiresAt: Date?
    var revocationsUpdatedAt: Date?
    var revocationsValidUntil: Date?
}

enum MessagingHealth: Equatable, Sendable {
    case off, healthy, waiting, degraded, blocked
}

struct NetworkSummary: Identifiable, Equatable, Sendable {
    let id: NetworkProfileID
    let networkID: NetworkID
    let displayName: String
    let isActive: Bool
    let capabilities: NetworkCapabilities
    var messagingHealth: MessagingHealth = .off
    var messagingHealthMessage: String = "Messaging: Not selected for this network"
    var credentialStatus: NetworkCredentialStatus? = nil

    var canManageNetwork: Bool { capabilities.contains(.manageNetwork) }
    var isHostingAuthority: Bool { capabilities.contains(.hostAuthority) }
    var canExchangeMessages: Bool { capabilities.contains(.exchangeMessages) }
}

enum NetworkSessionMembershipState: Equatable, Sendable {
    case unknown
    case identityReady
    case joining
    case member
    case leaving
    case recoveryRequired
}

enum NetworkSessionRuntimeState: Equatable, Sendable {
    case closed
    case opening
    case ready
    case stopping
    case failed
}

enum NetworkSessionAuthorityRole: Equatable, Sendable {
    case none
    case manager
    case host
}

/// Stable application-lifetime representation of one locally configured network.
/// Durable identity remains in `NetworkProfile`; this object coordinates the
/// mutable lifecycle state consumed by the application and its views.
@MainActor
@Observable
final class NetworkSession: Identifiable {
    let id: NetworkProfileID
    private(set) var profile: NetworkProfile
    private(set) var membershipState: NetworkSessionMembershipState
    private(set) var runtimeState: NetworkSessionRuntimeState
    private(set) var connectivity: ActiveNetworkConnectivity
    private(set) var authorityRole: NetworkSessionAuthorityRole
    private(set) var capabilities: NetworkCapabilities
    private(set) var lastError: String?
    private(set) var isSelected: Bool
    private(set) var isReconciled: Bool

    init(
        profile: NetworkProfile,
        membershipState: NetworkSessionMembershipState = .unknown,
        runtimeState: NetworkSessionRuntimeState = .closed,
        connectivity: ActiveNetworkConnectivity = .inactive,
        authorityRole: NetworkSessionAuthorityRole = .none,
        capabilities: NetworkCapabilities = [],
        lastError: String? = nil,
        isSelected: Bool = false,
        isReconciled: Bool = false
    ) {
        id = profile.id
        self.profile = profile
        self.membershipState = membershipState
        self.runtimeState = runtimeState
        self.connectivity = connectivity
        self.authorityRole = authorityRole
        self.capabilities = capabilities
        self.lastError = lastError
        self.isSelected = isSelected
        self.isReconciled = isReconciled
    }

    var summary: NetworkSummary {
        NetworkSummary(
            id: profile.id,
            networkID: profile.networkID,
            displayName: NodeBootstrapModel.friendlyNetworkName(profile.displayName),
            isActive: isSelected,
            capabilities: capabilities
        )
    }

    var statusTitle: String {
        guard isSelected else { return "Inactive" }
        switch connectivity {
        case .inactive:
            return "Inactive"
        case .reconnecting:
            return "Active — Reconnecting"
        case .discoveringPeers:
            return "Active — Discovering devices"
        case .readyNoPeers:
            return "Active — Operational, no other devices online"
        case .connected(let peerCount):
            return peerCount == 1
                ? "Active — Connected to 1 device"
                : "Active — Connected to \(peerCount) devices"
        case .localNetworkDenied:
            return "Local Network Permission Required"
        case .failed:
            return "Active — Connection error"
        }
    }

    /// A persisted profile is part of the application inventory immediately.
    /// Reconciliation may change its status, but must never make it appear later
    /// as though it were newly discovered.
    var isDisplayable: Bool { membershipState != .leaving }

    func recordLastError(_ message: String) {
        lastError = message
    }

    func clearLastError() {
        lastError = nil
    }

    func reconcile(
        profile: NetworkProfile,
        membershipState: NetworkSessionMembershipState,
        runtimeState: NetworkSessionRuntimeState,
        connectivity: ActiveNetworkConnectivity,
        authorityRole: NetworkSessionAuthorityRole,
        capabilities: NetworkCapabilities,
        lastError: String?,
        isSelected: Bool,
        isReconciled: Bool
    ) {
        self.profile = profile
        self.membershipState = membershipState
        self.runtimeState = runtimeState
        self.connectivity = connectivity
        self.authorityRole = authorityRole
        self.capabilities = capabilities
        self.lastError = lastError
        self.isSelected = isSelected
        self.isReconciled = isReconciled
    }

    func applyApplicationState(
        _ state: NodeBootstrapState,
        connectivity: ActiveNetworkConnectivity,
        statusMessage: String
    ) {
        guard isSelected else { return }
        self.connectivity = connectivity
        switch state {
        case .starting, .creatingNetwork, .joiningNetwork, .securing:
            runtimeState = .opening
        case .ready, .identityReady:
            runtimeState = .ready
        case .needsConfiguration:
            runtimeState = .closed
        case .failed:
            runtimeState = .failed
        }
        if state == .joiningNetwork {
            membershipState = .joining
        } else if state == .failed && membershipState == .unknown {
            membershipState = .recoveryRequired
            isReconciled = true
        }
        lastError = state == .failed || connectivity == .failed ? statusMessage : nil
    }

    func setConnectivity(_ connectivity: ActiveNetworkConnectivity) {
        self.connectivity = connectivity
    }
}

struct ContextSummary: Identifiable, Equatable, Sendable {
    let id: ContextID
    let displayName: String
    let knownNetworkIDs: [NetworkID]
    let attachedProfileIDs: [NetworkProfileID]
    let messageStoreID: StoreID
    let updatedAt: Date

    var archiveReason: ContextArchiveReason? = nil

    var isArchived: Bool { attachedProfileIDs.isEmpty }
}

enum NetworkMemberStatus: Equatable {
    case online
    case offline
    case revoked
    case unknown

    var title: LocalizedStringResource {
        switch self {
        case .online: "Online"
        case .offline: "Offline"
        case .revoked: "Revoked"
        case .unknown: "UnObserved"
        }
    }
}

struct NetworkMemberSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let isPlaceholderName: Bool
    let lastSeen: Date?
    let deviceIPAddress: String?
    let connectionIPAddress: String?
    let credentialID: UUID?

    nonisolated init(
        id: UUID,
        displayName: String,
        isPlaceholderName: Bool = false,
        lastSeen: Date? = nil,
        deviceIPAddress: String? = nil,
        connectionIPAddress: String? = nil,
        credentialID: UUID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isPlaceholderName = isPlaceholderName
        self.lastSeen = lastSeen
        self.deviceIPAddress = deviceIPAddress
        self.connectionIPAddress = connectionIPAddress
        self.credentialID = credentialID
    }
}

struct NetworkJoinAlert: Identifiable, Equatable, Sendable {
    let id = UUID()
    let succeeded: Bool
    let title: String
    let message: String
    let suggestedName: String?
    let invitationNetworkID: NetworkID?
    let invitationAccepted: Bool
    let existingProfileID: NetworkProfileID?
    let reattachmentContextID: ContextID?
    let connectivity: ActiveNetworkConnectivity?

    init(
        succeeded: Bool,
        title: String,
        message: String,
        suggestedName: String? = nil,
        invitationNetworkID: NetworkID? = nil,
        invitationAccepted: Bool = false,
        existingProfileID: NetworkProfileID? = nil,
        reattachmentContextID: ContextID? = nil,
        connectivity: ActiveNetworkConnectivity? = nil
    ) {
        self.succeeded = succeeded
        self.title = title
        self.message = message
        self.suggestedName = suggestedName
        self.invitationNetworkID = invitationNetworkID
        self.invitationAccepted = invitationAccepted
        self.existingProfileID = existingProfileID
        self.reattachmentContextID = reattachmentContextID
        self.connectivity = connectivity
    }
}

struct InvitationReview: Identifiable, Equatable, Sendable {
    let id: UUID
    let invitationJSON: String
    let networkDisplayName: String
    let networkID: NetworkID
    let authorityID: AuthorityID
    let authorityURL: URL
    let environment: String
    let serviceScopes: [String]
    let issuedAt: Date
    let receivedAt: Date
    let expiresAt: Date

    var validity: TimeInterval {
        expiresAt.timeIntervalSince(issuedAt)
    }

    func isExpired(at date: Date = Date()) -> Bool {
        expiresAt <= date
    }
}

enum ActiveNetworkConnectivity: Equatable, Sendable {
    case inactive
    case reconnecting
    case discoveringPeers
    case readyNoPeers
    case connected(peerCount: Int)
    case failed
    case localNetworkDenied

    var isLocalDeviceOnline: Bool {
        switch self {
        case .readyNoPeers, .connected:
            true
        case .inactive, .reconnecting, .discoveringPeers, .failed, .localNetworkDenied:
            false
        }
    }
}

private enum NetworkRuntimeTransitionError: Error {
    case timedOut
}

private enum ApplicationActivity: String {
    case launching
    case active
    case inactive
    case background
}

enum BootstrapStartReason: String {
    case applicationLaunch
    case profileSwitch
}

@MainActor
@Observable
final class NodeBootstrapModel {
    var controlPlaneURL = ""
    var networkIDText = ""
    var authorityPublicKeyBase64 = ""
    var authorityCertificateBase64 = ""
    var credentialJSON = ""
    var networkDisplayName = "Local Network"
    @ObservationIgnored private var friendlyNameDefaults = UserDefaults.standard
    var deviceFriendlyName = UserDefaults.standard.string(forKey: "net.beakr.app.deviceFriendlyName") ?? "" {
        didSet {
            friendlyNameDefaults.set(deviceFriendlyName, forKey: "net.beakr.app.deviceFriendlyName")
        }
    }
    var authorityHostname = NodeBootstrapModel.defaultAuthorityHostname()
    var authorityPort = "8443"
    var invitationJSON = ""
    var joinInvitationJSON = ""
    private(set) var state: NodeBootstrapState = .starting {
        didSet {
            if oldValue != state {
                let context = bootstrapTraceContext.map { " context=\($0.rawValue)" } ?? ""
                traceConnectivity("bootstrap-state\(context) \(oldValue) -> \(state)")
            }
            synchronizeSelectedNetworkSession()
        }
    }
    private(set) var nodeID: UUID?
    private(set) var profileID: UUID?
    private(set) var canCreateInvitations = false
    private(set) var ownedNetworks: [OwnedNetworkSummary] = []
    private(set) var savedMemberships: [NetworkProfileID: SavedNetworkMembership] = [:]

    func members(for network: NetworkSummary) -> [NetworkMemberSummary] {
        network.isActive ? networkMembers : savedMemberships[network.id]?.members ?? []
    }

    func localNodeID(for id: NetworkProfileID) -> UUID? {
        networkSessions.first { $0.id == id }?.profile.localNodeID.rawValue
    }

    private(set) var networkSessions: [NetworkSession] = []
    var networks: [NetworkSummary] {
        networkSessions.map { session in
            var summary = session.summary
            if summary.isActive {
                summary.credentialStatus = credentialStatus
                summary.messagingHealth = messagingHealth
                summary.messagingHealthMessage = messagingHealthMessage
            }
            return summary
        }
    }
    private(set) var peerTLSFailureCount = 0
    @ObservationIgnored private var tlsHealthTask: Task<Void, Never>?

    var messagingHealth: MessagingHealth {
        if let credentialStatus {
            return credentialStatus == .preparing || credentialStatus.retriesAutomatically ? .waiting : .blocked
        }
        switch activeNetworkConnectivity {
        case .failed, .localNetworkDenied: return .blocked
        case .inactive: return .off
        case .reconnecting: return .waiting
        default: return peerTLSFailureCount > 0 ? .degraded : (activeNetworkConnectivity == .discoveringPeers ? .waiting : .healthy)
        }
    }

    var messagingHealthMessage: String {
        if credentialStatus != nil { return "Messaging: \(statusMessage)" }
        if activeNetworkConnectivity == .localNetworkDenied { return "Messaging: Local Network permission required" }
        if activeNetworkConnectivity == .failed { return "Messaging: Connection failed. Open Services → Messaging for recovery." }
        if peerTLSFailureCount > 0 {
            return "Messaging: An outgoing peer connection failed certificate validation. Other trusted connections can continue. Open Services → Messaging for details."
        }
        return "Messaging: \(activeNetworkStatusTitle)"
    }

    private(set) var credentialStatus: NetworkCredentialStatus?
    private(set) var credentialDetails = NetworkCredentialDetails()
    private(set) var isRefreshingCredentials = false
    @ObservationIgnored private var credentialRetryTask: Task<Void, Never>?
    @ObservationIgnored private var credentialTask: Task<Void, Never>?
    @ObservationIgnored private var revokedProfilePendingRemoval: NetworkProfileID?
    @ObservationIgnored private var credentialPathTask: Task<Void, Never>?
    @ObservationIgnored var credentialRecoveryDelay: @Sendable (Int) async throws -> Void = {
        try await Task.sleep(for: .seconds($0))
    }
    @ObservationIgnored private var credentialRetryAttempt = 0
    @ObservationIgnored private var credentialOperationID: UUID?
    @ObservationIgnored private var explicitMessagingSelection: NetworkProfileID?

    private func cancelCredentialRecovery() {
        credentialOperationID = nil
        credentialTask?.cancel()
        credentialPathTask?.cancel()
        credentialPathTask = nil
        credentialRetryTask?.cancel()
        credentialRetryTask = nil
        credentialRetryAttempt = 0
    }

    private func scheduleCredentialRecovery(for profileID: NetworkProfileID) {
        guard credentialStatus?.retriesAutomatically == true,
              applicationActivity != .background, credentialRetryTask == nil else { return }
        let delay = min(30, 2 << min(credentialRetryAttempt, 4))
        credentialRetryAttempt += 1
        let sleep = credentialRecoveryDelay
        credentialRetryTask = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.credentialRetryTask = nil
            guard self.selectedProfile?.id == profileID,
                  self.applicationActivity != .background,
                  self.credentialStatus?.retriesAutomatically == true else { return }
            await self.enrollAndRecoverTrust()
        }
    }

    private func observeCredentialRecoveryPath(for profileID: NetworkProfileID) {
        guard credentialPathTask == nil, credentialStatus?.retriesAutomatically == true else { return }
        let manager = lanRuntimeManager
        credentialPathTask = Task { @MainActor [weak self] in
            var previous: Bool?
            for await available in await manager.localNetworkAvailabilityUpdates() {
                guard !Task.isCancelled, let self, self.selectedProfile?.id == profileID else { return }
                defer { previous = available }
                // Initial availability is not a new recovery signal.
                if previous == false, available, self.applicationActivity != .background,
                   self.credentialStatus?.retriesAutomatically == true {
                    self.credentialRetryTask?.cancel()
                    self.credentialRetryTask = nil
                    await self.enrollAndRecoverTrust()
                }
            }
        }
    }

    private func loadCredentialDetails(configuration: DevelopmentAuthorityConfiguration, runtime: ApplicationProfileRuntime) {
        credentialDetails = readCredentialDetails(configuration: configuration, profileID: runtime.profile.id, paths: runtime.paths)
    }

    func savedCredentialDetails(for id: NetworkProfileID) async -> (details: NetworkCredentialDetails, authority: String?)? {
        guard let profile = try? await profileRuntimeManager.profiles().first(where: { $0.id == id }),
              let configuration = try? configurationStore.load(profile: profile),
              let paths = try? await profileRuntimeManager.runtimePaths(for: profile) else { return nil }
        return (readCredentialDetails(configuration: configuration, profileID: id, paths: paths),
                configuration.controlPlaneURL.host)
    }

    private func readCredentialDetails(configuration: DevelopmentAuthorityConfiguration, profileID: NetworkProfileID, paths: ProfileRuntimePaths) -> NetworkCredentialDetails {
        var details = NetworkCredentialDetails(
            accessExpiresAt: Date(timeIntervalSince1970: Double(configuration.credential.claims.expiresAtMilliseconds) / 1_000)
        )
        if let snapshot = try? CredentialFiles.loadRevocationSnapshot(from: paths.revocationSnapshotURL),
           (try? RevocationVerifier.verify(snapshot, trustedAuthorityPublicKey: configuration.authorityPublicKey)) != nil {
            let updated = Date(timeIntervalSince1970: Double(snapshot.claims.generatedAtMilliseconds) / 1_000)
            details.revocationsUpdatedAt = updated
            details.revocationsValidUntil = updated.addingTimeInterval(LANHandshakeAuthenticator.maximumRevocationAge)
        }
        let namespace = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profileID)
        if let identity = try? KeychainLANTLSIdentityStore(namespace: namespace).load() {
            details.certificateExpiresAt = SecCertificateCopyNotValidAfterDate(identity.leafCertificate) as Date?
        }
        return details
    }

    private func presentCredentialFailure(_ error: Error) {
        switch error {
        case LANHandshakeError.expiredCredential, CredentialVerificationError.expired:
            credentialStatus = .expired
            statusMessage = "This device’s network access has expired. Contact the network authority to renew access."
        case LANHandshakeError.revokedCredential, CredentialVerificationError.revoked, ApplicationLANRuntimeError.localMembershipRemoved:
            credentialStatus = .revoked
            statusMessage = "The network authority removed this device’s access. New authority approval is required."
        case LANHandshakeError.staleRevocationSnapshot, ApplicationLANRuntimeError.missingRevocationSnapshot,
             ApplicationLANRuntimeError.missingMembershipSnapshot, NodeBootstrapError.noTrustedRevocationState:
            let owns = networks.first(where: { $0.isActive })?.isHostingAuthority == true
            if owns, let id = selectedProfile?.id, authorityHostingStates[id] == .stopped {
                credentialStatus = .authorityStopped
                statusMessage = "Credential validation is out of date. Authority hosting was stopped on this device. Start Hosting to resume automatic recovery."
            } else {
                credentialStatus = .waitingForAuthority
                let authority = activeAuthorityDeviceName ?? activeConfiguration?.controlPlaneURL.host ?? "the network authority"
                statusMessage = "Credential validation is out of date. Waiting for \(authority) to provide current signed membership and revocation records. Beakr retries automatically while active."
            }
        case AuthorityEndpointDiscoveryError.unavailable, DiscoveredAuthorityHTTPTransportError.endpointUnavailable:
            credentialStatus = .waitingForAuthority
            statusMessage = "Waiting for the network authority to refresh this device’s credentials. Beakr retries automatically while active."
        default:
            if credentialStatus != .authorityFailed {
                credentialStatus = (error is URLError) ? .waitingForAuthority : .invalid
                statusMessage = "Network credentials could not be refreshed: \(Self.describe(error)). Messaging remains paused."
            }
        }
    }

    func refreshNetworkCredentials() async {
        guard !isRefreshingCredentials, !applicationStartupInProgress, state != .securing else { return }
        isRefreshingCredentials = true
        defer { isRefreshingCredentials = false }
        if state == .ready, activeNetworkConnectivity != .failed {
            // The running maintenance coordinator refreshes revocations before membership,
            // preserving rollback protection and existing authenticated sessions.
            await refreshNetworkMembers()
            if let configuration = activeConfiguration, let runtime = activeRuntime {
                loadCredentialDetails(configuration: configuration, runtime: runtime)
            }
        } else if state == .ready {
            await reconnectActiveNetwork()
        } else {
            credentialRetryTask?.cancel()
            credentialRetryTask = nil
            await enrollAndRecoverTrust()
        }
    }
    private(set) var contexts: [ContextSummary] = []
    private(set) var archivedContexts: [ContextSummary] = []
    private(set) var archivedIncomingMessages: [ContextID: [IncomingMessage]] = [:]
    private(set) var archivedMailboxMetadata: [ContextID: ContextMailboxMetadata] = [:]
    private(set) var storedIncomingMessages: [NetworkProfileID: [IncomingMessage]] = [:]
    private(set) var storedMailboxMetadata: [NetworkProfileID: ContextMailboxMetadata] = [:]
    private(set) var networkMembers: [NetworkMemberSummary] = []
    private(set) var pendingEnrollmentRequests: [EnrollmentRequest] = []
    private(set) var enrollmentRequestActionMessage: String?
    private(set) var enrollmentAuditRecords: [EnrollmentAuditRecord] = []
    private var authorityAdministration: [NetworkProfileID: AuthorityAdministrationSnapshot] = [:]
    private var authorityAdministrationGeneration: [NetworkProfileID: UInt64] = [:]

    private func invalidateAuthorityAdministration(_ id: NetworkProfileID) {
        authorityAdministrationGeneration[id, default: 0] += 1
        updateAdministration(for: id) { $0.invitationJSON = ""; $0.requests = [] }
    }

    func administration(for id: NetworkProfileID) -> AuthorityAdministrationSnapshot {
        authorityAdministration[id] ?? AuthorityAdministrationSnapshot()
    }

    private func updateAdministration(for id: NetworkProfileID, generation: UInt64? = nil,
                                      _ update: (inout AuthorityAdministrationSnapshot) -> Void) {
        if let generation, generation != authorityAdministrationGeneration[id, default: 0] { return }
        var snapshot = administration(for: id)
        update(&snapshot)
        authorityAdministration[id] = snapshot
        if selectedProfile?.id == id {
            invitationJSON = snapshot.invitationJSON
            pendingEnrollmentRequests = snapshot.requests
            enrollmentAuditRecords = snapshot.records
            enrollmentRequestActionMessage = snapshot.message
        }
    }

    private func administrationProfile(_ id: NetworkProfileID?) async throws -> NetworkProfile {
        guard let targetID = id ?? selectedProfile?.id,
              let profile = try await profileRuntimeManager.profiles().first(where: { $0.id == targetID }) else {
            throw AuthoritativeNetworkCreationError.invalidPersistedAuthority
        }
        return profile
    }

    private(set) var hasPendingJoiningRequest = false
    private(set) var onlineMemberIDs: Set<UUID> = []
    private var connectivityWithoutSelectedSession: ActiveNetworkConnectivity = .inactive
    private var bootstrapTraceContext: BootstrapStartReason?
    private var lastPeerDiagnosticIDs: Set<UUID>?
    private var lastPeerDiagnosticLocalAvailability: Bool?
    private(set) var activeNetworkConnectivity: ActiveNetworkConnectivity {
        get {
            networkSessions.first(where: \.isSelected)?.connectivity
                ?? connectivityWithoutSelectedSession
        }
        set {
            if activeNetworkConnectivity != newValue {
                let level: BeakrDiagnosticLevel
                if newValue == .failed || newValue == .localNetworkDenied {
                    level = .failure
                } else if case .connected = newValue,
                          activeNetworkConnectivity == .reconnecting || activeNetworkConnectivity == .failed {
                    level = .recovered
                } else {
                    level = .info
                }
                activeLifecycleTrace?.record(.connectivity, .changed,
                                             previousState: String(describing: activeNetworkConnectivity),
                                             state: String(describing: newValue))
                traceConnectivity("connectivity \(activeNetworkConnectivity) -> \(newValue)", level: level)
            }
            connectivityWithoutSelectedSession = newValue
            networkSessions.first(where: \.isSelected)?.setConnectivity(newValue)
            synchronizeSelectedNetworkSession()
        }
    }
    private(set) var statusMessage = "Restoring this device’s node identity." {
        didSet { synchronizeSelectedNetworkSession() }
    }
    private(set) var profileRegistryLoadFailure: String?
    private(set) var authorityListenerConflict = false
    var networkJoinAlert: NetworkJoinAlert?
    var isInvitationReviewPresented = false

    /// A presented review owns polling results; underlying screens must not
    /// present a second alert for the same approval or failure.
    var standaloneNetworkJoinAlert: NetworkJoinAlert? {
        get { isInvitationReviewPresented ? nil : networkJoinAlert }
        set { if !isInvitationReviewPresented { networkJoinAlert = newValue } }
    }

    func consumeInvitationReviewResult() -> NetworkJoinAlert? {
        guard isInvitationReviewPresented else { return nil }
        defer { networkJoinAlert = nil }
        return networkJoinAlert
    }

    private let identityLoader: any NodeIdentityLoading
    private let configurationStore: any DevelopmentAuthorityConfigurationStoring
    private let trustBootstrapper: any NodeTrustBootstrapping
    private let lifecycleMigrator: any ApplicationLifecycleMigrating
    private let enrollmentRouter: any ApplicationEnrollmentRouting
    private let profileRuntimeManager: any ApplicationProfileRuntimeManaging
    private let lanRuntimeManager: any ApplicationLANRuntimeManaging
    private(set) var sharedStatusRevision = UUID()
    @ObservationIgnored private var statusPermissions: SharedStatusPermissionCoordinator?

    func sharedStatusPermissions(for id: NetworkProfileID, operation: StatusPermissionOperation = .read) async throws -> SharedStatusPermissionStore {
        guard let statusPermissions,
              let profile = try await profileRuntimeManager.profiles().first(where: { $0.id == id })
        else { throw SharedStatusPermissionError.unavailable }
        let paths = try await profileRuntimeManager.runtimePaths(for: profile)
        return try await statusPermissions.store(profile: profile, rootURL: paths.rootURL, operation: operation)
    }


    func sharedStatusRuntime(for profile: NetworkProfileID) async -> SharedStatusRuntime? {
        guard profileID == profile.rawValue else { return nil }
        let runtime = await lanRuntimeManager.sharedStatusRuntime(profileID: profile.rawValue)
        guard profileID == profile.rawValue else { return nil }
        return runtime
    }
    private let networkCreator: any AuthoritativeNetworkCreating
    private let networkStartTimeout: Duration
    private var localAuthority: (any ApplicationAuthorityRunning)?
    @ObservationIgnored private var hostingController: PersistedAuthorityHostingController<any ApplicationAuthorityRunning>?
    @ObservationIgnored private var hostingPreferencesURL: URL?
    private(set) var authorityHostingStates: [NetworkProfileID: AuthorityHostingState] = [:]
    private(set) var authorityHostingFailures: [NetworkProfileID: String] = [:]
    private(set) var authorityHostingEnabled: Set<NetworkProfileID> = []
    private(set) var authorityHostingBusy = false

    private func authorityController() throws -> PersistedAuthorityHostingController<any ApplicationAuthorityRunning> {
        if let hostingController { return hostingController }
        let url: URL
        if let hostingPreferencesURL { url = hostingPreferencesURL }
        else {
            url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: true)
                .appendingPathComponent("Beakr/authority-hosting.json")
        }
        let creator = networkCreator
        let preferences = try AuthorityHostingPreferences.open(fileURL: url)
        let controller = PersistedAuthorityHostingController<any ApplicationAuthorityRunning>(
            preferences: preferences, owns: { try await creator.owns(profile: $0) },
            start: { profile in
                guard let authority = try await creator.restore(profile: profile) else {
                    throw AuthoritativeNetworkCreationError.invalidPersistedAuthority
                }
                return authority
            }, stop: { await $0.stop() }
        )
        hostingController = controller
        return controller
    }

    private func reconcileAuthorityHosting(activeProfileID: NetworkProfileID?) async throws {
        let profiles = try await profileRuntimeManager.profiles()
        let statuses = try await authorityController().reconcile(profiles: profiles, activeProfileID: activeProfileID)
        for status in statuses {
            authorityHostingStates[status.profile.id] = status.state
            authorityHostingFailures[status.profile.id] = status.failure
            if let failure = status.failure {
                traceConnectivity("authority-hosting-failed profile=\(status.profile.id.rawValue.uuidString) reason=\(failure)", level: .failure)
            }
            if status.enabled { authorityHostingEnabled.insert(status.profile.id) }
            else { authorityHostingEnabled.remove(status.profile.id) }
        }
    }

    private func runningAuthority(for profile: NetworkProfile) async throws -> (any ApplicationAuthorityRunning)? {
        guard try await networkCreator.owns(profile: profile) else { return nil }
        return try await authorityController().runningHandle(for: profile)
    }

    private func updateAuthorityHostingStatus(_ profile: NetworkProfile) async {
        if let status = try? await authorityController().status(for: profile) {
            authorityHostingStates[profile.id] = status.state
            if status.enabled { authorityHostingEnabled.insert(profile.id) }
            else { authorityHostingEnabled.remove(profile.id) }
        }
        if selectedProfile?.id == profile.id {
            localAuthority = try? await runningAuthority(for: profile)
        }
    }

    func setAuthorityHosting(_ enabled: Bool, for id: NetworkProfileID) async {
        guard !authorityHostingBusy else { return }
        authorityHostingBusy = true
        defer { authorityHostingBusy = false }
        if !enabled, selectedProfile?.id == id {
            cancelCredentialRecovery()
            await credentialTask?.value
            if state != .ready {
                credentialStatus = .authorityStopped
                state = .identityReady
                statusMessage = "Authority hosting was stopped. Start Hosting to resume credential recovery."
            }
        }
        guard let profile = try? await profileRuntimeManager.profiles().first(where: { $0.id == id }) else { return }
        invalidateAuthorityAdministration(id)
        authorityHostingStates[id] = enabled ? .starting : .stopping
        do {
            try await authorityController().setEnabled(enabled, for: profile)
            authorityHostingFailures[id] = nil
            statusMessage = enabled ? "Authority hosting started for \(profile.displayName)." : "Authority hosting stopped for \(profile.displayName)."
        } catch {
            authorityHostingFailures[id] = Self.describe(error)
            statusMessage = "Authority hosting could not change: \(Self.describe(error))."
        }
        await updateAuthorityHostingStatus(profile)
        await refreshOwnedNetworks()
        if enabled, selectedProfile?.id == id, state != .ready, !applicationStartupInProgress {
            await enrollAndRecoverTrust()
        }
    }

    private var activeConfiguration: DevelopmentAuthorityConfiguration?
    private var activeRuntime: ApplicationProfileRuntime?
    private var selectedProfile: NetworkProfile?
    private var runtimeTransitionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttemptID: UUID?
    private var peerObservationTask: Task<Void, Never>?
    private var peerDiscoveryTask: Task<Void, Never>?
    private var localNetworkObservationTask: Task<Void, Never>?
    private var localNetworkPermissionTask: Task<Void, Never>?
    private(set) var isLocalNetworkPermissionDenied = false
    private var enrollmentPollingTask: Task<Void, Never>?
    private var hasUsableLocalNetwork = false
    private var runtimeGeneration = 0
    private var activeLifecycleTrace: RuntimeLifecycleTrace?
    private var approvedCollidingNetworkID: NetworkID?
    private var collidingNetworkDisplayName: String?
    private var approvedReattachmentNetworkID: NetworkID?
    private var hasStarted = false
    private var applicationStartupInProgress = false
    private var applicationActivity: ApplicationActivity = .launching

    // Operational diagnostics only: no message payloads, invitations, or credentials.
    private func traceConnectivity(_ event: String, level: BeakrDiagnosticLevel = .debug) {
        let profile = selectedProfile?.id.rawValue.uuidString ?? "none"
        let attempt = reconnectAttemptID?.uuidString ?? "none"
        BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [Beakr Connectivity] time=\(beakrConsoleTime()) profile=\(profile) generation=\(runtimeGeneration) attempt=\(attempt) cancelled=\(Task.isCancelled) \(event)", level: level, logger: BeakrDiagnosticLog.connectivity)
    }

    // Invitation diagnostics contain identifiers and lifecycle state only—never invitation data or credentials.
    func traceInvitationUI(_ event: String, level: BeakrDiagnosticLevel = .debug) {
        let profile = selectedProfile?.id.rawValue.uuidString ?? "none"
        BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [Beakr Invitation UI] time=\(beakrConsoleTime()) profile=\(profile) state=\(state) cancelled=\(Task.isCancelled) \(event)", level: level, logger: BeakrDiagnosticLog.enrollment)
    }

    private func synchronizeSelectedNetworkSession() {
        networkSessions.first(where: \.isSelected)?.applyApplicationState(
            state,
            connectivity: activeNetworkConnectivity,
            statusMessage: statusMessage
        )
    }

    var activeNetworkName: String? {
        selectedProfile.map { Self.friendlyNetworkName($0.displayName) }
    }

    var activeNetworkRole: String {
        guard let network = networks.first(where: \.isActive) else { return "No Network" }
        if network.isHostingAuthority { return "Authority Host and Manager" }
        if network.canManageNetwork { return "Network Manager" }
        return "Network Member"
    }

    var activeAuthorityHostname: String? { activeConfiguration?.controlPlaneURL.host }

    var activeAuthorityEndpoint: String? {
        guard let url = activeConfiguration?.controlPlaneURL,
              let host = url.host else { return nil }
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }

    var activeAuthorityDeviceName: String? {
        guard let network = networks.first(where: \.isActive) else { return nil }
        if network.isHostingAuthority { return deviceDisplayName }
        guard let hostname = activeAuthorityHostname else { return nil }
        let normalizedHost = Self.normalizedHostIdentity(hostname)
        return networkMembers.first {
            Self.normalizedHostIdentity($0.displayName) == normalizedHost
        }?.displayName
    }

    var activeNetworkStatusTitle: String {
        if let credentialStatus { return String(localized: credentialStatus.title) }
        switch activeNetworkConnectivity {
        case .localNetworkDenied:
            return "Local Network Permission Required"
        case .inactive:
            return "Inactive"
        case .reconnecting:
            return "Active — Reconnecting"
        case .discoveringPeers:
            return "Active — Discovering devices"
        case .readyNoPeers:
            return "Active — Ready, no devices online"
        case .connected(let peerCount):
            return peerCount == 1 ? "Active — Connected to 1 device" : "Active — Connected to \(peerCount) devices"
        case .failed:
            return "Active — Connection error"
        }
    }

    var deviceDisplayName: String {
        let friendlyName = deviceFriendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !friendlyName.isEmpty { return friendlyName }
#if canImport(UIKit)
        return UIDevice.current.name
#elseif os(macOS)
        return (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
#else
        return ProcessInfo.processInfo.hostName
#endif
    }

    private static func defaultAuthorityHostname() -> String {
#if os(macOS)
        if let localHostName = SCDynamicStoreCopyLocalHostName(nil) as String? {
            let trimmed = localHostName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !trimmed.isEmpty { return "\(trimmed).local" }
        }
#endif
        let fallback = ProcessInfo.processInfo.hostName
            .split(separator: ".", maxSplits: 1)
            .first
            .map(String.init) ?? "Beakr-Mac"
        return "\(fallback).local"
    }

    init() {
        let configurationStore = DevelopmentAuthorityConfigurationStore()
        let profileRuntimeManager = ApplicationProfileRuntimeManager()
        identityLoader = KeychainNodeIdentityLoader()
        self.configurationStore = configurationStore
        trustBootstrapper = DevelopmentNodeTrustBootstrapper()
        lifecycleMigrator = ApplicationLifecycleMigrator()
        enrollmentRouter = ApplicationEnrollmentRouter(
            profileRuntimeManager: profileRuntimeManager,
            configurationStore: configurationStore
        )
        self.profileRuntimeManager = profileRuntimeManager
        lanRuntimeManager = ApplicationLANRuntimeManager()
        networkCreator = SystemAuthoritativeNetworkCreator()
        networkStartTimeout = .seconds(8)
    }

    init(lanRuntimeManager: any ApplicationLANRuntimeManaging,
         statusPermissions: SharedStatusPermissionCoordinator? = nil) {
        self.statusPermissions = statusPermissions
        let configurationStore = DevelopmentAuthorityConfigurationStore()
        let profileRuntimeManager = ApplicationProfileRuntimeManager()
        identityLoader = KeychainNodeIdentityLoader()
        self.configurationStore = configurationStore
        trustBootstrapper = DevelopmentNodeTrustBootstrapper()
        lifecycleMigrator = ApplicationLifecycleMigrator()
        enrollmentRouter = ApplicationEnrollmentRouter(
            profileRuntimeManager: profileRuntimeManager,
            configurationStore: configurationStore
        )
        self.profileRuntimeManager = profileRuntimeManager
        self.lanRuntimeManager = lanRuntimeManager
        networkCreator = SystemAuthoritativeNetworkCreator()
        networkStartTimeout = .seconds(8)
    }

    init(identityLoader: any NodeIdentityLoading) {
        let configurationStore = DevelopmentAuthorityConfigurationStore()
        let profileRuntimeManager = ApplicationProfileRuntimeManager()
        self.identityLoader = identityLoader
        self.configurationStore = configurationStore
        trustBootstrapper = DevelopmentNodeTrustBootstrapper()
        lifecycleMigrator = ApplicationLifecycleMigrator()
        enrollmentRouter = ApplicationEnrollmentRouter(
            profileRuntimeManager: profileRuntimeManager,
            configurationStore: configurationStore
        )
        self.profileRuntimeManager = profileRuntimeManager
        lanRuntimeManager = ApplicationLANRuntimeManager()
        networkCreator = SystemAuthoritativeNetworkCreator()
        networkStartTimeout = .seconds(8)
    }

    init(identityLoader: any NodeIdentityLoading,
         configurationStore: any DevelopmentAuthorityConfigurationStoring) {
        let profileRuntimeManager = ApplicationProfileRuntimeManager()
        self.identityLoader = identityLoader
        self.configurationStore = configurationStore
        trustBootstrapper = DevelopmentNodeTrustBootstrapper()
        lifecycleMigrator = ApplicationLifecycleMigrator()
        enrollmentRouter = ApplicationEnrollmentRouter(
            profileRuntimeManager: profileRuntimeManager,
            configurationStore: configurationStore
        )
        self.profileRuntimeManager = profileRuntimeManager
        lanRuntimeManager = ApplicationLANRuntimeManager()
        networkCreator = SystemAuthoritativeNetworkCreator()
        networkStartTimeout = .seconds(8)
    }

    init(identityLoader: any NodeIdentityLoading,
         configurationStore: any DevelopmentAuthorityConfigurationStoring,
         trustBootstrapper: any NodeTrustBootstrapping,
         profileRuntimeManager: any ApplicationProfileRuntimeManaging,
         lanRuntimeManager: any ApplicationLANRuntimeManaging = ApplicationLANRuntimeManager(),
         networkCreator: any AuthoritativeNetworkCreating = SystemAuthoritativeNetworkCreator(),
         lifecycleMigrator: any ApplicationLifecycleMigrating = NoopApplicationLifecycleMigrator(),
         enrollmentRouter: any ApplicationEnrollmentRouting = MemberApplicationEnrollmentRouter(),
         networkStartTimeout: Duration = .seconds(8),
         friendlyNameDefaults: UserDefaults = .standard) {
        self.identityLoader = identityLoader
        self.configurationStore = configurationStore
        self.trustBootstrapper = trustBootstrapper
        self.lifecycleMigrator = lifecycleMigrator
        self.enrollmentRouter = enrollmentRouter
        self.profileRuntimeManager = profileRuntimeManager
        self.lanRuntimeManager = lanRuntimeManager
        self.networkCreator = networkCreator
        hostingPreferencesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Beakr-hosting-test-" + UUID().uuidString)
            .appendingPathComponent("hosting.json")
        self.networkStartTimeout = networkStartTimeout
        self.friendlyNameDefaults = friendlyNameDefaults
        deviceFriendlyName = friendlyNameDefaults.string(forKey: "net.beakr.app.deviceFriendlyName") ?? ""
    }

    func start(reason: BootstrapStartReason = .applicationLaunch) async {
        switch reason {
        case .applicationLaunch:
            traceConnectivity("application-start alreadyStarted=\(hasStarted)")
        case .profileSwitch:
            traceConnectivity("profile-session-start reason=profileSwitch alreadyStarted=\(hasStarted)")
        }
        guard !hasStarted else { return }
        let startupBegan = ContinuousClock.now
        traceConnectivity("startup-begin reason=\(reason.rawValue)")
        defer {
            traceConnectivity("startup-return elapsed=\(startupBegan.duration(to: .now)) state=\(state) connectivity=\(activeNetworkConnectivity)")
        }
        hasStarted = true
        applicationStartupInProgress = true
        defer { applicationStartupInProgress = false }
        state = .starting
        authorityListenerConflict = false
        statusMessage = "Selecting the active network profile."
        profileRegistryLoadFailure = nil
        let profile: NetworkProfile?
        do {
            traceConnectivity("startup-profile-load-begin")
            profile = try await profileRuntimeManager.activeProfile()
            traceConnectivity("startup-profile-load-end found=\(profile != nil)")
        } catch {
            activeNetworkConnectivity = .failed
            state = .failed
            profileRegistryLoadFailure = Self.describe(error)
            statusMessage = "Network data could not be loaded: \(Self.describe(error))."
            return
        }
        do {
            try await reconcileAuthorityHosting(activeProfileID: profile?.id)
            guard let profile else {
                activeNetworkConnectivity = .inactive
                nodeID = nil
                profileID = nil
                state = .needsConfiguration
                statusMessage = "Choose a network before creating its secure identity."
                await refreshOwnedNetworks()
                return
            }
            selectedProfile = profile
            // Establish the stable application network objects before opening
            // identity, trust, authority, or LAN services for the selected one.
            traceConnectivity("startup-network-list-begin")
            await refreshOwnedNetworks()
            traceConnectivity("startup-network-list-end")
            activeNetworkConnectivity = .reconnecting
            traceConnectivity("startup-identity-load-begin")
            guard let restoredNodeID = try identityLoader.loadNodeID(profileID: profile.id) else {
                throw NodeBootstrapError.profileIdentityMismatch
            }
            guard restoredNodeID == profile.localNodeID else {
                throw NodeBootstrapError.profileIdentityMismatch
            }
            traceConnectivity("startup-identity-load-end")
            traceConnectivity("startup-authority-restore-begin")
            localAuthority = try? await runningAuthority(for: profile)
            traceConnectivity("startup-authority-restore-end hosting=\(localAuthority != nil)")
            canCreateInvitations = localAuthority != nil
            nodeID = restoredNodeID.rawValue
            profileID = profile.id.rawValue
            traceConnectivity("startup-configuration-load-begin")
            if var configuration = try configurationStore.load(profile: profile) {
                traceConnectivity("startup-configuration-load-end found=true")
                if localAuthority != nil {
                    configuration = try await networkCreator.configurationForOwnedNetwork(profile: profile)
                        ?? configuration
                    try configurationStore.save(configuration, profile: profile)
                }
                try validate(configuration, nodeID: restoredNodeID)
                canCreateInvitations = Self.verifiedAuthorization(
                    profile: profile,
                    configuration: configuration,
                    isHostingAuthority: localAuthority != nil
                )?.capabilities.contains(.manageNetwork) == true
                controlPlaneURL = configuration.controlPlaneURL.absoluteString
                networkIDText = configuration.networkID.rawValue.uuidString
                authorityPublicKeyBase64 = configuration.authorityPublicKey.base64EncodedString()
                authorityCertificateBase64 = configuration.authorityCertificateDER?.base64EncodedString() ?? ""
                traceConnectivity("startup-profile-runtime-begin")
                let runtime = try await profileRuntimeManager.start(profile: profile)
                traceConnectivity("startup-profile-runtime-end")
                activeRuntime = runtime
                activeConfiguration = configuration
                traceConnectivity("startup-cached-membership-check-begin")
                if await localMembershipWasRemoved(
                    configuration: configuration,
                    runtime: runtime
                ) {
                    await removeRevokedActiveNetwork()
                    return
                }
                traceConnectivity("startup-cached-membership-check-end removed=false")
                state = .identityReady
                await refreshOwnedNetworks()
                statusMessage = "Securing this device."
                traceConnectivity("startup-pending-confirmations-begin")
                await flushPendingEnrollmentConfirmations(
                    profile: profile,
                    configuration: configuration
                )
                traceConnectivity("startup-pending-confirmations-end")
                await enrollAndRecoverTrust()
                await refreshOwnedNetworks()
            } else {
                if try await resumePendingReleaseEnrollment(profile: profile) {
                    return
                }
                state = .needsConfiguration
                statusMessage = "The profile identity is secure. Authority configuration is required."
                await refreshOwnedNetworks()
            }
        } catch {
            traceConnectivity("startup-error type=\(String(reflecting: type(of: error))) code=\((error as NSError).code) domain=\((error as NSError).domain)", level: .failure)
            nodeID = nil
            activeNetworkConnectivity = .failed
            state = .failed
            if Self.isAuthorityListenerConflict(error) {
                authorityListenerConflict = true
                statusMessage = "Startup failed — another copy of Beakr is running."
#if os(macOS)
                NSSound.beep()
#endif
            } else {
                presentCredentialFailure(error)
            }
        }
    }

    private(set) var isCreatingNetwork = false
    private(set) var lastCreatedNetworkID: NetworkProfileID?

    func createNetwork() async {
        guard !isCreatingNetwork else { return }
        isCreatingNetwork = true
        lastCreatedNetworkID = nil
        defer { isCreatingNetwork = false }
        let normalizedName = networkDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let profiles = try? await profileRuntimeManager.profiles(),
           profiles.contains(where: { Self.namesCollide($0.displayName, normalizedName) }) {
            statusMessage = "A network named \(normalizedName) already exists on this device. Choose a different name."
            return
        }
        guard let port = UInt16(authorityPort) else {
            statusMessage = "Enter a valid authority port."
            return
        }
        let previousProfileID = selectedProfile?.id
        var createdNetwork: CreatedAuthoritativeNetwork?
        if previousProfileID == nil { state = .creatingNetwork }
        statusMessage = "Creating the network authority and administrator identity."
        do {
            try await reconcileAuthorityHosting(activeProfileID: previousProfileID)
            if previousProfileID == nil && (activeRuntime != nil || localAuthority != nil) {
                await lanRuntimeManager.stop()
                try await profileRuntimeManager.stop()
                localAuthority = nil
                activeRuntime = nil
                activeConfiguration = nil
                canCreateInvitations = false
                networkMembers = []
            }
            let created = try await networkCreator.create(
                displayName: networkDisplayName,
                hostname: authorityHostname,
                port: port
            )
            createdNetwork = created
            try configurationStore.save(created.configuration, profile: created.profile)
            try await profileRuntimeManager.add(created.profile)
            let paths = try await profileRuntimeManager.runtimePaths(for: created.profile)
            try await enrollmentRouter.prepareNetworkCreation(
                profile: created.profile, configuration: created.configuration, paths: paths)
            try await authorityController().setEnabled(true, for: created.profile)
            await updateAuthorityHostingStatus(created.profile)
            networkDisplayName = "Local Network"
            if previousProfileID == nil {
                state = .needsConfiguration
                activeNetworkConnectivity = .inactive
            }
            await refreshOwnedNetworks()
            lastCreatedNetworkID = created.profile.id
            statusMessage = "\(created.profile.displayName) was created with its Authority Service on. Select Use for Messaging in Services when you want to use it for messaging."
        } catch {
            if let createdNetwork {
                try? await authorityController().setEnabled(false, for: createdNetwork.profile)
                await createdNetwork.authority.stop()
                if previousProfileID == nil {
                    try? await profileRuntimeManager.stop()
                }
                try? await profileRuntimeManager.delete(profile: createdNetwork.profile)
                // Save may have written only part of the new profile's configuration.
                try? configurationStore.delete(profile: createdNetwork.profile)
                try? await networkCreator.delete(profile: createdNetwork.profile)
            }
            if previousProfileID != nil {
                await refreshOwnedNetworks()
                statusMessage = "The new network could not be created: \(Self.describe(error)). The current network remains selected."
            } else {
                selectedProfile = nil
                activeRuntime = nil
                activeConfiguration = nil
                localAuthority = nil
                canCreateInvitations = false
                nodeID = nil
                profileID = nil
                activeNetworkConnectivity = .inactive
                state = .needsConfiguration
                statusMessage = "The network could not be created: \(Self.describe(error)). No partial profile was activated."
                await refreshOwnedNetworks()
            }
        }
    }

    func prepareForNetworkCreation() {
        statusMessage = "Choose a name for the network authority created on this device."
    }

    func prepareForNetworkJoin() {
        networkJoinAlert = nil
        // Opening a scanner must not replace the diagnostic for a failed or
        // pending enrollment with a generic instruction in Last Error.
        if state != .failed && !hasPendingJoiningRequest {
            statusMessage = "Scan or paste a current invitation from a network manager."
        }
    }

    func invitationReview(
        for invitationJSON: String,
        receivedAt: Date = Date(),
        reportFailure: Bool = true
    ) -> InvitationReview? {
        do {
            guard let data = invitationJSON.data(using: .utf8) else {
                throw NetworkInvitationError.invalidConfiguration
            }
            let enrollmentInvitation: EnrollmentInvitation?
            let canonicalInvitationJSON: String
            if let invitation = try? EnrollmentWireCodec.decode(EnrollmentInvitation.self, from: data) {
                enrollmentInvitation = invitation
                canonicalInvitationJSON = invitationJSON
            } else if let invitation = try? JSONDecoder().decode(EnrollmentInvitation.self, from: data),
                      let canonicalData = try? EnrollmentWireCodec.encode(invitation),
                      let verifiedInvitation = try? EnrollmentWireCodec.decode(
                          EnrollmentInvitation.self,
                          from: canonicalData
                      ) {
                enrollmentInvitation = verifiedInvitation
                canonicalInvitationJSON = String(decoding: canonicalData, as: UTF8.self)
            } else {
                enrollmentInvitation = nil
                canonicalInvitationJSON = invitationJSON
            }
            if let invitation = enrollmentInvitation {
                try EnrollmentWireVerifier.verifyInvitation(
                    invitation,
                    now: receivedAt,
                    allowedClockSkew: 60
                )
                guard let authorityURL = invitation.controlPlaneURL else {
                    throw EnrollmentWireError.invalidField
                }
                return InvitationReview(
                    id: invitation.invitationID,
                    invitationJSON: canonicalInvitationJSON,
                    networkDisplayName: invitation.networkDisplayName,
                    networkID: invitation.networkID,
                    authorityID: invitation.authorityID,
                    authorityURL: authorityURL,
                    environment: invitation.environment,
                    serviceScopes: invitation.serviceScopes,
                    issuedAt: Date(timeIntervalSince1970: TimeInterval(invitation.issuedAtMilliseconds) / 1_000),
                    receivedAt: receivedAt,
                    expiresAt: Date(timeIntervalSince1970: TimeInterval(invitation.expiresAtMilliseconds) / 1_000)
                )
            }
            let invitation = try NetworkInvitationWireCodec.decode(data)
            let issuedAt = Date(timeIntervalSince1970: TimeInterval(invitation.issuedAtMilliseconds) / 1_000)
            let expiresAt = Date(timeIntervalSince1970: TimeInterval(invitation.expiresAtMilliseconds) / 1_000)
            guard invitation.version == NetworkInvitation.currentVersion else {
                throw NetworkInvitationError.unsupportedVersion
            }
            guard expiresAt > issuedAt else {
                throw NetworkInvitationError.invalidValidity
            }
            return InvitationReview(
                id: invitation.invitationID,
                invitationJSON: invitationJSON,
                networkDisplayName: invitation.networkDisplayName,
                networkID: invitation.networkID,
                authorityID: invitation.authorityID,
                authorityURL: invitation.controlPlaneURL,
                environment: invitation.environment,
                serviceScopes: invitation.serviceScopes,
                issuedAt: issuedAt,
                receivedAt: receivedAt,
                expiresAt: expiresAt
            )
        } catch {
            if reportFailure {
                networkJoinAlert = NetworkJoinAlert(
                    succeeded: false,
                    title: "Invitation Cannot Be Reviewed",
                    message: Self.describe(error)
                )
            }
            return nil
        }
    }

    func isValidInvitation(_ invitationJSON: String) -> Bool {
        invitationReview(for: invitationJSON, reportFailure: false) != nil
    }

    func rejectInvitation(_ review: InvitationReview) {
        if joinInvitationJSON == review.invitationJSON {
            joinInvitationJSON = ""
        }
        statusMessage = "The invitation was not accepted."
    }

    func acceptInvitation(_ review: InvitationReview) async {
        guard !review.isExpired() else {
            networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: "Invitation Expired",
                message: "This invitation expired on \(review.expiresAt.formatted(date: .abbreviated, time: .standard)). Ask the authority for a new invitation."
            )
            return
        }
        joinInvitationJSON = review.invitationJSON
        await joinNetwork()
    }

    private var consumedInvitationIDs: Set<UUID> = []

    func invitationIsConsumed(_ invitationJSON: String) -> Bool {
        guard let invitation = try? EnrollmentWireCodec.decode(
            EnrollmentInvitation.self, from: Data(invitationJSON.utf8)
        ) else { return false }
        return consumedInvitationIDs.contains(invitation.invitationID) || authorityAdministration.values.flatMap(\.records).contains { record in
            record.request.invitation.invitationID == invitation.invitationID
                && record.request.invitation.networkID == invitation.networkID
                && record.status != .pending
        }
    }

    func createInvitation(for id: NetworkProfileID? = nil) async {
        guard let profile = try? await administrationProfile(id) else { return }
        let generation = authorityAdministrationGeneration[profile.id, default: 0]
        do {
            let encoded: String
            if let authority = try await runningAuthority(for: profile) {
                let invitation = try await authority.createEnrollmentInvitation()
                encoded = String(decoding: try EnrollmentWireCodec.encode(invitation), as: UTF8.self)
            } else {
                guard (try await networkCreator.owns(profile: profile)) == false,
                      let configuration = try configurationStore.load(profile: profile),
                      Self.verifiedAuthorization(profile: profile, configuration: configuration,
                                                 isHostingAuthority: false)?.capabilities.contains(.manageNetwork) == true else {
                    updateAdministration(for: profile.id, generation: generation) { $0.message = "Start hosting this network before creating invitations." }
                    return
                }
                let namespace = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profile.id)
                let identity = try KeychainNodeIdentityStore(namespace: namespace).loadOrCreate()
                let client = AuthorityAdministrationClient(transport: try configuration.makeTransport(profileID: profile.id))
                let invitation = try await client.createInvitation(credential: configuration.credential,
                                                                   identity: identity, validity: 15 * 60)
                guard invitation.networkID == configuration.networkID,
                      invitation.authorityPublicKey == configuration.authorityPublicKey,
                      invitation.environment == configuration.credential.claims.environment else {
                    throw NetworkInvitationError.invalidConfiguration
                }
                encoded = String(decoding: try NetworkInvitationWireCodec.encode(invitation), as: UTF8.self)
            }
            updateAdministration(for: profile.id, generation: generation) {
                $0.invitationJSON = encoded
                $0.message = "Invitation created. Previous requests were superseded."
            }
            await refreshPendingEnrollmentRequests(for: profile.id)
        } catch {
            updateAdministration(for: profile.id, generation: generation) {
                $0.invitationJSON = ""
                $0.message = "The invitation could not be created: \(Self.describe(error))."
            }
        }
    }

    func refreshPendingEnrollmentRequests(for id: NetworkProfileID? = nil) async {
        guard let profile = try? await administrationProfile(id) else { return }
        let generation = authorityAdministrationGeneration[profile.id, default: 0]
        do {
            guard let authority = try await runningAuthority(for: profile) else { return }
            let requests = try await authority.pendingEnrollmentRequests()
            let records = try await authority.enrollmentAuditRecords()
            guard !Task.isCancelled else { return }
            updateAdministration(for: profile.id, generation: generation) { $0.requests = requests; $0.records = records }
        } catch {
            updateAdministration(for: profile.id, generation: generation) {
                $0.message = "Registration history could not be loaded: \(Self.describe(error))."
            }
        }
    }

    func exportEnrollmentAudit(to fileURL: URL, for id: NetworkProfileID? = nil) async {
        guard let profile = try? await administrationProfile(id) else { return }
        let generation = authorityAdministrationGeneration[profile.id, default: 0]
        do {
            guard let authority = try await runningAuthority(for: profile) else { return }
            let data = try await authority.signedEnrollmentAuditExport()
            try data.write(to: fileURL, options: .atomic)
            updateAdministration(for: profile.id, generation: generation) { $0.message = "Enrollment history exported." }
        } catch {
            updateAdministration(for: profile.id, generation: generation) { $0.message = "Enrollment history could not be exported: \(Self.describe(error))." }
        }
    }

    func verifyEnrollmentAudit(at fileURL: URL, for id: NetworkProfileID? = nil) async {
        guard let profile = try? await administrationProfile(id) else { return }
        let generation = authorityAdministrationGeneration[profile.id, default: 0]
        do {
            guard let authority = try await runningAuthority(for: profile) else { return }
            let report = try await authority.verifyEnrollmentAuditExport(Data(contentsOf: fileURL, options: [.mappedIfSafe]))
            updateAdministration(for: profile.id, generation: generation) {
                $0.message = "Verified enrollment audit with \(report.recordCount) records. Authority: \(report.authorityID.rawValue.uuidString)."
            }
        } catch {
            updateAdministration(for: profile.id, generation: generation) { $0.message = "Enrollment audit verification failed: \(Self.describe(error))." }
        }
    }

    func approveEnrollmentRequest(_ requestID: UUID, for id: NetworkProfileID? = nil) async {
        await decideEnrollmentRequest(requestID, for: id, approve: true)
    }

    func rejectEnrollmentRequest(_ requestID: UUID, for id: NetworkProfileID? = nil) async {
        await decideEnrollmentRequest(requestID, for: id, approve: false)
    }

    private func decideEnrollmentRequest(_ requestID: UUID, for id: NetworkProfileID?, approve: Bool) async {
        guard let profile = try? await administrationProfile(id),
              let request = administration(for: profile.id).requests.first(where: { $0.requestID == requestID }),
              request.invitation.networkID == profile.networkID else { return }
        let generation = authorityAdministrationGeneration[profile.id, default: 0]
        do {
            let context = LAContext()
            let reason = approve ? "Approve this device to join \(profile.displayName)" : "Decline this device’s request to join \(profile.displayName)"
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { return }
            guard generation == authorityAdministrationGeneration[profile.id, default: 0],
                  let authority = try await runningAuthority(for: profile) else { return }
            if approve {
                _ = try await authority.approveEnrollment(requestID: requestID)
                consumedInvitationIDs.insert(request.invitation.invitationID)
            } else {
                _ = try await authority.rejectEnrollment(requestID: requestID)
            }
            await refreshPendingEnrollmentRequests(for: profile.id)
            if selectedProfile?.id == profile.id { await refreshNetworkMembers() }
            updateAdministration(for: profile.id, generation: generation) {
                $0.message = approve ? "Approved request \(requestID.uuidString)." : "Declined request \(requestID.uuidString)."
            }
        } catch {
            updateAdministration(for: profile.id, generation: generation) { $0.message = "The enrollment request could not be updated: \(Self.describe(error))." }
        }
    }

    @discardableResult
    func removeNetworkMember(_ memberID: UUID) async -> Bool {
        guard let profile = selectedProfile,
              profile.localNodeID.rawValue != memberID,
              networks.first(where: { $0.id == profile.id })?.isHostingAuthority == true,
              let localAuthority else {
            statusMessage = "Only the device hosting the network authority can remove members."
            return false
        }

        do {
            try await localAuthority.removeMember(
                nodeID: NodeID(rawValue: memberID),
                reason: "Removed by network authority"
            )
            networkMembers.removeAll { $0.id == memberID }
            onlineMemberIDs.remove(memberID)
            await refreshNetworkMembers()
            statusMessage = "The device was removed from the network. A new invitation is required to join again."
            return true
        } catch {
            statusMessage = "The device could not be removed: \(Self.describe(error))."
            return false
        }
    }

    func renameOwnedNetwork(_ id: NetworkProfileID, to displayName: String) async {
        guard let profile = try? await profileRuntimeManager.profiles().first(where: { $0.id == id }),
              (try? await networkCreator.owns(profile: profile)) == true else {
            statusMessage = "Only the device that created this network can rename it."
            return
        }
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let profiles = try? await profileRuntimeManager.profiles(),
           profiles.contains(where: { $0.id != id && Self.namesCollide($0.displayName, normalizedName) }) {
            statusMessage = "A network named \(normalizedName) already exists on this device. Choose a different name."
            return
        }
        do {
            let renamedProfile = try NetworkProfile(
                id: profile.id,
                networkID: profile.networkID,
                localNodeID: profile.localNodeID,
                displayName: normalizedName,
                createdAt: profile.createdAt
            )
            try await networkCreator.rename(profile: profile, to: normalizedName)
            do {
                try await runningAuthority(for: profile)?.renameNetwork(to: normalizedName)
                try await profileRuntimeManager.rename(profile.id, to: normalizedName)
            } catch {
                try? await networkCreator.rename(profile: renamedProfile, to: profile.displayName)
                try? await runningAuthority(for: profile)?.renameNetwork(to: profile.displayName)
                throw error
            }
            if selectedProfile?.id == profile.id {
                selectedProfile = renamedProfile
                if let activeRuntime {
                    self.activeRuntime = ApplicationProfileRuntime(
                        profile: renamedProfile,
                        contextID: activeRuntime.contextID,
                        messageStoreID: activeRuntime.messageStoreID,
                        mailboxMetadataURL: activeRuntime.mailboxMetadataURL,
                        paths: activeRuntime.paths,
                        dataState: activeRuntime.dataState
                    )
                }
            }
            statusMessage = "Network renamed to \(normalizedName)."
            invitationJSON = ""
            await refreshOwnedNetworks()
        } catch {
            statusMessage = "The network could not be renamed."
        }
    }

    @discardableResult
    func resetOwnedNetworkAuthority(_ id: NetworkProfileID) async -> Bool {
        guard !authorityHostingBusy else { return false }
        authorityHostingBusy = true
        defer { authorityHostingBusy = false }
        guard let profile = try? await profileRuntimeManager.profiles().first(where: { $0.id == id }),
              selectedProfile?.id == id,
              (try? await networkCreator.owns(profile: profile)) == true,
              let activeRuntime else {
            statusMessage = "Activate this creator-owned network before resetting its authority."
            return false
        }
        do {
            let context = LAContext()
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "Reset this network’s authority and invalidate every other device")
            )
            guard authenticated else { return false }
        } catch {
            statusMessage = "The authority reset was cancelled because device-owner authentication did not complete."
            return false
        }
        guard selectedProfile?.id == id, !Task.isCancelled else { return false }
        invalidateAuthorityAdministration(id)
        state = .securing
        statusMessage = "Resetting the network authority…"
        await lanRuntimeManager.stop()
        localAuthority = nil
        do {
            let creator = networkCreator
            let configuration = try await authorityController().withStoppedAuthority(for: profile) {
                let reset = try await creator.resetAuthority(profile: profile)
                await reset.authority.stop()
                return reset.configuration
            }
            try configurationStore.save(configuration, profile: profile)
            activeConfiguration = configuration
            localAuthority = try await runningAuthority(for: profile)
            await updateAuthorityHostingStatus(profile)
            canCreateInvitations = true
            invitationJSON = ""
            networkMembers = []
            onlineMemberIDs = []
            try await startDiagnosedLANRuntime(
                configuration: configuration,
                runtime: activeRuntime,
                displayName: deviceDisplayName
            )
            state = .ready
            statusMessage = "Authority reset. Every other device needs a new invitation."
            await refreshOwnedNetworks()
            return true
        } catch {
            state = .failed
            await updateAuthorityHostingStatus(profile)
            statusMessage = "The authority reset could not complete: \(Self.describe(error))."
            return false
        }
    }

    /// Renames only this device's profile label. Network identity, credentials,
    /// authority state, and the label shown by other devices are unchanged.
    func renameLocalNetwork(_ id: NetworkProfileID, to displayName: String) async -> Bool {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            statusMessage = "Enter a network name."
            return false
        }
        guard let profiles = try? await profileRuntimeManager.profiles(),
              let profile = profiles.first(where: { $0.id == id }) else {
            statusMessage = "The network profile is unavailable."
            return false
        }
        guard (try? await networkCreator.owns(profile: profile)) == true else {
            statusMessage = "Only the device hosting this network's authority can rename it."
            return false
        }
        guard !profiles.contains(where: {
            $0.id != id && Self.namesCollide($0.displayName, normalizedName)
        }) else {
            statusMessage = "A network named \(normalizedName) already exists on this device. Choose a different name."
            return false
        }
        guard !Self.namesCollide(profile.displayName, normalizedName) else {
            return true
        }
        do {
            try await profileRuntimeManager.rename(id, to: normalizedName)
            let renamedProfile = try NetworkProfile(
                id: profile.id,
                networkID: profile.networkID,
                localNodeID: profile.localNodeID,
                displayName: normalizedName,
                createdAt: profile.createdAt
            )
            if selectedProfile?.id == id {
                selectedProfile = renamedProfile
                if let activeRuntime {
                    self.activeRuntime = ApplicationProfileRuntime(
                        profile: renamedProfile,
                        contextID: activeRuntime.contextID,
                        messageStoreID: activeRuntime.messageStoreID,
                        mailboxMetadataURL: activeRuntime.mailboxMetadataURL,
                        paths: activeRuntime.paths,
                        dataState: activeRuntime.dataState
                    )
                }
            }
            statusMessage = "This device now displays the network as \(normalizedName)."
            await refreshOwnedNetworks()
            return true
        } catch {
            statusMessage = "The network name could not be changed."
            return false
        }
    }

    func deleteOwnedNetwork(_ id: NetworkProfileID) async {
        guard !authorityHostingBusy else { return }
        authorityHostingBusy = true
        defer { authorityHostingBusy = false }
        guard let profile = try? await profileRuntimeManager.profiles().first(where: { $0.id == id }),
              (try? await networkCreator.owns(profile: profile)) == true else {
            statusMessage = "Only the device that created this network can delete it."
            return
        }
        let deletingActiveProfile = selectedProfile?.id == profile.id
        invalidateAuthorityAdministration(id)
        do {
            if deletingActiveProfile {
                await lanRuntimeManager.stop()
                localAuthority = nil
                activeConfiguration = nil
                activeRuntime = nil
            }
            let creator = networkCreator
            try await authorityController().removeAuthority(for: profile) {
                try await creator.delete(profile: profile)
            }
            authorityHostingStates.removeValue(forKey: id)
            authorityHostingEnabled.remove(id)
            authorityAdministration.removeValue(forKey: id)
            await statusPermissions?.forget(profile.id)
            try configurationStore.delete(profile: profile)
            try await profileRuntimeManager.delete(profile: profile)
            if deletingActiveProfile {
                selectedProfile = nil
                nodeID = nil
                profileID = nil
                canCreateInvitations = false
                invitationJSON = ""
                state = .needsConfiguration
                statusMessage = "Network deleted from this creator device."
            }
            await refreshOwnedNetworks()
        } catch {
            state = .failed
            statusMessage = "The network could not be deleted completely."
        }
    }

    func forgetJoinedNetwork(
        _ id: NetworkProfileID,
        dataDisposition: ForgottenNetworkDataDisposition = .keepLocalData,
        archiveReason: ContextArchiveReason? = nil
    ) async {
        guard let profile = try? await profileRuntimeManager.profiles().first(where: { $0.id == id }) else {
            statusMessage = "That network is no longer available on this device."
            return
        }
        guard (try? await networkCreator.owns(profile: profile)) != true else {
            statusMessage = "Creator-owned networks must be deleted rather than left."
            return
        }
        let leavingActiveProfile = selectedProfile?.id == profile.id
        do {
            // Forgetting is a local operation and must remain available when an
            // older or partially-installed profile has no usable lifecycle record.
            // The lifecycle transition is recovery metadata, not a prerequisite
            // for removing the profile from this device.
            try? await enrollmentRouter.prepareToLeave(profile: profile)
            if leavingActiveProfile {
                await lanRuntimeManager.stop()
                activeConfiguration = nil
                activeRuntime = nil
            }
            await statusPermissions?.forget(profile.id)
            try configurationStore.delete(profile: profile)
            switch dataDisposition {
            case .keepLocalData:
                try await profileRuntimeManager.forget(profile: profile, reason: archiveReason)
            case .deleteLocalData:
                try await profileRuntimeManager.delete(profile: profile)
            }
            if leavingActiveProfile {
                selectedProfile = nil
                nodeID = nil
                profileID = nil
                canCreateInvitations = false
                invitationJSON = ""
                networkMembers = []
                state = .needsConfiguration
            }
            statusMessage = dataDisposition == .keepLocalData
                ? "This device forgot the network and preserved its local data."
                : "This device forgot the network and deleted its local data."
            await refreshOwnedNetworks()
            if leavingActiveProfile,
               let remainingProfiles = try? await profileRuntimeManager.profiles() {
                if remainingProfiles.count == 1, let remainingProfile = remainingProfiles.first {
                    await switchNetwork(to: remainingProfile.id)
                }
            }
        } catch {
            state = .failed
            statusMessage = "This device could not leave the network completely."
        }
    }

    func deleteArchivedContext(_ id: ContextID) async {
        guard archivedContexts.contains(where: { $0.id == id }) else {
            statusMessage = "Only a preserved Context without an attached network can be deleted."
            return
        }
        do {
            try await profileRuntimeManager.deleteContext(id)
            statusMessage = "The preserved Context and all of its local data were deleted."
            await refreshOwnedNetworks()
        } catch {
            statusMessage = "The preserved Context could not be deleted completely."
        }
    }

    func switchNetwork(to id: NetworkProfileID) async {
        guard !authorityHostingBusy else { return }
        guard (try? await profileRuntimeManager.profiles().contains(where: { $0.id == id })) == true else {
            statusMessage = "That network is no longer available on this device."
            return
        }
        cancelCredentialRecovery()
        await credentialTask?.value
        credentialStatus = nil
        credentialDetails = NetworkCredentialDetails()
        explicitMessagingSelection = id
        bootstrapTraceContext = .profileSwitch
        defer { bootstrapTraceContext = nil }
        traceConnectivity("profile-switch from=\(selectedProfile?.id.rawValue.uuidString ?? "none") to=\(id.rawValue.uuidString)")
        state = .starting
        statusMessage = "Switching networks."
        await lanRuntimeManager.stop(reason: .profileSwitch)
        localAuthority = nil
        do {
            do {
                try await profileRuntimeManager.stop()
            } catch ActiveProfileRuntimeError.runtimeNotActive {
                // The model and runtime manager can legitimately both be idle.
                // Always asking the manager to stop avoids leaving a stale
                // active runtime behind after a removal or failed startup.
            }
            try await profileRuntimeManager.activate(id)
            selectedProfile = nil
            activeConfiguration = nil
            activeRuntime = nil
            canCreateInvitations = false
            invitationJSON = ""
            networkMembers = []
            hasStarted = false
            await start(reason: .profileSwitch)
            if state == .ready {
                networkSessions.first { $0.id == id }?.clearLastError()
            } else {
                await refreshOwnedNetworks()
                networkSessions.first { $0.id == id }?.recordLastError(statusMessage)
            }
        } catch {
            state = .failed
            activeNetworkConnectivity = .failed
            statusMessage = "The selected network could not be activated: \(Self.describe(error))."
            await refreshOwnedNetworks()
            networkSessions.first { $0.id == id }?.recordLastError(statusMessage)
        }
    }

    func useExistingNetwork(_ id: NetworkProfileID) async {
        networkJoinAlert = nil
        if selectedProfile?.id == id {
            await reconnectActiveNetwork()
        } else {
            await switchNetwork(to: id)
        }
        let recovered = state == .ready
        networkJoinAlert = NetworkJoinAlert(
            succeeded: recovered,
            title: recovered ? "Using Existing Network" : "Existing Network Needs Attention",
            message: recovered
                ? "\(activeNetworkName ?? "The saved network") is active and its connection has been refreshed."
                : statusMessage
        )
    }

    func repairExistingNetwork(
        using review: InvitationReview,
        profileID: NetworkProfileID
    ) async -> NetworkJoinAlert {
        let repairAttemptID = UUID()
        traceInvitationUI(
            "repair-begin attempt=\(repairAttemptID) invitation=\(review.id) targetProfile=\(profileID.rawValue.uuidString)"
        )
        state = .joiningNetwork
        statusMessage = "Verifying the authority and repairing the existing network profile."
        var credentialAccepted = false
        do {
            guard let data = review.invitationJSON.data(using: .utf8) else {
                throw NetworkInvitationError.invalidConfiguration
            }
            if let enrollmentInvitation = try? EnrollmentWireCodec.decode(
                EnrollmentInvitation.self,
                from: data
            ) {
                traceInvitationUI("repair-release-invitation attempt=\(repairAttemptID)")
                await joinReleaseNetwork(enrollmentInvitation)
                let outcome = networkJoinAlert ?? NetworkJoinAlert(
                    succeeded: false,
                    title: "Repair Needs Attention",
                    message: statusMessage,
                    invitationAccepted: false,
                    connectivity: activeNetworkConnectivity
                )
                networkJoinAlert = nil
                traceInvitationUI(
                    "repair-release-finished attempt=\(repairAttemptID) accepted=\(outcome.invitationAccepted) succeeded=\(outcome.succeeded)"
                )
                return outcome
            }
            let invitation = try NetworkInvitationWireCodec.decode(data)
            guard !review.isExpired() else { throw NetworkInvitationError.expired }
            guard let profile = try await profileRuntimeManager.profiles().first(where: { $0.id == profileID }),
                  profile.networkID == invitation.networkID,
                  let savedConfiguration = try configurationStore.load(profile: profile),
                  savedConfiguration.networkID == invitation.networkID,
                  savedConfiguration.authorityPublicKey == invitation.authorityPublicKey,
                  savedConfiguration.credential.claims.issuerID == invitation.authorityID else {
                throw NodeBootstrapError.invitationAuthorityMismatch
            }


            let namespace = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profile.id)
            let identity = try KeychainNodeIdentityStore(namespace: namespace).loadOrCreate()
            guard identity.nodeID == profile.localNodeID else {
                throw NodeBootstrapError.profileIdentityMismatch
            }
            let transport = try makeAuthorityDiscoveryTransport(
                profileID: profileID, networkID: invitation.networkID,
                publicKey: invitation.authorityPublicKey, environment: invitation.environment,
                certificate: invitation.authorityCertificateDER
            )
            traceInvitationUI("repair-authority-request attempt=\(repairAttemptID)")
            let credential = try await NetworkInvitationClient(transport: transport).join(
                invitation: invitation,
                identity: identity
            )
            credentialAccepted = true
            traceInvitationUI("repair-authority-accepted attempt=\(repairAttemptID)")
            let repairedConfiguration = DevelopmentAuthorityConfiguration(
                controlPlaneURL: invitation.controlPlaneURL,
                networkID: invitation.networkID,
                authorityPublicKey: invitation.authorityPublicKey,
                authorityCertificateDER: invitation.authorityCertificateDER,
                credential: credential
            )

            stopObservingAuthenticatedPeers()
            stopObservingLocalNetwork()
            await lanRuntimeManager.stop()
            try await profileRuntimeManager.stop()
            try await profileRuntimeManager.activate(profileID)
            try configurationStore.save(repairedConfiguration, profile: profile)
            try KeychainLANTLSIdentityStore(namespace: namespace).delete()

            let runtime = try await profileRuntimeManager.start(profile: profile)
            selectedProfile = profile
            activeConfiguration = repairedConfiguration
            activeRuntime = runtime
            localAuthority = nil
            canCreateInvitations = Self.verifiedAuthorization(
                profile: profile,
                configuration: repairedConfiguration,
                isHostingAuthority: false
            )?.capabilities.contains(.manageNetwork) == true
            controlPlaneURL = invitation.controlPlaneURL.absoluteString
            authorityPublicKeyBase64 = invitation.authorityPublicKey.base64EncodedString()
            authorityCertificateBase64 = invitation.authorityCertificateDER.base64EncodedString()
            state = .identityReady
            statusMessage = "Membership repaired. Refreshing trust and reconnecting."
            await enrollAndRecoverTrust()

            if state == .ready {
                statusMessage = "Network profile repaired. Refreshing the connection."
                await reconnectActiveNetwork()
            }

            let recovered = state == .ready && activeNetworkConnectivity != .failed
            traceInvitationUI(
                "repair-finished attempt=\(repairAttemptID) recovered=\(recovered) connectivity=\(activeNetworkConnectivity)", level: recovered ? .recovered : .failure
            )
            return NetworkJoinAlert(
                succeeded: recovered,
                title: repairResultTitle(recovered: recovered),
                message: repairResultMessage(for: profile.displayName, recovered: recovered),
                invitationAccepted: true,
                connectivity: activeNetworkConnectivity
            )
        } catch {
            traceInvitationUI(
                "repair-failed attempt=\(repairAttemptID) credentialAccepted=\(credentialAccepted) errorType=\(String(reflecting: type(of: error))) domain=\((error as NSError).domain) code=\((error as NSError).code)", level: .failure
            )
            joinInvitationJSON = ""
            let outcome = NetworkJoinAlert(
                succeeded: false,
                title: credentialAccepted ? "Repair Needs Attention" : "Unable to Repair Network",
                message: credentialAccepted
                    ? "The authority accepted the invitation, but local recovery did not finish. Restart Beakr to continue safely."
                    : Self.describe(error),
                invitationAccepted: credentialAccepted
            )
            if credentialAccepted {
                state = .failed
                statusMessage = "The repaired membership was saved but could not start. Restart to recover it safely."
            } else {
                state = activeRuntime == nil ? .needsConfiguration : .ready
                statusMessage = "The existing network was not changed."
            }
            return outcome
        }
    }

    func joinNetwork() async {
        if let data = joinInvitationJSON.data(using: .utf8),
           let invitation = try? EnrollmentWireCodec.decode(EnrollmentInvitation.self, from: data) {
            await joinReleaseNetwork(invitation)
            return
        }
        state = .joiningNetwork
        statusMessage = "Verifying the invitation and requesting this device’s credential."
        let profileID = NetworkProfileID()
        let namespace = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profileID)
        let identityStore = KeychainNodeIdentityStore(namespace: namespace)
        var configurationSaved = false
        do {
            guard let data = joinInvitationJSON.data(using: .utf8) else {
                throw NetworkInvitationError.invalidConfiguration
            }
            let invitation = try NetworkInvitationWireCodec.decode(data)
            let existingProfiles = try await profileRuntimeManager.profiles()
            if let existing = existingProfiles.first(where: { $0.networkID == invitation.networkID }) {
                joinInvitationJSON = ""
                state = activeRuntime == nil ? .needsConfiguration : .ready
                statusMessage = "This Beakr'Net is already saved on this device."
                networkJoinAlert = NetworkJoinAlert(
                    succeeded: false,
                    title: "Network Already Added",
                    message: "\(existing.displayName) already represents this Network ID. Use the existing network instead of consuming a new invitation.",
                    existingProfileID: existing.id
                )
                return
            }
            if approvedReattachmentNetworkID != invitation.networkID,
               let existingContext = try await profileRuntimeManager.context(networkID: invitation.networkID),
               existingContext.attachedProfileIDs.isEmpty {
                state = activeRuntime == nil ? .needsConfiguration : .ready
                statusMessage = "Join paused to confirm reconnecting preserved data."
                networkJoinAlert = NetworkJoinAlert(
                    succeeded: false,
                    title: "Reconnect Preserved Context?",
                    message: "Beakr preserved the messages and data stores for \(existingContext.displayName) when its network profile was forgotten. Reconnecting will attach this invitation to that existing Context; no stored data will be deleted.",
                    invitationNetworkID: invitation.networkID,
                    reattachmentContextID: existingContext.id
                )
                return
            }
            if approvedCollidingNetworkID != invitation.networkID,
               let existing = existingProfiles.first(where: {
                   $0.networkID != invitation.networkID &&
                   Self.namesCollide($0.displayName, invitation.networkDisplayName)
               }) {
                let shortID = invitation.networkID.rawValue.uuidString.prefix(4)
                let suggestedName = "\(invitation.networkDisplayName) (\(shortID))"
                state = activeRuntime == nil ? .needsConfiguration : .ready
                statusMessage = "Join paused because the network name is already used on this device."
                networkJoinAlert = NetworkJoinAlert(
                    succeeded: false,
                    title: "Network Name Already Used",
                    message: "Existing \(existing.displayName): \(existing.networkID.rawValue.uuidString)\nInvitation: \(invitation.networkID.rawValue.uuidString)",
                    suggestedName: suggestedName,
                    invitationNetworkID: invitation.networkID
                )
                return
            }
            let joinedDisplayName = collidingNetworkDisplayName ?? invitation.networkDisplayName
            approvedCollidingNetworkID = nil
            collidingNetworkDisplayName = nil
            approvedReattachmentNetworkID = nil
            let identity = try identityStore.loadOrCreate()
            let transport = try makeAuthorityDiscoveryTransport(
                profileID: profileID, networkID: invitation.networkID,
                publicKey: invitation.authorityPublicKey, environment: invitation.environment,
                certificate: invitation.authorityCertificateDER
            )
            let joinResult = try await NetworkInvitationClient(transport: transport).joinResult(
                invitation: invitation,
                identity: identity
            )
            let credential = joinResult.credential
            let profile = try NetworkProfile(
                id: profileID,
                networkID: invitation.networkID,
                localNodeID: identity.nodeID,
                displayName: joinedDisplayName
            )
            let configuration = DevelopmentAuthorityConfiguration(
                controlPlaneURL: invitation.controlPlaneURL,
                networkID: invitation.networkID,
                authorityPublicKey: invitation.authorityPublicKey,
                authorityCertificateDER: invitation.authorityCertificateDER,
                credential: credential
            )
            try configurationStore.save(configuration, profile: profile)
            configurationSaved = true
            if activeRuntime != nil {
                await lanRuntimeManager.stop()
                try await profileRuntimeManager.stop()
                localAuthority = nil
                activeRuntime = nil
                activeConfiguration = nil
                canCreateInvitations = false
                networkMembers = []
            }
            try await profileRuntimeManager.addAndActivate(profile)
            let runtime = try await profileRuntimeManager.start(profile: profile)
            selectedProfile = profile
            activeConfiguration = configuration
            activeRuntime = runtime
            await refreshOwnedNetworks()
            nodeID = identity.nodeID.rawValue
            self.profileID = profileID.rawValue
            controlPlaneURL = invitation.controlPlaneURL.absoluteString
            networkIDText = invitation.networkID.rawValue.uuidString
            authorityPublicKeyBase64 = invitation.authorityPublicKey.base64EncodedString()
            authorityCertificateBase64 = invitation.authorityCertificateDER.base64EncodedString()
            joinInvitationJSON = ""
            state = .identityReady
            statusMessage = "Joined the network. Securing this device."
            let enrollmentTimestamp = Int64(
                (Date().timeIntervalSince1970 * 1_000).rounded(.down)
            )
            try await enrollmentRouter.prepareMembershipInstallation(
                profile: profile,
                configuration: configuration,
                runtime: runtime,
                kind: .joinNetwork,
                pendingEnrollment: PendingEnrollment(
                    invitationID: invitation.invitationID,
                    requestID: joinResult.request.requestID,
                    networkID: invitation.networkID,
                    expectedAuthorityID: invitation.authorityID,
                    localNodeID: identity.nodeID,
                    createdAtMilliseconds: min(enrollmentTimestamp, invitation.issuedAtMilliseconds),
                    expiresAtMilliseconds: invitation.expiresAtMilliseconds,
                    status: .approved
                )
            )
            await enrollAndRecoverTrust()
            let connectionReady = state == .ready
            networkJoinAlert = NetworkJoinAlert(
                succeeded: connectionReady,
                title: connectionReady ? "Network Joined" : "Network Joined — Setup Incomplete",
                message: connectionReady
                    ? "Joined and activated \(profile.displayName).\nNetwork ID: \(profile.networkID.rawValue.uuidString)"
                    : "Joined \(profile.displayName), but secure messaging is not ready.\nNetwork ID: \(profile.networkID.rawValue.uuidString)\n\(statusMessage)",
                invitationAccepted: true
            )
        } catch {
            joinInvitationJSON = ""
            approvedCollidingNetworkID = nil
            collidingNetworkDisplayName = nil
            approvedReattachmentNetworkID = nil
            networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: "Unable to Join Network",
                message: Self.describe(error)
            )
            if configurationSaved {
                state = .failed
                statusMessage = "The joined profile was saved but could not start. Restart to recover it safely."
            } else {
                try? identityStore.delete()
                state = .needsConfiguration
                statusMessage = "The invitation was rejected or could not reach its authority: \(Self.describe(error))."
            }
        }
    }

    private func joinReleaseNetwork(_ invitation: EnrollmentInvitation) async {
        networkJoinAlert = nil
        state = .joiningNetwork
        statusMessage = "Submitting this device for administrator approval."
        let existingProfile = try? await profileRuntimeManager.profiles().first {
            $0.networkID == invitation.networkID
        }
        let profileID = existingProfile?.id ?? NetworkProfileID()
        let namespace = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profileID)
        let identityStore = KeychainNodeIdentityStore(namespace: namespace)
        var profileAdded = false
        var joiningPersisted = false
        do {
            try EnrollmentWireVerifier.verifyInvitation(
                invitation,
                now: Date(),
                allowedClockSkew: 60
            )
            guard let controlPlaneURL = invitation.controlPlaneURL else {
                throw EnrollmentWireError.invalidField
            }
            let identity = try identityStore.loadOrCreate()
            let profile = try existingProfile ?? NetworkProfile(
                id: profileID,
                networkID: invitation.networkID,
                localNodeID: identity.nodeID,
                displayName: invitation.networkDisplayName
            )
            guard profile.localNodeID == identity.nodeID else {
                throw NodeBootstrapError.profileIdentityMismatch
            }

            stopObservingAuthenticatedPeers()
            stopObservingLocalNetwork()
            await lanRuntimeManager.stop()
            do {
                try await profileRuntimeManager.stop()
            } catch ActiveProfileRuntimeError.runtimeNotActive {
                // No saved network is a valid starting point for joining.
            }
            activeRuntime = nil
            activeConfiguration = nil
            if existingProfile == nil {
                try await profileRuntimeManager.addAndActivate(profile)
                profileAdded = true
            } else {
                try await profileRuntimeManager.activate(profile.id)
            }
            selectedProfile = profile
            await refreshOwnedNetworks()

            if existingProfile != nil,
               try await resumePendingReleaseEnrollment(profile: profile, replacingWith: invitation) {
                return
            }

            let paths = try await profileRuntimeManager.runtimePaths(for: profile)
            let lifecycleStore = try PersistentEnrollmentLifecycleStore.open(
                fileURL: paths.rootURL.appendingPathComponent("enrollment/lifecycle.json")
            )
            let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
            let previousLifecycle = await lifecycleStore.load()
            let lifecycleRecord = try EnrollmentLifecycleRecord(
                installationID: profile.id.rawValue,
                phase: .identityReady,
                nodeID: identity.nodeID,
                createdAtMilliseconds: previousLifecycle?.createdAtMilliseconds ?? now,
                updatedAtMilliseconds: now
            )
            if let previousLifecycle {
                try await lifecycleStore.save(
                    lifecycleRecord,
                    condition: .revision(previousLifecycle.revision)
                )
            } else {
                try await lifecycleStore.save(lifecycleRecord, condition: .create)
            }
            let joiningURL = paths.rootURL.appendingPathComponent("enrollment/joining.json")
            if existingProfile != nil {
                try? FileManager.default.removeItem(at: joiningURL)
            }
            let enrollmentStore = try PersistentJoiningEnrollmentStore.open(fileURL: joiningURL)
            let coordinator = JoiningEnrollmentCoordinator(
                lifecycleStore: lifecycleStore,
                enrollmentStore: enrollmentStore,
                membershipInstaller: ApplicationJoiningMembershipInstaller(
                    profile: profile,
                    paths: paths,
                    controlPlaneURL: controlPlaneURL,
                    authorityPublicKey: invitation.authorityPublicKey,
                    authorityCertificateDER: invitation.authorityCertificateDER,
                    configurationStore: configurationStore
                ),
                allowedClockSkew: 60,
                makeNonce: Self.randomEnrollmentNonce
            )
            let request = try await coordinator.beginJoining(
                invitation: invitation,
                identity: identity,
                deviceDisplayName: deviceDisplayName
            )

            joiningPersisted = true
            nodeID = identity.nodeID.rawValue
            self.profileID = profile.id.rawValue
            networkIDText = profile.networkID.rawValue.uuidString
            self.controlPlaneURL = controlPlaneURL.absoluteString
            authorityPublicKeyBase64 = invitation.authorityPublicKey.base64EncodedString()
            authorityCertificateBase64 = invitation.authorityCertificateDER?.base64EncodedString() ?? ""
            joinInvitationJSON = ""

            let client = EnrollmentRequestHTTPClient(
                transport: try makeAuthorityDiscoveryTransport(
                    profileID: profile.id, networkID: invitation.networkID,
                    publicKey: invitation.authorityPublicKey, environment: invitation.environment,
                    certificate: invitation.authorityCertificateDER
                )
            )
            await recoverReleaseEnrollment(
                request: request,
                profile: profile,
                identity: identity,
                coordinator: coordinator,
                client: client,
                preserveExistingProfile: existingProfile != nil
            )
        } catch {
            traceInvitationUI(
                "release-enrollment-failed invitation=\(invitation.invitationID) joiningPersisted=\(joiningPersisted) errorType=\(String(reflecting: type(of: error))) domain=\((error as NSError).domain) code=\((error as NSError).code) description=\(Self.describe(error))", level: .failure
            )
            enrollmentPollingTask?.cancel()
            if joiningPersisted {
                hasPendingJoiningRequest = true
                state = .failed
                activeNetworkConnectivity = .failed
                statusMessage = "Joining could not resume: \(Self.describe(error)). The saved request has been retained."
                networkJoinAlert = NetworkJoinAlert(
                    succeeded: false,
                    title: "Unable to Resume Join",
                    message: statusMessage,
                    invitationAccepted: true
                )
                return
            }
            if profileAdded, let profile = selectedProfile, profile.id == profileID {
                try? await profileRuntimeManager.delete(profile: profile)
                selectedProfile = nil
            }
            if existingProfile == nil {
                try? identityStore.delete()
            }
            state = existingProfile == nil ? .needsConfiguration : .identityReady
            statusMessage = "The enrollment request could not be submitted: \(Self.describe(error))."
            networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: existingProfile == nil ? "Unable to Request Access" : "Unable to Repair Network",
                message: Self.describe(error)
            )
        }
    }

    /// Uses the durable request for both initial submission and recovery after restart.
    private func recoverReleaseEnrollment(
        request: EnrollmentRequest,
        profile: NetworkProfile,
        identity: NodeIdentity,
        coordinator: JoiningEnrollmentCoordinator,
        client: EnrollmentRequestHTTPClient,
        preserveExistingProfile: Bool = false
    ) async {
        enrollmentPollingTask?.cancel()
        hasPendingJoiningRequest = true
        activeNetworkConnectivity = .reconnecting
        do {
            let status = try await client.resume(request)
            guard !Task.isCancelled, selectedProfile?.id == profile.id else { return }
            await handleReleaseEnrollmentStatus(
                status, profile: profile, identity: identity, coordinator: coordinator,
                client: client, preserveExistingProfile: preserveExistingProfile
            )
        } catch {
            guard !Task.isCancelled, selectedProfile?.id == profile.id else { return }
            guard reportEnrollmentFailure(error, requestID: request.requestID) else { return }
            networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: "Request Saved",
                message: statusMessage,
                invitationAccepted: true
            )
            // Retry the same signed request, never regenerate identity, nonce, or invitation.
            enrollmentPollingTask = Task { [weak self] in
                var delay = 2
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(delay))
                        guard let self, self.selectedProfile?.id == profile.id else { return }
                        let status = try await client.resume(request)
                        guard !Task.isCancelled, self.selectedProfile?.id == profile.id else { return }
                        await self.handleReleaseEnrollmentStatus(
                            status, profile: profile, identity: identity, coordinator: coordinator,
                            client: client, preserveExistingProfile: preserveExistingProfile
                        )
                        return
                    } catch {
                        guard !Task.isCancelled, let self,
                              self.selectedProfile?.id == profile.id else { return }
                        guard self.reportEnrollmentFailure(error, requestID: request.requestID) else { return }
                        delay = min(delay * 2, 30)
                    }
                }
            }
        }
    }

    /// Returns true only for failures that can recover without changing the request.
    private func reportEnrollmentFailure(_ error: Error, requestID: UUID) -> Bool {
        let retryable: Bool
        if let httpError = error as? EnrollmentRequestHTTPError {
            retryable = httpError.isRetryable
        } else if let urlError = error as? URLError {
            retryable = [
                .timedOut, .cannotFindHost, .cannotConnectToHost,
                .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet
            ].contains(urlError.code)
        } else {
            retryable = false
        }
        traceInvitationUI(
            "enrollment-recovery-failed request=\(requestID) retryable=\(retryable) description=\(Self.describe(error))", level: retryable ? .retry : .failure
        )
        hasPendingJoiningRequest = true
        state = retryable ? .identityReady : .failed
        activeNetworkConnectivity = retryable ? .reconnecting : .failed
        statusMessage = retryable
            ? "The saved join request will retry automatically. \(Self.describe(error))"
            : "Joining needs attention. \(Self.describe(error)) The saved request has been retained."
        if !retryable {
            networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: "Unable to Complete Join",
                message: statusMessage,
                invitationAccepted: true
            )
        }
        return retryable
    }

    private func handleReleaseEnrollmentStatus(
        _ status: EnrollmentRequestStatus,
        profile: NetworkProfile,
        identity: NodeIdentity,
        coordinator: JoiningEnrollmentCoordinator,
        client: EnrollmentRequestHTTPClient,
        preserveExistingProfile: Bool = false
    ) async {
        switch status {
        case .approved(let approval):
            hasPendingJoiningRequest = false
            do {
                let joined = try await coordinator.receiveApproval(approval, identity: identity)
                do {
                    try await client.confirm(joined.confirmation)
                    try await coordinator.acknowledgeConfirmation(
                        requestID: joined.confirmation.requestID
                    )
                } catch {
                    // The durable outbox retries this acknowledgement after restart.
                }
                try await activateApprovedReleaseEnrollment(profile: profile)
                if state == .ready {
                    networkJoinAlert = NetworkJoinAlert(
                        succeeded: true,
                        title: preserveExistingProfile ? "Network Rejoined" : "Network Joined",
                        message: "\(profile.displayName) is active on this device.",
                        invitationAccepted: true,
                        connectivity: activeNetworkConnectivity
                    )
                }
            } catch {
                state = .failed
                statusMessage = "Approved membership could not be installed: \(Self.describe(error))."
                networkJoinAlert = NetworkJoinAlert(
                    succeeded: false,
                    title: "Approval Installed — Setup Incomplete",
                    message: Self.describe(error),
                    invitationAccepted: true
                )
            }
        case .pending(let requestID):
            hasPendingJoiningRequest = true
            state = .identityReady
            statusMessage = "Waiting for a network administrator to approve this device."
            networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: "Awaiting Approval",
                message: "A network administrator must approve this device before it can finish joining. Request \(requestID.uuidString).",
                invitationAccepted: true
            )
            enrollmentPollingTask?.cancel()
            enrollmentPollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, self?.selectedProfile?.id == profile.id else { return }
                    do {
                        let next = try await client.status(requestID: requestID)
                        guard !Task.isCancelled, self?.selectedProfile?.id == profile.id else { return }
                        if case .pending = next {
                            self?.state = .identityReady
                            self?.statusMessage = "Waiting for a network administrator to approve this device."
                        }
                        if case .approved = next {
                            await self?.handleReleaseEnrollmentStatus(
                                next,
                                profile: profile,
                                identity: identity,
                                coordinator: coordinator,
                                client: client,
                                preserveExistingProfile: preserveExistingProfile
                            )
                            return
                        }
                        if case .rejected = next {
                            await self?.handleReleaseEnrollmentStatus(
                                next,
                                profile: profile,
                                identity: identity,
                                coordinator: coordinator,
                                client: client,
                                preserveExistingProfile: preserveExistingProfile
                            )
                            return
                        }
                    } catch {
                        guard !Task.isCancelled, let self,
                              self.selectedProfile?.id == profile.id else { return }
                        guard self.reportEnrollmentFailure(error, requestID: requestID) else { return }
                    }
                }
            }
        case .rejected(let rejection):
            hasPendingJoiningRequest = false
            do {
                try await coordinator.receiveRejection(rejection)
                enrollmentPollingTask?.cancel()
                enrollmentPollingTask = nil
                if !preserveExistingProfile {
                    try await removeIncompleteJoiningProfile(profile)
                }
                state = preserveExistingProfile ? .identityReady : .needsConfiguration
                let expired = rejection.reason == .expiredInvitation
                statusMessage = expired
                    ? "The enrollment request expired before it was approved."
                    : "A network administrator declined this enrollment request."
                networkJoinAlert = NetworkJoinAlert(
                    succeeded: false,
                    title: preserveExistingProfile
                        ? "Unable to Repair Network"
                        : (expired ? "Request Expired" : "Request Declined"),
                    message: expired
                        ? "This device was not added to the network. Ask a network manager for a new invitation."
                        : "This device was not added to the network. You can retry with another invitation."
                )
            } catch {
                state = .failed
                statusMessage = "The signed rejection could not be verified: \(Self.describe(error))."
            }
        }
    }

    func cancelPendingNetworkJoin() async {
        guard hasPendingJoiningRequest, let profile = selectedProfile else { return }
        enrollmentPollingTask?.cancel()
        enrollmentPollingTask = nil

        do {
            let paths = try await profileRuntimeManager.runtimePaths(for: profile)
            let lifecycleStore = try PersistentEnrollmentLifecycleStore.open(
                fileURL: paths.rootURL.appendingPathComponent("enrollment/lifecycle.json")
            )
            let enrollmentStore = try PersistentJoiningEnrollmentStore.open(
                fileURL: paths.rootURL.appendingPathComponent("enrollment/joining.json")
            )
            guard let record = await lifecycleStore.load(),
                  let requestID = record.pendingEnrollment?.requestID,
                  let request = await enrollmentStore.request(id: requestID),
                  let controlPlaneURL = request.invitation.controlPlaneURL else {
                throw JoiningEnrollmentError.invalidRecoveryCheckpoint
            }
            let namespace = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profile.id)
            guard let identity = try KeychainNodeIdentityStore(namespace: namespace).load() else {
                throw JoiningEnrollmentError.invalidRecoveryCheckpoint
            }
            let cancellation = try EnrollmentWireSigner.cancellation(
                request: request,
                identity: identity
            )
            let client = EnrollmentRequestHTTPClient(
                transport: try makeAuthorityDiscoveryTransport(
                    profileID: profile.id, networkID: request.invitation.networkID,
                    publicKey: request.invitation.authorityPublicKey, environment: request.invitation.environment,
                    certificate: request.invitation.authorityCertificateDER
                )
            )
            try await client.cancel(cancellation)

            let coordinator = JoiningEnrollmentCoordinator(
                lifecycleStore: lifecycleStore,
                enrollmentStore: enrollmentStore,
                membershipInstaller: ApplicationJoiningMembershipInstaller(
                    profile: profile,
                    paths: paths,
                    controlPlaneURL: controlPlaneURL,
                    authorityPublicKey: request.invitation.authorityPublicKey,
                    authorityCertificateDER: request.invitation.authorityCertificateDER,
                    configurationStore: configurationStore
                ),
                allowedClockSkew: 60,
                makeNonce: Self.randomEnrollmentNonce
            )
            try await coordinator.cancelJoining()

            try await removeIncompleteJoiningProfile(profile)
            state = .needsConfiguration
            statusMessage = "The enrollment request was cancelled. You can use another invitation."
            networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: "Request Cancelled",
                message: "This device will ignore any later decision for the cancelled request. You can now join with another invitation."
            )
        } catch {
            hasPendingJoiningRequest = true
            state = .identityReady
            statusMessage = "The pending request could not be cancelled safely: \(Self.describe(error))."
            networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: "Unable to Cancel Request",
                message: Self.describe(error)
            )
        }
    }

    private func removeIncompleteJoiningProfile(_ profile: NetworkProfile) async throws {
        stopObservingAuthenticatedPeers()
        stopObservingLocalNetwork()
        await lanRuntimeManager.stop()
        try await profileRuntimeManager.stop()
        await statusPermissions?.forget(profile.id)
        try await profileRuntimeManager.delete(profile: profile)
        try? KeychainNodeIdentityStore(
            namespace: ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profile.id)
        ).delete()

        if selectedProfile?.id == profile.id {
            selectedProfile = nil
            activeConfiguration = nil
            activeRuntime = nil
            nodeID = nil
            profileID = nil
            networkIDText = ""
            controlPlaneURL = ""
            authorityPublicKeyBase64 = ""
            authorityCertificateBase64 = ""
        }
        hasPendingJoiningRequest = false
        await refreshOwnedNetworks()
    }

    private func activateApprovedReleaseEnrollment(profile: NetworkProfile) async throws {
        guard let configuration = try configurationStore.load(profile: profile) else {
            throw ApplicationEnrollmentInstallationError.bindingMismatch
        }
        stopObservingAuthenticatedPeers()
        stopObservingLocalNetwork()
        await lanRuntimeManager.stop()
        do {
            try await profileRuntimeManager.stop()
        } catch ActiveProfileRuntimeError.runtimeNotActive {
            // Approval can arrive before this pending profile has ever been started.
        }
        activeRuntime = nil
        let runtime = try await profileRuntimeManager.start(profile: profile)
        selectedProfile = profile
        activeConfiguration = configuration
        activeRuntime = runtime
        state = .identityReady
        statusMessage = "Membership approved. Securing this device."
        await refreshOwnedNetworks()
        await enrollAndRecoverTrust()
        if state == .ready {
            // The active green network on the app root page is sufficient
            // confirmation; reserve alerts for outcomes requiring attention.
            networkJoinAlert = nil
        } else {
            networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: "Approval Installed — Setup Incomplete",
                message: statusMessage,
                invitationAccepted: true
            )
        }
    }

    private func flushPendingEnrollmentConfirmations(
        profile: NetworkProfile,
        configuration: DevelopmentAuthorityConfiguration
    ) async {
        guard let paths = try? await profileRuntimeManager.runtimePaths(for: profile),
              let store = try? PersistentJoiningEnrollmentStore.open(
                fileURL: paths.rootURL.appendingPathComponent("enrollment/joining.json")
              ),
              let client = try? EnrollmentRequestHTTPClient(
                transport: configuration.makeTransport(profileID: profile.id)
              ) else {
            return
        }
        let confirmations = await store.pendingConfirmations()
        traceConnectivity("startup-pending-confirmations count=\(confirmations.count)")
        for confirmation in confirmations {
            traceConnectivity("startup-confirmation-send-begin")
            do {
                try await client.confirm(confirmation)
                try await store.discardConfirmation(requestID: confirmation.requestID)
                traceConnectivity("startup-confirmation-send-end")
            } catch {
                traceConnectivity("startup-confirmation-send-error type=\(String(reflecting: type(of: error))) code=\((error as NSError).code) domain=\((error as NSError).domain)", level: .retry)
                return
            }
        }
    }

    private func resumePendingReleaseEnrollment(
        profile: NetworkProfile,
        replacingWith invitation: EnrollmentInvitation? = nil
    ) async throws -> Bool {
        let paths = try await profileRuntimeManager.runtimePaths(for: profile)
        let lifecycleStore = try PersistentEnrollmentLifecycleStore.open(
            fileURL: paths.rootURL.appendingPathComponent("enrollment/lifecycle.json")
        )
        guard let record = await lifecycleStore.load(),
              record.phase == .joining || record.phase == .installingMembership else {
            return false
        }
        let enrollmentStore = try PersistentJoiningEnrollmentStore.open(
            fileURL: paths.rootURL.appendingPathComponent("enrollment/joining.json")
        )
        guard let request = await enrollmentStore.request(
            id: record.pendingEnrollment?.requestID ?? UUID()
        ), let controlPlaneURL = request.invitation.controlPlaneURL else {
            throw JoiningEnrollmentError.invalidRecoveryCheckpoint
        }
        let namespace = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profile.id)
        guard let identity = try KeychainNodeIdentityStore(namespace: namespace).load() else {
            throw JoiningEnrollmentError.invalidRecoveryCheckpoint
        }
        let coordinator = JoiningEnrollmentCoordinator(
            lifecycleStore: lifecycleStore,
            enrollmentStore: enrollmentStore,
            membershipInstaller: ApplicationJoiningMembershipInstaller(
                profile: profile,
                paths: paths,
                controlPlaneURL: controlPlaneURL,
                authorityPublicKey: request.invitation.authorityPublicKey,
                authorityCertificateDER: request.invitation.authorityCertificateDER,
                configurationStore: configurationStore
            ),
            allowedClockSkew: 60,
            makeNonce: Self.randomEnrollmentNonce
        )
        if record.phase == .installingMembership {
            // Approval was durably saved before configuration existed. Replay that
            // transaction locally instead of polling or creating another join request.
            enrollmentPollingTask?.cancel()
            enrollmentPollingTask = nil
            _ = try await coordinator.resumeMembershipInstallation(identity: identity)
            guard !Task.isCancelled, selectedProfile?.id == profile.id else { return true }
            hasPendingJoiningRequest = false
            try await activateApprovedReleaseEnrollment(profile: profile)
            if let configuration = try configurationStore.load(profile: profile) {
                await flushPendingEnrollmentConfirmations(profile: profile, configuration: configuration)
            }
            return true
        }
        let client = EnrollmentRequestHTTPClient(
            transport: try makeAuthorityDiscoveryTransport(
                profileID: profile.id, networkID: request.invitation.networkID,
                publicKey: request.invitation.authorityPublicKey, environment: request.invitation.environment,
                certificate: request.invitation.authorityCertificateDER
            )
        )
        if let invitation {
            enrollmentPollingTask?.cancel()
            enrollmentPollingTask = nil
            if try await coordinator.prepareReplacementInvitation(
                invitation,
                identity: identity,
                cancelRequest: { cancellation in try await client.cancel(cancellation) }
            ) {
                hasPendingJoiningRequest = false
                return false
            }
        }
        activeRuntime = try await profileRuntimeManager.start(profile: profile)
        await recoverReleaseEnrollment(
            request: request,
            profile: profile,
            identity: identity,
            coordinator: coordinator,
            client: client
        )
        return true
    }

    nonisolated private static func randomEnrollmentNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    func confirmCollidingNetworkJoin() async {
        guard let alert = networkJoinAlert,
              let invitationNetworkID = alert.invitationNetworkID,
              let suggestedName = alert.suggestedName else { return }
        networkJoinAlert = nil
        approvedCollidingNetworkID = invitationNetworkID
        collidingNetworkDisplayName = suggestedName
        await joinNetwork()
    }

    func confirmContextReattachment() async {
        guard let alert = networkJoinAlert,
              alert.reattachmentContextID != nil,
              let invitationNetworkID = alert.invitationNetworkID else { return }
        networkJoinAlert = nil
        approvedReattachmentNetworkID = invitationNetworkID
        await joinNetwork()
    }

    func saveDevelopmentConfiguration() async {
        do {
            let configuration = try configuration()
            let profileID = selectedProfile?.id ?? NetworkProfileID()
            let restoredNodeID = try identityLoader.loadOrCreateNodeID(profileID: profileID)
            let profile: NetworkProfile
            if let selectedProfile {
                guard selectedProfile.networkID == configuration.networkID,
                      selectedProfile.localNodeID == restoredNodeID else {
                    throw NodeBootstrapError.activeProfileMismatch
                }
                profile = selectedProfile
            } else {
                profile = try NetworkProfile(
                    id: profileID,
                    networkID: configuration.networkID,
                    localNodeID: restoredNodeID,
                    displayName: "Primary Network"
                )
                selectedProfile = profile
            }
            nodeID = restoredNodeID.rawValue
            self.profileID = profileID.rawValue
            try validate(configuration, nodeID: restoredNodeID)
            try configurationStore.save(configuration, profile: profile)
            let runtime = try await profileRuntimeManager.start(profile: profile)
            credentialJSON = ""
            activeRuntime = runtime
            self.profileID = runtime.profile.id.rawValue
            activeConfiguration = configuration
            state = .identityReady
            statusMessage = "Securing this device."
            await enrollAndRecoverTrust()
        } catch {
            state = .needsConfiguration
            statusMessage = "Configuration rejected. Verify the HTTPS URL, authority key, and node credential."
        }
    }

    func enrollAndRecoverTrust() async {
        if let credentialTask { await credentialTask.value; return }
        let task = Task { @MainActor in
            await self.performCredentialRecovery()
            // Clear before resuming waiters so a completed old operation cannot
            // swallow the next profile's preparation or clear a newer task.
            self.credentialTask = nil
        }
        credentialTask = task
        await task.value
        if let revoked = revokedProfilePendingRemoval {
            revokedProfilePendingRemoval = nil
            if !task.isCancelled, selectedProfile?.id == revoked {
                await removeRevokedActiveNetwork()
            }
        }
    }

    private func performCredentialRecovery() async {
        guard credentialOperationID == nil, applicationActivity != .background, !Task.isCancelled else { return }
        guard var activeConfiguration else {
            state = .needsConfiguration
            statusMessage = "Verify development authority configuration before enrollment."
            return
        }
        guard let recoveryRuntime = activeRuntime else { return }
        let operationID = UUID()
        credentialOperationID = operationID
        credentialStatus = .preparing
        func isCurrent() -> Bool {
            credentialOperationID == operationID && selectedProfile?.id == recoveryRuntime.profile.id
                && applicationActivity != .background && !Task.isCancelled
        }
        defer { if credentialOperationID == operationID { credentialOperationID = nil } }
        let trustBegan = ContinuousClock.now
        traceConnectivity("startup-trust-begin")
        defer {
            traceConnectivity("startup-trust-return elapsed=\(trustBegan.duration(to: .now)) state=\(state) connectivity=\(activeNetworkConnectivity)")
        }
        activeNetworkConnectivity = .reconnecting
        state = .securing
        statusMessage = "Preparing Messaging… Updating network credentials."
        do {
            let activeRuntime = recoveryRuntime
            loadCredentialDetails(configuration: activeConfiguration, runtime: activeRuntime)
            if try await networkCreator.owns(profile: activeRuntime.profile) {
                guard isCurrent() else { return }
                let explicitSelection = explicitMessagingSelection == activeRuntime.profile.id
                explicitMessagingSelection = nil
                do {
                    try await authorityController().prepareForMessaging(for: activeRuntime.profile, explicitSelection: explicitSelection)
                    await updateAuthorityHostingStatus(activeRuntime.profile)
                    guard isCurrent() else { return }
                    if localAuthority != nil,
                       let refreshed = try await networkCreator.configurationForOwnedNetwork(profile: activeRuntime.profile) {
                        guard isCurrent() else { return }
                        activeConfiguration = refreshed
                        self.activeConfiguration = refreshed
                        try configurationStore.save(refreshed, profile: activeRuntime.profile)
                    }
                } catch {
                    guard isCurrent() else { return }
                    await updateAuthorityHostingStatus(activeRuntime.profile)
                    authorityHostingFailures[activeRuntime.profile.id] = Self.describe(error)
                    credentialStatus = .authorityFailed
                    statusMessage = "Authority couldn’t start on this device: \(Self.describe(error)). Beakr will retry."
                    throw error
                }
            }
            guard isCurrent() else { return }
            traceConnectivity("startup-certificate-revocation-restore-begin")
            try await trustBootstrapper.enrollAndRecover(
                using: activeConfiguration,
                profile: activeRuntime.profile,
                revocationSnapshotURL: activeRuntime.paths.revocationSnapshotURL
            )
            guard isCurrent() else { return }
            traceConnectivity("startup-certificate-revocation-restore-end")
            traceConnectivity("startup-membership-restore-begin")
            try await recoverMembershipSnapshot(
                configuration: activeConfiguration,
                runtime: activeRuntime
            )
            guard isCurrent() else { return }
            traceConnectivity("startup-membership-restore-end")
            traceConnectivity("startup-lifecycle-route-begin")
            if try await !enrollmentRouter.hasLifecycleRecord(runtime: activeRuntime) {
                try await lifecycleMigrator.migrate(
                    profile: activeRuntime.profile,
                    configuration: activeConfiguration,
                    runtime: activeRuntime
                )
            }
            let route = try await enrollmentRouter.route(runtime: activeRuntime)
            traceConnectivity("startup-lifecycle-route-end member=\(route == .member)")
            guard isCurrent() else { return }
            guard route == .member else {
                credentialStatus = nil
                applyEnrollmentRoute(route)
                return
            }
            guard isCurrent() else { return }
            traceConnectivity("startup-lan-begin")
            try await startDiagnosedLANRuntime(
                configuration: activeConfiguration,
                runtime: activeRuntime,
                displayName: deviceDisplayName
            )
            traceConnectivity("startup-lan-end")
            guard isCurrent() else { return }
            traceConnectivity("startup-path-probe-begin")
            hasUsableLocalNetwork = await lanRuntimeManager.localNetworkAvailable()
            traceConnectivity("startup-path-probe-end available=\(hasUsableLocalNetwork)")
            await beginObservingLocalNetwork(generation: runtimeGeneration)
            await beginObservingAuthenticatedPeers()
            guard isCurrent() else { return }
            traceConnectivity("startup-member-list-begin")
            await loadNetworkMembersFromRuntime()
            traceConnectivity("startup-member-list-end")
            guard isCurrent() else { return }
            loadCredentialDetails(configuration: activeConfiguration, runtime: activeRuntime)
            credentialStatus = nil
            credentialPathTask?.cancel()
            credentialPathTask = nil
            credentialRetryAttempt = 0
            credentialRetryTask?.cancel()
            credentialRetryTask = nil
            state = .ready
            statusMessage = "Network credentials are current. Ready for messaging."
            networkSessions.first { $0.id == activeRuntime.profile.id }?.clearLastError()
        } catch {
            guard isCurrent() else { return }
            traceConnectivity("startup-trust-error reason=\(String(describing: error)) type=\(String(reflecting: type(of: error))) code=\((error as NSError).code) domain=\((error as NSError).domain)", level: .failure)
            if let activeRuntime,
               await localMembershipWasRemoved(
                   configuration: activeConfiguration,
                   runtime: activeRuntime
               ) {
                guard isCurrent() else { return }
                credentialStatus = .revoked
                revokedProfilePendingRemoval = recoveryRuntime.profile.id
                return
            }
            guard isCurrent() else { return }
            activeNetworkConnectivity = .failed
            state = .identityReady
            presentCredentialFailure(error)
            loadCredentialDetails(configuration: activeConfiguration, runtime: recoveryRuntime)
            scheduleCredentialRecovery(for: recoveryRuntime.profile.id)
            observeCredentialRecoveryPath(for: recoveryRuntime.profile.id)
            if let activeRuntime {
                networkSessions.first { $0.id == activeRuntime.profile.id }?.recordLastError(statusMessage)
            }
        }
    }

    private func recoverMembershipSnapshot(
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime
    ) async throws {
        let revocationSnapshot = try CredentialFiles.loadRevocationSnapshot(
            from: runtime.paths.revocationSnapshotURL
        )
        let revokedCredentialIDs = try RevocationVerifier.verify(
            revocationSnapshot,
            trustedAuthorityPublicKey: configuration.authorityPublicKey
        )
        let directory = try await ProfileMembershipDirectory.open(
            fileURL: runtime.paths.membershipSnapshotURL,
            networkID: runtime.profile.networkID,
            environment: configuration.credential.claims.environment,
            trustedAuthorityPublicKey: configuration.authorityPublicKey,
            revokedCredentialIDs: revokedCredentialIDs
        )
        guard await directory.generation() == nil else { return }

        let refresh = ProfileMembershipRefreshController(
            directory: directory,
            requester: ProfileMembershipNetworkClient(
                transport: try configuration.makeTransport(profileID: runtime.profile.id)
            ),
            policy: try ProfileMembershipRefreshPolicy()
        )
        let outcome = await refresh.refreshNow(trigger: .startup)
        guard case .activated = outcome else {
            throw ApplicationLANRuntimeError.missingMembershipSnapshot
        }
    }

    private func localMembershipWasRemoved(
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime
    ) async -> Bool {
        do {
            let revocationSnapshot = try CredentialFiles.loadRevocationSnapshot(
                from: runtime.paths.revocationSnapshotURL
            )
            let revokedCredentialIDs = try RevocationVerifier.verify(
                revocationSnapshot,
                trustedAuthorityPublicKey: configuration.authorityPublicKey
            )
            let directory = try await ProfileMembershipDirectory.open(
                fileURL: runtime.paths.membershipSnapshotURL,
                networkID: runtime.profile.networkID,
                environment: configuration.credential.claims.environment,
                trustedAuthorityPublicKey: configuration.authorityPublicKey,
                revokedCredentialIDs: revokedCredentialIDs
            )
            guard await directory.generation() != nil else { return false }
            return await directory.sessionID(for: runtime.profile.localNodeID) == nil
        } catch {
            return false
        }
    }

    private func applyEnrollmentRoute(_ route: EnrollmentApplicationRoute) {
        activeNetworkConnectivity = .inactive
        switch route {
        case .welcome:
            state = .needsConfiguration
            statusMessage = "Network enrollment is required."
        case .identityReady:
            state = .identityReady
            statusMessage = "Identity is ready. Network enrollment is required."
        case .waitingForAdministrator:
            state = .identityReady
            statusMessage = "Waiting for a network administrator to approve this device."
        case .restoringMembership:
            state = .securing
            statusMessage = "Restoring network membership."
        case .locked:
            state = .identityReady
            statusMessage = "Unlock this device to restore network access."
        case .credentialRecovery:
            state = .identityReady
            statusMessage = "Network credentials must be recovered before routes can start."
        case .trustRecovery:
            state = .identityReady
            activeNetworkConnectivity = .failed
            presentCredentialFailure(LANHandshakeError.staleRevocationSnapshot)
            if let id = selectedProfile?.id {
                scheduleCredentialRecovery(for: id)
                observeCredentialRecoveryPath(for: id)
            }
        case .certificateRecovery:
            state = .identityReady
            statusMessage = "The device certificate must be recovered before routes can start."
        case .leaving:
            state = .identityReady
            statusMessage = "Finishing network removal."
        case .recoveryRequired:
            state = .identityReady
            statusMessage = "Enrollment recovery is required. Routes remain disabled."
        case .member:
            break
        }
    }

    func applicationDidBecomeInactive() {
        let previousActivity = applicationActivity
        guard previousActivity != .background else {
            traceConnectivity("application-inactive previous=background background-preserved")
            return
        }
        applicationActivity = .inactive
        traceConnectivity("application-inactive previous=\(previousActivity.rawValue)")
    }

    func applicationWillTerminate() async {
        cancelCredentialRecovery()
        applicationActivity = .background
        await credentialTask?.value
        traceConnectivity("application-terminating")
        runtimeGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttemptID = nil
        runtimeTransitionTask?.cancel()
        NSLog("[APP-OWNERSHIP] pid=%d stage=transition-wait", ProcessInfo.processInfo.processIdentifier)
        await runtimeTransitionTask?.value
        runtimeTransitionTask = nil
        NSLog("[APP-OWNERSHIP] pid=%d stage=observers-stop", ProcessInfo.processInfo.processIdentifier)
        stopObservingAuthenticatedPeers()
        stopObservingLocalNetwork()
        NSLog("[APP-OWNERSHIP] pid=%d stage=runtime-stop", ProcessInfo.processInfo.processIdentifier)
        await lanRuntimeManager.stop(reason: .applicationTerminating)
        NSLog("[APP-OWNERSHIP] pid=%d stage=permissions-checkpoint", ProcessInfo.processInfo.processIdentifier)
        await statusPermissions?.checkpointStopped()
        NSLog("[APP-OWNERSHIP] pid=%d stage=authority-invalidate", ProcessInfo.processInfo.processIdentifier)
        for id in authorityAdministration.keys { invalidateAuthorityAdministration(id) }
        NSLog("[APP-OWNERSHIP] pid=%d stage=hosting-stop", ProcessInfo.processInfo.processIdentifier)
        await hostingController?.shutdown()
        localAuthority = nil
        NSLog("[APP-OWNERSHIP] pid=%d stage=profile-checkpoint", ProcessInfo.processInfo.processIdentifier)
        try? await profileRuntimeManager.checkpoint(lifecycle: .stopping)
        NSLog("[APP-OWNERSHIP] pid=%d stage=bootstrap-shutdown-return", ProcessInfo.processInfo.processIdentifier)
    }

    func applicationDidEnterBackground() async {
        cancelCredentialRecovery()
        let previousActivity = applicationActivity
        applicationActivity = .background
        await credentialTask?.value
        traceConnectivity("application-background previous=\(previousActivity.rawValue)")
        guard previousActivity != .background else { return }
        guard activeRuntime != nil else {
            await statusPermissions?.checkpointStopped()
            return
        }
        runtimeGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttemptID = nil
        runtimeTransitionTask?.cancel()
        await queueRuntimeTransition { model in
            model.stopObservingAuthenticatedPeers()
            model.stopObservingLocalNetwork()
            await model.lanRuntimeManager.stop(reason: .applicationBackgrounded)
            await model.statusPermissions?.checkpointStopped()
            model.onlineMemberIDs = []
            model.activeNetworkConnectivity = .inactive
            do {
                try await model.profileRuntimeManager.checkpoint(lifecycle: .background)
            } catch {
                model.state = .failed
                model.statusMessage = "Profile state could not be checkpointed. Routes remain disabled."
            }
        }
    }

    func applicationBecameActive() async {
        let previousActivity = applicationActivity
        applicationActivity = .active
        traceConnectivity("application-active previous=\(previousActivity.rawValue)")
        guard !applicationStartupInProgress else {
            traceConnectivity("application-active ignored=startup-in-progress")
            return
        }
        if credentialStatus?.retriesAutomatically == true || credentialStatus == .preparing {
            await enrollAndRecoverTrust()
            return
        }
        guard previousActivity == .background else {
            traceConnectivity("application-active runtime-preserved")
            return
        }
        guard activeRuntime != nil, activeConfiguration != nil else { return }
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        guard applicationActivity == .active, !Task.isCancelled else { return }
        if state == .ready {
            // The background transition already stopped the runtime. Queue a
            // fresh start without issuing a second, redundant stop.
            await requestNetworkReconnect(forceRestart: false)
        } else {
            await lanRuntimeManager.stop()
            await enrollAndRecoverTrust()
        }
    }

    func reconnectActiveNetwork() async {
        traceConnectivity("manual-refresh")
        guard !applicationStartupInProgress, state != .securing else { return }
        guard state == .ready else {
            await enrollAndRecoverTrust()
            return
        }
        await requestNetworkReconnect(forceRestart: true)
    }

    private func repairResultTitle(recovered: Bool) -> String {
        guard recovered else { return "Profile Repaired — Connection Needs Attention" }
        switch activeNetworkConnectivity {
        case .connected:
            return "Network Repaired and Connected"
        case .readyNoPeers:
            return "Network Repaired — No Devices Found"
        case .reconnecting, .discoveringPeers:
            return "Network Repaired — Still Connecting"
        case .inactive, .failed, .localNetworkDenied:
            return "Profile Repaired — Connection Needs Attention"
        }
    }

    private func repairResultMessage(for networkName: String, recovered: Bool) -> String {
        let preserved = "\(networkName) kept its messages, settings, and device identity."
        guard recovered else {
            return "\(preserved) The profile was repaired, but the network connection did not restart successfully. Choose Reconnect to retry."
        }
        switch activeNetworkConnectivity {
        case .connected(let peerCount):
            let peers = peerCount == 1 ? "1 other device" : "\(peerCount) other devices"
            return "\(preserved) Its access was refreshed and it connected to \(peers)."
        case .readyNoPeers:
            return "\(preserved) Its access was refreshed, but no other authenticated devices were found online."
        case .reconnecting, .discoveringPeers:
            return "\(preserved) Its access was refreshed and device discovery is still in progress."
        case .inactive, .failed, .localNetworkDenied:
            return "\(preserved) The profile was repaired, but the network connection needs attention. Choose Reconnect to retry."
        }
    }

    private func requestNetworkReconnect(forceRestart: Bool) async {
        traceConnectivity("reconnect-request forceRestart=\(forceRestart)")
        if let reconnectTask {
            traceConnectivity("reconnect-coalesced waiting")
            await reconnectTask.value
            traceConnectivity("reconnect-coalesced finished")
            return
        }
        guard let activeConfiguration, let activeRuntime else {
            activeNetworkConnectivity = .inactive
            return
        }
        activeNetworkConnectivity = .reconnecting
        let attemptID = UUID()
        reconnectAttemptID = attemptID
        traceConnectivity("reconnect-begin")
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.queueRuntimeTransition { model in
                await model.startLANRuntime(
                    configuration: activeConfiguration,
                    runtime: activeRuntime,
                    forceRestart: forceRestart
                )
            }
        }
        reconnectTask = task
        await task.value
        traceConnectivity("reconnect-return completedAttempt=\(attemptID)")
        if reconnectAttemptID == attemptID {
            reconnectTask = nil
            reconnectAttemptID = nil
        }
    }

    func applyDeviceFriendlyName() async {
        let normalizedName = deviceFriendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            statusMessage = "Enter a friendly name for this device."
            return
        }
        guard normalizedName.utf8.count <= BonjourDiscoveryMetadata.maximumDisplayNameUTF8Length else {
            statusMessage = "The friendly name is too long. Use 128 UTF-8 bytes or fewer."
            return
        }

        deviceFriendlyName = normalizedName
        guard state == .ready else {
            statusMessage = "Friendly name saved. It will be advertised when messaging starts."
            return
        }

        // Serialize with lifecycle/network transitions. The normal startup path
        // restores both path monitoring and peer observation after restarting.
        // Read the current configuration and latest name when the queue runs.
        await queueRuntimeTransition { model in
            guard model.state == .ready,
                  let configuration = model.activeConfiguration,
                  let runtime = model.activeRuntime else { return }
            await model.startLANRuntime(
                configuration: configuration,
                runtime: runtime,
                forceRestart: true
            )
            switch model.activeNetworkConnectivity {
            case .connected, .readyNoPeers, .discoveringPeers:
                model.statusMessage = "Friendly name saved and advertised on the active network."
            default:
                break // Preserve the startup path's actionable failure status.
            }
        }
    }

    private func configuration() throws -> DevelopmentAuthorityConfiguration {
        guard let url = URL(string: controlPlaneURL),
              url.scheme?.lowercased() == "https",
              url.host != nil else { throw NodeBootstrapError.invalidURL }
        guard let networkUUID = UUID(uuidString: networkIDText) else {
            throw NodeBootstrapError.invalidNetworkID
        }
        guard let authorityKey = Data(base64Encoded: authorityPublicKeyBase64),
              !authorityKey.isEmpty else { throw NodeBootstrapError.invalidAuthorityKey }
        let authorityCertificate: Data?
        if authorityCertificateBase64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            authorityCertificate = nil
        } else {
            guard let decoded = Data(base64Encoded: authorityCertificateBase64),
                  !decoded.isEmpty else { throw NodeBootstrapError.invalidAuthorityKey }
            authorityCertificate = decoded
        }
        guard let credentialData = credentialJSON.data(using: .utf8),
              let credential = try? JSONDecoder().decode(NodeCredential.self, from: credentialData) else {
            throw NodeBootstrapError.invalidCredential
        }
        return DevelopmentAuthorityConfiguration(
            controlPlaneURL: url,
            networkID: NetworkID(rawValue: networkUUID),
            authorityPublicKey: authorityKey,
            authorityCertificateDER: authorityCertificate,
            credential: credential
        )
    }

    private func refreshOwnedNetworks() async {
        let profiles: [NetworkProfile]
        do {
            profiles = try await profileRuntimeManager.profiles()
            profileRegistryLoadFailure = nil
        } catch {
            profileRegistryLoadFailure = Self.describe(error)
            statusMessage = "Network data could not be loaded: \(Self.describe(error))."
            return
        }
        var summaries: [OwnedNetworkSummary] = []
        var reconciledSessions: [NetworkSession] = []
        var savedMemberships: [NetworkProfileID: SavedNetworkMembership] = [:]
        let existingSessions = Dictionary(uniqueKeysWithValues: networkSessions.map { ($0.id, $0) })
        for profile in profiles {
            let isHostingAuthority = (try? await networkCreator.owns(profile: profile)) == true
            let isActive = selectedProfile?.id == profile.id
            let configuration = try? configurationStore.load(profile: profile)
            if let configuration, let paths = try? await profileRuntimeManager.runtimePaths(for: profile) {
                let metadata = (UserDefaults.standard.object(forKey: ApplicationLANRuntimeManager.remembersPreviouslyConnectedDevicesKey) as? Bool ?? true)
                    ? (try? await profileRuntimeManager.memberMetadata(for: profile)) ?? [:] : [:]
                savedMemberships[profile.id] = SavedNetworkMembershipLoader.load(
                    paths: paths, profile: profile, configuration: configuration, metadata: metadata
                )
            } else {
                savedMemberships[profile.id] = .unavailable
            }
            let lifecycleRecord = try? await enrollmentRouter.lifecycleRecord(profile: profile)
            let authorization = configuration.flatMap {
                Self.verifiedAuthorization(
                    profile: profile,
                    configuration: $0,
                    isHostingAuthority: isHostingAuthority
                )
            }
            var capabilities = authorization?.capabilities ?? []
            if isHostingAuthority {
                capabilities.formUnion([.manageNetwork, .hostAuthority, .exchangeMessages])
            }
            let session = existingSessions[profile.id] ?? NetworkSession(profile: profile)
            let membershipState: NetworkSessionMembershipState
            if isActive && state == .joiningNetwork {
                membershipState = .joining
            } else if let lifecycleRecord {
                membershipState = Self.sessionMembershipState(for: lifecycleRecord.phase)
            } else if authorization != nil || isHostingAuthority {
                membershipState = .member
            } else if configuration != nil {
                membershipState = .recoveryRequired
            } else {
                membershipState = .identityReady
            }
            let runtimeState: NetworkSessionRuntimeState
            if !isActive {
                runtimeState = .closed
            } else {
                switch state {
                case .starting, .creatingNetwork, .joiningNetwork, .securing:
                    runtimeState = .opening
                case .ready, .identityReady:
                    runtimeState = .ready
                case .needsConfiguration:
                    runtimeState = .closed
                case .failed:
                    runtimeState = .failed
                }
            }
            let authorityRole: NetworkSessionAuthorityRole = isHostingAuthority
                ? .host
                : (capabilities.contains(.manageNetwork) ? .manager : .none)
            session.reconcile(
                profile: profile,
                membershipState: membershipState,
                runtimeState: runtimeState,
                connectivity: isActive ? activeNetworkConnectivity : .inactive,
                authorityRole: authorityRole,
                capabilities: capabilities,
                lastError: isActive && state == .failed ? statusMessage : session.lastError,
                isSelected: isActive,
                isReconciled: state != .starting
            )
            reconciledSessions.append(session)
            if isHostingAuthority {
                summaries.append(.init(
                    id: profile.id,
                    displayName: Self.friendlyNetworkName(profile.displayName),
                    isActive: isActive
                ))
            }
        }
        self.savedMemberships = savedMemberships
        ownedNetworks = summaries
        networkSessions = reconciledSessions.sorted {
            if $0.profile.createdAt != $1.profile.createdAt {
                return $0.profile.createdAt < $1.profile.createdAt
            }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
        if let records = try? await profileRuntimeManager.contexts() {
            contexts = records.map {
                ContextSummary(
                    id: $0.id,
                    displayName: $0.displayName,
                    knownNetworkIDs: $0.knownNetworkIDs,
                    attachedProfileIDs: $0.attachedProfileIDs,
                    messageStoreID: $0.messageStoreID,
                    updatedAt: $0.updatedAt,
                    archiveReason: $0.archiveReason
                )
            }
            archivedContexts = contexts.filter(\.isArchived)
            var archivedMessages: [ContextID: [IncomingMessage]] = [:]
            var archivedMetadata: [ContextID: ContextMailboxMetadata] = [:]
            var profileMessages: [NetworkProfileID: [IncomingMessage]] = [:]
            var profileMetadata: [NetworkProfileID: ContextMailboxMetadata] = [:]
            for context in contexts {
                let messages = (try? await profileRuntimeManager.incomingMessages(contextID: context.id)) ?? []
                let metadata = (try? await profileRuntimeManager.mailboxMetadata(contextID: context.id)) ?? .empty
                if context.isArchived {
                    archivedMessages[context.id] = messages
                    archivedMetadata[context.id] = metadata
                }
                for profileID in context.attachedProfileIDs {
                    profileMessages[profileID] = messages
                    profileMetadata[profileID] = metadata
                }
            }
            archivedIncomingMessages = archivedMessages
            archivedMailboxMetadata = archivedMetadata
            storedIncomingMessages = profileMessages
            storedMailboxMetadata = profileMetadata
        } else {
            contexts = []
            archivedContexts = []
            archivedIncomingMessages = [:]
            archivedMailboxMetadata = [:]
            storedIncomingMessages = [:]
            storedMailboxMetadata = [:]
        }
    }

    private static func sessionMembershipState(
        for phase: EnrollmentPhase
    ) -> NetworkSessionMembershipState {
        switch phase {
        case .unconfigured, .identityReady:
            return .identityReady
        case .joining, .installingMembership:
            return .joining
        case .member:
            return .member
        case .leaving:
            return .leaving
        case .recoveryRequired:
            return .recoveryRequired
        }
    }

    static func verifiedAuthorization(
        profile: NetworkProfile,
        configuration: DevelopmentAuthorityConfiguration,
        isHostingAuthority: Bool,
        now: Date = Date()
    ) -> NetworkAuthorization? {
        let credential = configuration.credential
        let claims = credential.claims
        guard configuration.networkID == profile.networkID,
              claims.networkID == profile.networkID,
              claims.nodeID == profile.localNodeID else { return nil }
        do {
            try CredentialVerifier.verify(
                credential,
                trustedAuthorityPublicKey: configuration.authorityPublicKey,
                networkID: profile.networkID,
                environment: claims.environment,
                now: now
            )
        } catch {
            return nil
        }

        var capabilities: NetworkCapabilities = []
        if claims.serviceScopes.contains("lan") { capabilities.insert(.exchangeMessages) }
        if claims.serviceScopes.contains("admin") { capabilities.insert(.manageNetwork) }
        if isHostingAuthority { capabilities.insert(.hostAuthority) }
        return NetworkAuthorization(
            networkID: profile.networkID,
            nodeID: profile.localNodeID,
            authorityID: claims.issuerID,
            credentialID: claims.credentialID,
            capabilities: capabilities
        )
    }

    fileprivate static func friendlyNetworkName(_ storedName: String) -> String {
        let prefix = "Network Name:"
        guard storedName.lowercased().hasPrefix(prefix.lowercased()) else { return storedName }
        let trimmed = storedName.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? storedName : trimmed
    }

    private static func namesCollide(_ lhs: String, _ rhs: String) -> Bool {
        friendlyNetworkName(lhs).trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(
                friendlyNetworkName(rhs).trimmingCharacters(in: .whitespacesAndNewlines)
            ) == .orderedSame
    }

    private static func normalizedHostIdentity(_ value: String) -> String {
        let withoutLocalSuffix = value.lowercased().hasSuffix(".local")
            ? String(value.dropLast(6))
            : value
        return withoutLocalSuffix.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    // Presentation retains verified credential IDs per profile so an open detail
    // can explain removal after the member disappears from the current directory.
    private(set) var revokedCredentialsByProfile: [NetworkProfileID: Set<UUID>] = [:]

    func memberStatus(
        profileID: NetworkProfileID,
        nodeID: UUID?,
        credentialID: UUID?,
        isLocalDevice: Bool
    ) -> NetworkMemberStatus {
        let isSelected = selectedProfile?.id == profileID
        let currentCredential = isSelected
            ? networkMembers.first(where: { $0.id == nodeID })?.credentialID
            : nil
        if let credential = currentCredential ?? credentialID,
           revokedCredentialsByProfile[profileID]?.contains(credential) == true {
            return .revoked
        }
        guard isSelected else { return .unknown }
        if isLocalDevice {
            return state == .ready && activeNetworkConnectivity.isLocalDeviceOnline ? .online : .offline
        }
        return nodeID.map { onlineMemberIDs.contains($0) } == true ? .online : .offline
    }

    private func refreshRevocationPresentation() {
        guard let configuration = activeConfiguration, let runtime = activeRuntime,
              selectedProfile?.id == runtime.profile.id else { return }
        // Failure to read/verify new evidence must not erase previously verified revocations.
        guard let snapshot = try? CredentialFiles.loadRevocationSnapshot(
            from: runtime.paths.revocationSnapshotURL
        ), let revoked = try? RevocationVerifier.verify(
            snapshot, trustedAuthorityPublicKey: configuration.authorityPublicKey
        ) else { return }
        revokedCredentialsByProfile[runtime.profile.id, default: []].formUnion(revoked)
    }

    func refreshNetworkMembers() async {
        let localNodeID = nodeID
        let profile = selectedProfile?.id
        let generation = runtimeGeneration
        let members = await lanRuntimeManager.refreshMemberSummaries()
        guard !Task.isCancelled, selectedProfile?.id == profile, runtimeGeneration == generation else { return }
        networkMembers = members.filter { $0.id != localNodeID }
        refreshRevocationPresentation()

        if state == .ready {
            let peerIDs = await lanRuntimeManager.authenticatedPeerIDs()
            applyAuthenticatedPeerIDs(peerIDs)
        }

        if let sharedName = await lanRuntimeManager.networkDisplayName() {
            await adoptSharedNetworkName(sharedName)
        }
    }

    /// Loads the membership state already verified while starting the runtime.
    /// This avoids immediately repeating the authority refresh that startup just
    /// attempted, while explicit refresh actions retain their existing behavior.
    private func loadNetworkMembersFromRuntime() async {
        let localNodeID = nodeID
        networkMembers = await lanRuntimeManager.memberSummaries()
            .filter { $0.id != localNodeID }
        refreshRevocationPresentation()

        if state == .ready {
            let peerIDs = await lanRuntimeManager.authenticatedPeerIDs()
            applyAuthenticatedPeerIDs(peerIDs)
        }

        if let sharedName = await lanRuntimeManager.networkDisplayName() {
            await adoptSharedNetworkName(sharedName)
        }
    }

    /// Reconciles locally available Bonjour names and authenticated presence
    /// without fetching authority trust state. Periodic UI maintenance uses this
    /// path so signed membership and revocation polling retains its own cadence.
    func reconcileLocalNetworkMembers() async {
        // Confirmation can arrive after the approval UI's initial refresh.
        // Re-read authority audit state even if the peer set has not changed.
        await refreshPendingEnrollmentRequests()
        guard !Task.isCancelled else { return }
        let localNodeID = nodeID
        networkMembers = await lanRuntimeManager.memberSummaries()
            .filter { $0.id != localNodeID }
        refreshRevocationPresentation()

        if state == .ready {
            let peerIDs = await lanRuntimeManager.authenticatedPeerIDs()
            applyAuthenticatedPeerIDs(peerIDs)
        }
    }

    func setRemembersPreviouslyConnectedDevices(_ enabled: Bool) async {
        await lanRuntimeManager.setRemembersPreviouslyConnectedDevices(enabled)
        await refreshNetworkMembers()
        await refreshOwnedNetworks()
    }

    @discardableResult
    func forgetRememberedDevice(_ id: UUID) async -> Bool {
        let didForget = await lanRuntimeManager.forgetRememberedDevice(id)
        if didForget {
            await refreshNetworkMembers()
        }
        return didForget
    }

    private func adoptSharedNetworkName(_ displayName: String) async {
        guard let profile = selectedProfile else { return }
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName != profile.displayName else { return }
        do {
            try await profileRuntimeManager.rename(profile.id, to: normalizedName)
            let renamed = try NetworkProfile(
                id: profile.id,
                networkID: profile.networkID,
                localNodeID: profile.localNodeID,
                displayName: normalizedName,
                createdAt: profile.createdAt
            )
            selectedProfile = renamed
            if let activeRuntime {
                self.activeRuntime = ApplicationProfileRuntime(
                    profile: renamed,
                    contextID: activeRuntime.contextID,
                    messageStoreID: activeRuntime.messageStoreID,
                    mailboxMetadataURL: activeRuntime.mailboxMetadataURL,
                    paths: activeRuntime.paths,
                    dataState: activeRuntime.dataState
                )
            }
            await refreshOwnedNetworks()
        } catch {
            statusMessage = "The shared network name could not be updated on this device."
        }
    }

    private func queueRuntimeTransition(
        _ operation: @escaping @MainActor (NodeBootstrapModel) async -> Void
    ) async {
        let transitionID = UUID()
        let transitionTrace = RuntimeLifecycleTrace(
            context: RuntimeTraceContext(runID: BeakrDiagnosticLog.runID, operationID: transitionID,
                                         profileID: selectedProfile?.id.rawValue,
                                         networkID: selectedProfile?.networkID.rawValue,
                                         generation: runtimeGeneration),
            journal: BeakrDiagnosticLog.lifecycleJournal, observesPeers: false
        )
        let queuedAt = transitionTrace.instant()
        transitionTrace.record(.transitionWait, .began)
        traceConnectivity("transition-queued id=\(transitionID)")
        let previous = runtimeTransitionTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else {
                transitionTrace.close(.cancelled)
                return
            }
            transitionTrace.record(.transitionWait, .completed, since: queuedAt)
            let enteredAt = transitionTrace.instant()
            transitionTrace.record(.transition, .began)
            self.traceConnectivity("transition-enter id=\(transitionID)")
            await RuntimeLifecycleDiagnostics.$transitionID.withValue(transitionID) {
                await operation(self)
            }
            transitionTrace.record(.transition, Task.isCancelled ? .cancelled : .completed, since: enteredAt)
            transitionTrace.close(Task.isCancelled ? .cancelled : .completed)
            self.traceConnectivity("transition-exit id=\(transitionID)")
        }
        runtimeTransitionTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func startLANRuntime(
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime,
        forceRestart: Bool
    ) async {
        traceConnectivity("runtime-restart-enter forceRestart=\(forceRestart)")
        defer { traceConnectivity("runtime-restart-return") }
        runtimeGeneration += 1
        let generation = runtimeGeneration
        activeNetworkConnectivity = .reconnecting
        guard !Task.isCancelled else { return }
        if forceRestart {
            stopObservingAuthenticatedPeers()
            stopObservingLocalNetwork()
            traceConnectivity("runtime-stop-begin")
            await lanRuntimeManager.stop()
            traceConnectivity("runtime-stop-end")
            guard !Task.isCancelled else { return }
        }
        do {
            try await trustBootstrapper.enrollAndRecover(using: configuration, profile: runtime.profile,
                                                        revocationSnapshotURL: runtime.paths.revocationSnapshotURL)
            guard !Task.isCancelled, generation == runtimeGeneration else { return }
            traceConnectivity("runtime-start-begin")
            try await startDiagnosedLANRuntime(
                configuration: configuration,
                runtime: runtime,
                displayName: deviceDisplayName,
                usesDeadline: true
            )
            traceConnectivity("runtime-start-end")
            guard !Task.isCancelled, generation == runtimeGeneration else {
                await lanRuntimeManager.stop()
                return
            }
            traceConnectivity("path-probe-begin")
            hasUsableLocalNetwork = await lanRuntimeManager.localNetworkAvailable()
            traceConnectivity("path-probe-end available=\(hasUsableLocalNetwork)")
            await beginObservingLocalNetwork(generation: generation)
            await beginObservingAuthenticatedPeers(generation: generation)
            guard generation == runtimeGeneration else { return }
            await loadNetworkMembersFromRuntime()
        } catch ApplicationLANRuntimeError.alreadyRunning {
            traceConnectivity("runtime-start-already-running")
            guard generation == runtimeGeneration else { return }
            traceConnectivity("path-probe-begin")
            hasUsableLocalNetwork = await lanRuntimeManager.localNetworkAvailable()
            traceConnectivity("path-probe-end available=\(hasUsableLocalNetwork)")
            await beginObservingLocalNetwork(generation: generation)
            await beginObservingAuthenticatedPeers(generation: generation)
            await refreshNetworkMembers()
        } catch ApplicationLANRuntimeError.localMembershipRemoved {
            traceConnectivity("runtime-start-membership-removed", level: .failure)
            guard generation == runtimeGeneration else { return }
            await removeRevokedActiveNetwork()
        } catch NetworkRuntimeTransitionError.timedOut {
            traceConnectivity("runtime-start-timeout", level: .failure)
            guard generation == runtimeGeneration else { return }
            activeNetworkConnectivity = .failed
            statusMessage = "Local Network startup timed out. Pull down to retry."
        } catch {
            traceConnectivity("runtime-start-error type=\(String(reflecting: type(of: error))) code=\((error as NSError).code) domain=\((error as NSError).domain)", level: .failure)
            guard !Task.isCancelled, generation == runtimeGeneration else { return }
            activeNetworkConnectivity = .failed
            switch error {
            case is LANHandshakeError, is CredentialVerificationError,
                 NodeBootstrapError.noTrustedRevocationState,
                 ApplicationLANRuntimeError.missingRevocationSnapshot,
                 ApplicationLANRuntimeError.missingMembershipSnapshot:
                state = .identityReady
                presentCredentialFailure(error)
                scheduleCredentialRecovery(for: runtime.profile.id)
                observeCredentialRecoveryPath(for: runtime.profile.id)
            default:
                statusMessage = "Local Network startup failed. Pull down to retry."
            }
        }
    }

    /// Adds observation around existing startup paths without changing their deadlines.
    private func startDiagnosedLANRuntime(
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime,
        displayName: String,
        usesDeadline: Bool = false
    ) async throws {
        let trace = RuntimeLifecycleTrace(
            context: RuntimeTraceContext(runID: BeakrDiagnosticLog.runID,
                                         parentOperationID: RuntimeLifecycleDiagnostics.transitionID,
                                         profileID: runtime.profile.id.rawValue,
                                         networkID: runtime.profile.networkID.rawValue,
                                         generation: runtimeGeneration),
            journal: BeakrDiagnosticLog.lifecycleJournal
        )
        let previousTrace = activeLifecycleTrace
        activeLifecycleTrace = trace
        let began = trace.instant()
        trace.record(.startup, .began)
        do {
            try await RuntimeLifecycleDiagnostics.$current.withValue(trace) {
                if usesDeadline {
                    try await startLANRuntimeWithinDeadline(
                        configuration: configuration, runtime: runtime, displayName: displayName
                    )
                } else {
                    try await lanRuntimeManager.start(
                        configuration: configuration, runtime: runtime, displayName: displayName
                    )
                }
            }
            previousTrace?.close(.stopped)
            if Task.isCancelled {
                trace.record(.startup, .cancelled, since: began, reason: .cancellation)
                trace.close(.cancelled)
            } else {
                trace.record(.startup, .completed, since: began)
                sharedStatusRevision = UUID()
            }
        } catch {
            let outcome: RuntimeTraceOutcome
            switch error {
            case ApplicationLANRuntimeError.alreadyRunning: outcome = .alreadyRunning
            case NetworkRuntimeTransitionError.timedOut: outcome = .timedOut
            case is CancellationError: outcome = .cancelled
            default: outcome = Task.isCancelled ? .cancelled : .failed
            }
            let reason: RuntimeTraceReason?
            switch error {
            case ApplicationLANRuntimeError.missingMembershipSnapshot,
                 ApplicationLANRuntimeError.missingRevocationSnapshot: reason = .missingTrust
            case ApplicationLANRuntimeError.localMembershipRemoved: reason = .membershipRemoved
            case NetworkRuntimeTransitionError.timedOut: reason = .deadline
            case is CancellationError: reason = .cancellation
            case ApplicationLANRuntimeError.alreadyRunning: reason = nil
            default: reason = Task.isCancelled ? .cancellation : .startupError
            }
            trace.record(.startup, outcome, since: began, reason: reason)
            trace.close(outcome)
            if outcome == .alreadyRunning { activeLifecycleTrace = previousTrace }
            throw error
        }
    }

    private func startLANRuntimeWithinDeadline(
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime,
        displayName: String
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [lanRuntimeManager] in
                try await lanRuntimeManager.start(
                    configuration: configuration,
                    runtime: runtime,
                    displayName: displayName
                )
            }
            group.addTask { [networkStartTimeout] in
                try await Task.sleep(for: networkStartTimeout)
                throw NetworkRuntimeTransitionError.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func removeRevokedActiveNetwork() async {
        refreshRevocationPresentation()
        let credentialIsRevoked = selectedProfile.map { profile in
            activeConfiguration.map {
                revokedCredentialsByProfile[profile.id]?.contains($0.credential.claims.credentialID) == true
            } ?? false
        } ?? false
        stopObservingAuthenticatedPeers()
        stopObservingLocalNetwork()
        await lanRuntimeManager.stop()
        onlineMemberIDs = []
        networkMembers = []
        activeNetworkConnectivity = .inactive

        if let profileID = selectedProfile?.id {
            await forgetJoinedNetwork(
                profileID,
                dataDisposition: .keepLocalData,
                archiveReason: credentialIsRevoked ? .membershipRevoked : nil
            )
        } else {
            state = .needsConfiguration
        }
        statusMessage = "Membership has been revoked for this device. A new invitation is required to rejoin this network."
    }

    private func beginObservingAuthenticatedPeers(generation: Int? = nil) async {
        let observedGeneration = generation ?? runtimeGeneration
        stopObservingAuthenticatedPeers()
        guard observedGeneration == runtimeGeneration else { return }
        let initialPeerIDs = await lanRuntimeManager.authenticatedPeerIDs()
        guard observedGeneration == runtimeGeneration else { return }
        beginPeerDiscovery(with: initialPeerIDs, generation: observedGeneration)
        let updates = await lanRuntimeManager.authenticatedPeerIDUpdates()
        peerObservationTask = Task { @MainActor [weak self] in
            for await peerIDs in updates {
                guard !Task.isCancelled,
                      self?.runtimeGeneration == observedGeneration else { return }
                guard let self else { return }
                self.applyAuthenticatedPeerIDs(peerIDs)
                let members = await self.lanRuntimeManager.memberSummaries()
                guard !Task.isCancelled, self.runtimeGeneration == observedGeneration else { return }
                self.networkMembers = members.filter { $0.id != self.nodeID }
                self.refreshRevocationPresentation()
                await self.refreshPendingEnrollmentRequests()
            }
        }
    }

    private func beginObservingLocalNetwork(generation: Int) async {
        tlsHealthTask?.cancel()
        let tlsUpdates = await lanRuntimeManager.peerTLSFailureUpdates()
        guard generation == runtimeGeneration else { return }
        tlsHealthTask = Task { @MainActor [weak self] in
            for await count in tlsUpdates {
                guard !Task.isCancelled, let self, self.runtimeGeneration == generation else { return }
                self.peerTLSFailureCount = count
            }
        }
        localNetworkObservationTask?.cancel()
        localNetworkPermissionTask?.cancel()
        let denied = await lanRuntimeManager.localNetworkPermissionDenied()
        guard generation == runtimeGeneration else { return }
        applyLocalNetworkPermission(denied, generation: generation)
        let permissionUpdates = await lanRuntimeManager.localNetworkPermissionUpdates()
        guard generation == runtimeGeneration else { return }
        localNetworkPermissionTask = Task { @MainActor [weak self] in
            for await denied in permissionUpdates {
                guard !Task.isCancelled, let self,
                      self.runtimeGeneration == generation else { return }
                self.applyLocalNetworkPermission(denied, generation: generation)
                if !denied {
                    let peers = await self.lanRuntimeManager.authenticatedPeerIDs()
                    guard !Task.isCancelled, self.runtimeGeneration == generation else { return }
                    self.applyAuthenticatedPeerIDs(peers)
                }
            }
        }
        let updates = await lanRuntimeManager.localNetworkAvailabilityUpdates()
        localNetworkObservationTask = Task { @MainActor [weak self] in
            for await isAvailable in updates {
                guard !Task.isCancelled,
                      self?.runtimeGeneration == generation else { return }
                self?.applyLocalNetworkAvailability(isAvailable, generation: generation)
            }
        }
    }

    private func stopObservingAuthenticatedPeers() {
        peerObservationTask?.cancel()
        peerObservationTask = nil
        peerDiscoveryTask?.cancel()
        peerDiscoveryTask = nil
    }

    private func stopObservingLocalNetwork() {
        tlsHealthTask?.cancel()
        tlsHealthTask = nil
        peerTLSFailureCount = 0
        localNetworkPermissionTask?.cancel()
        localNetworkPermissionTask = nil
        isLocalNetworkPermissionDenied = false
        localNetworkObservationTask?.cancel()
        localNetworkObservationTask = nil
        hasUsableLocalNetwork = false
    }

    private func beginPeerDiscovery(with peerIDs: Set<UUID>, generation: Int) {
        guard !isLocalNetworkPermissionDenied else {
            onlineMemberIDs = []
            activeNetworkConnectivity = .localNetworkDenied
            return
        }
        guard hasUsableLocalNetwork else {
            onlineMemberIDs = []
            activeNetworkConnectivity = .inactive
            return
        }
        onlineMemberIDs = peerIDs
        guard peerIDs.isEmpty else {
            activeNetworkConnectivity = .connected(peerCount: peerIDs.count)
            return
        }
        activeNetworkConnectivity = .discoveringPeers
        traceConnectivity("peer-discovery-settle-begin seconds=15")
        peerDiscoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            guard let self,
                  self.runtimeGeneration == generation,
                  self.activeNetworkConnectivity == .discoveringPeers else { return }
            self.traceConnectivity("peer-discovery-settle-end noPeers=true")
            self.activeNetworkConnectivity = .readyNoPeers
            self.peerDiscoveryTask = nil
        }
    }

    private func applyAuthenticatedPeerIDs(_ peerIDs: Set<UUID>) {
        if lastPeerDiagnosticIDs != peerIDs || lastPeerDiagnosticLocalAvailability != hasUsableLocalNetwork {
            lastPeerDiagnosticIDs = peerIDs
            lastPeerDiagnosticLocalAvailability = hasUsableLocalNetwork
            traceConnectivity("peer-update count=\(peerIDs.count) localAvailable=\(hasUsableLocalNetwork)")
        }
        // Periodic directory reconciliation is not evidence that startup recovered.
        // Only runtime recovery may replace an in-progress or failed startup state.
        guard !isLocalNetworkPermissionDenied,
              activeNetworkConnectivity != .failed,
              activeNetworkConnectivity != .reconnecting else {
            onlineMemberIDs = []
            return
        }
        guard hasUsableLocalNetwork else {
            onlineMemberIDs = []
            peerDiscoveryTask?.cancel()
            peerDiscoveryTask = nil
            activeNetworkConnectivity = .inactive
            return
        }
        onlineMemberIDs = peerIDs
        if peerIDs.isEmpty {
            if activeNetworkConnectivity != .discoveringPeers {
                activeNetworkConnectivity = .readyNoPeers
            }
            // Bonjour owns connection retries. A peer leaving must not stop our
            // listener/browser or require a fresh authority request to keep discovering.
        } else {
            peerDiscoveryTask?.cancel()
            peerDiscoveryTask = nil
            activeNetworkConnectivity = .connected(peerCount: peerIDs.count)
        }
    }

    private func applyLocalNetworkPermission(_ denied: Bool, generation: Int) {
        let wasDenied = isLocalNetworkPermissionDenied
        isLocalNetworkPermissionDenied = denied
        if denied {
            peerDiscoveryTask?.cancel()
            peerDiscoveryTask = nil
            onlineMemberIDs = []
            activeNetworkConnectivity = .localNetworkDenied
        } else if wasDenied {
            beginPeerDiscovery(with: [], generation: generation)
        }
    }

    private func applyLocalNetworkAvailability(_ isAvailable: Bool, generation: Int) {
        traceConnectivity("path-update available=\(isAvailable) callbackGeneration=\(generation)")
        guard hasUsableLocalNetwork != isAvailable else { return }
        hasUsableLocalNetwork = isAvailable
        guard !isLocalNetworkPermissionDenied else { return }
        if isAvailable, credentialStatus?.retriesAutomatically == true {
            credentialRetryTask?.cancel()
            credentialRetryTask = nil
            Task { await self.enrollAndRecoverTrust() }
            return
        }
        if isAvailable {
            beginPeerDiscovery(with: onlineMemberIDs, generation: generation)
        } else {
            peerDiscoveryTask?.cancel()
            peerDiscoveryTask = nil
            onlineMemberIDs = []
            activeNetworkConnectivity = .inactive
        }
    }

    private static func isAuthorityListenerConflict(_ error: Error) -> Bool {
        #if os(macOS)
        guard let authorityError = error as? EmbeddedAuthorityNodeError,
              case .listenerFailed(let reason) = authorityError else { return false }
        let normalized = reason.lowercased()
        return normalized.contains("address already in use")
            || normalized.contains("posixerrorcode(rawvalue: 48)")
        #else
        false
        #endif
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? EnrollmentRequestHTTPError {
            return error.localizedDescription
        }
        #if os(macOS)
        if let error = error as? EmbeddedAuthorityNodeError {
            switch error {
            case .listenerFailed(let reason):
                return reason.isEmpty
                    ? "The network authority listener could not start."
                    : "The network authority listener could not start: \(reason)."
            case .invalidPort:
                return "The network authority port is invalid."
            case .alreadyRunning:
                return "The network authority is already running in this app."
            case .missingPassword:
                return "The network authority TLS password is missing."
            case .authorityMismatch:
                return "The saved network authority identity does not match."
            case .rotationRequiresPrivateKeyActivation:
                return "The network authority key rotation requires completion."
            case .notRunning:
                return "The network authority is not running."
            case .missingControlPlaneURL:
                return "The network authority address is missing."
            case .connectionClosed:
                return "The network authority connection closed unexpectedly."
            case .emptyRead:
                return "The network authority received an empty request."
            }
        }
        #endif
        if let error = error as? NetworkInvitationError {
            switch error {
            case .invalidValidity:
                return "The invitation has an invalid validity period. Create a new invitation."
            case .invalidConfiguration:
                return "The authority rejected the join request. Create a new invitation and try again."
            case .unsupportedVersion:
                return "The invitation was created by an incompatible Beakr version."
            case .wrongAuthority:
                return "The invitation does not belong to the authority that answered."
            case .invalidAuthoritySignature:
                return "The invitation’s authority signature is invalid."
            case .issuedInFuture:
                return "The invitation appears to be from the future. Check the clocks on both devices."
            case .expired:
                return "The invitation expired. Create a new invitation."
            case .alreadyConsumed:
                return "The invitation has already been used. Create a new single-use invitation."
            case .nodeIdentityMismatch, .invalidNodeSignature:
                return "This device’s signed join request was invalid. Create a new invitation and retry."
            }
        }
        if let error = error as? NodeBootstrapError {
            switch error {
            case .invalidURL:
                return "The network authority address is invalid."
            case .invalidNetworkID:
                return "The Network ID is invalid."
            case .invalidAuthorityKey:
                return "The network authority identity is invalid."
            case .invalidCredential:
                return "This device’s saved network credential is invalid."
            case .credentialIdentityMismatch:
                return "The network credential does not belong to this device. No network changes were made."
            case .profileIdentityMismatch:
                return "The saved network profile does not belong to this device. No network changes were made."
            case .activeProfileMismatch:
                return "Another network profile is still active. Close and reopen Network Settings, then try again."
            case .noTrustedRevocationState:
                return "The network’s current trust information could not be verified. The saved membership was not activated."
            case .invitationAuthorityMismatch:
                return "The invitation was not issued by the authority trusted for this saved network. No network changes were made."
            case .keychain(let status):
                return "Secure network credentials could not be accessed (Keychain status \(status))."
            }
        }
        if let error = error as? ActiveProfileRuntimeError {
            switch error {
            case .runtimeAlreadyActive:
                return "The saved network was already running and could not be reopened after approval. Restart the app to finish setup."
            case .noActiveProfile:
                return "The approved network could not be selected for activation."
            case .runtimeNotActive:
                return "The network runtime was not active when setup attempted to stop it."
            case .checkpointGenerationExhausted:
                return "The network runtime could not save another lifecycle checkpoint."
            }
        }
        if let error = error as? AuthoritativeNetworkCreationError {
            switch error {
            case .requiresMacOS:
                return "Creating a network authority on iPhone requires a provisioned TLS server identity and is not enabled yet."
            case .openSSLUnavailable:
                return "The TLS certificate tool is unavailable on this Mac."
            case .invalidHostname:
                return "The authority hostname is invalid."
            case .missingAuthorityPassword:
                return "The authority TLS password is missing from the Keychain."
            case .missingAuthorityPrivateKeys:
                return "The authority private keys are missing from the Keychain."
            case .invalidPersistedAuthority:
                return "The saved authority data is inconsistent."
            case .notNetworkCreator:
                return "This device did not create the selected network authority."
            case .certificateRepairFailed(let reason):
                return reason.isEmpty ? "The authority certificate could not be repaired." : reason
            case .keychain(let status):
                return "The authority could not access the Keychain (status \(status))."
            }
        }
        if let error = error as? NetworkProfileRegistryError {
            switch error {
            case .unsupportedFormatVersion:
                return "The saved network list was created by an incompatible Beakr version."
            case .invalidDisplayName:
                return "The network name is invalid."
            case .capacityExceeded(let maximumProfiles):
                return "This device already has the maximum of \(maximumProfiles) saved networks."
            case .duplicateProfileID:
                return "This network profile is already saved on this device."
            case .duplicateNetworkID:
                return "This Beakr'Net is already saved on this device."
            case .unknownProfile:
                return "The selected network profile could not be found."
            case .activeProfileRemoval:
                return "The active network must be stopped before it can be removed."
            case .noncanonicalSnapshot:
                return "The saved network list is inconsistent and could not be opened safely."
            }
        }
        if let error = error as? CertificateEnrollmentNetworkError {
            switch error {
            case .invalidConfiguration: return "The enrollment client configuration is inconsistent."
            case .wrongEnvironment: return "The enrollment authority belongs to a different environment."
            case .insecureBaseURL: return "The enrollment authority URL is not secure."
            case .invalidTrustAnchor: return "The enrollment authority trust certificate is invalid."
            case .invalidURL: return "The enrollment request URL is invalid."
            case .invalidResponse: return "The enrollment authority returned an invalid HTTPS response."
            case .responseTooLarge: return "The enrollment authority response exceeded its size limit."
            case .invalidChallenge: return "The enrollment authority returned an invalid challenge."
            case .challengeNotIssued: return "The enrollment challenge was not issued by this authority."
            case .challengeCapacityExceeded: return "The enrollment authority has too many pending challenges."
            case .serverRejected(let status): return "The enrollment authority rejected the request (HTTP \(status))."
            case .malformedJSON: return "The enrollment authority returned malformed data."
            case .nonCanonicalJSON: return "The enrollment authority returned noncanonical data."
            }
        }
        if let error = error as? EnrollmentAuditExportVerificationError {
            switch error {
            case .invalidSignature:
                return "The audit signature is invalid or belongs to a different network authority."
            case .fileTooLarge:
                return "The audit file exceeds the 4 MiB verification limit."
            case .malformedDocument:
                return "The audit file is not a valid signed audit document."
            case .nonCanonicalDocument:
                return "The audit file is not canonically encoded and may have been modified."
            case .invalidKeyring:
                return "The authority audit verification keyring is invalid."
            case .untrustedAuthority:
                return "The audit was signed by an authority key that is not in this network’s trusted key history."
            case .invalidRotationStatement:
                return "The authority-key rotation statement is invalid or does not have both required signatures."
            }
        }
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return "\(nsError.domain) \(nsError.code): \(underlying.localizedDescription)"
        }
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    private func validate(_ configuration: DevelopmentAuthorityConfiguration, nodeID: NodeID) throws {
        guard configuration.credential.claims.nodeID == nodeID else {
            throw NodeBootstrapError.credentialIdentityMismatch
        }
        try CredentialVerifier.verify(
            configuration.credential,
            trustedAuthorityPublicKey: configuration.authorityPublicKey,
            networkID: configuration.networkID,
            environment: configuration.credential.claims.environment
        )
    }
}
