import Foundation
import Testing
import BeakrNetCore
import BeakrBlackboard

@Suite("Persistent Blackboard repository")
struct BlackboardPersistenceTests {
    @Test("Snapshot and journal state recover canonically across restart")
    func restartRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("blackboard.json")
        let owner = NodeID()
        let space = BlackboardSpaceID()
        let record = BlackboardRecordID()
        let replica = BlackboardReplicaID()
        let operation = BlackboardOperation(
            spaceID: space, recordID: record, dot: .init(replicaID: replica, counter: 1),
            context: .init(), kind: .write,
            value: .init(schema: "com.example.note", schemaVersion: 1, bytes: Data("hello".utf8)),
            authoredAt: Date(timeIntervalSince1970: 1_000)
        )
        let first = try await PersistentBlackboardRepository.open(fileURL: url)
        try await first.createSpace(id: space, name: "Notes", owner: owner)
        _ = try await first.apply(operation, authorizedNodeID: owner)
        let before = try await first.snapshot(spaceID: space, authorizedNodeID: owner)

        let restored = try await PersistentBlackboardRepository.open(fileURL: url)
        let after = try await restored.snapshot(spaceID: space, authorizedNodeID: owner)
        #expect(after == before)
        #expect(try await restored.incremental(
            spaceID: space, after: .init(compactionGeneration: 0, journalOffset: 0),
            limit: 10, authorizedNodeID: owner
        ).operations == [operation])
    }

    @Test("Approved compaction removes observed tombstones and invalidates old cursors")
    func compactionBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try await PersistentBlackboardRepository.open(fileURL: directory.appendingPathComponent("state.json"))
        let owner = NodeID(), space = BlackboardSpaceID(), record = BlackboardRecordID(), replica = BlackboardReplicaID()
        try await repository.createSpace(id: space, name: "Notes", owner: owner)
        let deletion = BlackboardOperation(
            spaceID: space, recordID: record, dot: .init(replicaID: replica, counter: 1), context: .init(),
            kind: .delete, value: nil, authoredAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = try await repository.apply(deletion, authorizedNodeID: owner)
        let frontier = BlackboardFrontier(entries: [.init(replicaID: replica, counter: 1)])
        try await repository.compact(spaceID: space, through: frontier, authorizedNodeID: owner)
        let snapshot = try await repository.snapshot(spaceID: space, authorizedNodeID: owner)
        #expect(snapshot.records.isEmpty)
        #expect(snapshot.compactionGeneration == 1)
        await #expect(throws: BlackboardRepositoryError.compactionBoundaryMismatch) {
            try await repository.incremental(
                spaceID: space, after: .init(compactionGeneration: 0, journalOffset: 0),
                limit: 10, authorizedNodeID: owner
            )
        }
    }
}
