import Foundation
import Testing
import BeakrBlackboard

@Suite("Blackboard causal model")
struct BlackboardModelTests {
    @Test("Frontiers are canonical and advance monotonically")
    func frontierOrdering() {
        let high = BlackboardReplicaID(rawValue: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!)
        let low = BlackboardReplicaID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let frontier = BlackboardFrontier(entries: [
            .init(replicaID: high, counter: 2),
            .init(replicaID: low, counter: 1)
        ])
        #expect(frontier.entries.map(\.replicaID) == [low, high])
        let advanced = frontier.advancing(.init(replicaID: low, counter: 3))
        #expect(advanced.counter(for: low) == 3)
        #expect(advanced.dominates(frontier))
    }
}
