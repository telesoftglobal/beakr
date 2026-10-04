import Foundation
import BeakrNetCore

public enum DataPersistenceError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case capacityExceeded
}

public struct StoredDataResult: Codable, Equatable, Sendable {
    public let messageID: MessageID
    public let idempotencyKey: DataIdempotencyKey?
    public let response: DataMessage?
    public let completedAt: Date

    public init(messageID: MessageID, idempotencyKey: DataIdempotencyKey?, response: DataMessage?, completedAt: Date) {
        self.messageID = messageID
        self.idempotencyKey = idempotencyKey
        self.response = response
        self.completedAt = completedAt
    }
}

/// Restart-safe node-side state. The snapshot is replaced atomically after every mutation.
/// Application handlers remain responsible for making their own mutations idempotent.
public actor PersistentDataState {
    private struct Snapshot: Codable {
        static let currentFormatVersion = 1
        let formatVersion: Int
        let outgoing: [BeakrNetEnvelope]
        let incoming: [StoredDataResult]
    }

    public let fileURL: URL
    public let maximumOutgoing: Int
    public let maximumIncoming: Int
    private var outgoing: [MessageID: BeakrNetEnvelope] = [:]
    private var outgoingOrder: [MessageID] = []
    private var incoming: [MessageID: StoredDataResult] = [:]
    private var incomingOrder: [MessageID] = []
    private var idempotencyResults: [DataIdempotencyKey: StoredDataResult] = [:]

    private init(fileURL: URL, maximumOutgoing: Int, maximumIncoming: Int) {
        self.fileURL = fileURL
        self.maximumOutgoing = maximumOutgoing
        self.maximumIncoming = maximumIncoming
    }

    public static func open(
        fileURL: URL,
        maximumOutgoing: Int = 4_096,
        maximumIncoming: Int = 8_192,
        now: Date = Date()
    ) async throws -> PersistentDataState {
        precondition(maximumOutgoing > 0 && maximumIncoming > 0)
        let state = PersistentDataState(fileURL: fileURL, maximumOutgoing: maximumOutgoing, maximumIncoming: maximumIncoming)
        try await state.restore(now: now)
        return state
    }

    public func enqueue(_ envelope: BeakrNetEnvelope, now: Date = Date()) throws {
        guard envelope.channel == .data else { throw DataCodecError.wrongChannel }
        try envelope.validate(now: now)
        guard outgoing[envelope.messageID] == nil else { return }
        guard outgoing.count < maximumOutgoing else { throw DataPersistenceError.capacityExceeded }
        outgoing[envelope.messageID] = envelope
        outgoingOrder.append(envelope.messageID)
        try persist()
    }

    public func pending(now: Date = Date()) throws -> [BeakrNetEnvelope] {
        try removeExpiredOutgoing(now: now)
        return outgoingOrder.compactMap { outgoing[$0] }
    }

    @discardableResult
    public func acknowledge(_ messageID: MessageID) throws -> Bool {
        guard outgoing.removeValue(forKey: messageID) != nil else { return false }
        outgoingOrder.removeAll { $0 == messageID }
        try persist()
        return true
    }

    public func result(for messageID: MessageID) -> StoredDataResult? { incoming[messageID] }
    public func result(for key: DataIdempotencyKey) -> StoredDataResult? { idempotencyResults[key] }

    public func record(_ result: StoredDataResult) throws {
        if let existing = incoming[result.messageID] {
            guard existing == result else { throw DataPersistenceError.capacityExceeded }
            return
        }
        if incomingOrder.count >= maximumIncoming, let oldest = incomingOrder.first {
            incomingOrder.removeFirst()
            if let removed = incoming.removeValue(forKey: oldest), let key = removed.idempotencyKey {
                idempotencyResults.removeValue(forKey: key)
            }
        }
        incoming[result.messageID] = result
        incomingOrder.append(result.messageID)
        if let key = result.idempotencyKey { idempotencyResults[key] = result }
        try persist()
    }

    private func restore(now: Date) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.formatVersion == Snapshot.currentFormatVersion else {
            throw DataPersistenceError.unsupportedFormatVersion(snapshot.formatVersion)
        }
        for envelope in snapshot.outgoing.prefix(maximumOutgoing) {
            guard envelope.deliveryPolicy.expiresAt.map({ $0 > now }) ?? true else { continue }
            outgoing[envelope.messageID] = envelope
            outgoingOrder.append(envelope.messageID)
        }
        for result in snapshot.incoming.suffix(maximumIncoming) {
            incoming[result.messageID] = result
            incomingOrder.append(result.messageID)
            if let key = result.idempotencyKey { idempotencyResults[key] = result }
        }
        try persist()
    }

    private func removeExpiredOutgoing(now: Date) throws {
        let expired = outgoingOrder.filter { id in
            outgoing[id]?.deliveryPolicy.expiresAt.map { $0 <= now } ?? false
        }
        guard !expired.isEmpty else { return }
        for id in expired { outgoing.removeValue(forKey: id) }
        outgoingOrder.removeAll { expired.contains($0) }
        try persist()
    }

    private func persist() throws {
        let snapshot = Snapshot(
            formatVersion: Snapshot.currentFormatVersion,
            outgoing: outgoingOrder.compactMap { outgoing[$0] },
            incoming: incomingOrder.compactMap { incoming[$0] }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
