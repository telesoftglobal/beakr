import Foundation
import Testing
import BeakrNetCore
import BeakrNetHost

@Suite("Persistent authority hosting intent")
struct AuthorityHostingPreferencesTests {
    private func profile() throws -> NetworkProfile {
        try NetworkProfile(networkID: NetworkID(), localNodeID: NodeID(), displayName: "Disposable")
    }

    @Test("Initialization enables only the active owned authority; explicit stop survives reopen")
    func restart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hosting.json")
        let a = try profile()
        let b = try profile()
        let store = try AuthorityHostingPreferences.open(fileURL: url)
        try await store.initialize(ownedProfiles: [a, b], activeProfileID: a.id)
        #expect(try await store.isEnabled(for: a))
        #expect(try await !store.isEnabled(for: b))
        try await store.setEnabled(false, for: a)
        try await store.setEnabled(true, for: b)
        let reopened = try AuthorityHostingPreferences.open(fileURL: url)
        try await reopened.initialize(ownedProfiles: [a, b], activeProfileID: a.id)
        #expect(try await !reopened.isEnabled(for: a))
        #expect(try await reopened.isEnabled(for: b))
        #expect(await reopened.records().count == 2)
    }

    @Test("Empty initialization stays initialized; later profiles require explicit intent")
    func emptyInitialization() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hosting.json")
        let a = try profile()
        let store = try AuthorityHostingPreferences.open(fileURL: url)
        await #expect(throws: AuthorityHostingPreferencesError.notInitialized) {
            try await store.setEnabled(true, for: a)
        }
        try await store.initialize(ownedProfiles: [], activeProfileID: nil)
        let reopened = try AuthorityHostingPreferences.open(fileURL: url)
        try await reopened.initialize(ownedProfiles: [a], activeProfileID: a.id)
        #expect(await reopened.isInitialized())
        #expect(try await !reopened.isEnabled(for: a))
        try await reopened.setEnabled(true, for: a)
        #expect(try await reopened.isEnabled(for: a))
    }

    @Test("Invalid bindings and capacity do not modify saved intent")
    func bindingAndCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hosting.json")
        let a = try profile()
        let b = try profile()
        let store = try AuthorityHostingPreferences.open(fileURL: url, maximumAuthorities: 1)
        try await store.initialize(ownedProfiles: [a], activeProfileID: a.id)
        let before = try Data(contentsOf: url)
        let mismatch = try NetworkProfile(
            id: a.id, networkID: NetworkID(), localNodeID: a.localNodeID, displayName: "Mismatch"
        )
        await #expect(throws: AuthorityHostingPreferencesError.profileBindingMismatch) {
            try await store.setEnabled(false, for: mismatch)
        }
        await #expect(throws: AuthorityHostingPreferencesError.capacityExceeded) {
            try await store.setEnabled(true, for: b)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(try await store.isEnabled(for: a))
    }

    @Test("A failed atomic write leaves in-memory intent unchanged")
    func failedWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hosting.json")
        let a = try profile()
        let store = try AuthorityHostingPreferences.open(fileURL: url)
        try await store.initialize(ownedProfiles: [a], activeProfileID: a.id)
        // Only this disposable fixture is replaced with a blocking regular file.
        try FileManager.default.removeItem(at: directory)
        try Data("block".utf8).write(to: directory)
        await #expect(throws: (any Error).self) {
            try await store.setEnabled(false, for: a)
        }
        #expect(try await store.isEnabled(for: a))
    }

    @Test("Corrupt, oversized and unsupported snapshots fail without resetting")
    func corruptSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("hosting.json")
        for data in [
            Data("not-json".utf8), Data(repeating: 32, count: 65_537),
            Data(#"{"version":2,"initialized":true,"records":[]}"#.utf8)
        ] {
            try data.write(to: url)
            #expect(throws: (any Error).self) { try AuthorityHostingPreferences.open(fileURL: url) }
            #expect(try Data(contentsOf: url) == data)
        }
    }
}
