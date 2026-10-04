import Foundation
import Network
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

public struct RelayTransportConfiguration: Sendable {
    public let host: String
    public let port: UInt16
    public let preSharedKey: Data
    public let identity: NodeIdentity
    public let credential: NodeCredential
    public let trustedAuthorityPublicKey: Data?
    public let now: @Sendable () -> Date
    public let reconnectDelays: [TimeInterval]
    public let connectionAttemptTimeout: TimeInterval

    public init(
        host: String,
        port: UInt16,
        preSharedKey: Data,
        identity: NodeIdentity,
        credential: NodeCredential,
        trustedAuthorityPublicKey: Data? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        reconnectDelays: [TimeInterval] = [0.25, 0.5, 1, 2, 5],
        connectionAttemptTimeout: TimeInterval = 3
    ) throws {
        guard credential.claims.nodeID == identity.nodeID,
              credential.claims.nodePublicKey == identity.publicKeyRepresentation else {
            throw RelayTransportError.credentialIdentityMismatch
        }
        guard !reconnectDelays.isEmpty,
              reconnectDelays.allSatisfy({ $0 > 0 }),
              connectionAttemptTimeout > 0 else {
            throw RelayTransportError.invalidReconnectPolicy
        }
        self.host = host
        self.port = port
        self.preSharedKey = preSharedKey
        self.identity = identity
        self.credential = credential
        self.trustedAuthorityPublicKey = trustedAuthorityPublicKey
        self.now = now
        self.reconnectDelays = reconnectDelays
        self.connectionAttemptTimeout = connectionAttemptTimeout
    }
}

public enum RelayTransportState: Equatable, Sendable {
    case idle
    case connecting
    case authenticating
    case ready
    case waitingToReconnect(attempt: Int)
    case closed
}

public enum RelayTransportDiagnostic: Equatable, Sendable {
    case stateChanged(RelayTransportState)
    case authenticated(NodeID)
    case envelopeReceived(MessageID)
    case connectionLost(String)
}

public enum RelayTransportError: Error, Equatable, Sendable {
    case credentialIdentityMismatch
    case invalidReconnectPolicy
    case invalidPort
    case unavailable
    case authenticationRejected
    case unexpectedAuthenticationMessage
    case unexpectedRelayMessage
    case connectionCancelled
    case connectionTimedOut
    case missingTrustedAuthority
    case localCredentialRevoked
}

public actor RelayTransport: BeakrNetTransport, RevocationSnapshotConsumer {
    public nonisolated let id: TransportID
    public nonisolated let kind = TransportKind.relay
    public nonisolated var revocationConsumerID: TransportID { id }
    public nonisolated let capabilities = TransportCapabilities(
        preservesOrder: true,
        supportsImmediateDelivery: true,
        supportsQueuedDelivery: true,
        supportsBackgroundDelivery: false
    )

    public private(set) var state: RelayTransportState = .idle
    public private(set) var diagnosticHistory: [RelayTransportDiagnostic] = []

    private let configuration: RelayTransportConfiguration
    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var queuedEnvelopes: [BeakrNetEnvelope] = []
    private var waitingReceivers: [CheckedContinuation<BeakrNetEnvelope?, Never>] = []
    private var isClosing = false

    public init(
        id: TransportID = TransportID(),
        configuration: RelayTransportConfiguration
    ) {
        self.id = id
        self.configuration = configuration
    }

    public func connect() async throws {
        if state == .ready { return }
        isClosing = false
        reconnectTask?.cancel()
        reconnectTask = nil
        try await establishConnection()
    }

    public func send(_ envelope: BeakrNetEnvelope) async throws {
        guard state == .ready, let connection else {
            throw RelayTransportError.unavailable
        }
        do {
            try await NetworkConnectionIO.send(.envelope(envelope), over: connection)
        } catch {
            handleConnectionLoss(connection, error: error)
            throw error
        }
    }

    public func receive() async -> BeakrNetEnvelope? {
        if !queuedEnvelopes.isEmpty {
            return queuedEnvelopes.removeFirst()
        }
        if state == .closed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            waitingReceivers.append(continuation)
        }
    }

    public func installRevocationSnapshot(
        _ snapshot: CredentialRevocationSnapshot
    ) async throws {
        guard let trustedAuthorityPublicKey = configuration.trustedAuthorityPublicKey else {
            throw RelayTransportError.missingTrustedAuthority
        }
        let revoked = try RevocationVerifier.verify(
            snapshot,
            trustedAuthorityPublicKey: trustedAuthorityPublicKey,
            now: configuration.now()
        )
        guard !revoked.contains(configuration.credential.claims.credentialID) else {
            await close()
            throw RelayTransportError.localCredentialRevoked
        }
    }

    public func close() async {
        guard state != .closed else { return }
        isClosing = true
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
        transition(to: .closed)
        let receivers = waitingReceivers
        waitingReceivers.removeAll()
        receivers.forEach { $0.resume(returning: nil) }
    }

    private func establishConnection() async throws {
        transition(to: .connecting)
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw RelayTransportError.invalidPort
        }
        let parameters = try RelayTLSConfiguration.parameters(
            preSharedKey: configuration.preSharedKey
        )
        let newConnection = NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: port,
            using: parameters
        )

        do {
            try await ConnectionStarter.start(
                newConnection,
                timeout: configuration.connectionAttemptTimeout
            )
            transition(to: .authenticating)
            try await authenticate(over: newConnection)
            guard !isClosing else {
                newConnection.cancel()
                return
            }
            connection?.cancel()
            connection = newConnection
            transition(to: .ready)
            diagnosticHistory.append(.authenticated(configuration.identity.nodeID))
            startReceiveLoop(for: newConnection)
        } catch {
            newConnection.cancel()
            transition(to: .idle)
            throw error
        }
    }

    private func authenticate(over connection: NWConnection) async throws {
        try await NetworkConnectionIO.send(
            .clientHello(credential: configuration.credential),
            over: connection
        )
        let challengeMessage = try await NetworkConnectionIO.receive(from: connection)
        guard case .serverChallenge(let challenge) = challengeMessage else {
            if case .registrationRejected = challengeMessage {
                throw RelayTransportError.authenticationRejected
            }
            throw RelayTransportError.unexpectedAuthenticationMessage
        }

        let signature = try configuration.identity.signature(
            forRegistrationChallenge: challenge
        )
        try await NetworkConnectionIO.send(.clientProof(signature), over: connection)
        let result = try await NetworkConnectionIO.receive(from: connection)
        switch result {
        case .registrationAccepted(let nodeID)
            where nodeID == configuration.identity.nodeID:
            return
        case .registrationRejected:
            throw RelayTransportError.authenticationRejected
        default:
            throw RelayTransportError.unexpectedAuthenticationMessage
        }
    }

    private func startReceiveLoop(for connection: NWConnection) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self, connection] in
            do {
                while !Task.isCancelled {
                    let message = try await NetworkConnectionIO.receive(from: connection)
                    guard case .envelope(let envelope) = message else {
                        throw RelayTransportError.unexpectedRelayMessage
                    }
                    await self?.enqueueReceived(envelope)
                }
            } catch {
                await self?.handleConnectionLoss(connection, error: error)
            }
        }
    }

    private func enqueueReceived(_ envelope: BeakrNetEnvelope) {
        diagnosticHistory.append(.envelopeReceived(envelope.messageID))
        if waitingReceivers.isEmpty {
            queuedEnvelopes.append(envelope)
        } else {
            waitingReceivers.removeFirst().resume(returning: envelope)
        }
    }

    private func handleConnectionLoss(_ lostConnection: NWConnection, error: Error) {
        guard connection === lostConnection else { return }
        connection = nil
        receiveTask = nil
        lostConnection.cancel()
        diagnosticHistory.append(.connectionLost(error.localizedDescription))
        guard !isClosing else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    private func runReconnectLoop() async {
        var attempt = 0
        while !Task.isCancelled, !isClosing {
            let delayIndex = min(attempt, configuration.reconnectDelays.count - 1)
            let delay = configuration.reconnectDelays[delayIndex]
            attempt += 1
            transition(to: .waitingToReconnect(attempt: attempt))
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
                try await establishConnection()
                reconnectTask = nil
                return
            } catch is CancellationError {
                reconnectTask = nil
                return
            } catch {
                diagnosticHistory.append(.connectionLost(error.localizedDescription))
            }
        }
        reconnectTask = nil
    }

    private func transition(to newState: RelayTransportState) {
        state = newState
        diagnosticHistory.append(.stateChanged(newState))
    }
}

private enum ConnectionStarter {
    static func start(
        _ connection: NWConnection,
        timeout: TimeInterval
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await waitUntilReady(connection)
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(timeout * 1_000_000_000)
                )
                throw RelayTransportError.connectionTimedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private static func waitUntilReady(_ connection: NWConnection) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
                let gate = ConnectionStartGate()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if gate.claim() { continuation.resume() }
                    case .failed(let error):
                        if gate.claim() { continuation.resume(throwing: error) }
                    case .cancelled:
                        if gate.claim() {
                            continuation.resume(
                                throwing: RelayTransportError.connectionCancelled
                            )
                        }
                    default:
                        break
                    }
                }
                connection.start(
                    queue: DispatchQueue(label: "BeakrNetRelayTransport.connection")
                )
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

private final class ConnectionStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}
