import Foundation
import Testing
@testable import BeakrNetCore

@Suite("Persistent Context registry")
struct ContextRegistryTests {
    @Test("A replacement membership reattaches to the existing network Context")
    func reattachmentPreservesContextAndStoreIdentity() async throws {
        let files = temporaryFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let registry = try PersistentContextRegistry.open(
            fileURL: files.registry,
            contextsRootURL: files.contexts
        )
        let networkID = NetworkID()
        let firstProfile = try NetworkProfile(
            networkID: networkID,
            localNodeID: NodeID(),
            displayName: "Home"
        )

        let original = try await registry.resolve(for: firstProfile)
        try await registry.detach(firstProfile.id)
        let archived = try #require(await registry.context(networkID: networkID))
        #expect(archived.id == original.id)
        #expect(archived.messageStoreID == original.messageStoreID)
        #expect(archived.attachedProfileIDs.isEmpty)

        let replacementProfile = try NetworkProfile(
            networkID: networkID,
            localNodeID: NodeID(),
            displayName: "Home Rejoined"
        )
        let reattached = try await registry.resolve(for: replacementProfile)

        #expect(reattached.id == original.id)
        #expect(reattached.messageStoreID == original.messageStoreID)
        #expect(reattached.attachedProfileIDs == [replacementProfile.id])

        let reopened = try PersistentContextRegistry.open(
            fileURL: files.registry,
            contextsRootURL: files.contexts
        )
        #expect(await reopened.context(networkID: networkID) == reattached)
        #expect(await reopened.messageStoreURL(for: reattached) == files.contexts
            .appendingPathComponent(original.id.rawValue.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("Stores", isDirectory: true)
            .appendingPathComponent(original.messageStoreID.rawValue.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("messages.json"))
    }

    @Test("Different networks receive isolated Context and Store identities")
    func networkIsolation() async throws {
        let files = temporaryFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let registry = try PersistentContextRegistry.open(
            fileURL: files.registry,
            contextsRootURL: files.contexts
        )
        let first = try await registry.resolve(for: NetworkProfile(
            networkID: NetworkID(),
            localNodeID: NodeID(),
            displayName: "First"
        ))
        let second = try await registry.resolve(for: NetworkProfile(
            networkID: NetworkID(),
            localNodeID: NodeID(),
            displayName: "Second"
        ))

        #expect(first.id != second.id)
        #expect(first.messageStoreID != second.messageStoreID)
        #expect(await registry.messageStoreURL(for: first) != registry.messageStoreURL(for: second))
    }

    private func temporaryFiles() -> (directory: URL, registry: URL, contexts: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeakrNetContexts-\(UUID().uuidString)", isDirectory: true)
        return (
            directory,
            directory.appendingPathComponent("contexts.json"),
            directory.appendingPathComponent("Contexts", isDirectory: true)
        )
    }
}
