import Foundation
import Observation
import BeakrNetCore
import BeakrNetSecurity

enum NodeBootstrapState: Equatable {
    case starting
    case needsConfiguration
    case identityReady
    case failed
}

protocol NodeIdentityLoading: Sendable {
    func loadOrCreateNodeID() throws -> NodeID
}

struct KeychainNodeIdentityLoader: NodeIdentityLoading {
    private let store = KeychainNodeIdentityStore(service: "net.beakr.app")

    func loadOrCreateNodeID() throws -> NodeID {
        try store.loadOrCreate().nodeID
    }
}

@MainActor
@Observable
final class NodeBootstrapModel {
    private(set) var state: NodeBootstrapState = .starting
    private(set) var nodeID: UUID?
    private(set) var statusMessage = "Restoring this device’s node identity."

    private let identityLoader: any NodeIdentityLoading

    init() {
        identityLoader = KeychainNodeIdentityLoader()
    }

    init(identityLoader: any NodeIdentityLoading) {
        self.identityLoader = identityLoader
    }

    func start() async {
        state = .starting
        statusMessage = "Restoring this device’s node identity."

        do {
            let restoredNodeID = try identityLoader.loadOrCreateNodeID()
            nodeID = restoredNodeID.rawValue
            state = .needsConfiguration
            statusMessage = "Identity is secure. Development authority configuration is required."
        } catch {
            nodeID = nil
            state = .failed
            statusMessage = "The secure node identity could not be restored."
        }
    }
}
