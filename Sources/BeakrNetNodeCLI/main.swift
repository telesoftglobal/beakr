import Foundation
import Network
import BeakrNetCore
import BeakrNetSecurity

@main
struct BeakrNetNodeCLI {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2,
              let mode = Mode(rawValue: arguments[0]) else {
            printUsage()
            return
        }

        if mode == .psk {
            _ = try RelayTLSConfiguration.createPreSharedKey(
                at: URL(fileURLWithPath: arguments[1])
            )
            print("Created a 32-byte development relay PSK")
            return
        }

        let identity = try FileNodeIdentityStore(
            fileURL: URL(fileURLWithPath: arguments[1])
        ).loadOrCreate()

        if mode == .identity {
            print(identity.nodeID.rawValue.uuidString)
            return
        }

        guard arguments.count >= 4,
              let count = Int(arguments[2]),
              count > 0 else {
            printUsage()
            return
        }

        let peerUUID = mode == .send ? UUID(uuidString: arguments[3]) : nil
        let preSharedKeyPath: String
        let portArgument: String?
        switch mode {
        case .receive:
            preSharedKeyPath = arguments[3]
            portArgument = arguments.count > 4 ? arguments[4] : nil
        case .send:
            guard arguments.count >= 5 else {
                printUsage()
                return
            }
            preSharedKeyPath = arguments[4]
            portArgument = arguments.count > 5 ? arguments[5] : nil
        case .identity, .psk:
            preSharedKeyPath = ""
            portArgument = nil
        }
        let portValue: UInt16
        if let portArgument {
            guard let parsedPort = UInt16(portArgument) else {
                throw NodeCLIError.invalidPort
            }
            portValue = parsedPort
        } else {
            portValue = 7878
        }
        guard let port = NWEndpoint.Port(rawValue: portValue) else {
            throw NodeCLIError.invalidPort
        }

        let nodeID = identity.nodeID
        let preSharedKey = try RelayTLSConfiguration.loadPreSharedKey(
            from: URL(fileURLWithPath: preSharedKeyPath)
        )
        let parameters = try RelayTLSConfiguration.parameters(preSharedKey: preSharedKey)
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: parameters
        )
        try await start(connection)
        defer { connection.cancel() }
        try await authenticate(identity: identity, over: connection)

        switch mode {
        case .identity, .psk:
            return
        case .receive:
            try await receive(count: count, nodeID: nodeID, from: connection)
        case .send:
            guard let peerUUID else {
                printUsage()
                return
            }
            try await send(
                count: count,
                from: nodeID,
                to: NodeID(rawValue: peerUUID),
                over: connection
            )
        }
    }

    private static func authenticate(
        identity: NodeIdentity,
        over connection: NWConnection
    ) async throws {
        try await NetworkConnectionIO.send(
            .clientHello(
                nodeID: identity.nodeID,
                publicKey: identity.publicKeyRepresentation
            ),
            over: connection
        )
        guard case .serverChallenge(let challenge) = try await NetworkConnectionIO.receive(
            from: connection
        ) else {
            throw NodeCLIError.authenticationFailed
        }
        let signature = try identity.signature(forRegistrationChallenge: challenge)
        try await NetworkConnectionIO.send(.clientProof(signature), over: connection)
        guard case .registrationAccepted(let nodeID) = try await NetworkConnectionIO.receive(
            from: connection
        ), nodeID == identity.nodeID else {
            throw NodeCLIError.authenticationFailed
        }
        print("Authenticated as \(nodeID.rawValue.uuidString)")
    }

    private static func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let gate = ConnectionStartGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.claim() {
                        continuation.resume()
                    }
                case .failed(let error):
                    if gate.claim() {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if gate.claim() {
                        continuation.resume(throwing: NodeCLIError.connectionCancelled)
                    }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "BeakrNetNodeCLI.connection"))
        }
    }

    private static func send(
        count: Int,
        from source: NodeID,
        to destination: NodeID,
        over connection: NWConnection
    ) async throws {
        let sessionID = SessionID()
        for sequenceNumber in 1...count {
            let envelope = BeakrNetEnvelope(
                sessionID: sessionID,
                sourceNodeID: source,
                destinationNodeID: destination,
                sequenceNumber: UInt64(sequenceNumber),
                payloadType: "ping",
                payload: Data("ping-\(sequenceNumber)".utf8)
            )
            try await NetworkConnectionIO.send(.envelope(envelope), over: connection)
        }
        print("Sent \(count) envelopes to \(destination.rawValue.uuidString)")
    }

    private static func receive(
        count: Int,
        nodeID: NodeID,
        from connection: NWConnection
    ) async throws {
        var receivedSequences: [UInt64] = []
        while receivedSequences.count < count {
            let message = try await NetworkConnectionIO.receive(from: connection)
            guard case .envelope(let envelope) = message,
                  envelope.destinationNodeID == nodeID else { continue }
            receivedSequences.append(envelope.sequenceNumber)
            print("Received sequence \(envelope.sequenceNumber)")
        }

        let expected = (1...count).map(UInt64.init)
        guard receivedSequences == expected else {
            throw NodeCLIError.unexpectedSequence(receivedSequences)
        }
        print("Received \(count) envelopes in order")
    }

    private static func printUsage() {
        print("Usage:")
        print("  BeakrNetNodeCLI identity <identity-file>")
        print("  BeakrNetNodeCLI psk <psk-file>")
        print("  BeakrNetNodeCLI receive <identity-file> <count> <psk-file> [port]")
        print("  BeakrNetNodeCLI send <identity-file> <count> <peer-node-uuid> <psk-file> [port]")
    }
}

private enum Mode: String {
    case identity
    case psk
    case send
    case receive
}

private enum NodeCLIError: Error {
    case invalidPort
    case authenticationFailed
    case connectionCancelled
    case unexpectedSequence([UInt64])
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
