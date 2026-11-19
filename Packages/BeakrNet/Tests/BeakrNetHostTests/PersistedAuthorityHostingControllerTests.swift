import Foundation
import Testing
import BeakrNetCore
import BeakrNetHost

@Suite("Persisted independent authority hosting")
struct PersistedAuthorityHostingControllerTests {
    @Test("Replacement drains its target and preserves enabled or stopped intent")
    func replacementLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try profile("A"), b = try profile("B")
        let preferences = try AuthorityHostingPreferences.open(fileURL: root.appendingPathComponent("hosting.json"))
        let fixture = PersistedHostingFixture()
        let controller = fixture.controller(preferences)
        _ = try await controller.reconcile(profiles: [a, b], activeProfileID: a.id)
        try await controller.setEnabled(true, for: b)
        try await controller.withStoppedAuthority(for: a) {
            #expect(await fixture.live == Set([b.id]))
        }
        #expect(await fixture.live == Set([a.id, b.id]))
        try await controller.setEnabled(false, for: a)
        try await controller.withStoppedAuthority(for: a) {
            #expect(await fixture.live == Set([b.id]))
        }
        #expect(await fixture.live == Set([b.id]))
        try await controller.removeAuthority(for: b) {
            #expect(await fixture.live.isEmpty)
        }
        #expect(await preferences.records().allSatisfy { $0.profileID != b.id })
        await controller.shutdown()
    }

    @Test("Messaging preparation starts owned authorities and preserves explicit stops across restart")
    func messagingPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hosting.json")
        let a = try profile("A"), b = try profile("B")
        let fixture = PersistedHostingFixture()
        let controller = fixture.controller(try AuthorityHostingPreferences.open(fileURL: url))
        _ = try await controller.reconcile(profiles: [a, b], activeProfileID: nil)
        try await controller.prepareForMessaging(for: a)
        #expect(await fixture.live == [a.id])
        try await controller.prepareForMessaging(for: b, explicitSelection: true)
        #expect(await fixture.live == [a.id, b.id])
        try await controller.setEnabled(false, for: a)
        try await controller.prepareForMessaging(for: a)
        #expect(await fixture.live == [b.id])
        await controller.shutdown()
        let reopened = fixture.controller(try AuthorityHostingPreferences.open(fileURL: url))
        _ = try await reopened.reconcile(profiles: [a, b], activeProfileID: a.id)
        try await reopened.prepareForMessaging(for: a)
        #expect(await fixture.live == [b.id])
        try await reopened.prepareForMessaging(for: a, explicitSelection: true)
        #expect(await fixture.live == [a.id, b.id])
        await reopened.shutdown()
    }

    @Test("A member device cannot start a remote authority during messaging preparation")
    func memberPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try profile("Remote")
        let preferences = try AuthorityHostingPreferences.open(fileURL: root.appendingPathComponent("hosting.json"))
        let controller = PersistedAuthorityHostingController<NetworkProfileID>(
            preferences: preferences, owns: { _ in false },
            start: { profile in Issue.record("A remote authority must not start locally"); return profile.id },
            stop: { _ in }
        )
        _ = try await controller.reconcile(profiles: [a], activeProfileID: a.id)
        try await controller.prepareForMessaging(for: a, explicitSelection: true)
        #expect(await preferences.records().isEmpty)
        await controller.shutdown()
    }

    private func profile(_ name: String) throws -> NetworkProfile {
        try NetworkProfile(networkID: NetworkID(), localNodeID: NodeID(), displayName: name)
    }

    @Test("Messaging selection cannot override hosting intent; restart restores both enabled authorities")
    func independentIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hosting.json")
        let a = try profile("A"), b = try profile("B")
        let fixture = PersistedHostingFixture()
        let preferences = try AuthorityHostingPreferences.open(fileURL: url)
        let controller = fixture.controller(preferences)
        _ = try await controller.reconcile(profiles: [a, b], activeProfileID: a.id)
        #expect(try await controller.runningHandle(for: a) == a.id)
        #expect(try await controller.runningHandle(for: b) == nil)
        try await controller.setEnabled(true, for: b)
        _ = try await controller.reconcile(profiles: [a, b], activeProfileID: b.id)
        #expect(await fixture.live == Set([a.id, b.id]))
        await controller.shutdown()
        #expect(await fixture.live.isEmpty)
        let reopened = fixture.controller(try AuthorityHostingPreferences.open(fileURL: url))
        _ = try await reopened.reconcile(profiles: [a, b], activeProfileID: nil)
        #expect(await fixture.live == Set([a.id, b.id]))
        try await reopened.setEnabled(false, for: a)
        _ = try await reopened.reconcile(profiles: [a, b], activeProfileID: a.id)
        #expect(try await reopened.runningHandle(for: a) == nil)
        #expect(try await reopened.runningHandle(for: b) == b.id)
        await reopened.shutdown()
    }

    @Test("A failed authority does not prevent another enabled authority from starting")
    func isolatedFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try profile("A"), b = try profile("B")
        let preferences = try AuthorityHostingPreferences.open(fileURL: root.appendingPathComponent("hosting.json"))
        try await preferences.initialize(ownedProfiles: [a, b], activeProfileID: a.id)
        try await preferences.setEnabled(true, for: b)
        let fixture = PersistedHostingFixture(failing: a.id)
        let controller = fixture.controller(preferences)
        let statuses = try await controller.reconcile(profiles: [a, b], activeProfileID: a.id)
        #expect(statuses.first(where: { $0.profile.id == a.id })?.state == .failed)
        #expect(statuses.first(where: { $0.profile.id == a.id })?.failure != nil)
        #expect(try await controller.runningHandle(for: b) == b.id)
        await controller.shutdown()
        let ownershipFailure = PersistedAuthorityHostingController<NetworkProfileID>(
            preferences: preferences,
            owns: { profile in
                if profile.id == a.id { throw PersistedAuthorityHostingError.notOwned }
                return true
            }, start: { $0.id }, stop: { _ in }
        )
        let recovered = try await ownershipFailure.reconcile(profiles: [a, b], activeProfileID: a.id)
        #expect(recovered.first(where: { $0.profile.id == a.id })?.state == .failed)
        #expect(try await ownershipFailure.runningHandle(for: b) == b.id)
        await ownershipFailure.shutdown()
    }

    @Test("Ownership and immutable binding are required for administration")
    func administrationBinding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try profile("A"), foreign = try profile("Foreign")
        let preferences = try AuthorityHostingPreferences.open(fileURL: root.appendingPathComponent("hosting.json"))
        let controller = PersistedAuthorityHostingController<NetworkProfileID>(
            preferences: preferences, owns: { $0.id == a.id }, start: { $0.id }, stop: { _ in }
        )
        _ = try await controller.reconcile(profiles: [a, foreign], activeProfileID: a.id)
        await #expect(throws: PersistedAuthorityHostingError.notOwned) {
            try await controller.setEnabled(true, for: foreign)
        }
        let rebound = try NetworkProfile(id: a.id, networkID: foreign.networkID,
                                         localNodeID: a.localNodeID, displayName: "Rebound")
        await #expect(throws: AuthorityHostingError.profileBindingMismatch) {
            try await controller.runningHandle(for: rebound)
        }
        await controller.shutdown()
        await #expect(throws: AuthorityHostingError.shutDown) {
            try await controller.runningHandle(for: a)
        }
    }

    @Test("Persistence failure cannot start a listener")
    func failedWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try profile("A")
        let preferences = try AuthorityHostingPreferences.open(fileURL: root.appendingPathComponent("hosting.json"))
        try Data([1]).write(to: root)
        let fixture = PersistedHostingFixture()
        let controller = fixture.controller(preferences)
        await #expect(throws: (any Error).self) {
            try await controller.reconcile(profiles: [a], activeProfileID: a.id)
        }
        #expect(await fixture.live.isEmpty)
        await controller.shutdown()
    }
}

private actor PersistedHostingFixture {
    var live: Set<NetworkProfileID> = []
    let failing: NetworkProfileID?
    init(failing: NetworkProfileID? = nil) { self.failing = failing }
    nonisolated func controller(_ preferences: AuthorityHostingPreferences)
        -> PersistedAuthorityHostingController<NetworkProfileID> {
        PersistedAuthorityHostingController(preferences: preferences, owns: { _ in true },
                                            start: { try await self.start($0) },
                                            stop: { await self.stop($0) })
    }
    func start(_ profile: NetworkProfile) throws -> NetworkProfileID {
        if profile.id == failing { throw PersistedAuthorityHostingError.notOwned }
        live.insert(profile.id)
        return profile.id
    }
    func stop(_ id: NetworkProfileID) { live.remove(id) }
}
