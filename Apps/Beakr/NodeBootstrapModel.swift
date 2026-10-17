import Foundation
import Observation
#if os(macOS)
import SystemConfiguration
#endif
import Security
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetData
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
    case enrolling
    case ready
    case failed
}

struct DevelopmentAuthorityConfiguration: Equatable, Sendable {
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

    func makeTransport() throws -> URLSessionCertificateEnrollmentTransport {
        try URLSessionCertificateEnrollmentTransport(
            baseURL: controlPlaneURL,
            trustedAuthorityCertificateDER: authorityCertificateDER
        )
    }
}

protocol NodeIdentityLoading: Sendable {
    func loadOrCreateNodeID(profileID: NetworkProfileID) throws -> NodeID
}

protocol DevelopmentAuthorityConfigurationStoring: Sendable {
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
    func addAndActivate(_ profile: NetworkProfile) async throws
    func rename(_ profileID: NetworkProfileID, to displayName: String) async throws
    func start(profile: NetworkProfile) async throws -> ApplicationProfileRuntime
    func checkpoint(lifecycle: HostLifecycleState) async throws
    func stop() async throws
    func forget(profile: NetworkProfile) async throws
    func delete(profile: NetworkProfile) async throws
}

extension ApplicationProfileRuntimeManaging {
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
}

nonisolated protocol ApplicationLANRuntimeManaging: Sendable {
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
    func setRemembersPreviouslyConnectedDevices(_ enabled: Bool) async
    func forgetRememberedDevice(_ id: UUID) async -> Bool
    func stop() async
}

extension ApplicationLANRuntimeManaging {
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
    func loadOrCreateNodeID(profileID: NetworkProfileID) throws -> NodeID {
        let namespace = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profileID)
        return try KeychainNodeIdentityStore(namespace: namespace).loadOrCreate().nodeID
    }
}

struct DevelopmentAuthorityConfigurationStore: DevelopmentAuthorityConfigurationStoring {
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

        let transport = try configuration.makeTransport()
        let tlsIdentityStore = KeychainLANTLSIdentityStore(namespace: namespace)
        if try tlsIdentityStore.load() == nil {
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

        let distributor = RevocationSnapshotDistributor(
            trustedAuthorityPublicKey: configuration.authorityPublicKey
        )
        let controller = RevocationRefreshController(
            distributor: distributor,
            requester: RevocationSnapshotNetworkClient(transport: transport),
            store: FileRevocationSnapshotStore(fileURL: revocationSnapshotURL),
            policy: try RevocationRefreshPolicy()
        )
        let restored = try await controller.restorePersistedSnapshot() != nil
        if restored {
            return
        }
        let outcome = await controller.refreshNow(trigger: .startup)
        switch outcome {
        case .activated:
            return
        case .unchanged where restored:
            return
        case .failed where restored:
            return
        case .unchanged, .failed:
            throw NodeBootstrapError.noTrustedRevocationState
        }
    }

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

    func addAndActivate(_ profile: NetworkProfile) async throws {
        guard manager == nil else {
            throw ActiveProfileRuntimeError.runtimeAlreadyActive(profile.id)
        }
        try await openRegistry().add(profile, activate: true)
    }

    func rename(_ profileID: NetworkProfileID, to displayName: String) async throws {
        try await openRegistry().rename(profileID, to: displayName)
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
        let registry = try openRegistry()
        let storageRoot = try await registry.storageRoot(for: profile.id)
        if let manager, await manager.activeProfile()?.id == profile.id {
            try await manager.stop()
            self.manager = nil
        }
        try await registry.removeActive(profile.id)
        let contexts = try openContextRegistry(applicationRoot: applicationRoot())
        try await contexts.detach(profile.id)
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

struct NetworkSummary: Identifiable, Equatable, Sendable {
    let id: NetworkProfileID
    let networkID: NetworkID
    let displayName: String
    let isActive: Bool
    let capabilities: NetworkCapabilities

    var canManageNetwork: Bool { capabilities.contains(.manageNetwork) }
    var isHostingAuthority: Bool { capabilities.contains(.hostAuthority) }
    var canExchangeMessages: Bool { capabilities.contains(.exchangeMessages) }
}

struct ContextSummary: Identifiable, Equatable, Sendable {
    let id: ContextID
    let displayName: String
    let knownNetworkIDs: [NetworkID]
    let attachedProfileIDs: [NetworkProfileID]
    let messageStoreID: StoreID
    let updatedAt: Date

    var isArchived: Bool { attachedProfileIDs.isEmpty }
}

struct NetworkMemberSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let isPlaceholderName: Bool
    let lastSeen: Date?

    nonisolated init(
        id: UUID,
        displayName: String,
        isPlaceholderName: Bool = false,
        lastSeen: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isPlaceholderName = isPlaceholderName
        self.lastSeen = lastSeen
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
}

private enum NetworkRuntimeTransitionError: Error {
    case timedOut
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
    var deviceFriendlyName = UserDefaults.standard.string(forKey: "net.beakr.app.deviceFriendlyName") ?? "" {
        didSet {
            UserDefaults.standard.set(deviceFriendlyName, forKey: "net.beakr.app.deviceFriendlyName")
        }
    }
    var authorityHostname = NodeBootstrapModel.defaultAuthorityHostname()
    var authorityPort = "8443"
    var invitationJSON = ""
    var joinInvitationJSON = ""
    private(set) var state: NodeBootstrapState = .starting
    private(set) var nodeID: UUID?
    private(set) var profileID: UUID?
    private(set) var canCreateInvitations = false
    private(set) var ownedNetworks: [OwnedNetworkSummary] = []
    private(set) var networks: [NetworkSummary] = []
    private(set) var contexts: [ContextSummary] = []
    private(set) var archivedContexts: [ContextSummary] = []
    private(set) var archivedIncomingMessages: [ContextID: [IncomingMessage]] = [:]
    private(set) var archivedMailboxMetadata: [ContextID: ContextMailboxMetadata] = [:]
    private(set) var networkMembers: [NetworkMemberSummary] = []
    private(set) var onlineMemberIDs: Set<UUID> = []
    private(set) var activeNetworkConnectivity: ActiveNetworkConnectivity = .inactive
    private(set) var statusMessage = "Restoring this device’s node identity."
    private(set) var profileRegistryLoadFailure: String?
    var networkJoinAlert: NetworkJoinAlert?

    private let identityLoader: any NodeIdentityLoading
    private let configurationStore: any DevelopmentAuthorityConfigurationStoring
    private let trustBootstrapper: any NodeTrustBootstrapping
    private let profileRuntimeManager: any ApplicationProfileRuntimeManaging
    private let lanRuntimeManager: any ApplicationLANRuntimeManaging
    private let networkCreator: any AuthoritativeNetworkCreating
    private let networkStartTimeout: Duration
    private var localAuthority: (any ApplicationAuthorityRunning)?
    private var activeConfiguration: DevelopmentAuthorityConfiguration?
    private var activeRuntime: ApplicationProfileRuntime?
    private var selectedProfile: NetworkProfile?
    private var runtimeTransitionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttemptID: UUID?
    private var peerObservationTask: Task<Void, Never>?
    private var peerDiscoveryTask: Task<Void, Never>?
    private var localNetworkObservationTask: Task<Void, Never>?
    private var hasUsableLocalNetwork = false
    private var runtimeGeneration = 0
    private var approvedCollidingNetworkID: NetworkID?
    private var collidingNetworkDisplayName: String?
    private var approvedReattachmentNetworkID: NetworkID?
    private var hasStarted = false

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
        switch activeNetworkConnectivity {
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
        identityLoader = KeychainNodeIdentityLoader()
        configurationStore = DevelopmentAuthorityConfigurationStore()
        trustBootstrapper = DevelopmentNodeTrustBootstrapper()
        profileRuntimeManager = ApplicationProfileRuntimeManager()
        lanRuntimeManager = ApplicationLANRuntimeManager()
        networkCreator = SystemAuthoritativeNetworkCreator()
        networkStartTimeout = .seconds(8)
    }

    init(lanRuntimeManager: any ApplicationLANRuntimeManaging) {
        identityLoader = KeychainNodeIdentityLoader()
        configurationStore = DevelopmentAuthorityConfigurationStore()
        trustBootstrapper = DevelopmentNodeTrustBootstrapper()
        profileRuntimeManager = ApplicationProfileRuntimeManager()
        self.lanRuntimeManager = lanRuntimeManager
        networkCreator = SystemAuthoritativeNetworkCreator()
        networkStartTimeout = .seconds(8)
    }

    init(identityLoader: any NodeIdentityLoading) {
        self.identityLoader = identityLoader
        configurationStore = DevelopmentAuthorityConfigurationStore()
        trustBootstrapper = DevelopmentNodeTrustBootstrapper()
        profileRuntimeManager = ApplicationProfileRuntimeManager()
        lanRuntimeManager = ApplicationLANRuntimeManager()
        networkCreator = SystemAuthoritativeNetworkCreator()
        networkStartTimeout = .seconds(8)
    }

    init(identityLoader: any NodeIdentityLoading,
         configurationStore: any DevelopmentAuthorityConfigurationStoring) {
        self.identityLoader = identityLoader
        self.configurationStore = configurationStore
        trustBootstrapper = DevelopmentNodeTrustBootstrapper()
        profileRuntimeManager = ApplicationProfileRuntimeManager()
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
         networkStartTimeout: Duration = .seconds(8)) {
        self.identityLoader = identityLoader
        self.configurationStore = configurationStore
        self.trustBootstrapper = trustBootstrapper
        self.profileRuntimeManager = profileRuntimeManager
        self.lanRuntimeManager = lanRuntimeManager
        self.networkCreator = networkCreator
        self.networkStartTimeout = networkStartTimeout
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        state = .starting
        statusMessage = "Selecting the active network profile."
        profileRegistryLoadFailure = nil
        let profile: NetworkProfile?
        do {
            profile = try await profileRuntimeManager.activeProfile()
        } catch {
            activeNetworkConnectivity = .failed
            state = .failed
            profileRegistryLoadFailure = Self.describe(error)
            statusMessage = "Network data could not be loaded: \(Self.describe(error))."
            return
        }
        do {
            guard let profile else {
                activeNetworkConnectivity = .inactive
                nodeID = nil
                profileID = nil
                state = .needsConfiguration
                statusMessage = "Choose a network before creating its secure identity."
                await refreshOwnedNetworks()
                return
            }
            activeNetworkConnectivity = .reconnecting
            selectedProfile = profile
            await refreshOwnedNetworks()
            let restoredNodeID = try identityLoader.loadOrCreateNodeID(profileID: profile.id)
            guard restoredNodeID == profile.localNodeID else {
                throw NodeBootstrapError.profileIdentityMismatch
            }
            localAuthority = try await networkCreator.restore(profile: profile)
            canCreateInvitations = localAuthority != nil
            nodeID = restoredNodeID.rawValue
            profileID = profile.id.rawValue
            if var configuration = try configurationStore.load(profile: profile) {
                if localAuthority != nil {
                    configuration = DevelopmentAuthorityConfiguration(
                        controlPlaneURL: configuration.controlPlaneURL,
                        networkID: configuration.networkID,
                        authorityPublicKey: configuration.authorityPublicKey,
                        authorityCertificateDER: try await networkCreator.authorityCertificateDER(
                            profile: profile
                        ),
                        credential: configuration.credential
                    )
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
                let runtime = try await profileRuntimeManager.start(profile: profile)
                activeRuntime = runtime
                activeConfiguration = configuration
                state = .identityReady
                statusMessage = "Securing this device."
                await enrollAndRecoverTrust()
            } else {
                state = .needsConfiguration
                statusMessage = "The profile identity is secure. Authority configuration is required."
            }
        } catch {
            nodeID = nil
            state = .failed
            statusMessage = "Secure bootstrap failed: \(Self.describe(error))."
        }
    }

    func createNetwork() async {
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
        var configurationSaved = false
        state = .creatingNetwork
        statusMessage = "Creating the network authority and administrator identity."
        do {
            if activeRuntime != nil || localAuthority != nil {
                await lanRuntimeManager.stop()
                await localAuthority?.stop()
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
            configurationSaved = true
            try await profileRuntimeManager.addAndActivate(created.profile)
            let runtime = try await profileRuntimeManager.start(profile: created.profile)
            selectedProfile = created.profile
            activeConfiguration = created.configuration
            activeRuntime = runtime
            localAuthority = created.authority
            canCreateInvitations = true
            nodeID = created.profile.localNodeID.rawValue
            profileID = created.profile.id.rawValue
            controlPlaneURL = created.configuration.controlPlaneURL.absoluteString
            networkIDText = created.profile.networkID.rawValue.uuidString
            authorityPublicKeyBase64 = created.configuration.authorityPublicKey.base64EncodedString()
            authorityCertificateBase64 = created.configuration.authorityCertificateDER?.base64EncodedString() ?? ""
            networkDisplayName = "Local Network"
            state = .identityReady
            statusMessage = "Network created. Securing this device."
            await refreshOwnedNetworks()
            await enrollAndRecoverTrust()
        } catch {
            if let createdNetwork {
                await createdNetwork.authority.stop()
                try? await profileRuntimeManager.stop()
                try? await profileRuntimeManager.delete(profile: createdNetwork.profile)
                if configurationSaved {
                    try? configurationStore.delete(profile: createdNetwork.profile)
                }
                try? await networkCreator.delete(profile: createdNetwork.profile)
            }
            if let previousProfileID {
                try? await profileRuntimeManager.activate(previousProfileID)
                await start()
                statusMessage = "The new network could not be created: \(Self.describe(error)). The previous network was restored."
            } else {
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
        statusMessage = "Scan or paste a current invitation from a network manager."
    }

    func invitationReview(for invitationJSON: String, receivedAt: Date = Date()) -> InvitationReview? {
        do {
            guard let data = invitationJSON.data(using: .utf8) else {
                throw NetworkInvitationError.invalidConfiguration
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
            networkJoinAlert = NetworkJoinAlert(
                succeeded: false,
                title: "Invitation Cannot Be Reviewed",
                message: Self.describe(error)
            )
            return nil
        }
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

    func createInvitation() async {
        do {
            let invitation: NetworkInvitation
            if let localAuthority {
                invitation = try await localAuthority.createInvitation(validity: 10 * 60)
            } else {
                guard let profile = selectedProfile,
                      let configuration = activeConfiguration,
                      Self.verifiedAuthorization(
                        profile: profile,
                        configuration: configuration,
                        isHostingAuthority: false
                      )?.capabilities.contains(.manageNetwork) == true else {
                    statusMessage = "This device is not authorized to create invitations."
                    return
                }
                let namespace = ProfileKeychainNamespace(
                    baseService: "net.beakr.app",
                    profileID: profile.id
                )
                let identity = try KeychainNodeIdentityStore(namespace: namespace).loadOrCreate()
                let client = AuthorityAdministrationClient(
                    transport: try configuration.makeTransport()
                )
                invitation = try await client.createInvitation(
                    credential: configuration.credential,
                    identity: identity,
                    validity: 10 * 60
                )
                guard invitation.networkID == configuration.networkID,
                      invitation.authorityPublicKey == configuration.authorityPublicKey,
                      invitation.environment == configuration.credential.claims.environment else {
                    throw NetworkInvitationError.invalidConfiguration
                }
            }
            invitationJSON = String(
                decoding: try NetworkInvitationWireCodec.encode(invitation),
                as: UTF8.self
            )
            statusMessage = "Invitation created. It expires in 10 minutes and can be used once."
        } catch {
            invitationJSON = ""
            statusMessage = "The invitation could not be created: \(Self.describe(error))."
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
                try await localAuthority?.renameNetwork(to: normalizedName)
                try await profileRuntimeManager.rename(profile.id, to: normalizedName)
            } catch {
                try? await networkCreator.rename(profile: renamedProfile, to: profile.displayName)
                try? await localAuthority?.renameNetwork(to: profile.displayName)
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
        guard let profile = try? await profileRuntimeManager.profiles().first(where: { $0.id == id }),
              (try? await networkCreator.owns(profile: profile)) == true else {
            statusMessage = "Only the device that created this network can delete it."
            return
        }
        let deletingActiveProfile = selectedProfile?.id == profile.id
        do {
            if deletingActiveProfile {
                await lanRuntimeManager.stop()
                await localAuthority?.stop()
                localAuthority = nil
                activeConfiguration = nil
                activeRuntime = nil
            }
            try await networkCreator.delete(profile: profile)
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

    func forgetJoinedNetwork(_ id: NetworkProfileID) async {
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
            if leavingActiveProfile {
                await lanRuntimeManager.stop()
                activeConfiguration = nil
                activeRuntime = nil
            }
            try configurationStore.delete(profile: profile)
            try await profileRuntimeManager.forget(profile: profile)
            if leavingActiveProfile {
                selectedProfile = nil
                nodeID = nil
                profileID = nil
                canCreateInvitations = false
                invitationJSON = ""
                networkMembers = []
                state = .needsConfiguration
            }
            statusMessage = "This device forgot the network."
            await refreshOwnedNetworks()
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
        guard selectedProfile?.id != id else { return }
        guard (try? await profileRuntimeManager.profiles().contains(where: { $0.id == id })) == true else {
            statusMessage = "That network is no longer available on this device."
            return
        }
        state = .starting
        statusMessage = "Switching networks."
        await lanRuntimeManager.stop()
        await localAuthority?.stop()
        localAuthority = nil
        do {
            if activeRuntime != nil {
                try await profileRuntimeManager.stop()
            }
            try await profileRuntimeManager.activate(id)
            selectedProfile = nil
            activeConfiguration = nil
            activeRuntime = nil
            canCreateInvitations = false
            invitationJSON = ""
            networkMembers = []
            hasStarted = false
            await start()
        } catch {
            state = .failed
            statusMessage = "The selected network could not be activated."
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

    func repairExistingNetwork(using review: InvitationReview, profileID: NetworkProfileID) async {
        state = .joiningNetwork
        statusMessage = "Verifying the authority and repairing the existing network profile."
        var credentialAccepted = false
        do {
            guard let data = review.invitationJSON.data(using: .utf8) else {
                throw NetworkInvitationError.invalidConfiguration
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

            if selectedProfile?.id != profileID {
                await switchNetwork(to: profileID)
                guard selectedProfile?.id == profileID else {
                    throw NodeBootstrapError.activeProfileMismatch
                }
            }

            let namespace = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profile.id)
            let identity = try KeychainNodeIdentityStore(namespace: namespace).loadOrCreate()
            guard identity.nodeID == profile.localNodeID else {
                throw NodeBootstrapError.profileIdentityMismatch
            }
            let transport = try URLSessionCertificateEnrollmentTransport(
                baseURL: invitation.controlPlaneURL,
                trustedAuthorityCertificateDER: invitation.authorityCertificateDER
            )
            let credential = try await NetworkInvitationClient(transport: transport).join(
                invitation: invitation,
                identity: identity
            )
            credentialAccepted = true
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
            networkJoinAlert = NetworkJoinAlert(
                succeeded: recovered,
                title: repairResultTitle(recovered: recovered),
                message: repairResultMessage(for: profile.displayName, recovered: recovered),
                invitationAccepted: true,
                connectivity: activeNetworkConnectivity
            )
        } catch {
            joinInvitationJSON = ""
            networkJoinAlert = NetworkJoinAlert(
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
        }
    }

    func joinNetwork() async {
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
            let transport = try URLSessionCertificateEnrollmentTransport(
                baseURL: invitation.controlPlaneURL,
                trustedAuthorityCertificateDER: invitation.authorityCertificateDER
            )
            let credential = try await NetworkInvitationClient(transport: transport).join(
                invitation: invitation,
                identity: identity
            )
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
                await localAuthority?.stop()
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
        guard let activeConfiguration else {
            state = .needsConfiguration
            statusMessage = "Verify development authority configuration before enrollment."
            return
        }
        activeNetworkConnectivity = .reconnecting
        state = .enrolling
        statusMessage = "Enrolling certificate and recovering revocation state."
        do {
            guard let activeRuntime else { throw NodeBootstrapError.activeProfileMismatch }
            try await trustBootstrapper.enrollAndRecover(
                using: activeConfiguration,
                profile: activeRuntime.profile,
                revocationSnapshotURL: activeRuntime.paths.revocationSnapshotURL
            )
            try await lanRuntimeManager.start(
                configuration: activeConfiguration,
                runtime: activeRuntime,
                displayName: deviceDisplayName
            )
            hasUsableLocalNetwork = await lanRuntimeManager.localNetworkAvailable()
            await beginObservingLocalNetwork(generation: runtimeGeneration)
            await beginObservingAuthenticatedPeers()
            await refreshNetworkMembers()
            state = .ready
            statusMessage = "Identity, certificate, and revocation state are ready."
        } catch {
            activeNetworkConnectivity = .failed
            state = .identityReady
            if let runtimeError = error as? ApplicationLANRuntimeError {
                switch runtimeError {
                case .missingRevocationSnapshot:
                    statusMessage = "The network’s revocation information is unavailable. Keep the authority Mac running, then retry device setup."
                case .missingMembershipSnapshot:
                    statusMessage = "The network’s device membership is unavailable. Keep the authority Mac running, then retry device setup."
                case .alreadyRunning:
                    statusMessage = "Messaging is already running."
                case .notRunning:
                    statusMessage = "Messaging could not be started. Retry device setup."
                }
            } else {
                statusMessage = "Device setup failed: \(Self.describe(error)). Routes remain disabled."
            }
        }
    }

    func applicationDidEnterBackground() async {
        guard activeRuntime != nil else { return }
        runtimeGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttemptID = nil
        runtimeTransitionTask?.cancel()
        await queueRuntimeTransition { model in
            model.stopObservingAuthenticatedPeers()
            model.stopObservingLocalNetwork()
            await model.lanRuntimeManager.stop()
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

    func applicationBecameActive(forceRestart: Bool = false) async {
        guard activeRuntime != nil, activeConfiguration != nil else { return }
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        if state == .ready {
            await requestNetworkReconnect(forceRestart: forceRestart)
        } else {
            await lanRuntimeManager.stop()
            await enrollAndRecoverTrust()
        }
    }

    func reconnectActiveNetwork() async {
        await requestNetworkReconnect(forceRestart: true)
        await waitForNetworkRefreshResult()
    }

    private func waitForNetworkRefreshResult() async {
        for _ in 0..<80 {
            guard !Task.isCancelled else { return }
            switch activeNetworkConnectivity {
            case .reconnecting, .discoveringPeers:
                try? await Task.sleep(for: .milliseconds(250))
            case .inactive, .readyNoPeers, .connected, .failed:
                return
            }
        }
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
        case .inactive, .failed:
            return "Profile Repaired — Connection Needs Attention"
        }
    }

    private func repairResultMessage(for networkName: String, recovered: Bool) -> String {
        let preserved = "\(networkName) kept its messages, settings, and device identity."
        guard recovered else {
            return "\(preserved) The profile was repaired, but the network connection did not restart successfully. Choose Refresh Connection to retry."
        }
        switch activeNetworkConnectivity {
        case .connected(let peerCount):
            let peers = peerCount == 1 ? "1 other device" : "\(peerCount) other devices"
            return "\(preserved) Its access was refreshed and it connected to \(peers)."
        case .readyNoPeers:
            return "\(preserved) Its access was refreshed, but no other authenticated devices were found online."
        case .reconnecting, .discoveringPeers:
            return "\(preserved) Its access was refreshed and device discovery is still in progress."
        case .inactive, .failed:
            return "\(preserved) The profile was repaired, but the network connection needs attention. Choose Refresh Connection to retry."
        }
    }

    private func requestNetworkReconnect(forceRestart: Bool) async {
        if let reconnectTask {
            await reconnectTask.value
            return
        }
        guard let activeConfiguration, let activeRuntime else {
            activeNetworkConnectivity = .inactive
            return
        }
        activeNetworkConnectivity = .reconnecting
        let attemptID = UUID()
        reconnectAttemptID = attemptID
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
        guard state == .ready, let activeConfiguration, let activeRuntime else {
            statusMessage = "Friendly name saved. It will be advertised when messaging starts."
            return
        }

        stopObservingAuthenticatedPeers()
        stopObservingLocalNetwork()
        await lanRuntimeManager.stop()
        do {
            try await lanRuntimeManager.start(
                configuration: activeConfiguration,
                runtime: activeRuntime,
                displayName: normalizedName
            )
            await beginObservingAuthenticatedPeers()
            await refreshNetworkMembers()
            statusMessage = "Friendly name saved and advertised on the active network."
        } catch {
            state = .identityReady
            statusMessage = "Friendly name was saved, but messaging must be restarted to advertise it."
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
        var allNetworks: [NetworkSummary] = []
        for profile in profiles {
            let isHostingAuthority = (try? await networkCreator.owns(profile: profile)) == true
            let isActive = selectedProfile?.id == profile.id
            let configuration = try? configurationStore.load(profile: profile)
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
            allNetworks.append(.init(
                id: profile.id,
                networkID: profile.networkID,
                displayName: Self.friendlyNetworkName(profile.displayName),
                isActive: isActive,
                capabilities: capabilities
            ))
            if isHostingAuthority {
                summaries.append(.init(
                    id: profile.id,
                    displayName: Self.friendlyNetworkName(profile.displayName),
                    isActive: isActive
                ))
            }
        }
        ownedNetworks = summaries
        networks = allNetworks
        if let records = try? await profileRuntimeManager.contexts() {
            contexts = records.map {
                ContextSummary(
                    id: $0.id,
                    displayName: $0.displayName,
                    knownNetworkIDs: $0.knownNetworkIDs,
                    attachedProfileIDs: $0.attachedProfileIDs,
                    messageStoreID: $0.messageStoreID,
                    updatedAt: $0.updatedAt
                )
            }
            archivedContexts = contexts.filter(\.isArchived)
            var archivedMessages: [ContextID: [IncomingMessage]] = [:]
            var archivedMetadata: [ContextID: ContextMailboxMetadata] = [:]
            for context in archivedContexts {
                archivedMessages[context.id] = (try? await profileRuntimeManager.incomingMessages(contextID: context.id)) ?? []
                archivedMetadata[context.id] = (try? await profileRuntimeManager.mailboxMetadata(contextID: context.id)) ?? .empty
            }
            archivedIncomingMessages = archivedMessages
            archivedMailboxMetadata = archivedMetadata
        } else {
            contexts = []
            archivedContexts = []
            archivedIncomingMessages = [:]
            archivedMailboxMetadata = [:]
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

    private static func friendlyNetworkName(_ storedName: String) -> String {
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

    func refreshNetworkMembers() async {
        let localNodeID = nodeID
        networkMembers = await lanRuntimeManager.refreshMemberSummaries()
            .filter { $0.id != localNodeID }

        if state == .ready {
            let peerIDs = await lanRuntimeManager.authenticatedPeerIDs()
            applyAuthenticatedPeerIDs(peerIDs)
        }

        if let sharedName = await lanRuntimeManager.networkDisplayName() {
            await adoptSharedNetworkName(sharedName)
        }
    }

    func setRemembersPreviouslyConnectedDevices(_ enabled: Bool) async {
        await lanRuntimeManager.setRemembersPreviouslyConnectedDevices(enabled)
        await refreshNetworkMembers()
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
        let previous = runtimeTransitionTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await operation(self)
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
        runtimeGeneration += 1
        let generation = runtimeGeneration
        activeNetworkConnectivity = .reconnecting
        guard !Task.isCancelled else { return }
        if forceRestart {
            stopObservingAuthenticatedPeers()
            stopObservingLocalNetwork()
            await lanRuntimeManager.stop()
            guard !Task.isCancelled else { return }
        }
        do {
            try await startLANRuntimeWithinDeadline(
                configuration: configuration,
                runtime: runtime,
                displayName: deviceDisplayName
            )
            guard !Task.isCancelled, generation == runtimeGeneration else {
                await lanRuntimeManager.stop()
                return
            }
            hasUsableLocalNetwork = await lanRuntimeManager.localNetworkAvailable()
            await beginObservingLocalNetwork(generation: generation)
            await beginObservingAuthenticatedPeers(generation: generation)
            guard generation == runtimeGeneration else { return }
            await refreshNetworkMembers()
        } catch ApplicationLANRuntimeError.alreadyRunning {
            guard generation == runtimeGeneration else { return }
            hasUsableLocalNetwork = await lanRuntimeManager.localNetworkAvailable()
            await beginObservingLocalNetwork(generation: generation)
            await beginObservingAuthenticatedPeers(generation: generation)
            await refreshNetworkMembers()
        } catch NetworkRuntimeTransitionError.timedOut {
            guard generation == runtimeGeneration else { return }
            activeNetworkConnectivity = .failed
            statusMessage = "Local Network startup timed out. Pull down to retry."
        } catch {
            guard !Task.isCancelled, generation == runtimeGeneration else { return }
            activeNetworkConnectivity = .failed
            statusMessage = "Local Network startup failed. Pull down to retry."
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
                self?.applyAuthenticatedPeerIDs(peerIDs)
            }
        }
    }

    private func beginObservingLocalNetwork(generation: Int) async {
        localNetworkObservationTask?.cancel()
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
        localNetworkObservationTask?.cancel()
        localNetworkObservationTask = nil
        hasUsableLocalNetwork = false
    }

    private func beginPeerDiscovery(with peerIDs: Set<UUID>, generation: Int) {
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
        peerDiscoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            guard let self,
                  self.runtimeGeneration == generation,
                  self.activeNetworkConnectivity == .discoveringPeers else { return }
            self.activeNetworkConnectivity = .readyNoPeers
            self.peerDiscoveryTask = nil
        }
    }

    private func applyAuthenticatedPeerIDs(_ peerIDs: Set<UUID>) {
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
        } else {
            peerDiscoveryTask?.cancel()
            peerDiscoveryTask = nil
            activeNetworkConnectivity = .connected(peerCount: peerIDs.count)
        }
    }

    private func applyLocalNetworkAvailability(_ isAvailable: Bool, generation: Int) {
        guard hasUsableLocalNetwork != isAvailable else { return }
        hasUsableLocalNetwork = isAvailable
        if isAvailable {
            beginPeerDiscovery(with: onlineMemberIDs, generation: generation)
        } else {
            peerDiscoveryTask?.cancel()
            peerDiscoveryTask = nil
            onlineMemberIDs = []
            activeNetworkConnectivity = .inactive
        }
    }

    private static func describe(_ error: Error) -> String {
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
        if let error = error as? NodeBootstrapError,
           case .invitationAuthorityMismatch = error {
            return "The invitation names this Network ID but was not issued by the authority trusted by the saved profile. The existing profile was not changed."
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
