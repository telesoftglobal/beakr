import Foundation
import Testing
import BeakrNetCore
import BeakrNetHost

@Suite("Profile-owned runtime storage")
struct ProfileRuntimeStorageTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Red and Blue runtime repositories use disjoint bounded roots")
    func profileIsolation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let red = try profile(name: "Red")
        let blue = try profile(name: "Blue")
        let redRoot = directory.appendingPathComponent("red", isDirectory: true)
        let blueRoot = directory.appendingPathComponent("blue", isDirectory: true)

        let redRuntime = try await ProfileRuntimeStorage.open(
            profile: red, rootURL: redRoot, policy: policy(), now: now
        )
        let blueRuntime = try await ProfileRuntimeStorage.open(
            profile: blue, rootURL: blueRoot, policy: policy(), now: now
        )

        #expect(redRuntime.paths.rootURL != blueRuntime.paths.rootURL)
        #expect(redRuntime.paths.persistentURLs.allSatisfy { isDescendant($0, of: redRoot) })
        #expect(blueRuntime.paths.persistentURLs.allSatisfy { isDescendant($0, of: blueRoot) })
        #expect(Set(redRuntime.paths.persistentURLs).isDisjoint(with: Set(blueRuntime.paths.persistentURLs)))
        let redRelayNetworkID = await redRuntime.relayQueue.networkID
        let blueRelayNetworkID = await blueRuntime.relayQueue.networkID
        #expect(redRelayNetworkID == red.networkID)
        #expect(blueRelayNetworkID == blue.networkID)
    }

    @Test("A bound runtime root survives restart and rejects another profile")
    func restartAndMismatch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let red = try profile(name: "Red")
        let root = directory.appendingPathComponent("runtime", isDirectory: true)

        let first = try await ProfileRuntimeStorage.open(
            profile: red, rootURL: root, policy: policy(), now: now
        )
        try await first.checkpointStore.save(.init(
            generation: 1,
            lifecycle: .background,
            checkpointedAt: now,
            cleanShutdown: false
        ))

        let restored = try await ProfileRuntimeStorage.open(
            profile: red, rootURL: root, policy: policy(), now: now
        )
        #expect(await restored.checkpointStore.load()?.generation == 1)

        let blue = try profile(name: "Blue")
        await #expect(throws: ProfileRuntimeStorageError.profileMismatch) {
            _ = try await ProfileRuntimeStorage.open(
                profile: blue, rootURL: root, policy: policy(), now: now
            )
        }
    }

    @Test("Existing unbound content is never adopted by a profile")
    func unboundStorageFailsClosed() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: root.appendingPathComponent("state.json"))
        let red = try profile(name: "Red")

        await #expect(throws: ProfileRuntimeStorageError.unboundNonemptyStorage) {
            _ = try await ProfileRuntimeStorage.open(
                profile: red, rootURL: root, policy: policy(), now: now
            )
        }
    }

    @Test("Message state can live outside the profile-owned runtime root")
    func contextOwnedMessageState() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileRoot = directory.appendingPathComponent("profile", isDirectory: true)
        let messageState = directory
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent("messages.json")
        let red = try profile(name: "Red")

        let runtime = try await ProfileRuntimeStorage.open(
            profile: red,
            rootURL: profileRoot,
            dataStateURL: messageState,
            policy: policy(),
            now: now
        )

        #expect(runtime.paths.dataStateURL == messageState.standardizedFileURL)
        #expect(!isDescendant(runtime.paths.dataStateURL, of: profileRoot))
        #expect(runtime.paths.persistentURLs.filter { $0 != runtime.paths.dataStateURL }
            .allSatisfy { isDescendant($0, of: profileRoot) })
    }

    @Test("Active selection opens exactly one runtime and requires stop before switching")
    func activeRuntimeSelection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = try PersistentNetworkProfileRegistry.open(
            fileURL: directory.appendingPathComponent("profiles.json"),
            profilesRootURL: directory.appendingPathComponent("profiles", isDirectory: true)
        )
        let red = try profile(name: "Red")
        let blue = try profile(name: "Blue")
        try await registry.add(red, activate: true)
        try await registry.add(blue)
        let manager = ActiveProfileRuntimeManager(registry: registry, policy: policy())

        let redRuntime = try await manager.start(now: now)
        #expect(redRuntime.profile.id == red.id)
        await #expect(throws: ActiveProfileRuntimeError.runtimeAlreadyActive(red.id)) {
            try await manager.activate(blue.id)
        }
        try await manager.checkpoint(lifecycle: .background, now: now)
        let backgroundCheckpoint = await redRuntime.checkpointStore.load()
        #expect(backgroundCheckpoint?.lifecycle == .background)
        #expect(backgroundCheckpoint?.cleanShutdown == false)
        try await manager.stop(now: now.addingTimeInterval(1))
        let stoppedCheckpoint = await redRuntime.checkpointStore.load()
        #expect(stoppedCheckpoint?.generation == 2)
        #expect(stoppedCheckpoint?.lifecycle == .stopped)
        #expect(stoppedCheckpoint?.cleanShutdown == true)
        try await manager.activate(blue.id)
        let blueRuntime = try await manager.start(now: now)
        #expect(blueRuntime.profile.id == blue.id)
        #expect(blueRuntime.paths.rootURL != redRuntime.paths.rootURL)
    }

    @Test("Profile diagnostics persist canonically and remain bounded")
    func persistentDiagnostics() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let red = try profile(name: "Red")
        let runtime = try await ProfileRuntimeStorage.open(
            profile: red,
            rootURL: directory,
            policy: policy(diagnosticMaximumEvents: 2),
            now: now
        )
        try await runtime.diagnosticJournal.record(.init(
            timestamp: now,
            subsystem: .lifecycle,
            reason: .started
        ))
        try await runtime.diagnosticJournal.record(.init(
            timestamp: now.addingTimeInterval(1),
            subsystem: .storage,
            reason: .resourceLimit,
            count: 2
        ))
        try await runtime.diagnosticJournal.record(.init(
            timestamp: now.addingTimeInterval(2),
            subsystem: .lifecycle,
            reason: .checkpointed
        ))

        let restored = try await ProfileRuntimeStorage.open(
            profile: red,
            rootURL: directory,
            policy: policy(diagnosticMaximumEvents: 2),
            now: now
        )
        let events = await restored.diagnosticJournal.snapshot()
        #expect(events.count == 2)
        #expect(events.first?.reason == .resourceLimit)
        #expect(FileManager.default.fileExists(atPath: restored.paths.diagnosticExportURL.path))
    }

    private func profile(name: String) throws -> NetworkProfile {
        try NetworkProfile(
            networkID: NetworkID(),
            localNodeID: NodeID(),
            displayName: name,
            createdAt: now
        )
    }

    private func policy(diagnosticMaximumEvents: Int = 1_024) -> ProfileRuntimePolicy {
        ProfileRuntimePolicy(relayQueue: RelayQueuePolicy(
            maximumMessagesPerNode: 8,
            maximumTotalMessages: 16,
            reservedControlMessagesPerNode: 2,
            reservedControlMessagesTotal: 4,
            messageTimeToLive: 60
        ), diagnostics: HostDiagnosticPolicy(
            maximumEvents: diagnosticMaximumEvents,
            maximumExportBytes: 256 * 1_024
        ))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path + "/"
        return candidate.standardizedFileURL.path.hasPrefix(rootPath)
    }
}
