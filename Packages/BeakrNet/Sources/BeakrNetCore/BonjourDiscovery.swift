import Foundation

public struct BonjourEndpointID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct BonjourAdvertisement: Equatable, Sendable {
    public let endpointID: BonjourEndpointID
    public let interfaceNames: Set<String>
    public let txtRecord: [String: String]

    public init(
        endpointID: BonjourEndpointID,
        interfaceNames: Set<String> = [],
        txtRecord: [String: String]
    ) {
        self.endpointID = endpointID
        self.interfaceNames = interfaceNames
        self.txtRecord = txtRecord
    }
}

public struct BonjourDiscoveryMetadata: Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumDisplayNameUTF8Length = 128

    public let version: Int
    public let protocolMajorVersion: Int
    public let nodeIDHint: NodeID
    public let advertisementNonce: Data
    public let displayName: String?

    public init(
        version: Int = Self.currentVersion,
        protocolMajorVersion: Int = TransportCapabilities.currentProtocolVersion,
        nodeIDHint: NodeID,
        advertisementNonce: Data,
        displayName: String? = nil
    ) {
        self.version = version
        self.protocolMajorVersion = protocolMajorVersion
        self.nodeIDHint = nodeIDHint
        self.advertisementNonce = advertisementNonce
        self.displayName = displayName
    }

    public var txtRecord: [String: String] {
        var record = [
            "v": String(version),
            "pv": String(protocolMajorVersion),
            "node": nodeIDHint.rawValue.uuidString.lowercased(),
            "nonce": advertisementNonce.base64EncodedString()
        ]
        if let displayName {
            record["name"] = displayName
        }
        return record
    }
}

public enum BonjourMetadataError: Error, Equatable, Sendable {
    case missingField(String)
    case unsupportedVersion(Int)
    case invalidProtocolVersion
    case invalidNodeID
    case invalidAdvertisementNonce
    case invalidDisplayName
}

public enum BonjourMetadataParser {
    public static func parse(_ record: [String: String]) throws -> BonjourDiscoveryMetadata {
        guard let versionValue = record["v"] else { throw BonjourMetadataError.missingField("v") }
        guard let version = Int(versionValue) else { throw BonjourMetadataError.unsupportedVersion(-1) }
        guard version == BonjourDiscoveryMetadata.currentVersion else {
            throw BonjourMetadataError.unsupportedVersion(version)
        }
        guard let protocolValue = record["pv"] else { throw BonjourMetadataError.missingField("pv") }
        guard let protocolVersion = Int(protocolValue), protocolVersion > 0 else {
            throw BonjourMetadataError.invalidProtocolVersion
        }
        guard let nodeValue = record["node"] else { throw BonjourMetadataError.missingField("node") }
        guard let nodeUUID = UUID(uuidString: nodeValue) else { throw BonjourMetadataError.invalidNodeID }
        guard let nonceValue = record["nonce"] else { throw BonjourMetadataError.missingField("nonce") }
        guard let nonce = Data(base64Encoded: nonceValue), nonce.count == 32 else {
            throw BonjourMetadataError.invalidAdvertisementNonce
        }
        let displayName = record["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let displayName,
           displayName.isEmpty || displayName.utf8.count > BonjourDiscoveryMetadata.maximumDisplayNameUTF8Length {
            throw BonjourMetadataError.invalidDisplayName
        }
        return BonjourDiscoveryMetadata(
            version: version,
            protocolMajorVersion: protocolVersion,
            nodeIDHint: NodeID(rawValue: nodeUUID),
            advertisementNonce: nonce,
            displayName: displayName
        )
    }
}

public struct BonjourDiscoveryKey: Hashable, Sendable {
    public let endpointID: BonjourEndpointID
    public let advertisementNonce: Data

    public init(endpointID: BonjourEndpointID, advertisementNonce: Data) {
        self.endpointID = endpointID
        self.advertisementNonce = advertisementNonce
    }
}

public struct BonjourDiscoveryCandidate: Equatable, Sendable {
    public let key: BonjourDiscoveryKey
    public let nodeIDHint: NodeID
    public let protocolMajorVersion: Int
    public let interfaceNames: Set<String>
    public let displayName: String?

    public init(advertisement: BonjourAdvertisement, metadata: BonjourDiscoveryMetadata) {
        key = BonjourDiscoveryKey(
            endpointID: advertisement.endpointID,
            advertisementNonce: metadata.advertisementNonce
        )
        nodeIDHint = metadata.nodeIDHint
        protocolMajorVersion = metadata.protocolMajorVersion
        interfaceNames = advertisement.interfaceNames
        displayName = metadata.displayName
    }
}

public enum BonjourBrowserState: Equatable, Sendable {
    case setup
    case ready
    case waiting(reason: String)
    case failed(reason: String)
    case cancelled
}

public enum BonjourBrowserEvent: Equatable, Sendable {
    case added(BonjourAdvertisement)
    case changed(BonjourAdvertisement)
    case removed(endpointID: BonjourEndpointID)
    case state(BonjourBrowserState)
    case permissionDenied
}

public protocol BonjourBrowsing: Sendable {
    func start(eventHandler: @escaping @Sendable (BonjourBrowserEvent) -> Void)
    func cancel()
}

public enum BonjourListenerState: Equatable, Sendable {
    case setup
    case ready(port: UInt16?)
    case waiting(reason: String)
    case failed(reason: String)
    case cancelled
}

public enum BonjourListenerEvent: Sendable {
    case state(BonjourListenerState)
    case connection(any BonjourConnection)
    case permissionDenied
}

public protocol BonjourListening: Sendable {
    func start(eventHandler: @escaping @Sendable (BonjourListenerEvent) -> Void)
    func cancel()
}

public enum BonjourConnectionState: Equatable, Sendable {
    case setup
    case preparing
    case waiting(reason: String)
    case ready
    case failed(reason: String)
    case cancelled
}

public struct BonjourPeerCertificate: Equatable, Sendable {
    public let derRepresentation: Data
    public let publicKeyRepresentation: Data

    public init(derRepresentation: Data, publicKeyRepresentation: Data) {
        self.derRepresentation = derRepresentation
        self.publicKeyRepresentation = publicKeyRepresentation
    }
}

public enum BonjourConnectionIOError: Error, Equatable, Sendable {
    case connectionClosed
    case incompleteFrame
    case frameTooLarge(maximumBytes: Int, actualBytes: Int)
    case peerCertificateUnavailable
}

public protocol BonjourConnection: AnyObject, Sendable {
    var id: UUID { get }
    func start(stateHandler: @escaping @Sendable (BonjourConnectionState) -> Void)
    func sendFrame(_ data: Data) async throws
    func receiveFrame(maximumBytes: Int) async throws -> Data
    func peerCertificate() throws -> BonjourPeerCertificate
    func cancel()
}

public protocol BonjourConnectionFactory: Sendable {
    func makeConnection(to endpointID: BonjourEndpointID) throws -> any BonjourConnection
}

public enum BonjourDiagnostic: Equatable, Sendable {
    case browserState(BonjourBrowserState)
    case listenerState(BonjourListenerState)
    case discoveryAdded(BonjourDiscoveryKey, nodeIDHint: NodeID)
    case discoveryChanged(BonjourDiscoveryKey, nodeIDHint: NodeID)
    case discoveryRemoved(BonjourEndpointID)
    case discoveryRejected(BonjourEndpointID, reason: BonjourMetadataError)
    case permissionDenied(component: String)
    case initiatorSelected(BonjourDiscoveryKey, hintedPeer: NodeID)
    case acceptorSelected(BonjourDiscoveryKey, hintedPeer: NodeID)
    case nodeIDHintCollision(BonjourDiscoveryKey)
    case connectionState(UUID, BonjourConnectionState)
    case connectionCreationFailed(BonjourDiscoveryKey, reason: String)
    case staleCallbackIgnored(component: String, generation: UInt64)
}

public typealias BonjourDiagnosticSink = @Sendable (BonjourDiagnostic) -> Void

public actor BonjourDiscoveryCoordinator {
    public typealias ConnectionHandler = @Sendable (BonjourDiscoveryCandidate, any BonjourConnection) -> Void
    public typealias ConnectionEndedHandler = @Sendable (UUID) -> Void

    private let localNodeID: NodeID
    private let browser: any BonjourBrowsing
    private let connectionFactory: any BonjourConnectionFactory
    private let diagnosticSink: BonjourDiagnosticSink
    private let connectionHandler: ConnectionHandler
    private let connectionEndedHandler: ConnectionEndedHandler
    private let reconnectDelay: Duration
    private var generation: UInt64 = 0
    private var candidates: [BonjourDiscoveryKey: BonjourDiscoveryCandidate] = [:]
    private var keysByEndpoint: [BonjourEndpointID: BonjourDiscoveryKey] = [:]
    private var connections: [BonjourDiscoveryKey: any BonjourConnection] = [:]
    private var handedOffConnectionIDs: Set<UUID> = []
    private var reconnectTasks: [BonjourDiscoveryKey: Task<Void, Never>] = [:]

    public init(
        localNodeID: NodeID,
        browser: any BonjourBrowsing,
        connectionFactory: any BonjourConnectionFactory,
        reconnectDelay: Duration = .seconds(1),
        diagnosticSink: @escaping BonjourDiagnosticSink = { _ in },
        connectionHandler: @escaping ConnectionHandler = { _, _ in },
        connectionEndedHandler: @escaping ConnectionEndedHandler = { _ in }
    ) {
        self.localNodeID = localNodeID
        self.browser = browser
        self.connectionFactory = connectionFactory
        self.reconnectDelay = reconnectDelay
        self.diagnosticSink = diagnosticSink
        self.connectionHandler = connectionHandler
        self.connectionEndedHandler = connectionEndedHandler
    }

    public func start() {
        generation &+= 1
        let callbackGeneration = generation
        browser.start { [weak self] event in
            Task { await self?.handle(event, generation: callbackGeneration) }
        }
    }

    public func stop() {
        generation &+= 1
        browser.cancel()
        connections.values.forEach { $0.cancel() }
        handedOffConnectionIDs.forEach(connectionEndedHandler)
        handedOffConnectionIDs.removeAll()
        reconnectTasks.values.forEach { $0.cancel() }
        reconnectTasks.removeAll()
        connections.removeAll()
        candidates.removeAll()
        keysByEndpoint.removeAll()
    }

    public func discoveredCandidates() -> [BonjourDiscoveryCandidate] {
        candidates.values.sorted { lhs, rhs in
            lhs.key.endpointID.rawValue.uuidString < rhs.key.endpointID.rawValue.uuidString
        }
    }

    private func handle(_ event: BonjourBrowserEvent, generation callbackGeneration: UInt64) {
        guard callbackGeneration == generation else {
            diagnosticSink(.staleCallbackIgnored(component: "browser", generation: callbackGeneration))
            return
        }
        switch event {
        case .added(let advertisement):
            upsert(advertisement, isChange: false, generation: callbackGeneration)
        case .changed(let advertisement):
            upsert(advertisement, isChange: true, generation: callbackGeneration)
        case .removed(let endpointID):
            remove(endpointID: endpointID)
        case .state(let state):
            diagnosticSink(.browserState(state))
        case .permissionDenied:
            diagnosticSink(.permissionDenied(component: "browser"))
        }
    }

    private func upsert(
        _ advertisement: BonjourAdvertisement,
        isChange: Bool,
        generation callbackGeneration: UInt64
    ) {
        let metadata: BonjourDiscoveryMetadata
        do {
            metadata = try BonjourMetadataParser.parse(advertisement.txtRecord)
        } catch let error as BonjourMetadataError {
            diagnosticSink(.discoveryRejected(advertisement.endpointID, reason: error))
            return
        } catch {
            return
        }

        if let previousKey = keysByEndpoint[advertisement.endpointID],
           previousKey.advertisementNonce != metadata.advertisementNonce {
            connections.removeValue(forKey: previousKey)?.cancel()
            reconnectTasks.removeValue(forKey: previousKey)?.cancel()
            candidates.removeValue(forKey: previousKey)
        }
        let candidate = BonjourDiscoveryCandidate(advertisement: advertisement, metadata: metadata)
        candidates[candidate.key] = candidate
        keysByEndpoint[advertisement.endpointID] = candidate.key
        diagnosticSink(isChange
            ? .discoveryChanged(candidate.key, nodeIDHint: candidate.nodeIDHint)
            : .discoveryAdded(candidate.key, nodeIDHint: candidate.nodeIDHint))

        guard candidate.protocolMajorVersion == TransportCapabilities.currentProtocolVersion else { return }
        guard candidate.nodeIDHint != localNodeID else {
            diagnosticSink(.nodeIDHintCollision(candidate.key))
            return
        }
        guard Self.canonicalNodeID(localNodeID, precedes: candidate.nodeIDHint) else {
            diagnosticSink(.acceptorSelected(candidate.key, hintedPeer: candidate.nodeIDHint))
            return
        }
        diagnosticSink(.initiatorSelected(candidate.key, hintedPeer: candidate.nodeIDHint))
        startConnection(for: candidate, generation: callbackGeneration)
    }

    private func startConnection(
        for candidate: BonjourDiscoveryCandidate,
        generation callbackGeneration: UInt64
    ) {
        guard callbackGeneration == generation,
              candidates[candidate.key] != nil,
              connections[candidate.key] == nil else { return }
        reconnectTasks.removeValue(forKey: candidate.key)?.cancel()
        do {
            let connection = try connectionFactory.makeConnection(to: candidate.key.endpointID)
            connections[candidate.key] = connection
            let connectionID = connection.id
            connection.start { [weak self] state in
                Task { await self?.handleConnectionState(
                    state,
                    connectionID: connectionID,
                    key: candidate.key,
                    generation: callbackGeneration
                ) }
            }
        } catch {
            diagnosticSink(.connectionCreationFailed(candidate.key, reason: String(describing: error)))
            scheduleReconnect(for: candidate.key, generation: callbackGeneration)
        }
    }

    private func remove(endpointID: BonjourEndpointID) {
        guard let key = keysByEndpoint.removeValue(forKey: endpointID) else { return }
        candidates.removeValue(forKey: key)
        reconnectTasks.removeValue(forKey: key)?.cancel()
        diagnosticSink(.discoveryRemoved(endpointID))
        // Discovery loss is not authentication failure and does not tear down a connection.
    }

    private func handleConnectionState(
        _ state: BonjourConnectionState,
        connectionID: UUID,
        key: BonjourDiscoveryKey,
        generation callbackGeneration: UInt64
    ) {
        guard callbackGeneration == generation, connections[key]?.id == connectionID else {
            diagnosticSink(.staleCallbackIgnored(component: "connection", generation: callbackGeneration))
            return
        }
        diagnosticSink(.connectionState(connectionID, state))
        if state == .ready, let connection = connections[key] {
            reconnectTasks.removeValue(forKey: key)?.cancel()
            guard let candidate = candidates[key] else {
                connection.cancel()
                removeConnection(for: key)
                return
            }
            if handedOffConnectionIDs.insert(connectionID).inserted {
                connectionHandler(candidate, connection)
            }
        }
        if case .failed = state {
            removeConnection(for: key)
            scheduleReconnect(for: key, generation: callbackGeneration)
        }
        if state == .cancelled {
            removeConnection(for: key)
            scheduleReconnect(for: key, generation: callbackGeneration)
        }
    }

    private func scheduleReconnect(for key: BonjourDiscoveryKey, generation callbackGeneration: UInt64) {
        guard callbackGeneration == generation,
              reconnectTasks[key] == nil,
              let candidate = candidates[key],
              candidate.protocolMajorVersion == TransportCapabilities.currentProtocolVersion,
              candidate.nodeIDHint != localNodeID,
              Self.canonicalNodeID(localNodeID, precedes: candidate.nodeIDHint) else { return }
        reconnectTasks[key] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.reconnectDelay)
            guard !Task.isCancelled else { return }
            await self.retryConnection(for: key, generation: callbackGeneration)
        }
    }

    private func retryConnection(for key: BonjourDiscoveryKey, generation callbackGeneration: UInt64) {
        reconnectTasks.removeValue(forKey: key)
        guard let candidate = candidates[key] else { return }
        startConnection(for: candidate, generation: callbackGeneration)
    }

    private func removeConnection(for key: BonjourDiscoveryKey) {
        guard let connection = connections.removeValue(forKey: key) else { return }
        if handedOffConnectionIDs.remove(connection.id) != nil {
            connectionEndedHandler(connection.id)
        }
    }

    private static func canonicalNodeID(_ lhs: NodeID, precedes rhs: NodeID) -> Bool {
        lhs.rawValue.uuidString.lowercased() < rhs.rawValue.uuidString.lowercased()
    }
}

public actor BonjourListenerCoordinator {
    private let listener: any BonjourListening
    private let diagnosticSink: BonjourDiagnosticSink
    private let connectionHandler: @Sendable (any BonjourConnection) -> Void
    private var generation: UInt64 = 0

    public init(
        listener: any BonjourListening,
        diagnosticSink: @escaping BonjourDiagnosticSink = { _ in },
        connectionHandler: @escaping @Sendable (any BonjourConnection) -> Void
    ) {
        self.listener = listener
        self.diagnosticSink = diagnosticSink
        self.connectionHandler = connectionHandler
    }

    public func start() {
        generation &+= 1
        let callbackGeneration = generation
        listener.start { [weak self] event in
            Task { await self?.handle(event, generation: callbackGeneration) }
        }
    }

    public func stop() {
        generation &+= 1
        listener.cancel()
    }

    private func handle(_ event: BonjourListenerEvent, generation callbackGeneration: UInt64) {
        guard callbackGeneration == generation else {
            diagnosticSink(.staleCallbackIgnored(component: "listener", generation: callbackGeneration))
            return
        }
        switch event {
        case .state(let state): diagnosticSink(.listenerState(state))
        case .connection(let connection): connectionHandler(connection)
        case .permissionDenied: diagnosticSink(.permissionDenied(component: "listener"))
        }
    }
}
