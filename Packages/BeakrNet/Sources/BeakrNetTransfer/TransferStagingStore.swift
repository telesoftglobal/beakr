import Foundation
import CryptoKit

public struct TransferStagingPolicy: Equatable, Sendable {
    public let maximumConcurrentTransfers: Int
    public let maximumReservedBytes: UInt64
    public init(maximumConcurrentTransfers: Int = 16, maximumReservedBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024) {
        precondition(maximumConcurrentTransfers > 0 && maximumReservedBytes > 0)
        self.maximumConcurrentTransfers = maximumConcurrentTransfers
        self.maximumReservedBytes = maximumReservedBytes
    }
}

public enum TransferStagingError: Error, Equatable, Sendable {
    case unknownTransfer, conflictingManifest, storageLimit, expired, invalidChunk
    case conflictingChunk, integrityFailure, incomplete, unsupportedFormat(Int)
}

public struct TransferProgress: Equatable, Sendable {
    public let transferID: TransferID
    public let receivedChunks: UInt32
    public let totalChunks: UInt32
    public let receivedBytes: UInt64
    public let totalBytes: UInt64
}

public actor TransferStagingStore {
    private struct Entry: Codable, Equatable, Sendable {
        let manifest: TransferManifest
        var received: [UInt32]
    }
    private struct Snapshot: Codable, Sendable {
        static let version = 1
        let version: Int
        let entries: [Entry]
    }

    public let rootURL: URL
    public let policy: TransferStagingPolicy
    private var entries: [TransferID: Entry] = [:]

    private init(rootURL: URL, policy: TransferStagingPolicy) {
        self.rootURL = rootURL; self.policy = policy
    }

    public static func open(rootURL: URL, policy: TransferStagingPolicy = TransferStagingPolicy(), now: Date = Date()) async throws -> TransferStagingStore {
        let store = TransferStagingStore(rootURL: rootURL, policy: policy)
        try await store.restore(now: now)
        return store
    }

    public func admit(_ manifest: TransferManifest, now: Date = Date()) throws {
        guard manifest.expiresAt > now else { throw TransferStagingError.expired }
        if let existing = entries[manifest.transferID] {
            guard existing.manifest == manifest else { throw TransferStagingError.conflictingManifest }
            return
        }
        guard entries.count < policy.maximumConcurrentTransfers,
              reservedBytes() + manifest.byteCount <= policy.maximumReservedBytes else { throw TransferStagingError.storageLimit }
        entries[manifest.transferID] = Entry(manifest: manifest, received: [])
        try FileManager.default.createDirectory(at: transferDirectory(manifest.transferID), withIntermediateDirectories: true)
        try persist()
    }

    public func receive(_ chunk: TransferChunk, now: Date = Date()) throws -> TransferProgress {
        guard var entry = entries[chunk.transferID] else { throw TransferStagingError.unknownTransfer }
        guard entry.manifest.expiresAt > now else { throw TransferStagingError.expired }
        let expectedOffset = UInt64(chunk.index) * UInt64(entry.manifest.chunkSize)
        let remaining = entry.manifest.byteCount - min(entry.manifest.byteCount, expectedOffset)
        let expectedLength = Int(min(UInt64(entry.manifest.chunkSize), remaining))
        guard chunk.index < entry.manifest.chunkCount, chunk.offset == expectedOffset,
              chunk.bytes.count == expectedLength, digest(chunk.bytes) == chunk.digest else {
            throw TransferStagingError.invalidChunk
        }
        let url = chunkURL(chunk.transferID, chunk.index)
        if entry.received.contains(chunk.index) {
            guard let existing = try? Data(contentsOf: url), existing == chunk.bytes else { throw TransferStagingError.conflictingChunk }
            return progress(entry)
        }
        try chunk.bytes.write(to: url, options: .atomic)
        entry.received.append(chunk.index); entry.received.sort()
        entries[chunk.transferID] = entry
        do { try persist() } catch { try? FileManager.default.removeItem(at: url); entries[chunk.transferID] = entries[chunk.transferID].map { Entry(manifest: $0.manifest, received: $0.received.filter { $0 != chunk.index }) }; throw error }
        return progress(entry)
    }

    public func missingRanges(for id: TransferID) throws -> [TransferChunkRange] {
        guard let entry = entries[id] else { throw TransferStagingError.unknownTransfer }
        let missing = (0..<entry.manifest.chunkCount).filter { !entry.received.contains($0) }
        var ranges: [TransferChunkRange] = []
        for index in missing {
            if let last = ranges.last, last.upperBound == index {
                ranges[ranges.count - 1] = .init(lowerBound: last.lowerBound, upperBound: index + 1)
            } else { ranges.append(.init(lowerBound: index, upperBound: index + 1)) }
        }
        return ranges
    }

    public func manifest(for id: TransferID) throws -> TransferManifest {
        guard let entry = entries[id] else { throw TransferStagingError.unknownTransfer }
        return entry.manifest
    }

    public func finalize(_ id: TransferID) throws -> URL {
        guard let entry = entries[id] else { throw TransferStagingError.unknownTransfer }
        guard entry.received.count == Int(entry.manifest.chunkCount) else { throw TransferStagingError.incomplete }
        let temporary = transferDirectory(id).appendingPathComponent("assembled.tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        var hasher = SHA256()
        do {
            for index in 0..<entry.manifest.chunkCount {
                let data = try Data(contentsOf: chunkURL(id, index)); hasher.update(data: data); try handle.write(contentsOf: data)
            }
            try handle.close()
        } catch { try? handle.close(); try? FileManager.default.removeItem(at: temporary); throw error }
        guard Data(hasher.finalize()) == entry.manifest.contentDigest else {
            try? FileManager.default.removeItem(at: temporary); throw TransferStagingError.integrityFailure
        }
        let completed = transferDirectory(id).appendingPathComponent("completed.data")
        try? FileManager.default.removeItem(at: completed)
        try FileManager.default.moveItem(at: temporary, to: completed)
        return completed
    }

    public func cancel(_ id: TransferID) throws {
        guard entries.removeValue(forKey: id) != nil else { return }
        try? FileManager.default.removeItem(at: transferDirectory(id)); try persist()
    }

    public func garbageCollect(now: Date = Date()) throws {
        let expired = entries.values.filter { $0.manifest.expiresAt <= now }.map { $0.manifest.transferID }
        for id in expired { entries.removeValue(forKey: id); try? FileManager.default.removeItem(at: transferDirectory(id)) }
        if !expired.isEmpty { try persist() }
    }

    private func restore(now: Date) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let url = rootURL.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == Snapshot.version else { throw TransferStagingError.unsupportedFormat(snapshot.version) }
        for var entry in snapshot.entries where entry.manifest.expiresAt > now {
            entry.received = entry.received.filter { index in
                guard let data = try? Data(contentsOf: chunkURL(entry.manifest.transferID, index)) else { return false }
                return data.count == Int(min(UInt64(entry.manifest.chunkSize), entry.manifest.byteCount - UInt64(index) * UInt64(entry.manifest.chunkSize)))
            }
            entries[entry.manifest.transferID] = entry
        }
        try persist()
    }

    private func persist() throws {
        let snapshot = Snapshot(version: Snapshot.version, entries: entries.values.sorted { $0.manifest.transferID.rawValue.uuidString < $1.manifest.transferID.rawValue.uuidString })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(snapshot).write(to: rootURL.appendingPathComponent("state.json"), options: .atomic)
    }
    private func reservedBytes() -> UInt64 { entries.values.reduce(0) { $0 + $1.manifest.byteCount } }
    private func transferDirectory(_ id: TransferID) -> URL { rootURL.appendingPathComponent(id.rawValue.uuidString, isDirectory: true) }
    private func chunkURL(_ id: TransferID, _ index: UInt32) -> URL { transferDirectory(id).appendingPathComponent("chunk-\(index).data") }
    private func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private func progress(_ entry: Entry) -> TransferProgress {
        let bytes = entry.received.reduce(UInt64(0)) { total, index in total + min(UInt64(entry.manifest.chunkSize), entry.manifest.byteCount - UInt64(index) * UInt64(entry.manifest.chunkSize)) }
        return .init(transferID: entry.manifest.transferID, receivedChunks: UInt32(entry.received.count), totalChunks: entry.manifest.chunkCount, receivedBytes: bytes, totalBytes: entry.manifest.byteCount)
    }
}
