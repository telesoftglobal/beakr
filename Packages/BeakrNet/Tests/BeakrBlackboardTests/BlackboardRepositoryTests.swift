import Foundation
import Testing
import BeakrNetCore
import BeakrBlackboard

@Suite("Blackboard repository")
struct BlackboardRepositoryTests {
    @Test("Concurrent offline writes expose the same deterministic conflict in either order")
    func offlineConflictConvergence() async throws {
        let fixture = Fixture()
        let first = fixture.operation(replica: fixture.replicaA, counter: 1, bytes: "A", operationID: fixture.operationA)
        let second = fixture.operation(replica: fixture.replicaB, counter: 1, bytes: "B", operationID: fixture.operationB)
        let left = try await fixture.repository(applying: [first, second])
        let right = try await fixture.repository(applying: [second, first])

        let leftRecord = try #require(left.records.first)
        let rightRecord = try #require(right.records.first)
        #expect(leftRecord.hasConflict)
        #expect(leftRecord == rightRecord)
        #expect(left.frontier == right.frontier)
    }

    @Test("A causally later write supersedes only observed versions")
    func causalSupersession() async throws {
        let fixture = Fixture()
        let repository = try await fixture.repository(applying: [
            fixture.operation(replica: fixture.replicaA, counter: 1, bytes: "A", operationID: fixture.operationA)
        ], returnRepository: true)
        let context = BlackboardFrontier(entries: [.init(replicaID: fixture.replicaA, counter: 1)])
        let later = fixture.operation(replica: fixture.replicaA, counter: 2, bytes: "new", context: context)
        _ = try await repository.apply(later, authorizedNodeID: fixture.owner)
        let snapshot = try await repository.snapshot(spaceID: fixture.space, authorizedNodeID: fixture.owner)
        #expect(snapshot.records.first?.versions.count == 1)
        #expect(snapshot.records.first?.versions.first?.value?.bytes == Data("new".utf8))
    }

    @Test("Unauthorized, missing-dependency, rollback, and cursor mismatch fail closed")
    func rejectionBoundaries() async throws {
        let fixture = Fixture()
        let repository = try await fixture.repository(applying: [], returnRepository: true)
        let operation = fixture.operation(replica: fixture.replicaA, counter: 1, bytes: "A")
        await #expect(throws: BlackboardRepositoryError.unauthorized) {
            try await repository.apply(operation, authorizedNodeID: NodeID())
        }
        let missing = fixture.operation(
            replica: fixture.replicaB, counter: 1, bytes: "B",
            context: .init(entries: [.init(replicaID: fixture.replicaA, counter: 1)])
        )
        await #expect(throws: BlackboardRepositoryError.missingCausalDependency) {
            try await repository.apply(missing, authorizedNodeID: fixture.owner)
        }
        _ = try await repository.apply(operation, authorizedNodeID: fixture.owner)
        await #expect(throws: BlackboardRepositoryError.causalRollback) {
            try await repository.apply(fixture.operation(replica: fixture.replicaA, counter: 1, bytes: "other"), authorizedNodeID: fixture.owner)
        }
        await #expect(throws: BlackboardRepositoryError.compactionBoundaryMismatch) {
            try await repository.incremental(
                spaceID: fixture.space,
                after: .init(compactionGeneration: 1, journalOffset: 0),
                limit: 10,
                authorizedNodeID: fixture.owner
            )
        }
    }

    @Test("A rejected operation batch has no partial mutation")
    func atomicBatch() async throws {
        let fixture = Fixture()
        let repository = try await fixture.repository(applying: [], returnRepository: true)
        let valid = fixture.operation(replica: fixture.replicaA, counter: 1, bytes: "A")
        let invalid = fixture.operation(replica: fixture.replicaB, counter: 2, bytes: "B")
        await #expect(throws: BlackboardRepositoryError.causalRollback) {
            try await repository.applyBatch([valid, invalid], authorizedNodeID: fixture.owner)
        }
        let snapshot = try await repository.snapshot(spaceID: fixture.space, authorizedNodeID: fixture.owner)
        #expect(snapshot.records.isEmpty)
        #expect(snapshot.journalOffset == 0)
    }

    @Test("Conflict resolution must name and observe every current version")
    func explicitResolution() async throws {
        let fixture = Fixture()
        let repository = try await fixture.repository(applying: [
            fixture.operation(replica: fixture.replicaA, counter: 1, bytes: "A", operationID: fixture.operationA),
            fixture.operation(replica: fixture.replicaB, counter: 1, bytes: "B", operationID: fixture.operationB)
        ], returnRepository: true)
        let context = BlackboardFrontier(entries: [
            .init(replicaID: fixture.replicaA, counter: 1), .init(replicaID: fixture.replicaB, counter: 1)
        ])
        let resolver = BlackboardReplicaID()
        let incomplete = BlackboardOperation(
            spaceID: fixture.space, recordID: fixture.record, dot: .init(replicaID: resolver, counter: 1),
            context: context, kind: .resolve,
            value: .init(schema: "com.example.note", schemaVersion: 1, bytes: Data("merged".utf8)),
            resolves: [fixture.operationA], authoredAt: fixture.now
        )
        await #expect(throws: BlackboardRepositoryError.conflictResolutionMismatch) {
            try await repository.apply(incomplete, authorizedNodeID: fixture.owner)
        }
        let resolution = BlackboardOperation(
            spaceID: fixture.space, recordID: fixture.record, dot: .init(replicaID: resolver, counter: 1),
            context: context, kind: .resolve,
            value: .init(schema: "com.example.note", schemaVersion: 1, bytes: Data("merged".utf8)),
            resolves: [fixture.operationA, fixture.operationB], authoredAt: fixture.now
        )
        _ = try await repository.apply(resolution, authorizedNodeID: fixture.owner)
        let snapshot = try await repository.snapshot(spaceID: fixture.space, authorizedNodeID: fixture.owner)
        #expect(snapshot.records.first?.hasConflict == false)
        #expect(snapshot.records.first?.versions.first?.value?.bytes == Data("merged".utf8))
    }

    @Test("Subscriptions are bounded and publish identifiers without values")
    func subscriptions() async throws {
        let fixture = Fixture()
        let repository = BlackboardRepository(policy: .init(maximumSubscriptions: 1))
        try await repository.createSpace(id: fixture.space, name: "Notes", owner: fixture.owner)
        let recorder = ChangeRecorder()
        _ = try await repository.subscribe(spaceID: fixture.space, authorizedNodeID: fixture.owner) { recorder.append($0) }
        await #expect(throws: BlackboardRepositoryError.resourceLimit) {
            try await repository.subscribe(spaceID: fixture.space, authorizedNodeID: fixture.owner) { _ in }
        }
        let operation = fixture.operation(replica: fixture.replicaA, counter: 1, bytes: "private")
        _ = try await repository.apply(operation, authorizedNodeID: fixture.owner)
        #expect(recorder.values.map(\.operationID) == [operation.operationID])
    }
}

private final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BlackboardChange] = []
    var values: [BlackboardChange] { lock.withLock { storage } }
    func append(_ change: BlackboardChange) { lock.withLock { storage.append(change) } }
}

private struct Fixture {
    let owner = NodeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let space = BlackboardSpaceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let record = BlackboardRecordID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    let replicaA = BlackboardReplicaID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
    let replicaB = BlackboardReplicaID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
    let operationA = BlackboardOperationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!)
    let operationB = BlackboardOperationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!)
    let now = Date(timeIntervalSince1970: 1_000)

    func operation(
        replica: BlackboardReplicaID,
        counter: UInt64,
        bytes: String,
        context: BlackboardFrontier = BlackboardFrontier(),
        operationID: BlackboardOperationID = BlackboardOperationID()
    ) -> BlackboardOperation {
        BlackboardOperation(
            operationID: operationID, spaceID: space, recordID: record,
            dot: .init(replicaID: replica, counter: counter), context: context,
            kind: .write,
            value: .init(schema: "com.example.note", schemaVersion: 1, bytes: Data(bytes.utf8)),
            authoredAt: now
        )
    }

    func repository(applying operations: [BlackboardOperation]) async throws -> BlackboardSpaceSnapshot {
        let repository = try await repository(applying: operations, returnRepository: true)
        return try await repository.snapshot(spaceID: space, authorizedNodeID: owner)
    }

    func repository(applying operations: [BlackboardOperation], returnRepository: Bool) async throws -> BlackboardRepository {
        let repository = BlackboardRepository()
        try await repository.createSpace(id: space, name: "Notes", owner: owner)
        for operation in operations { _ = try await repository.apply(operation, authorizedNodeID: owner) }
        return repository
    }
}
