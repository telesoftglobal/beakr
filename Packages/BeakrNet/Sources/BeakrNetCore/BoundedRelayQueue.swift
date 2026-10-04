import Foundation

public struct RelayQueuePolicy: Equatable, Sendable {
    public let maximumMessagesPerNode: Int
    public let maximumTotalMessages: Int
    public let reservedControlMessagesPerNode: Int
    public let reservedControlMessagesTotal: Int
    public let maximumConsecutiveControlMessages: Int
    public let messageTimeToLive: TimeInterval

    public init(
        maximumMessagesPerNode: Int,
        maximumTotalMessages: Int,
        reservedControlMessagesPerNode: Int = 0,
        reservedControlMessagesTotal: Int = 0,
        maximumConsecutiveControlMessages: Int = 4,
        messageTimeToLive: TimeInterval
    ) {
        precondition(maximumMessagesPerNode > 0)
        precondition(maximumTotalMessages >= maximumMessagesPerNode)
        precondition((0...maximumMessagesPerNode).contains(reservedControlMessagesPerNode))
        precondition((0...maximumTotalMessages).contains(reservedControlMessagesTotal))
        precondition(maximumConsecutiveControlMessages > 0)
        precondition(messageTimeToLive > 0)
        self.maximumMessagesPerNode = maximumMessagesPerNode
        self.maximumTotalMessages = maximumTotalMessages
        self.reservedControlMessagesPerNode = reservedControlMessagesPerNode
        self.reservedControlMessagesTotal = reservedControlMessagesTotal
        self.maximumConsecutiveControlMessages = maximumConsecutiveControlMessages
        self.messageTimeToLive = messageTimeToLive
    }

    public static let development = RelayQueuePolicy(
        maximumMessagesPerNode: 100,
        maximumTotalMessages: 1_000,
        reservedControlMessagesPerNode: 10,
        reservedControlMessagesTotal: 100,
        maximumConsecutiveControlMessages: 4,
        messageTimeToLive: 5 * 60
    )
}

public enum RelayQueueEvictionReason: Equatable, Sendable {
    case perNodeLimit
    case globalLimit
}

public struct RelayQueueEviction: Equatable, Sendable {
    public let messageID: MessageID
    public let reason: RelayQueueEvictionReason
}

public struct RelayQueueAdmission: Equatable, Sendable {
    public let evictions: [RelayQueueEviction]

    public init(evictions: [RelayQueueEviction] = []) {
        self.evictions = evictions
    }
}

public struct RelayQueueDiagnostics: Equatable, Sendable {
    public let controlMessages: Int
    public let applicationMessages: Int
    public let admittedMessages: UInt64
    public let evictedMessages: UInt64
    public let expiredMessages: UInt64

    public var totalMessages: Int { controlMessages + applicationMessages }
}

public actor BoundedRelayQueue {
    private struct Entry: Sendable {
        let envelope: BeakrNetEnvelope
        let enqueuedAt: Date
    }

    private struct DestinationQueue: Sendable {
        var control: [Entry] = []
        var application: [Entry] = []
        var count: Int { control.count + application.count }
    }

    public let policy: RelayQueuePolicy
    private var entries: [NodeID: DestinationQueue] = [:]
    private var admittedMessages: UInt64 = 0
    private var evictedMessages: UInt64 = 0
    private var expiredMessages: UInt64 = 0

    public init(policy: RelayQueuePolicy) {
        self.policy = policy
    }

    @discardableResult
    public func enqueue(
        _ envelope: BeakrNetEnvelope,
        for destination: NodeID,
        now: Date = Date()
    ) -> RelayQueueAdmission {
        purgeExpired(now: now)
        var evictions: [RelayQueueEviction] = []

        let perNodeApplicationLimit = policy.maximumMessagesPerNode - policy.reservedControlMessagesPerNode
        if envelope.channel != .control,
           entries[destination, default: DestinationQueue()].application.count >= perNodeApplicationLimit {
            if let messageID = removeOldestApplication(for: destination) {
                evictions.append(RelayQueueEviction(messageID: messageID, reason: .perNodeLimit))
            }
        } else if entries[destination, default: DestinationQueue()].count >= policy.maximumMessagesPerNode {
            if let messageID = removeOldestPreferApplication(for: destination) {
                evictions.append(RelayQueueEviction(messageID: messageID, reason: .perNodeLimit))
            }
        }

        let globalApplicationLimit = policy.maximumTotalMessages - policy.reservedControlMessagesTotal
        if envelope.channel != .control, applicationCount >= globalApplicationLimit {
            if let messageID = removeOldestApplication() {
                evictions.append(RelayQueueEviction(messageID: messageID, reason: .globalLimit))
            }
        } else if totalCount >= policy.maximumTotalMessages {
            if let messageID = removeOldestPreferApplication() {
                evictions.append(RelayQueueEviction(messageID: messageID, reason: .globalLimit))
            }
        }

        let entry = Entry(envelope: envelope, enqueuedAt: now)
        if envelope.channel == .control {
            entries[destination, default: DestinationQueue()].control.append(entry)
        } else {
            entries[destination, default: DestinationQueue()].application.append(entry)
        }
        admittedMessages += 1
        evictedMessages += UInt64(evictions.count)
        return RelayQueueAdmission(evictions: evictions)
    }

    public func drain(for destination: NodeID, now: Date = Date()) -> [BeakrNetEnvelope] {
        purgeExpired(now: now)
        guard let queue = entries.removeValue(forKey: destination) else { return [] }
        var control = queue.control
        var application = queue.application
        var drained: [BeakrNetEnvelope] = []
        while !control.isEmpty || !application.isEmpty {
            for _ in 0..<policy.maximumConsecutiveControlMessages where !control.isEmpty {
                drained.append(control.removeFirst().envelope)
            }
            if !application.isEmpty {
                drained.append(application.removeFirst().envelope)
            }
        }
        return drained
    }

    public func count(for destination: NodeID, now: Date = Date()) -> Int {
        purgeExpired(now: now)
        return entries[destination]?.count ?? 0
    }

    public func countAll(now: Date = Date()) -> Int {
        purgeExpired(now: now)
        return totalCount
    }

    public func diagnostics(now: Date = Date()) -> RelayQueueDiagnostics {
        purgeExpired(now: now)
        return RelayQueueDiagnostics(
            controlMessages: controlCount,
            applicationMessages: applicationCount,
            admittedMessages: admittedMessages,
            evictedMessages: evictedMessages,
            expiredMessages: expiredMessages
        )
    }

    func storedEntries(now: Date = Date()) -> [RelayQueueStoredEntry] {
        purgeExpired(now: now)
        return entries.flatMap { destination, queue in
            (queue.control + queue.application).map {
                RelayQueueStoredEntry(destination: destination, envelope: $0.envelope, enqueuedAt: $0.enqueuedAt)
            }
        }
    }

    private var totalCount: Int { entries.values.reduce(0) { $0 + $1.count } }
    private var controlCount: Int { entries.values.reduce(0) { $0 + $1.control.count } }
    private var applicationCount: Int { entries.values.reduce(0) { $0 + $1.application.count } }

    private func purgeExpired(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.messageTimeToLive)
        for destination in Array(entries.keys) {
            guard var queue = entries[destination] else { continue }
            let previousCount = queue.count
            queue.control.removeAll { $0.enqueuedAt <= cutoff }
            queue.application.removeAll { $0.enqueuedAt <= cutoff }
            expiredMessages += UInt64(previousCount - queue.count)
            entries[destination] = queue.count == 0 ? nil : queue
        }
    }

    private func removeOldestApplication(for destination: NodeID) -> MessageID? {
        guard var queue = entries[destination], !queue.application.isEmpty else { return nil }
        let messageID = queue.application.removeFirst().envelope.messageID
        entries[destination] = queue.count == 0 ? nil : queue
        return messageID
    }

    private func removeOldestPreferApplication(for destination: NodeID) -> MessageID? {
        if let removed = removeOldestApplication(for: destination) { return removed }
        guard var queue = entries[destination], !queue.control.isEmpty else { return nil }
        let messageID = queue.control.removeFirst().envelope.messageID
        entries[destination] = queue.count == 0 ? nil : queue
        return messageID
    }

    private func removeOldestApplication() -> MessageID? {
        guard let destination = oldestDestination(for: \DestinationQueue.application) else { return nil }
        return removeOldestApplication(for: destination)
    }

    private func removeOldestPreferApplication() -> MessageID? {
        if let removed = removeOldestApplication() { return removed }
        guard let destination = oldestDestination(for: \DestinationQueue.control),
              var queue = entries[destination] else { return nil }
        let messageID = queue.control.removeFirst().envelope.messageID
        entries[destination] = queue.count == 0 ? nil : queue
        return messageID
    }

    private func oldestDestination(for keyPath: KeyPath<DestinationQueue, [Entry]>) -> NodeID? {
        entries.compactMap { destination, queue in
            queue[keyPath: keyPath].first.map { (destination, $0.enqueuedAt) }
        }.min { $0.1 < $1.1 }?.0
    }
}

struct RelayQueueStoredEntry: Codable, Sendable {
    let destination: NodeID
    let envelope: BeakrNetEnvelope
    let enqueuedAt: Date
}
