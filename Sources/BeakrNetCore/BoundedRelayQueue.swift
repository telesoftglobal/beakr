import Foundation

public struct RelayQueuePolicy: Equatable, Sendable {
    public let maximumMessagesPerNode: Int
    public let maximumTotalMessages: Int
    public let messageTimeToLive: TimeInterval

    public init(
        maximumMessagesPerNode: Int,
        maximumTotalMessages: Int,
        messageTimeToLive: TimeInterval
    ) {
        precondition(maximumMessagesPerNode > 0)
        precondition(maximumTotalMessages >= maximumMessagesPerNode)
        precondition(messageTimeToLive > 0)
        self.maximumMessagesPerNode = maximumMessagesPerNode
        self.maximumTotalMessages = maximumTotalMessages
        self.messageTimeToLive = messageTimeToLive
    }

    public static let development = RelayQueuePolicy(
        maximumMessagesPerNode: 100,
        maximumTotalMessages: 1_000,
        messageTimeToLive: 5 * 60
    )
}

public actor BoundedRelayQueue {
    private struct Entry: Sendable {
        let envelope: BeakrNetEnvelope
        let enqueuedAt: Date
    }

    public let policy: RelayQueuePolicy
    private var entries: [NodeID: [Entry]] = [:]

    public init(policy: RelayQueuePolicy) {
        self.policy = policy
    }

    public func enqueue(
        _ envelope: BeakrNetEnvelope,
        for destination: NodeID,
        now: Date = Date()
    ) {
        purgeExpired(now: now)

        var destinationEntries = entries[destination, default: []]
        while destinationEntries.count >= policy.maximumMessagesPerNode {
            destinationEntries.removeFirst()
        }
        entries[destination] = destinationEntries

        while totalCount >= policy.maximumTotalMessages {
            evictOldest()
        }
        entries[destination, default: []].append(
            Entry(envelope: envelope, enqueuedAt: now)
        )
    }

    public func drain(for destination: NodeID, now: Date = Date()) -> [BeakrNetEnvelope] {
        purgeExpired(now: now)
        return entries.removeValue(forKey: destination)?.map(\.envelope) ?? []
    }

    public func count(for destination: NodeID, now: Date = Date()) -> Int {
        purgeExpired(now: now)
        return entries[destination]?.count ?? 0
    }

    public func countAll(now: Date = Date()) -> Int {
        purgeExpired(now: now)
        return totalCount
    }

    private var totalCount: Int {
        entries.values.reduce(0) { $0 + $1.count }
    }

    private func purgeExpired(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.messageTimeToLive)
        for destination in Array(entries.keys) {
            entries[destination]?.removeAll { $0.enqueuedAt <= cutoff }
            if entries[destination]?.isEmpty == true {
                entries.removeValue(forKey: destination)
            }
        }
    }

    private func evictOldest() {
        let oldest = entries.compactMap { destination, values in
            values.first.map { (destination, $0.enqueuedAt) }
        }.min { $0.1 < $1.1 }
        guard let destination = oldest?.0 else { return }
        entries[destination]?.removeFirst()
        if entries[destination]?.isEmpty == true {
            entries.removeValue(forKey: destination)
        }
    }
}
