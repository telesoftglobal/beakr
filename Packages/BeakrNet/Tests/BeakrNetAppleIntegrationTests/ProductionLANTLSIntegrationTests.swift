#if os(macOS)
import CryptoKit
import Foundation
import Network
import Security
import Testing
import BeakrNetSecurity
import BeakrNetCore
import BeakrNetData
import BeakrNetAuthority

@Suite("Production LAN TLS certificate admission",
       .enabled(if: ProcessInfo.processInfo.environment["BEAKRNET_RUN_PRODUCTION_TLS_INTEGRATION"] == "1"),
       .serialized)
struct ProductionLANTLSIntegrationTests {
    @Test("TLS 1.3 mutual authentication accepts trusted identities and rejects invalid chains",
          .timeLimit(.minutes(2)))
    func certificateAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("beakr-mtls-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = CertificateFixture(root: root)
        try fixture.createCA("trusted")
        try fixture.createCA("other")
        let anchor = try fixture.certificate("trusted")
        let otherAnchor = try fixture.certificate("other")
        let valid = try fixture.identity("valid", ca: "trusted")
        let untrusted = try fixture.identity("untrusted", ca: "other")
        let expired = try fixture.identity("expired", ca: "trusted", expired: true)
        // The foreign certificate must work under its own CA: rejection below must
        // not be explained by a malformed identity or an unusable private key.
        try await connect(client: untrusted, server: untrusted, anchor: otherAnchor, rejectingSide: nil)
        try verifyExpiredFixture(expired, anchor: anchor)
        // Valid controls bracket the failures so broken fixture connectivity cannot pass.
        try await connect(client: valid, server: valid, anchor: anchor, rejectingSide: nil)
        try await connect(client: untrusted, server: valid, anchor: anchor, rejectingSide: .server)
        try await connect(client: valid, server: untrusted, anchor: anchor, rejectingSide: .client)
        try await connect(client: expired, server: valid, anchor: anchor, rejectingSide: .server)
        try await connect(client: valid, server: expired, anchor: anchor, rejectingSide: .client)
        try await connect(client: valid, server: valid, anchor: anchor, rejectingSide: nil)
    }

    @Test("Production mutual TLS and Beakr admission persist one message and reject a revoked credential",
          .timeLimit(.minutes(2)))
    func combinedCredentialAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("beakr-combined-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = CertificateFixture(root: root)
        try fixture.createCA("combined")
        let anchor = try fixture.certificate("combined")
        let clientNode = NodeIdentity()
        let serverNode = NodeIdentity()
        let clientTLS = try fixture.identity("client", ca: "combined", node: clientNode)
        let serverTLS = try fixture.identity("server", ca: "combined", node: serverNode)
        let clientCertificate = try fixture.certificate("client")
        let serverCertificate = try fixture.certificate("server")
        let authority = CredentialAuthority()
        let network = NetworkID()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let clientCredential = try authority.issue(nodeID: clientNode.nodeID,
            nodePublicKey: clientNode.publicKeyRepresentation, networkID: network,
            environment: "combined-test", validity: 3_600, serviceScopes: ["lan"], now: now)
        let serverCredential = try authority.issue(nodeID: serverNode.nodeID,
            nodePublicKey: serverNode.publicKeyRepresentation, networkID: network,
            environment: "combined-test", validity: 3_600, serviceScopes: ["lan"], now: now)
        let message = DataMessage(kind: .message,
            operation: .init(namespace: "beakr", name: "text-message", version: 1),
            correlationID: DataCorrelationID(), idempotencyKey: DataIdempotencyKey(),
            body: Data("single accepted message".utf8))
        let blockedMessage = DataMessage(kind: .message, operation: message.operation,
            correlationID: DataCorrelationID(), idempotencyKey: DataIdempotencyKey(),
            body: Data("revoked peer must not persist this".utf8))
        let envelope = BeakrNetEnvelope(networkID: network, sessionID: SessionID(),
            sourceNodeID: clientNode.nodeID, destinationNodeID: serverNode.nodeID, sequenceNumber: 1,
            deliveryPolicy: .init(durability: .durable, expiresAt: now.addingTimeInterval(60)),
            payloadType: DataMessage.payloadType, payload: try DataCodec().encode(message), createdAt: now)
        let blockedEnvelope = BeakrNetEnvelope(networkID: network, sessionID: envelope.sessionID,
            sourceNodeID: clientNode.nodeID, destinationNodeID: serverNode.nodeID, sequenceNumber: 2,
            deliveryPolicy: envelope.deliveryPolicy, payloadType: DataMessage.payloadType,
            payload: try DataCodec().encode(blockedMessage), createdAt: now)
        #expect(blockedEnvelope.messageID != envelope.messageID)
        let incomingURL = root.appendingPathComponent("incoming.json")
        let incomingState = try await PersistentDataState.open(fileURL: incomingURL, now: now)
        let expectedRecord = StoredDataResult(messageID: envelope.messageID,
            idempotencyKey: message.idempotencyKey, response: message, completedAt: now)
        let receiver = BeakrNetSession(id: envelope.sessionID, networkID: network,
            localNodeID: serverNode.nodeID, remoteNodeID: clientNode.nodeID, state: .active, now: now)
        let routes = PeerRouteCoordinator(networkID: network, remoteNodeID: clientNode.nodeID)
        let driver = SessionDeliveryDriver(session: receiver, coordinator: routes, clock: { now })
        let nonce = Data(repeating: 0x37, count: 32)
        for revoked in [false, true] {
            let attemptedEnvelope = revoked ? blockedEnvelope : envelope
            let beforeAttempt = try? Data(contentsOf: incomingURL)
            let snapshot = try authority.issueRevocationSnapshot(revocations: revoked ? [CredentialRevocation(
                credentialID: clientCredential.claims.credentialID,
                revokedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000), reason: "Disposable combined test"
            )] : [], now: now)
            func configuration(_ node: NodeIdentity, _ credential: NodeCredential,
                               _ certificate: SecCertificate) -> LANTransportConfiguration {
                LANTransportConfiguration(identity: node, credential: credential,
                    trustedAuthorityPublicKey: authority.publicKeyRepresentation, networkID: network,
                    environment: "combined-test", revocationSnapshot: snapshot,
                    localCertificateDER: SecCertificateCopyData(certificate) as Data,
                    localCertificatePublicKey: node.publicKeyRepresentation,
                    capabilities: .init(maximumEnvelopeBytes: 512_000, preservesOrder: true,
                        supportsImmediateDelivery: true, supportsQueuedDelivery: true, supportsBackgroundDelivery: false),
                    now: { now })
            }
            let clientConfig = configuration(clientNode, clientCredential, clientCertificate)
            let serverConfig = configuration(serverNode, serverCredential, serverCertificate)
            try await connect(client: clientTLS, server: serverTLS, anchor: anchor, rejectingSide: nil) { client, server in
                // Both sockets have completed production mTLS before Beakr begins.
                let outgoing = NetworkBonjourConnection(connection: client)
                let incoming = NetworkBonjourConnection(connection: server)
                let peer = try incoming.peerCertificate()
                #expect(peer.derRepresentation == SecCertificateCopyData(clientCertificate) as Data)
                #expect(peer.publicKeyRepresentation == clientNode.publicKeyRepresentation)
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    client.cancel(); server.cancel()
                }
                defer { deadline.cancel() }
                let sender = Task<LANTransport?, Never> {
                    do {
                        let transport = try await LANTransport.authenticate(connection: outgoing, role: .initiator,
                            expectedPeerNodeID: serverNode.nodeID, advertisementNonce: nonce, configuration: clientConfig)
                        // Attempt payload delivery even when the receiver will reject this credential.
                        try await transport.send(attemptedEnvelope)
                        if !revoked { try await transport.send(envelope) }
                        return transport
                    } catch {
                        if !revoked { Issue.record("Valid sender failed: \(error)") }
                        return nil as LANTransport?
                    }
                }
                do {
                    let transport = try await LANTransport.authenticate(connection: incoming, role: .acceptor,
                        expectedPeerNodeID: clientNode.nodeID, advertisementNonce: nonce, configuration: serverConfig)
                    if revoked { Issue.record("Revoked Beakr credential admitted over valid mTLS") }
                    else {
                        let generation = await routes.beginCandidate(transportID: transport.id, kind: .local,
                                                                    capabilities: transport.capabilities)
                        #expect(await routes.candidateAuthenticated(transportID: transport.id, generation: generation))
                        #expect(await routes.candidateReady(transportID: transport.id, generation: generation))
                        await driver.register(transport, generation: generation)
                        for index in 0..<2 {
                            let received = try #require(await transport.receive())
                            #expect(received == envelope)
                            let result = try #require(try await driver.receive(received, receivedOn: transport.id,
                                                                             generation: generation))
                            #expect(result.acceptance == (index == 0 ? .accepted : .duplicate))
                            if result.acceptance == .accepted {
                                // Fixture bridge to the production mailbox storage primitive;
                                // the app's ApplicationMessageInbox is not linked in this package test.
                                let decoded = try DataCodec().decode(envelope: received)
                                try await incomingState.record(StoredDataResult(messageID: received.messageID,
                                    idempotencyKey: decoded.idempotencyKey, response: decoded, completedAt: now))
                            }
                        }
                        await driver.unregister(transportID: transport.id, generation: generation)
                        _ = await routes.removeCandidate(transportID: transport.id, generation: generation, reason: .connectionFailed)
                    }
                    await transport.close()
                } catch {
                    #expect(revoked)
                    #expect(error as? LANHandshakeError == .revokedCredential)
                }
                if let transport = await sender.value { await transport.close() }
                print("Combined production mTLS/Beakr: revoked=\(revoked), both TLS endpoints ready")
            }
            #expect(await incomingState.recordedResults() == [expectedRecord])
            let reopened = try await PersistentDataState.open(fileURL: incomingURL, now: now)
            #expect(await reopened.recordedResults() == [expectedRecord])
            #expect(await reopened.result(for: blockedEnvelope.messageID) == nil)
            if revoked {
                // Rejection must not change the file, including hidden extra records.
                #expect(try Data(contentsOf: incomingURL) == beforeAttempt)
            }
            print("Combined persistence: revoked=\(revoked), reopened store contains only the original message")
            let history = await receiver.diagnosticHistory
            #expect(history.filter { if case .envelopeAccepted = $0 { true } else { false } }.count == 1)
            #expect(history.filter { if case .duplicateRejected = $0 { true } else { false } }.count == 1)
        }
    }

    private func verifyExpiredFixture(_ identity: SecIdentity, anchor: SecCertificate) throws {
        var certificate: SecCertificate?
        try #require(SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess)
        let leaf = try #require(certificate)
        var trust: SecTrust?
        try #require(SecTrustCreateWithCertificates(leaf, SecPolicyCreateSSL(true, nil), &trust) == errSecSuccess)
        let evaluatedTrust = try #require(trust)
        try #require(SecTrustSetAnchorCertificates(evaluatedTrust, [anchor] as CFArray) == errSecSuccess)
        try #require(SecTrustSetAnchorCertificatesOnly(evaluatedTrust, true) == errSecSuccess)
        var error: CFError?
        #expect(!SecTrustEvaluateWithError(evaluatedTrust, &error))
        let failure = try #require(error)
        #expect(CFErrorGetCode(failure) == errSecCertificateExpired)
    }

    enum Side: Sendable { case client, server }
    private enum Event: @unchecked Sendable {
        case listening(NWEndpoint.Port)
        case ready(Side)
        case failed(Side, NWError)
        case accepted(NWConnection)
        case payload(Data)
        case timeout
        case listenerFailed
    }

    func connect(client: SecIdentity, server: SecIdentity, anchor: SecCertificate,
                         rejectingSide: Side?,
                         onReady: ((NWConnection, NWConnection) async throws -> Void)? = nil) async throws {
        let (events, continuation) = AsyncStream<Event>.makeStream()
        let queue = DispatchQueue(label: "BeakrNet.Tests.ProductionTLS")
        let serverParameters = try LANTLSConfiguration.parameters(
            localIdentity: server, role: .acceptor, trustPolicy: .production(authorityCertificates: [anchor]))
        serverParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: serverParameters)
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port { continuation.yield(.listening(port)) }
            if case .failed = state { continuation.yield(.listenerFailed) }
        }
        listener.newConnectionHandler = { continuation.yield(.accepted($0)) }
        listener.start(queue: queue)
        var outbound: NWConnection?
        var inbound: NWConnection?
        let timer = Task {
            do { try await Task.sleep(for: .seconds(8)) }
            catch { return }
            continuation.yield(.timeout)
        }
        defer {
            timer.cancel()
            outbound?.cancel()
            inbound?.cancel()
            listener.cancel()
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            continuation.finish()
        }
        var clientReady = false
        var serverReady = false
        let marker = Data("production-tls-admitted".utf8)
        for await event in events {
            switch event {
            case .listening(let port):
                let parameters = try LANTLSConfiguration.parameters(
                    localIdentity: client, role: .initiator,
                    trustPolicy: .production(authorityCertificates: [anchor]))
                let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
                outbound = connection
                connection.stateUpdateHandler = { state in
                    if case .ready = state { continuation.yield(.ready(.client)) }
                    if case .failed(let error) = state { continuation.yield(.failed(.client, error)) }
                    if case .waiting(let error) = state { continuation.yield(.failed(.client, error)) }
                }
                connection.start(queue: queue)
            case .accepted(let connection):
                inbound = connection
                connection.stateUpdateHandler = { state in
                    if case .ready = state { continuation.yield(.ready(.server)) }
                    if case .failed(let error) = state { continuation.yield(.failed(.server, error)) }
                    if case .waiting(let error) = state { continuation.yield(.failed(.server, error)) }
                }
                connection.start(queue: queue)
            case .ready(let side):
                if side == .client { clientReady = true } else { serverReady = true }
                #expect(side != rejectingSide, "The verifying endpoint must not become ready for an invalid certificate")
                if clientReady && serverReady {
                    try #require(rejectingSide == nil)
                    if let onReady {
                        try await onReady(try #require(outbound), try #require(inbound))
                        return
                    }
                    inbound?.receive(minimumIncompleteLength: marker.count, maximumLength: marker.count) { data, _, _, _ in
                        continuation.yield(.payload(data ?? Data()))
                    }
                    outbound?.send(content: marker, completion: .contentProcessed { error in
                        if let error { continuation.yield(.failed(.client, error)) }
                    })
                }
            case .failed(let side, let error):
                guard let rejectingSide else {
                    Issue.record("Valid TLS control failed: \(error)")
                    return
                }
                // A remote alert alone is insufficient: require failure at the verifier.
                if side == rejectingSide {
                    if case .tls = error {} else { Issue.record("Expected TLS verification failure, got \(error)") }
                    #expect(side == .client ? !clientReady : !serverReady)
                    print("Production TLS rejected certificate at \(side): \(error)")
                    return
                }
            case .payload(let data):
                #expect(rejectingSide == nil)
                #expect(data == marker)
                print("Production TLS trusted control: both endpoints ready, marker received")
                return
            case .timeout, .listenerFailed:
                Issue.record("Production TLS fixture timed out or listener failed")
                return
            }
        }
    }
}

struct CertificateFixture {
    let root: URL
    private func path(_ name: String) -> String { root.appendingPathComponent(name).path }

    func createCA(_ name: String) throws {
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "2",
                 "-subj", "/CN=Beakr Disposable \(name) \(UUID())", "-addext", "basicConstraints=critical,CA:TRUE",
                 "-keyout", path("\(name).key"), "-out", path("\(name).pem")])
    }

    func certificate(_ name: String) throws -> SecCertificate {
        try run(["x509", "-in", path("\(name).pem"), "-outform", "DER", "-out", path("\(name).der")])
        return try #require(SecCertificateCreateWithData(nil, try Data(contentsOf: URL(fileURLWithPath: path("\(name).der"))) as CFData))
    }

    func identity(_ name: String, ca: String, expired: Bool = false, node: NodeIdentity? = nil, dnsName: String? = nil) throws -> SecIdentity {
        if let node {
            let key = try P256.Signing.PrivateKey(rawRepresentation: node.privateKeyRepresentation)
            try Data(key.pemRepresentation.utf8).write(to: URL(fileURLWithPath: path("\(name).key")))
            try run(["req", "-new", "-key", path("\(name).key"), "-subj", "/CN=\(name)",
                     "-out", path("\(name).csr")])
        } else {
            try run(["req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=\(name)",
                     "-keyout", path("\(name).key"), "-out", path("\(name).csr")])
        }
        try Data(("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\n" + (dnsName.map { "subjectAltName=DNS:\($0)\n" } ?? "")).utf8)
            .write(to: URL(fileURLWithPath: path("\(name).ext")))
        try run(["x509", "-req", "-in", path("\(name).csr"), "-CA", path("\(ca).pem"),
                 "-CAkey", path("\(ca).key"), "-CAcreateserial", "-sha256",
                 "-extfile", path("\(name).ext"), "-out", path("\(name).pem")]
                 + (expired ? ["-not_before", "20200101000000Z", "-not_after", "20200102000000Z"] : ["-days", "2"]))
        let password = UUID().uuidString
        try run(["pkcs12", "-export", "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
                 "-inkey", path("\(name).key"), "-in", path("\(name).pem"), "-certfile", path("\(ca).pem"),
                 "-passout", "pass:\(password)", "-out", path("\(name).p12")])
        var imported: CFArray?
        let data = try Data(contentsOf: URL(fileURLWithPath: path("\(name).p12")))
        // Test identities never enter the user's persistent keychain.
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase: password,
                                                     kSecImportToMemoryOnly: true] as CFDictionary, &imported)
        try #require(status == errSecSuccess, "Memory-only identity import failed: \(status)")
        let items = try #require(imported as? [[String: Any]])
        let value = try #require(items.first?[kSecImportItemIdentity as String])
        try #require(CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID())
        return unsafeDowncast(value as AnyObject, to: SecIdentity.self)
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BEAKRNET_OPENSSL_PATH"] ?? "/opt/homebrew/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let reason = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try #require(process.terminationStatus == 0, "Disposable certificate generation failed: \(reason)")
    }
}
#endif
