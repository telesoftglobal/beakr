import Foundation
import Darwin
import BeakrNetCore
import BeakrNetSecurity
import BeakrNetAuthority
import BeakrNetRelayTransport

@main
struct BeakrNetNodeCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            let failure = error as NSError
            let message = "🔴 [FAIL] BeakrNetNodeCLI type=\(String(reflecting: type(of: error))) domain=\(failure.domain) code=\(failure.code)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
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
            print("[INFO] Created a 32-byte development relay PSK")
            return
        }

        let identity = try FileNodeIdentityStore(
            fileURL: URL(fileURLWithPath: arguments[1])
        ).loadOrCreate()

        if mode == .identity {
            print(identity.nodeID.rawValue.uuidString)
            return
        }

        guard arguments.count >= 5,
              let count = Int(arguments[2]),
              count > 0 else {
            printUsage()
            return
        }

        let peerUUID = mode == .send ? UUID(uuidString: arguments[3]) : nil
        let preSharedKeyPath: String
        let credentialPath: String
        let portArgument: String?
        switch mode {
        case .receive:
            preSharedKeyPath = arguments[3]
            credentialPath = arguments[4]
            portArgument = arguments.count > 5 ? arguments[5] : nil
        case .send:
            guard arguments.count >= 6 else {
                printUsage()
                return
            }
            preSharedKeyPath = arguments[4]
            credentialPath = arguments[5]
            portArgument = arguments.count > 6 ? arguments[6] : nil
        case .identity, .psk:
            preSharedKeyPath = ""
            credentialPath = ""
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
        guard portValue > 0 else {
            throw NodeCLIError.invalidPort
        }

        let nodeID = identity.nodeID
        let credential = try CredentialFiles.loadCredential(
            from: URL(fileURLWithPath: credentialPath)
        )
        let preSharedKey = try RelayTLSConfiguration.loadPreSharedKey(
            from: URL(fileURLWithPath: preSharedKeyPath)
        )
        let configuration = try RelayTransportConfiguration(
            host: "127.0.0.1",
            port: portValue,
            preSharedKey: preSharedKey,
            identity: identity,
            credential: credential
        )
        let transport = RelayTransport(configuration: configuration)
        try await transport.connect()
        print("[INFO] Authenticated as \(nodeID.rawValue.uuidString)")

        do {
            switch mode {
            case .identity, .psk:
                break
            case .receive:
                try await receive(count: count, nodeID: nodeID, from: transport)
            case .send:
                guard let peerUUID else {
                    printUsage()
                    await transport.close()
                    return
                }
                try await send(
                    count: count,
                    networkID: credential.claims.networkID,
                    from: nodeID,
                    to: NodeID(rawValue: peerUUID),
                    over: transport
                )
            }
            await transport.close()
        } catch {
            await transport.close()
            throw error
        }
    }

    private static func send(
        count: Int,
        networkID: NetworkID,
        from source: NodeID,
        to destination: NodeID,
        over transport: RelayTransport
    ) async throws {
        let sessionID = SessionID()
        for sequenceNumber in 1...count {
            let envelope = BeakrNetEnvelope(
                networkID: networkID,
                sessionID: sessionID,
                sourceNodeID: source,
                destinationNodeID: destination,
                sequenceNumber: UInt64(sequenceNumber),
                payloadType: "ping",
                payload: Data("ping-\(sequenceNumber)".utf8)
            )
            try await transport.send(envelope)
        }
        print("[INFO] Sent \(count) envelopes to \(destination.rawValue.uuidString)")
    }

    private static func receive(
        count: Int,
        nodeID: NodeID,
        from transport: RelayTransport
    ) async throws {
        var receivedSequences: [UInt64] = []
        while receivedSequences.count < count {
            guard let envelope = await transport.receive() else {
                throw NodeCLIError.connectionCancelled
            }
            guard envelope.destinationNodeID == nodeID else { continue }
            receivedSequences.append(envelope.sequenceNumber)
            print("[INFO] Received sequence \(envelope.sequenceNumber)")
        }

        let expected = (1...count).map(UInt64.init)
        guard receivedSequences == expected else {
            throw NodeCLIError.unexpectedSequence(receivedSequences)
        }
        print("[INFO] Received \(count) envelopes in order")
    }

    private static func printUsage() {
        print("Usage:")
        print("  BeakrNetNodeCLI identity <identity-file>")
        print("  BeakrNetNodeCLI psk <psk-file>")
        print("  BeakrNetNodeCLI receive <identity-file> <count> <psk-file> <credential> [port]")
        print("  BeakrNetNodeCLI send <identity-file> <count> <peer-node-uuid> <psk-file> <credential> [port]")
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
    case connectionCancelled
    case unexpectedSequence([UInt64])
}
