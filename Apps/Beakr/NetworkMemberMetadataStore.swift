import Foundation

nonisolated struct NetworkMemberMetadata: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var displayName: String?
    var lastSeen: Date?
}

nonisolated enum NetworkMemberMetadataStoreError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
}

nonisolated enum NetworkMemberMetadataStore {
    private nonisolated struct Document: Codable {
        let version: Int
        let members: [NetworkMemberMetadata]
    }

    private static let currentVersion = 1

    nonisolated static func load(from fileURL: URL) throws -> [UUID: NetworkMemberMetadata] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let document = try decoder.decode(Document.self, from: Data(contentsOf: fileURL))
        guard document.version == currentVersion else {
            throw NetworkMemberMetadataStoreError.unsupportedVersion(document.version)
        }
        return Dictionary(uniqueKeysWithValues: document.members.map { ($0.id, $0) })
    }

    nonisolated static func save(_ members: [UUID: NetworkMemberMetadata], to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let document = Document(
            version: currentVersion,
            members: members.values.sorted { $0.id.uuidString < $1.id.uuidString }
        )
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
