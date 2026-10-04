import Foundation
import BeakrNetCore
import BeakrNetData
import BeakrBlackboard
import BeakrNetTransfer

public enum HostLifecycleState: String, Codable, Sendable {
    case starting, foreground, background, suspended, locked, stopping, stopped, failed
}

public enum HostPermissionState: String, Codable, Sendable { case unknown, granted, denied, restricted }
public enum HostStoragePressure: String, Codable, Sendable { case normal, constrained, critical }

public struct HostSynchronizationState: Equatable, Sendable {
    public let lifecycle: HostLifecycleState
    public let localNetworkPermission: HostPermissionState
    public let notificationPermission: HostPermissionState
    public let storagePressure: HostStoragePressure
    public let pendingMessages: Int
    public let activeTransfers: Int
    public let routesPermitted: Bool
    public let recovered: Bool

    public init(lifecycle: HostLifecycleState, localNetworkPermission: HostPermissionState,
                notificationPermission: HostPermissionState, storagePressure: HostStoragePressure,
                pendingMessages: Int, activeTransfers: Int, routesPermitted: Bool, recovered: Bool) {
        self.lifecycle = lifecycle; self.localNetworkPermission = localNetworkPermission
        self.notificationPermission = notificationPermission; self.storagePressure = storagePressure
        self.pendingMessages = pendingMessages; self.activeTransfers = activeTransfers
        self.routesPermitted = routesPermitted; self.recovered = recovered
    }
}

public struct HostMessageRequest: Sendable {
    public let destination: NodeID
    public let message: DataMessage
    public init(destination: NodeID, message: DataMessage) { self.destination = destination; self.message = message }
}

public protocol HostMessagingService: Sendable {
    func send(_ request: HostMessageRequest) async throws
    func cancel(correlationID: DataCorrelationID) async throws
}

public protocol HostBlackboardService: Sendable {
    func snapshot(spaceID: BlackboardSpaceID) async throws -> BlackboardSpaceSnapshot
    func apply(_ operation: BlackboardOperation) async throws
}

public protocol HostTransferService: Sendable {
    func start(_ manifest: TransferManifest) async throws
    func cancel(_ transferID: TransferID) async throws
}

public protocol HostRecoveryService: Sendable {
    func openRepositories() async throws
    func restorePendingWork() async throws
    func restoreTrustState() async throws
    func reconcileExpiredWork() async throws
    func checkpoint() async throws
    func setRoutesPermitted(_ permitted: Bool) async
    func setLANPermitted(_ permitted: Bool) async
    func setNewDurableWorkPermitted(_ permitted: Bool) async
    func setNewTransfersPermitted(_ permitted: Bool) async
    func pendingMessageCount() async -> Int
    func activeTransferCount() async -> Int
}
