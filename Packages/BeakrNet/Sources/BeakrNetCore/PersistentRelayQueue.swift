import Foundation

public enum PersistentRelayQueueError: Error, Equatable {
    case unsupportedFormatVersion(Int)
}

/// A durable facade over `BoundedRelayQueue` that atomically replaces its snapshot.
public actor PersistentRelayQueue {
    private struct Snapshot: Codable {
        static let currentFormatVersion = 1

        let formatVersion: Int
        let entries: [RelayQueueStoredEntry]
    }

    public let policy: RelayQueuePolicy
    public let fileURL: URL
    private let queue: BoundedRelayQueue

    private init(policy: RelayQueuePolicy, fileURL: URL) {
        self.policy = policy
        self.fileURL = fileURL
        queue = BoundedRelayQueue(policy: policy)
    }

    public static func open(
        policy: RelayQueuePolicy,
        fileURL: URL,
        now: Date = Date()
    ) async throws -> PersistentRelayQueue {
        let persistentQueue = PersistentRelayQueue(policy: policy, fileURL: fileURL)
        try await persistentQueue.restore(now: now)
        return persistentQueue
    }

    @discardableResult
    public func enqueue(
        _ envelope: BeakrNetEnvelope,
        for destination: NodeID,
        now: Date = Date()
    ) async throws -> RelayQueueAdmission {
        let admission = await queue.enqueue(envelope, for: destination, now: now)
        try await persist(now: now)
        return admission
    }

    public func drain(for destination: NodeID, now: Date = Date()) async throws -> [BeakrNetEnvelope] {
        let envelopes = await queue.drain(for: destination, now: now)
        try await persist(now: now)
        return envelopes
    }

    public func count(for destination: NodeID, now: Date = Date()) async -> Int {
        await queue.count(for: destination, now: now)
    }

    public func countAll(now: Date = Date()) async -> Int {
        await queue.countAll(now: now)
    }

    public func diagnostics(now: Date = Date()) async -> RelayQueueDiagnostics {
        await queue.diagnostics(now: now)
    }

    private func restore(now: Date) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.formatVersion == Snapshot.currentFormatVersion else {
            throw PersistentRelayQueueError.unsupportedFormatVersion(snapshot.formatVersion)
        }

        for entry in snapshot.entries.sorted(by: { $0.enqueuedAt < $1.enqueuedAt }) {
            await queue.enqueue(entry.envelope, for: entry.destination, now: entry.enqueuedAt)
        }
        try await persist(now: now)
    }

    private func persist(now: Date) async throws {
        let entries = await queue.storedEntries(now: now)
        let snapshot = Snapshot(formatVersion: Snapshot.currentFormatVersion, entries: entries)
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
