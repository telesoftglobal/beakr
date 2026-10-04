import Foundation
import BeakrNetCore

public actor PersistentBlackboardRepository {
    public let fileURL: URL
    public let policy: BlackboardPolicy
    private var repository: BlackboardRepository

    private init(fileURL: URL, policy: BlackboardPolicy, repository: BlackboardRepository) {
        self.fileURL = fileURL
        self.policy = policy
        self.repository = repository
    }

    public static func open(fileURL: URL, policy: BlackboardPolicy = BlackboardPolicy()) async throws -> PersistentBlackboardRepository {
        let repository: BlackboardRepository
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let state = try decoder.decode(BlackboardRepositoryState.self, from: Data(contentsOf: fileURL))
            repository = try BlackboardRepository(restoring: state, policy: policy)
        } else {
            repository = BlackboardRepository(policy: policy)
        }
        return PersistentBlackboardRepository(fileURL: fileURL, policy: policy, repository: repository)
    }

    public func createSpace(id: BlackboardSpaceID = BlackboardSpaceID(), name: String, owner: NodeID) async throws {
        try await mutate { try await $0.createSpace(id: id, name: name, owner: owner) }
    }

    public func apply(_ operation: BlackboardOperation, authorizedNodeID: NodeID) async throws -> BlackboardApplyResult {
        try await mutate { try await $0.apply(operation, authorizedNodeID: authorizedNodeID) }
    }

    public func applyBatch(_ operations: [BlackboardOperation], authorizedNodeID: NodeID) async throws -> [BlackboardApplyResult] {
        try await mutate { try await $0.applyBatch(operations, authorizedNodeID: authorizedNodeID) }
    }

    public func compact(spaceID: BlackboardSpaceID, through frontier: BlackboardFrontier, authorizedNodeID: NodeID) async throws {
        try await mutate { try await $0.compact(spaceID: spaceID, through: frontier, authorizedNodeID: authorizedNodeID) }
    }

    public func snapshot(spaceID: BlackboardSpaceID, authorizedNodeID: NodeID) async throws -> BlackboardSpaceSnapshot {
        try await repository.snapshot(spaceID: spaceID, authorizedNodeID: authorizedNodeID)
    }

    public func incremental(spaceID: BlackboardSpaceID, after cursor: BlackboardCursor, limit: Int, authorizedNodeID: NodeID) async throws -> BlackboardIncrementalResult {
        try await repository.incremental(spaceID: spaceID, after: cursor, limit: limit, authorizedNodeID: authorizedNodeID)
    }

    private func mutate<T: Sendable>(_ body: @Sendable (BlackboardRepository) async throws -> T) async throws -> T {
        let before = await repository.exportState()
        let result = try await body(repository)
        do { try await persist() }
        catch {
            repository = try BlackboardRepository(restoring: before, policy: policy)
            throw error
        }
        return result
    }

    private func persist() async throws {
        let state = await repository.exportState()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
