import Foundation
import BeakrNetCore

public enum PersistedAuthorityHostingError: Error, Equatable, Sendable {
    case notOwned
}

/// Serializes intent persistence with listener transitions. Messaging preparation
/// starts owned authorities unless explicitly stopped; explicit selection can restart them.
/// Selecting another network never stops an existing authority.
public actor PersistedAuthorityHostingController<Handle: Sendable> {
    public struct Status: Sendable {
        public let profile: NetworkProfile
        public let enabled: Bool
        public let state: AuthorityHostingState
        public let failure: String?
    }

    private let preferences: AuthorityHostingPreferences
    private let coordinator: AuthorityHostingCoordinator<Handle>
    private let owns: @Sendable (NetworkProfile) async throws -> Bool
    private var tail: Task<Void, Never>?
    private var pending = 0
    private var closed = false

    public init(preferences: AuthorityHostingPreferences,
                owns: @escaping @Sendable (NetworkProfile) async throws -> Bool,
                start: @escaping AuthorityHostingCoordinator<Handle>.Start,
                stop: @escaping AuthorityHostingCoordinator<Handle>.Stop) {
        self.preferences = preferences
        self.owns = owns
        coordinator = AuthorityHostingCoordinator(start: start, stop: stop)
    }

    public func reconcile(profiles: [NetworkProfile], activeProfileID: NetworkProfileID?) async throws -> [Status] {
        try await enqueue {
            var owned: [NetworkProfile] = []
            var statuses: [Status] = []
            for profile in profiles {
                do {
                    if try await self.owns(profile) { owned.append(profile) }
                } catch {
                    let enabled = (try? await self.preferences.isEnabled(for: profile)) ?? false
                    statuses.append(Status(profile: profile, enabled: enabled, state: .failed,
                                           failure: String(describing: error)))
                }
            }
            try await self.preferences.initialize(ownedProfiles: owned, activeProfileID: activeProfileID)
            for profile in owned {
                let enabled = try await self.preferences.isEnabled(for: profile)
                var failure: String?
                do {
                    if enabled { _ = try await self.coordinator.start(profile: profile) }
                    else { try await self.coordinator.stop(profile: profile) }
                } catch { failure = String(describing: error) }
                statuses.append(Status(profile: profile, enabled: enabled,
                                       state: await self.coordinator.state(for: profile.id), failure: failure))
            }
            return statuses
        }
    }

    public func setEnabled(_ enabled: Bool, for profile: NetworkProfile) async throws {
        try await enqueue {
            guard try await self.owns(profile) else { throw PersistedAuthorityHostingError.notOwned }
            try await self.preferences.setEnabled(enabled, for: profile)
            if enabled { _ = try await self.coordinator.start(profile: profile) }
            else { try await self.coordinator.stop(profile: profile) }
        }
    }

    /// Explicit messaging selection may restart hosting. Automatic recovery respects
    /// a persisted user stop, including after an application restart.
    public func prepareForMessaging(for profile: NetworkProfile, explicitSelection: Bool = false) async throws {
        try await enqueue {
            try Task.checkCancellation()
            guard try await self.owns(profile) else { return }
            if !explicitSelection, try await self.preferences.wasExplicitlyStopped(for: profile) { return }
            try await self.preferences.setEnabled(true, for: profile)
            _ = try await self.coordinator.start(profile: profile)
        }
    }

    public func runningHandle(for profile: NetworkProfile) async throws -> Handle? {
        guard !closed else { throw AuthorityHostingError.shutDown }
        guard try await owns(profile) else { throw PersistedAuthorityHostingError.notOwned }
        guard !closed else { throw AuthorityHostingError.shutDown }
        return try await coordinator.runningHandle(for: profile)
    }

    public func shutdown() async {
        closed = true
        await tail?.value
        await coordinator.shutdown()
    }

    public func status(for profile: NetworkProfile) async throws -> Status {
        Status(profile: profile, enabled: try await preferences.isEnabled(for: profile),
               state: await coordinator.state(for: profile.id), failure: nil)
    }

    public func removeAuthority(for profile: NetworkProfile,
                                operation: @escaping @Sendable () async throws -> Void) async throws {
        try await enqueue {
            guard try await self.owns(profile) else { throw PersistedAuthorityHostingError.notOwned }
            try await self.preferences.setEnabled(false, for: profile)
            try await self.coordinator.stop(profile: profile)
            try await operation()
            try await self.preferences.removeStoppedProfile(profile)
            try await self.coordinator.forgetStoppedProfile(profile)
        }
    }

    /// Replacement work runs only after this profile's listener drains. Restore
    /// through the same owner afterwards, preserving explicit stopped intent.
    public func withStoppedAuthority<Value: Sendable>(
        for profile: NetworkProfile,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await enqueue {
            guard try await self.owns(profile) else { throw PersistedAuthorityHostingError.notOwned }
            let enabled = try await self.preferences.isEnabled(for: profile)
            try await self.coordinator.stop(profile: profile)
            let value = try await operation()
            if enabled { _ = try await self.coordinator.start(profile: profile) }
            return value
        }
    }

    private func enqueue<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard !closed else { throw AuthorityHostingError.shutDown }
        guard pending < 16 else { throw AuthorityHostingError.operationLimitExceeded }
        pending += 1
        let previous = tail
        let task = Task {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = await task.result }
        defer { pending -= 1 }
        return try await task.value
    }
}
