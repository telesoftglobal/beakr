#if canImport(Network)
import Foundation
import Network
import Security

public enum NetworkBonjourAdapterError: Error, Equatable, Sendable {
    case endpointUnavailable
}

public final class NetworkBonjourEndpointRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [BonjourEndpointID: NWEndpoint] = [:]
    private var identifiers: [NWEndpoint: BonjourEndpointID] = [:]

    public init() {}

    fileprivate func retain(_ endpoint: NWEndpoint) -> BonjourEndpointID {
        lock.withLock {
            if let existing = identifiers[endpoint] { return existing }
            let identifier = BonjourEndpointID()
            endpoints[identifier] = endpoint
            identifiers[endpoint] = identifier
            return identifier
        }
    }

    fileprivate func endpoint(for identifier: BonjourEndpointID) -> NWEndpoint? {
        lock.withLock { endpoints[identifier] }
    }

    public func removeAll() {
        lock.withLock {
            endpoints.removeAll()
            identifiers.removeAll()
        }
    }
}

public final class NetworkBonjourBrowser: BonjourBrowsing, @unchecked Sendable {
    private let browser: NWBrowser
    private let registry: NetworkBonjourEndpointRegistry
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var advertisements: [NWEndpoint: BonjourAdvertisement] = [:]

    public init(
        serviceType: String,
        domain: String? = nil,
        parameters: NWParameters = .tcp,
        registry: NetworkBonjourEndpointRegistry,
        queue: DispatchQueue = DispatchQueue(label: "BeakrNet.BonjourBrowser")
    ) {
        browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: serviceType, domain: domain),
            using: parameters
        )
        self.registry = registry
        self.queue = queue
    }

    public func start(eventHandler: @escaping @Sendable (BonjourBrowserEvent) -> Void) {
        browser.stateUpdateHandler = { state in
            switch state {
            case .setup: eventHandler(.state(.setup))
            case .ready: eventHandler(.state(.ready))
            case .waiting(let error):
                if Self.isPermissionDenied(error) { eventHandler(.permissionDenied) }
                eventHandler(.state(.waiting(reason: Self.safeReason(error))))
            case .failed(let error):
                if Self.isPermissionDenied(error) { eventHandler(.permissionDenied) }
                eventHandler(.state(.failed(reason: Self.safeReason(error))))
            case .cancelled: eventHandler(.state(.cancelled))
            @unknown default: eventHandler(.state(.failed(reason: "unknown-browser-state")))
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.publish(results: results, eventHandler: eventHandler)
        }
        browser.start(queue: queue)
    }

    public func cancel() {
        browser.cancel()
    }

    private func publish(
        results: Set<NWBrowser.Result>,
        eventHandler: @escaping @Sendable (BonjourBrowserEvent) -> Void
    ) {
        var updated: [NWEndpoint: BonjourAdvertisement] = [:]
        for result in results {
            let txtRecord: [String: String]
            if case .bonjour(let record) = result.metadata {
                txtRecord = record.dictionary
            } else {
                txtRecord = [:]
            }
            updated[result.endpoint] = BonjourAdvertisement(
                endpointID: registry.retain(result.endpoint),
                interfaceNames: Set(result.interfaces.map(\.name)),
                txtRecord: txtRecord
            )
        }

        let events: [BonjourBrowserEvent] = lock.withLock {
            var values: [BonjourBrowserEvent] = []
            for (endpoint, advertisement) in updated {
                if let previous = advertisements[endpoint] {
                    if previous != advertisement { values.append(.changed(advertisement)) }
                } else {
                    values.append(.added(advertisement))
                }
            }
            for (endpoint, advertisement) in advertisements where updated[endpoint] == nil {
                values.append(.removed(endpointID: advertisement.endpointID))
            }
            advertisements = updated
            return values
        }
        events.forEach(eventHandler)
    }

    private static func isPermissionDenied(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EACCES }
        return false
    }

    private static func safeReason(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "posix-\(code.rawValue)"
        case .dns(let code): return "dns-\(code)"
        case .tls(let code): return "tls-\(code)"
        default: return "other-network-error"
        }
    }
}

public final class NetworkBonjourConnectionFactory: BonjourConnectionFactory, @unchecked Sendable {
    private let registry: NetworkBonjourEndpointRegistry
    private let parameters: @Sendable () -> NWParameters
    private let queue: DispatchQueue

    public init(
        registry: NetworkBonjourEndpointRegistry,
        queue: DispatchQueue = DispatchQueue(label: "BeakrNet.BonjourConnection"),
        parameters: @escaping @Sendable () -> NWParameters
    ) {
        self.registry = registry
        self.queue = queue
        self.parameters = parameters
    }

    public func makeConnection(to endpointID: BonjourEndpointID) throws -> any BonjourConnection {
        guard let endpoint = registry.endpoint(for: endpointID) else {
            throw NetworkBonjourAdapterError.endpointUnavailable
        }
        return NetworkBonjourConnection(
            connection: NWConnection(to: endpoint, using: parameters()),
            queue: queue
        )
    }
}

public final class NetworkBonjourConnection: BonjourConnection, @unchecked Sendable {
    public let id: UUID
    public let connection: NWConnection
    private let queue: DispatchQueue

    public init(
        id: UUID = UUID(),
        connection: NWConnection,
        queue: DispatchQueue = DispatchQueue(label: "BeakrNet.BonjourConnection")
    ) {
        self.id = id
        self.connection = connection
        self.queue = queue
    }

    public func start(stateHandler: @escaping @Sendable (BonjourConnectionState) -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .setup: stateHandler(.setup)
            case .preparing: stateHandler(.preparing)
            case .waiting(let error): stateHandler(.waiting(reason: Self.safeReason(error)))
            case .ready: stateHandler(.ready)
            case .failed(let error): stateHandler(.failed(reason: Self.safeReason(error)))
            case .cancelled: stateHandler(.cancelled)
            @unknown default: stateHandler(.failed(reason: "unknown-connection-state"))
            }
        }
        connection.start(queue: queue)
    }

    public func cancel() {
        connection.cancel()
    }

    public func sendFrame(_ data: Data) async throws {
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(data)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    public func receiveFrame(maximumBytes: Int) async throws -> Data {
        let header = try await receiveExactly(MemoryLayout<UInt32>.size)
        let length = header.withUnsafeBytes {
            Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)))
        }
        guard length <= maximumBytes else {
            throw BonjourConnectionIOError.frameTooLarge(maximumBytes: maximumBytes, actualBytes: length)
        }
        return try await receiveExactly(length)
    }

    public func peerCertificate() throws -> BonjourPeerCertificate {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            throw BonjourConnectionIOError.peerCertificateUnavailable
        }
        var leaf: SecCertificate?
        let available = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if leaf == nil { leaf = sec_certificate_copy_ref(certificate).takeRetainedValue() }
        }
        guard available, let leaf,
              let key = SecCertificateCopyKey(leaf),
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw BonjourConnectionIOError.peerCertificateUnavailable
        }
        return BonjourPeerCertificate(
            derRepresentation: SecCertificateCopyData(leaf) as Data,
            publicKeyRepresentation: keyData
        )
    }

    private func receiveExactly(_ byteCount: Int) async throws -> Data {
        var result = Data()
        while result.count < byteCount {
            let remaining = byteCount - result.count
            let chunk = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, any Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) {
                    content, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let content, !content.isEmpty { continuation.resume(returning: content) }
                    else if isComplete { continuation.resume(throwing: BonjourConnectionIOError.connectionClosed) }
                    else { continuation.resume(throwing: BonjourConnectionIOError.incompleteFrame) }
                }
            }
            result.append(chunk)
        }
        return result
    }

    private static func safeReason(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "posix-\(code.rawValue)"
        case .dns(let code): return "dns-\(code)"
        case .tls(let code): return "tls-\(code)"
        default: return "other-network-error"
        }
    }
}

public final class NetworkBonjourListener: BonjourListening, @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue

    public init(
        listener: NWListener,
        queue: DispatchQueue = DispatchQueue(label: "BeakrNet.BonjourListener")
    ) {
        self.listener = listener
        self.queue = queue
    }

    public convenience init(
        parameters: NWParameters,
        serviceName: String? = nil,
        serviceType: String,
        domain: String? = nil,
        metadata: BonjourDiscoveryMetadata,
        queue: DispatchQueue = DispatchQueue(label: "BeakrNet.BonjourListener")
    ) throws {
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(
            name: serviceName,
            type: serviceType,
            domain: domain,
            txtRecord: NWTXTRecord(metadata.txtRecord)
        )
        self.init(listener: listener, queue: queue)
    }

    public func start(eventHandler: @escaping @Sendable (BonjourListenerEvent) -> Void) {
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .setup: eventHandler(.state(.setup))
            case .ready: eventHandler(.state(.ready(port: listener?.port?.rawValue)))
            case .waiting(let error):
                if Self.isPermissionDenied(error) { eventHandler(.permissionDenied) }
                eventHandler(.state(.waiting(reason: Self.safeReason(error))))
            case .failed(let error):
                if Self.isPermissionDenied(error) { eventHandler(.permissionDenied) }
                eventHandler(.state(.failed(reason: Self.safeReason(error))))
            case .cancelled: eventHandler(.state(.cancelled))
            @unknown default: eventHandler(.state(.failed(reason: "unknown-listener-state")))
            }
        }
        listener.newConnectionHandler = { connection in
            let wrappedConnection = NetworkBonjourConnection(connection: connection)
            wrappedConnection.start { state in
                switch state {
                case .ready:
                    wrappedConnection.connection.stateUpdateHandler = nil
                    eventHandler(.connection(wrappedConnection))
                case .failed, .cancelled:
                    wrappedConnection.connection.stateUpdateHandler = nil
                    wrappedConnection.cancel()
                case .setup, .preparing, .waiting:
                    break
                }
            }
        }
        listener.start(queue: queue)
    }

    public func cancel() {
        listener.cancel()
    }

    private static func isPermissionDenied(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EACCES }
        return false
    }

    private static func safeReason(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "posix-\(code.rawValue)"
        case .dns(let code): return "dns-\(code)"
        case .tls(let code): return "tls-\(code)"
        default: return "other-network-error"
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
#endif
