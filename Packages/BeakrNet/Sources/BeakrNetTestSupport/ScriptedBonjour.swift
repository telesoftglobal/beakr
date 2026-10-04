import Foundation
import BeakrNetCore

public final class ScriptedBonjourBrowser: BonjourBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [@Sendable (BonjourBrowserEvent) -> Void] = []
    public private(set) var cancelCount = 0

    public init() {}

    public func start(eventHandler: @escaping @Sendable (BonjourBrowserEvent) -> Void) {
        lock.withLock { handlers.append(eventHandler) }
    }

    public func cancel() {
        lock.withLock { cancelCount += 1 }
    }

    public func send(_ event: BonjourBrowserEvent, toStart index: Int? = nil) {
        let selected = lock.withLock { index.map { handlers[$0] } ?? handlers.last }
        selected?(event)
    }
}

public final class ScriptedBonjourListener: BonjourListening, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [@Sendable (BonjourListenerEvent) -> Void] = []
    public private(set) var cancelCount = 0

    public init() {}

    public func start(eventHandler: @escaping @Sendable (BonjourListenerEvent) -> Void) {
        lock.withLock { handlers.append(eventHandler) }
    }

    public func cancel() {
        lock.withLock { cancelCount += 1 }
    }

    public func send(_ event: BonjourListenerEvent, toStart index: Int? = nil) {
        let selected = lock.withLock { index.map { handlers[$0] } ?? handlers.last }
        selected?(event)
    }
}

public final class ScriptedBonjourConnection: BonjourConnection, @unchecked Sendable {
    public let id: UUID
    private let lock = NSLock()
    private var handlers: [@Sendable (BonjourConnectionState) -> Void] = []
    public private(set) var cancelCount = 0

    public init(id: UUID = UUID()) {
        self.id = id
    }

    public func start(stateHandler: @escaping @Sendable (BonjourConnectionState) -> Void) {
        lock.withLock { handlers.append(stateHandler) }
    }

    public func cancel() {
        lock.withLock { cancelCount += 1 }
        send(.cancelled)
    }

    public func sendFrame(_ data: Data) async throws {
        throw BonjourConnectionIOError.connectionClosed
    }

    public func receiveFrame(maximumBytes: Int) async throws -> Data {
        throw BonjourConnectionIOError.connectionClosed
    }

    public func peerCertificate() throws -> BonjourPeerCertificate {
        throw BonjourConnectionIOError.peerCertificateUnavailable
    }

    public func send(_ state: BonjourConnectionState, toStart index: Int? = nil) {
        let selected = lock.withLock { index.map { handlers[$0] } ?? handlers.last }
        selected?(state)
    }
}

public enum ScriptedBonjourFactoryError: Error, Equatable, Sendable {
    case refused
}

public final class ScriptedBonjourConnectionFactory: BonjourConnectionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var queuedResults: [Result<ScriptedBonjourConnection, ScriptedBonjourFactoryError>]
    public private(set) var requestedEndpoints: [BonjourEndpointID] = []

    public init(results: [Result<ScriptedBonjourConnection, ScriptedBonjourFactoryError>] = []) {
        queuedResults = results
    }

    public func enqueue(_ result: Result<ScriptedBonjourConnection, ScriptedBonjourFactoryError>) {
        lock.withLock { queuedResults.append(result) }
    }

    public func makeConnection(to endpointID: BonjourEndpointID) throws -> any BonjourConnection {
        try lock.withLock {
            requestedEndpoints.append(endpointID)
            guard !queuedResults.isEmpty else { throw ScriptedBonjourFactoryError.refused }
            return try queuedResults.removeFirst().get()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
