import Foundation

public struct HostCheckpoint: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public let formatVersion: Int
    public let generation: UInt64
    public let lifecycle: HostLifecycleState
    public let checkpointedAt: Date
    public let cleanShutdown: Bool

    public init(formatVersion: Int = Self.currentFormatVersion, generation: UInt64,
                lifecycle: HostLifecycleState, checkpointedAt: Date, cleanShutdown: Bool) {
        self.formatVersion = formatVersion; self.generation = generation; self.lifecycle = lifecycle
        self.checkpointedAt = checkpointedAt; self.cleanShutdown = cleanShutdown
    }
}

public enum HostCheckpointError: Error, Equatable, Sendable {
    case unsupportedFormat(Int)
    case generationRollback
}

public actor FileHostCheckpointStore {
    public let fileURL: URL
    private var active: HostCheckpoint?

    private init(fileURL: URL, active: HostCheckpoint?) { self.fileURL = fileURL; self.active = active }

    public static func open(fileURL: URL) throws -> FileHostCheckpointStore {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return FileHostCheckpointStore(fileURL: fileURL, active: nil) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let checkpoint = try decoder.decode(HostCheckpoint.self, from: Data(contentsOf: fileURL))
        guard checkpoint.formatVersion == HostCheckpoint.currentFormatVersion else {
            throw HostCheckpointError.unsupportedFormat(checkpoint.formatVersion)
        }
        return FileHostCheckpointStore(fileURL: fileURL, active: checkpoint)
    }

    public func load() -> HostCheckpoint? { active }

    public func save(_ checkpoint: HostCheckpoint) throws {
        guard checkpoint.formatVersion == HostCheckpoint.currentFormatVersion else {
            throw HostCheckpointError.unsupportedFormat(checkpoint.formatVersion)
        }
        guard active.map({ checkpoint.generation > $0.generation }) ?? true else { throw HostCheckpointError.generationRollback }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(checkpoint)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        active = checkpoint
    }
}
