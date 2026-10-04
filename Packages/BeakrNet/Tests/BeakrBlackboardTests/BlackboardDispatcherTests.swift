import Foundation
import Testing
import BeakrNetCore
import BeakrBlackboard

@Suite("Blackboard dispatcher")
struct BlackboardDispatcherTests {
    @Test("Authenticated membership gates snapshot disclosure")
    func authorizationBeforeRead() async throws {
        let owner = NodeID()
        let outsider = NodeID()
        let space = BlackboardSpaceID()
        let repository = BlackboardRepository()
        try await repository.createSpace(id: space, name: "Notes", owner: owner)
        let dispatcher = BlackboardDispatcher(repository: repository)
        let codec = BlackboardCodec()
        let request = BlackboardWireMessage(kind: .snapshotRequest, spaceID: space)
        let envelope = try codec.makeEnvelope(
            for: request, sessionID: SessionID(), sourceNodeID: outsider, destinationNodeID: owner,
            sequenceNumber: 1, createdAt: Date(timeIntervalSince1970: 1_000),
            deliveryPolicy: .init(durability: .durable)
        )
        guard case .rejected(.unauthorized, let response) = await dispatcher.dispatch(envelope) else {
            Issue.record("Expected authorization rejection"); return
        }
        #expect(response?.errorCode == .unauthorized)
    }

    @Test("Snapshot requests return canonical repository state")
    func snapshotDispatch() async throws {
        let owner = NodeID()
        let space = BlackboardSpaceID()
        let repository = BlackboardRepository()
        try await repository.createSpace(id: space, name: "Notes", owner: owner)
        let dispatcher = BlackboardDispatcher(repository: repository)
        let request = BlackboardWireMessage(kind: .snapshotRequest, spaceID: space)
        let envelope = try BlackboardCodec().makeEnvelope(
            for: request, sessionID: SessionID(), sourceNodeID: owner, destinationNodeID: NodeID(),
            sequenceNumber: 1, createdAt: Date(timeIntervalSince1970: 1_000),
            deliveryPolicy: .init(durability: .durable)
        )
        guard case .handled(let response) = await dispatcher.dispatch(envelope) else {
            Issue.record("Expected snapshot"); return
        }
        #expect(response?.kind == .snapshotResponse)
        #expect(response?.snapshot?.name == "Notes")
    }
}
