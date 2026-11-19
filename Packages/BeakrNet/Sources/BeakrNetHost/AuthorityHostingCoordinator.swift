import Foundation
import BeakrNetCore

public enum AuthorityHostingState: Equatable, Sendable {
    case stopped, starting, running, stopping, failed
}

public enum AuthorityHostingError: Error, Equatable, Sendable {
    case profileBindingMismatch, capacityExceeded, operationLimitExceeded, shutDown
}

/// Owns authority lifetimes independently of messaging/UI selection.
/// Adapters must return only after listening, clean up failed starts, and bound
/// their start/stop duration. This coordinator does not grant authority ownership.
public actor AuthorityHostingCoordinator<Handle: Sendable> {
    public typealias Start = @Sendable (NetworkProfile) async throws -> Handle
    public typealias Stop = @Sendable (Handle) async -> Void

    private let startAuthority: Start
    private let stopAuthority: Stop
    private let maximumAuthorities: Int
    private let maximumPendingOperations: Int
    private var entries: [NetworkProfileID: Entry] = [:]
    private var isShutDown = false
    private var shutdownTask: Task<Void, Never>?

    // Accessed only on the coordinator actor.
    private final class Entry {
        let profile: NetworkProfile
        var handle: Handle?
        var state: AuthorityHostingState = .stopped
        var generation: UInt64 = 0
        var pending = 0
        var tail: Task<Void, Never>?
        var startTask: Task<Handle, Error>?
        var stopTask: Task<Void, Never>?

        init(profile: NetworkProfile) { self.profile = profile }
    }

    public init(
        maximumAuthorities: Int = 8,
        maximumPendingOperations: Int = 16,
        start: @escaping Start,
        stop: @escaping Stop
    ) {
        precondition(maximumAuthorities > 0 && maximumPendingOperations > 0)
        self.maximumAuthorities = maximumAuthorities
        self.maximumPendingOperations = maximumPendingOperations
        startAuthority = start
        stopAuthority = stop
    }

    public func state(for profileID: NetworkProfileID) -> AuthorityHostingState {
        entries[profileID]?.state ?? .stopped
    }

    /// Administration must supply the complete immutable profile binding.
    public func runningHandle(for profile: NetworkProfile) throws -> Handle? {
        guard let entry = entries[profile.id] else { return nil }
        guard entry.profile.networkID == profile.networkID,
              entry.profile.localNodeID == profile.localNodeID else {
            throw AuthorityHostingError.profileBindingMismatch
        }
        return entry.state == .running ? entry.handle : nil
    }

    public func forgetStoppedProfile(_ profile: NetworkProfile) throws {
        try validateBinding(profile)
        guard let entry = entries[profile.id] else { return }
        guard entry.state == .stopped, entry.pending == 0, entry.handle == nil else {
            throw AuthorityHostingError.operationLimitExceeded
        }
        entries.removeValue(forKey: profile.id)
    }

    /// Duplicate starts share one operation. Cancelling a waiting caller does
    /// not cancel shared hosting; use stop(profile:) to stop the service.
    @discardableResult
    public func start(profile: NetworkProfile) async throws -> Handle {
        guard !isShutDown else { throw AuthorityHostingError.shutDown }
        let entry = try register(profile)
        if let task = entry.startTask { return try await task.value }
        if entry.state == .running, let handle = entry.handle { return handle }
        guard entry.pending < maximumPendingOperations else {
            throw AuthorityHostingError.operationLimitExceeded
        }
        let previous = entry.tail
        entry.generation += 1
        let generation = entry.generation
        entry.pending += 1
        entry.state = .starting
        entry.stopTask = nil
        let task = Task {
            await previous?.value
            return try await self.performStart(profile: profile, generation: generation)
        }
        entry.startTask = task
        entry.tail = Task { _ = await task.result }
        return try await task.value
    }

    public func stop(profile: NetworkProfile) async throws {
        try validateBinding(profile)
        guard !isShutDown else {
            await shutdownTask?.value
            return
        }
        guard let entry = entries[profile.id] else { return }
        if let task = entry.stopTask {
            await task.value
            return
        }
        if entry.state == .stopped { return }
        guard entry.pending < maximumPendingOperations else {
            throw AuthorityHostingError.operationLimitExceeded
        }
        await enqueueStop(entry).value
    }

    /// Closes admission and drains all owned services, including pending starts.
    /// Saved hosting intent belongs to the caller and is not changed by shutdown.
    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShutDown = true
        let tasks = entries.values.map { enqueueStop($0) }
        let task = Task { for task in tasks { await task.value } }
        shutdownTask = task
        await task.value
    }

    private func register(_ profile: NetworkProfile) throws -> Entry {
        try validateBinding(profile)
        if let entry = entries[profile.id] { return entry }
        guard entries.count < maximumAuthorities else { throw AuthorityHostingError.capacityExceeded }
        guard !entries.values.contains(where: { $0.profile.networkID == profile.networkID }) else {
            throw AuthorityHostingError.profileBindingMismatch
        }
        let entry = Entry(profile: profile)
        entries[profile.id] = entry
        return entry
    }

    private func validateBinding(_ profile: NetworkProfile) throws {
        if let existing = entries[profile.id]?.profile {
            guard existing.networkID == profile.networkID,
                  existing.localNodeID == profile.localNodeID else {
                throw AuthorityHostingError.profileBindingMismatch
            }
        }
    }

    private func enqueueStop(_ entry: Entry) -> Task<Void, Never> {
        if let task = entry.stopTask { return task }
        let previous = entry.tail
        let profileID = entry.profile.id
        entry.generation += 1
        let generation = entry.generation
        entry.pending += 1
        entry.state = .stopping
        entry.startTask = nil
        let task = Task {
            await previous?.value
            await self.performStop(profileID: profileID, generation: generation)
        }
        entry.stopTask = task
        entry.tail = task
        return task
    }

    private func performStart(profile: NetworkProfile, generation: UInt64) async throws -> Handle {
        do {
            let handle = try await startAuthority(profile)
            // Superseded starts stay owned until their queued stop drains them.
            entries[profile.id]?.handle = handle
            complete(profileID: profile.id, generation: generation, state: .running)
            return handle
        } catch {
            complete(profileID: profile.id, generation: generation, state: .failed)
            throw error
        }
    }

    private func performStop(profileID: NetworkProfileID, generation: UInt64) async {
        if let handle = entries[profileID]?.handle {
            await stopAuthority(handle)
            entries[profileID]?.handle = nil
        }
        complete(profileID: profileID, generation: generation, state: .stopped)
    }

    private func complete(
        profileID: NetworkProfileID, generation: UInt64, state: AuthorityHostingState
    ) {
        guard let entry = entries[profileID] else { return }
        entry.pending -= 1
        guard entry.generation == generation else { return }
        entry.state = state
        entry.startTask = nil
        entry.stopTask = nil
        entry.tail = nil
    }
}
