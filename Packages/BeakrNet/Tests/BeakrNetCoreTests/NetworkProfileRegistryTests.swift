import Foundation
import Testing
@testable import BeakrNetCore

@Suite("Persistent network profile registry")
struct NetworkProfileRegistryTests {
    private let redProfileID = NetworkProfileID(rawValue: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!)
    private let blueProfileID = NetworkProfileID(rawValue: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!)
    private let redNetworkID = NetworkID(rawValue: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!)
    private let blueNetworkID = NetworkID(rawValue: UUID(uuidString: "20000000-0000-4000-8000-000000000002")!)
    private let redNodeID = NodeID(rawValue: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!)
    private let blueNodeID = NodeID(rawValue: UUID(uuidString: "30000000-0000-4000-8000-000000000002")!)

    @Test("Red and Blue persist with explicit activation and isolated storage roots")
    func activationAndStorageIsolation() async throws {
        let files = temporaryFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let registry = try PersistentNetworkProfileRegistry.open(
            fileURL: files.registry,
            profilesRootURL: files.profiles
        )
        let red = try profile(id: redProfileID, networkID: redNetworkID, nodeID: redNodeID, name: "Red Network", second: 1)
        let blue = try profile(id: blueProfileID, networkID: blueNetworkID, nodeID: blueNodeID, name: "Blue Network", second: 2)

        try await registry.add(red)
        try await registry.add(blue)
        #expect(await registry.activeProfile() == red)

        let redRoot = try await registry.storageRoot(for: redProfileID)
        let blueRoot = try await registry.storageRoot(for: blueProfileID)
        #expect(redRoot != blueRoot)
        #expect(FileManager.default.fileExists(atPath: redRoot.path))
        #expect(FileManager.default.fileExists(atPath: blueRoot.path))
        #expect(redRoot.path.contains(redNetworkID.rawValue.uuidString.lowercased()))
        #expect(blueRoot.path.contains(blueNetworkID.rawValue.uuidString.lowercased()))

        try await registry.activate(blueProfileID)
        #expect(await registry.activeProfile() == blue)

        let originalBytes = try Data(contentsOf: files.registry)
        let reopened = try PersistentNetworkProfileRegistry.open(
            fileURL: files.registry,
            profilesRootURL: files.profiles
        )
        #expect(await reopened.profiles() == [red, blue])
        #expect(await reopened.activeProfile() == blue)
        #expect(try Data(contentsOf: files.registry) == originalBytes)
    }

    @Test("Profile names, uniqueness, capacity, and active removal fail closed")
    func boundedMutations() async throws {
        #expect(throws: NetworkProfileRegistryError.invalidDisplayName) {
            try NetworkProfile(networkID: redNetworkID, localNodeID: redNodeID, displayName: "   ")
        }

        let files = temporaryFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let registry = try PersistentNetworkProfileRegistry.open(
            fileURL: files.registry,
            profilesRootURL: files.profiles,
            maximumProfiles: 2
        )
        let red = try profile(id: redProfileID, networkID: redNetworkID, nodeID: redNodeID, name: "Red", second: 1)
        try await registry.add(red)

        await #expect(throws: NetworkProfileRegistryError.activeProfileRemoval(redProfileID)) {
            try await registry.remove(redProfileID)
        }
        let duplicateNetwork = try profile(id: blueProfileID, networkID: redNetworkID, nodeID: blueNodeID, name: "Duplicate", second: 2)
        await #expect(throws: NetworkProfileRegistryError.duplicateNetworkID(redNetworkID)) {
            try await registry.add(duplicateNetwork)
        }

        let blue = try profile(id: blueProfileID, networkID: blueNetworkID, nodeID: blueNodeID, name: "Blue", second: 2)
        try await registry.add(blue)
        let third = try NetworkProfile(networkID: NetworkID(), localNodeID: NodeID(), displayName: "Third")
        await #expect(throws: NetworkProfileRegistryError.capacityExceeded(maximumProfiles: 2)) {
            try await registry.add(third)
        }

        try await registry.activate(blueProfileID)
        try await registry.remove(redProfileID)
        #expect(await registry.profile(id: redProfileID) == nil)
        #expect(FileManager.default.fileExists(atPath: (try await registry.storageRoot(for: blueProfileID)).path))
    }

    @Test("Unsupported snapshots are rejected while valid alternate JSON formatting is accepted")
    func strictPersistence() async throws {
        let files = temporaryFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let registry = try PersistentNetworkProfileRegistry.open(fileURL: files.registry, profilesRootURL: files.profiles)
        try await registry.add(try profile(id: redProfileID, networkID: redNetworkID, nodeID: redNodeID, name: "Red", second: 1))

        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: files.registry)) as? [String: Any])
        object["formatVersion"] = 2
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: files.registry, options: .atomic)
        #expect(throws: NetworkProfileRegistryError.unsupportedFormatVersion(2)) {
            try PersistentNetworkProfileRegistry.open(fileURL: files.registry, profilesRootURL: files.profiles)
        }

        object["formatVersion"] = 1
        let noncanonical = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try noncanonical.write(to: files.registry, options: .atomic)
        let reopened = try PersistentNetworkProfileRegistry.open(fileURL: files.registry, profilesRootURL: files.profiles)
        #expect(await reopened.profiles().count == 1)
        #expect(await reopened.activeProfile()?.networkID == redNetworkID)
        #expect(try Data(contentsOf: files.registry) == noncanonical)
    }

    private func profile(
        id: NetworkProfileID,
        networkID: NetworkID,
        nodeID: NodeID,
        name: String,
        second: TimeInterval
    ) throws -> NetworkProfile {
        try NetworkProfile(
            id: id,
            networkID: networkID,
            localNodeID: nodeID,
            displayName: name,
            createdAt: Date(timeIntervalSince1970: second)
        )
    }

    private func temporaryFiles() -> (directory: URL, registry: URL, profiles: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeakrNetProfiles-\(UUID().uuidString)", isDirectory: true)
        return (
            directory,
            directory.appendingPathComponent("profiles.json"),
            directory.appendingPathComponent("Profiles", isDirectory: true)
        )
    }
}
