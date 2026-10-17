import Foundation
import BeakrBlackboard
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetData
import BeakrNetTransfer

public enum ProfileRuntimeStorageError: Error, Equatable, Sendable {
    case unsupportedManifestVersion(Int)
    case noncanonicalManifest
    case profileMismatch
    case networkMismatch
    case localNodeMismatch
    case unboundNonemptyStorage
}

public struct ProfileRuntimePaths: Equatable, Sendable {
    public let rootURL: URL
    public let manifestURL: URL
    public let checkpointURL: URL
    public let dataStateURL: URL
    public let blackboardRepositoryURL: URL
    public let transferRootURL: URL
    public let relayQueueURL: URL
    public let revocationSnapshotURL: URL
    public let membershipSnapshotURL: URL
    public let diagnosticExportURL: URL

    public init(rootURL: URL, dataStateURL: URL? = nil) {
        let root = rootURL.standardizedFileURL
        self.rootURL = root
        manifestURL = root.appendingPathComponent("profile-runtime.json")
        checkpointURL = root.appendingPathComponent("host/checkpoint.json")
        self.dataStateURL = dataStateURL?.standardizedFileURL
            ?? root.appendingPathComponent("data/state.json")
        blackboardRepositoryURL = root.appendingPathComponent("blackboard/repository.json")
        transferRootURL = root.appendingPathComponent("transfer", isDirectory: true)
        relayQueueURL = root.appendingPathComponent("relay/queue.json")
        revocationSnapshotURL = root.appendingPathComponent("trust/revocations.json")
        membershipSnapshotURL = root.appendingPathComponent("trust/membership.json")
        diagnosticExportURL = root.appendingPathComponent("diagnostics/events.json")
    }

    public var persistentURLs: [URL] {
        [
            manifestURL, checkpointURL, dataStateURL, blackboardRepositoryURL,
            transferRootURL, relayQueueURL, revocationSnapshotURL, membershipSnapshotURL,
            diagnosticExportURL
        ]
    }
}

public struct ProfileRuntimePolicy: Sendable {
    public let relayQueue: RelayQueuePolicy
    public let blackboard: BlackboardPolicy
    public let transfer: TransferStagingPolicy
    public let diagnostics: HostDiagnosticPolicy
    public let maximumOutgoingDataMessages: Int
    public let maximumIncomingDataResults: Int

    public init(
        relayQueue: RelayQueuePolicy,
        blackboard: BlackboardPolicy = BlackboardPolicy(),
        transfer: TransferStagingPolicy = TransferStagingPolicy(),
        diagnostics: HostDiagnosticPolicy = HostDiagnosticPolicy(),
        maximumOutgoingDataMessages: Int = 4_096,
        maximumIncomingDataResults: Int = 8_192
    ) {
        precondition(maximumOutgoingDataMessages > 0 && maximumIncomingDataResults > 0)
        self.relayQueue = relayQueue
        self.blackboard = blackboard
        self.transfer = transfer
        self.diagnostics = diagnostics
        self.maximumOutgoingDataMessages = maximumOutgoingDataMessages
        self.maximumIncomingDataResults = maximumIncomingDataResults
    }
}

public struct ProfileRuntimeRepositories: Sendable {
    public let profile: NetworkProfile
    public let paths: ProfileRuntimePaths
    public let checkpointStore: FileHostCheckpointStore
    public let dataState: PersistentDataState
    public let blackboardRepository: PersistentBlackboardRepository
    public let transferStore: TransferStagingStore
    public let relayQueue: PersistentRelayQueue
    public let revocationStore: FileRevocationSnapshotStore
    public let diagnosticJournal: PersistentHostDiagnosticJournal
}

/// Opens all durable host state beneath one profile-owned root. The canonical
/// manifest binds that root to exactly one Profile ID, Network ID, and Node ID.
public enum ProfileRuntimeStorage {
    private struct Manifest: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let profileID: NetworkProfileID
        let networkID: NetworkID
        let localNodeID: NodeID
    }

    public static func open(
        profile: NetworkProfile,
        rootURL: URL,
        dataStateURL: URL? = nil,
        policy: ProfileRuntimePolicy,
        now: Date = Date()
    ) async throws -> ProfileRuntimeRepositories {
        let paths = ProfileRuntimePaths(rootURL: rootURL, dataStateURL: dataStateURL)
        try bind(profile: profile, paths: paths)

        let checkpoint = try FileHostCheckpointStore.open(fileURL: paths.checkpointURL)
        let data = try await PersistentDataState.open(
            fileURL: paths.dataStateURL,
            maximumOutgoing: policy.maximumOutgoingDataMessages,
            maximumIncoming: policy.maximumIncomingDataResults,
            now: now
        )
        let blackboard = try await PersistentBlackboardRepository.open(
            fileURL: paths.blackboardRepositoryURL,
            policy: policy.blackboard
        )
        let transfer = try await TransferStagingStore.open(
            rootURL: paths.transferRootURL,
            policy: policy.transfer,
            now: now
        )
        let relay = try await PersistentRelayQueue.open(
            networkID: profile.networkID,
            policy: policy.relayQueue,
            fileURL: paths.relayQueueURL,
            now: now
        )

        return ProfileRuntimeRepositories(
            profile: profile,
            paths: paths,
            checkpointStore: checkpoint,
            dataState: data,
            blackboardRepository: blackboard,
            transferStore: transfer,
            relayQueue: relay,
            revocationStore: FileRevocationSnapshotStore(fileURL: paths.revocationSnapshotURL),
            diagnosticJournal: try PersistentHostDiagnosticJournal.open(
                fileURL: paths.diagnosticExportURL,
                policy: policy.diagnostics
            )
        )
    }

    private static func bind(profile: NetworkProfile, paths: ProfileRuntimePaths) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.rootURL, withIntermediateDirectories: true)
        let expected = Manifest(
            version: Manifest.currentVersion,
            profileID: profile.id,
            networkID: profile.networkID,
            localNodeID: profile.localNodeID
        )
        let encoder = makeEncoder()

        if fileManager.fileExists(atPath: paths.manifestURL.path) {
            let data = try Data(contentsOf: paths.manifestURL)
            let actual = try JSONDecoder().decode(Manifest.self, from: data)
            guard actual.version == Manifest.currentVersion else {
                throw ProfileRuntimeStorageError.unsupportedManifestVersion(actual.version)
            }
            guard try encoder.encode(actual) == data else {
                throw ProfileRuntimeStorageError.noncanonicalManifest
            }
            guard actual.profileID == expected.profileID else {
                throw ProfileRuntimeStorageError.profileMismatch
            }
            guard actual.networkID == expected.networkID else {
                throw ProfileRuntimeStorageError.networkMismatch
            }
            guard actual.localNodeID == expected.localNodeID else {
                throw ProfileRuntimeStorageError.localNodeMismatch
            }
            return
        }

        let existing = try fileManager.contentsOfDirectory(
            at: paths.rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard existing.isEmpty else { throw ProfileRuntimeStorageError.unboundNonemptyStorage }
        try encoder.encode(expected).write(to: paths.manifestURL, options: .atomic)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public enum ActiveProfileRuntimeError: Error, Equatable, Sendable {
    case noActiveProfile
    case runtimeAlreadyActive(NetworkProfileID)
    case runtimeNotActive
    case checkpointGenerationExhausted
}

/// Serializes profile selection and runtime opening. A profile can only be
/// changed while no runtime is active, preventing overlapping route ownership.
public actor ActiveProfileRuntimeManager {
    public let registry: PersistentNetworkProfileRegistry
    public let policy: ProfileRuntimePolicy
    public let dataStateURL: URL?
    private var activeRuntime: ProfileRuntimeRepositories?

    public init(
        registry: PersistentNetworkProfileRegistry,
        policy: ProfileRuntimePolicy,
        dataStateURL: URL? = nil
    ) {
        self.registry = registry
        self.policy = policy
        self.dataStateURL = dataStateURL
    }

    public func start(now: Date = Date()) async throws -> ProfileRuntimeRepositories {
        if let activeRuntime {
            throw ActiveProfileRuntimeError.runtimeAlreadyActive(activeRuntime.profile.id)
        }
        guard let profile = await registry.activeProfile() else {
            throw ActiveProfileRuntimeError.noActiveProfile
        }
        let root = try await registry.storageRoot(for: profile.id)
        let runtime = try await ProfileRuntimeStorage.open(
            profile: profile,
            rootURL: root,
            dataStateURL: dataStateURL,
            policy: policy,
            now: now
        )
        activeRuntime = runtime
        return runtime
    }

    public func checkpoint(
        lifecycle: HostLifecycleState,
        cleanShutdown: Bool = false,
        now: Date = Date()
    ) async throws {
        guard let activeRuntime else { throw ActiveProfileRuntimeError.runtimeNotActive }
        let generation = await activeRuntime.checkpointStore.load()?.generation ?? 0
        guard generation < UInt64.max else {
            throw ActiveProfileRuntimeError.checkpointGenerationExhausted
        }
        try await activeRuntime.checkpointStore.save(.init(
            generation: generation + 1,
            lifecycle: lifecycle,
            checkpointedAt: now,
            cleanShutdown: cleanShutdown
        ))
        try await activeRuntime.diagnosticJournal.record(.init(
            timestamp: now,
            subsystem: .lifecycle,
            reason: .checkpointed,
            count: generation + 1
        ))
    }

    public func stop(now: Date = Date()) async throws {
        guard let activeRuntime else { throw ActiveProfileRuntimeError.runtimeNotActive }
        try await checkpoint(lifecycle: .stopped, cleanShutdown: true, now: now)
        try await activeRuntime.diagnosticJournal.record(.init(
            timestamp: now,
            subsystem: .lifecycle,
            reason: .stopped
        ))
        self.activeRuntime = nil
    }

    public func activate(_ profileID: NetworkProfileID) async throws {
        if let activeRuntime {
            throw ActiveProfileRuntimeError.runtimeAlreadyActive(activeRuntime.profile.id)
        }
        try await registry.activate(profileID)
    }

    public func activeProfile() -> NetworkProfile? { activeRuntime?.profile }
}
