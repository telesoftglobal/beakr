import Foundation
import Network
import BeakrNetCore
import BeakrNetSecurity
import BeakrNetAuthority

@main
struct BeakrNetRelayServerMain {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 5,
              let portValue = UInt16(arguments[0]) else {
            print("Usage: BeakrNetRelayServer <port> <psk-file> <authority-public-key> <environment> <revocation-snapshot>")
            return
        }
        guard let port = NWEndpoint.Port(rawValue: portValue) else {
            throw RelayServerError.invalidPort(portValue)
        }
        let preSharedKey = try RelayTLSConfiguration.loadPreSharedKey(
            from: URL(fileURLWithPath: arguments[1])
        )
        let authorityPublicKey = try Data(
            contentsOf: URL(fileURLWithPath: arguments[2])
        )
        let revocationSnapshot = try CredentialFiles.loadRevocationSnapshot(
            from: URL(fileURLWithPath: arguments[4])
        )
        let revokedCredentialIDs = try RevocationVerifier.verify(
            revocationSnapshot,
            trustedAuthorityPublicKey: authorityPublicKey
        )

        let server = try RelayServer(
            port: port,
            preSharedKey: preSharedKey,
            authorityPublicKey: authorityPublicKey,
            environment: arguments[3],
            revokedCredentialIDs: revokedCredentialIDs
        )
        try await server.run()
    }
}

private actor RelayServer {
    private let listener: NWListener
    private let port: NWEndpoint.Port
    private let authorityPublicKey: Data
    private let environment: String
    private let revokedCredentialIDs: Set<UUID>
    private let offlineQueue = BoundedRelayQueue(policy: .development)
    private var connections: [NodeID: NWConnection] = [:]
    private var nodeIDsByConnection: [ObjectIdentifier: NodeID] = [:]
    private var authenticationAttempts: [ObjectIdentifier: AuthenticationAttempt] = [:]

    init(
        port: NWEndpoint.Port,
        preSharedKey: Data,
        authorityPublicKey: Data,
        environment: String,
        revokedCredentialIDs: Set<UUID>
    ) throws {
        self.port = port
        self.authorityPublicKey = authorityPublicKey
        self.environment = environment
        self.revokedCredentialIDs = revokedCredentialIDs
        let parameters = try RelayTLSConfiguration.parameters(preSharedKey: preSharedKey)
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port
        )
        listener = try NWListener(using: parameters)
    }

    func run() async throws {
        let listener = self.listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: DispatchQueue(label: "BeakrNetRelayServer.listener"))
        print("BeakrNet relay listening on 127.0.0.1:\(port.rawValue)")

        try await withTaskCancellationHandler {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3_600))
            }
        } onCancel: {
            listener.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "BeakrNetRelayServer.connection"))
        Task { await receiveLoop(from: connection) }
    }

    private func receiveLoop(from connection: NWConnection) async {
        do {
            while true {
                let message = try await NetworkConnectionIO.receive(from: connection)
                try await handle(message, from: connection)
            }
        } catch {
            remove(connection)
            connection.cancel()
        }
    }

    private func handle(_ message: RelayWireMessage, from connection: NWConnection) async throws {
        switch message {
        case .clientHello(let credential):
            do {
                try CredentialVerifier.verify(
                    credential,
                    trustedAuthorityPublicKey: authorityPublicKey,
                    environment: environment,
                    revokedCredentialIDs: revokedCredentialIDs
                )
            } catch {
                try await NetworkConnectionIO.send(.registrationRejected, over: connection)
                throw RelayServerError.invalidCredential
            }
            let nodeID = credential.claims.nodeID
            let publicKey = credential.claims.nodePublicKey
            let challenge = secureRandomData(count: 32)
            authenticationAttempts[ObjectIdentifier(connection)] = AuthenticationAttempt(
                nodeID: nodeID,
                publicKey: publicKey,
                challenge: challenge
            )
            try await NetworkConnectionIO.send(.serverChallenge(challenge), over: connection)

        case .clientProof(let signature):
            let identifier = ObjectIdentifier(connection)
            guard let attempt = authenticationAttempts.removeValue(forKey: identifier),
                  NodeIdentity.verifyRegistrationProof(
                    nodeID: attempt.nodeID,
                    publicKeyRepresentation: attempt.publicKey,
                    challenge: attempt.challenge,
                    signature: signature
                  ) else {
                try await NetworkConnectionIO.send(.registrationRejected, over: connection)
                throw RelayServerError.invalidRegistrationProof
            }
            let nodeID = attempt.nodeID
            if let previousNodeID = nodeIDsByConnection[identifier] {
                connections.removeValue(forKey: previousNodeID)
            }
            connections[nodeID] = connection
            nodeIDsByConnection[identifier] = nodeID
            print("Registered node \(nodeID.rawValue.uuidString)")
            try await NetworkConnectionIO.send(
                .registrationAccepted(nodeID: nodeID),
                over: connection
            )

            let queued = await offlineQueue.drain(for: nodeID)
            for queuedEnvelope in queued {
                try await NetworkConnectionIO.send(
                    .envelope(queuedEnvelope),
                    over: connection
                )
            }

        case .envelope(let envelope):
            guard nodeIDsByConnection[ObjectIdentifier(connection)] == envelope.sourceNodeID else {
                throw RelayServerError.sourceIdentityMismatch
            }
            let outbound = RelayWireMessage.envelope(envelope)
            if let destination = connections[envelope.destinationNodeID] {
                try await NetworkConnectionIO.send(outbound, over: destination)
            } else {
                await offlineQueue.enqueue(
                    envelope,
                    for: envelope.destinationNodeID
                )
            }

        case .serverChallenge, .registrationAccepted, .registrationRejected:
            throw RelayServerError.unexpectedClientMessage
        }
    }

    private func remove(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        authenticationAttempts.removeValue(forKey: identifier)
        guard let nodeID = nodeIDsByConnection.removeValue(forKey: identifier) else { return }
        if connections[nodeID] === connection {
            connections.removeValue(forKey: nodeID)
        }
        print("Disconnected node \(nodeID.rawValue.uuidString)")
    }
}

private struct AuthenticationAttempt: Sendable {
    let nodeID: NodeID
    let publicKey: Data
    let challenge: Data
}

private func secureRandomData(count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}

private enum RelayServerError: Error {
    case invalidPort(UInt16)
    case invalidCredential
    case invalidRegistrationProof
    case unexpectedClientMessage
    case sourceIdentityMismatch
}
