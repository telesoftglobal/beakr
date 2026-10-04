import Foundation
import Network
import Security
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

@Suite(
    "Signed LAN mutual TLS integration",
    .enabled(if: ProcessInfo.processInfo.environment["BEAKRNET_RUN_SIGNED_MTLS_INTEGRATION"] == "1"),
    .serialized
)
struct BeakrNetDemoIntegrationTests {
    @Test("Two provisioned node identities establish mutual TLS 1.3")
    func mutualTLSLoopback() async throws {
        let fixtures = try TLSFixtures.load()
        let listener = try NWListener(using: LANTLSConfiguration.parameters(
            localIdentity: fixtures.serverIdentity,
            role: .acceptor,
            trustPolicy: .production(authorityCertificates: [fixtures.authority])
        ))
        let listenerStates = StateEvents<NWListener.State>()
        listener.stateUpdateHandler = { listenerStates.record($0) }
        let acceptedConnections = ConnectionEvents()
        listener.newConnectionHandler = { acceptedConnections.record($0) }
        listener.start(queue: DispatchQueue(label: "BeakrNet.SignedMTLS.Listener"))
        defer { listener.cancel() }

        let ready = try await listenerStates.next(
            where: { if case .ready = $0 { true } else { false } },
            timeout: .seconds(10)
        )
        guard case .ready = ready, let port = listener.port else {
            throw SignedIntegrationError.listenerNotReady
        }

        let client = NWConnection(
            host: .ipv4(.loopback),
            port: port,
            using: try LANTLSConfiguration.parameters(
                localIdentity: fixtures.clientIdentity,
                role: .initiator,
                trustPolicy: .production(authorityCertificates: [fixtures.authority])
            )
        )
        let clientStates = StateEvents<NWConnection.State>()
        client.stateUpdateHandler = { clientStates.record($0) }
        client.start(queue: DispatchQueue(label: "BeakrNet.SignedMTLS.Client"))
        defer { client.cancel() }

        let server = try await acceptedConnections.next(timeout: .seconds(10))
        let serverStates = StateEvents<NWConnection.State>()
        server.stateUpdateHandler = { serverStates.record($0) }
        server.start(queue: DispatchQueue(label: "BeakrNet.SignedMTLS.Server"))
        defer { server.cancel() }

        _ = try await clientStates.next(
            where: { if case .ready = $0 { true } else { false } },
            timeout: .seconds(10)
        )
        _ = try await serverStates.next(
            where: { if case .ready = $0 { true } else { false } },
            timeout: .seconds(10)
        )

        let message = Data("signed-mutual-tls".utf8)
        try await client.sendData(message)
        #expect(try await server.receiveData(maximumLength: 1024) == message)
        #expect(try client.peerLeafCertificate() != nil)
        #expect(try server.peerLeafCertificate() != nil)
    }

    @Test("A peer anchored to the wrong authority is rejected")
    func wrongAuthority() async throws {
        let fixtures = try TLSFixtures.load()
        let clientParameters = try LANTLSConfiguration.parameters(
            localIdentity: fixtures.clientIdentity,
            role: .initiator,
            trustPolicy: .production(authorityCertificates: [fixtures.wrongAuthority])
        )
        let serverParameters = try LANTLSConfiguration.parameters(
            localIdentity: fixtures.serverIdentity,
            role: .acceptor,
            trustPolicy: .production(authorityCertificates: [fixtures.authority])
        )
        #expect(try await TLSFailureProbe.fails(
            clientParameters: clientParameters,
            serverParameters: serverParameters
        ))
    }

    @Test("An expired peer certificate is rejected")
    func expiredCertificate() async throws {
        let fixtures = try TLSFixtures.load()
        let clientParameters = try LANTLSConfiguration.parameters(
            localIdentity: fixtures.clientIdentity,
            role: .initiator,
            trustPolicy: .production(authorityCertificates: [fixtures.authority])
        )
        let serverParameters = try LANTLSConfiguration.parameters(
            localIdentity: fixtures.expiredServerIdentity,
            role: .acceptor,
            trustPolicy: .production(authorityCertificates: [fixtures.authority])
        )
        #expect(try await TLSFailureProbe.fails(
            clientParameters: clientParameters,
            serverParameters: serverParameters
        ))
    }

    @Test("A server requiring mutual TLS rejects a client without an identity")
    func missingClientIdentity() async throws {
        let fixtures = try TLSFixtures.load()
        let serverParameters = try LANTLSConfiguration.parameters(
            localIdentity: fixtures.serverIdentity,
            role: .acceptor,
            trustPolicy: .production(authorityCertificates: [fixtures.authority])
        )
        #expect(try await TLSFailureProbe.fails(
            clientParameters: TLSFailureProbe.uncredentialedParameters(),
            serverParameters: serverParameters
        ))
    }

    @Test("Keychain certificate installation keeps the previous identity on rejected replacement")
    func keychainIdentityReplacement() throws {
        let fixtures = try TLSFixtures.load()
        let clientNodeIdentity = try nodeIdentity(from: fixtures.clientIdentity)
        let serverNodeIdentity = try nodeIdentity(from: fixtures.serverIdentity)
        let clientLeaf = try certificate(from: fixtures.clientIdentity)
        let serverLeaf = try certificate(from: fixtures.serverIdentity)
        let authorityDER = SecCertificateCopyData(fixtures.authority) as Data
        let store = KeychainLANTLSIdentityStore(
            service: "org.beakrnet.tests.lan-tls.\(UUID().uuidString)"
        )
        defer { try? store.delete() }

        _ = try store.install(
            leafCertificateDER: clientLeaf,
            certificateChainDER: [authorityDER],
            nodeIdentity: clientNodeIdentity
        )
        #expect(throws: KeychainLANTLSIdentityStoreError.privateKeyMismatch) {
            try store.install(
                leafCertificateDER: serverLeaf,
                certificateChainDER: [authorityDER],
                nodeIdentity: serverNodeIdentity
            )
        }
        let loaded = try #require(try store.load())
        #expect(SecCertificateCopyData(loaded.leafCertificate) as Data == clientLeaf)
        #expect(loaded.certificateChain.count == 1)
    }

    @Test("Enrollment survives restart and renewal replaces the active schedule")
    func enrollmentRestartAndRenewal() async throws {
        let fixtures = try TLSFixtures.load()
        let nodeIdentity = try nodeIdentity(from: fixtures.clientIdentity)
        let leafDER = try certificate(from: fixtures.clientIdentity)
        let chainDER = [SecCertificateCopyData(fixtures.authority) as Data]
        let authority = CredentialAuthority()
        let now = Date()
        let credential = try authority.issue(
            nodeID: nodeIdentity.nodeID,
            nodePublicKey: nodeIdentity.publicKeyRepresentation,
            environment: "integration",
            validity: 86_400,
            serviceScopes: ["lan"],
            now: now
        )
        let initialRequest = try enrollmentRequest(
            identity: nodeIdentity,
            credential: credential,
            authorityID: authority.authorityID,
            now: now
        )
        let initialResponse = try authority.issueCertificateEnrollmentResponse(
            for: ValidatedCertificateEnrollment(
                requestID: initialRequest.requestID,
                nodeID: nodeIdentity.nodeID,
                nodePublicKey: nodeIdentity.publicKeyRepresentation,
                validity: 3_600
            ),
            leafCertificateDER: leafDER,
            certificateChainDER: chainDER,
            now: now
        )
        try CertificateEnrollmentResponseVerifier.verify(
            initialResponse,
            for: initialRequest,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation
        )

        let service = "org.beakrnet.tests.lifecycle.\(UUID().uuidString)"
        let initialStore = KeychainLANTLSIdentityStore(service: service)
        defer { try? initialStore.delete() }
        try initialStore.install(response: initialResponse, nodeIdentity: nodeIdentity)

        // A fresh store value models a new app process restoring the active pointer.
        let restartedStore = KeychainLANTLSIdentityStore(service: service)
        let restored = try #require(try restartedStore.load())
        #expect(SecCertificateCopyData(restored.leafCertificate) as Data == leafDER)

        let renewalDate = now.addingTimeInterval(1_800)
        let renewalRequest = try enrollmentRequest(
            identity: nodeIdentity,
            credential: credential,
            authorityID: authority.authorityID,
            now: renewalDate
        )
        let renewalResponse = try authority.issueCertificateEnrollmentResponse(
            for: ValidatedCertificateEnrollment(
                requestID: renewalRequest.requestID,
                nodeID: nodeIdentity.nodeID,
                nodePublicKey: nodeIdentity.publicKeyRepresentation,
                validity: 7_200
            ),
            leafCertificateDER: leafDER,
            certificateChainDER: chainDER,
            now: renewalDate
        )
        let requester = IntegrationRenewalRequester(exchange: CertificateRenewalExchange(
            request: renewalRequest,
            response: renewalResponse
        ))
        let scheduler = CertificateRenewalScheduler(
            currentResponse: initialResponse,
            nodeIdentity: nodeIdentity,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            requester: requester,
            installer: restartedStore,
            policy: try CertificateRenewalPolicy()
        )

        let expectedExpiry = Date(
            timeIntervalSince1970: TimeInterval(renewalResponse.expiresAtMilliseconds) / 1_000
        )
        #expect(await scheduler.attemptRenewal(now: renewalDate) == .installed(
            expiresAt: expectedExpiry
        ))
        #expect(await scheduler.activeResponse() == renewalResponse)
        #expect(try restartedStore.load() != nil)
    }

    private func enrollmentRequest(
        identity: NodeIdentity,
        credential: NodeCredential,
        authorityID: AuthorityID,
        now: Date
    ) throws -> CertificateEnrollmentRequest {
        let milliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        return try CertificateEnrollmentRequest.signed(
            identity: identity,
            credential: credential,
            environment: "integration",
            challenge: CertificateEnrollmentChallenge(
                authorityID: authorityID,
                environment: "integration",
                nonce: Data(repeating: 0x42, count: 32),
                issuedAtMilliseconds: milliseconds,
                expiresAtMilliseconds: milliseconds + 300_000
            ),
            requestedValidity: 7_200
        )
    }

    private func certificate(from identity: SecIdentity) throws -> Data {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else {
            throw SignedIntegrationError.invalidIdentity
        }
        return SecCertificateCopyData(certificate) as Data
    }

    private func nodeIdentity(from identity: SecIdentity) throws -> NodeIdentity {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key else {
            throw SignedIntegrationError.invalidIdentity
        }
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(key, &error) as Data?,
              representation.count == 97 else {
            throw SignedIntegrationError.invalidIdentity
        }
        return try NodeIdentity(privateKeyRepresentation: representation.suffix(32))
    }
}

private actor IntegrationRenewalRequester: CertificateRenewalRequesting {
    let exchange: CertificateRenewalExchange

    init(exchange: CertificateRenewalExchange) {
        self.exchange = exchange
    }

    func renewCertificate() async throws -> CertificateRenewalExchange {
        exchange
    }
}

private struct TLSFixtures {
    let clientIdentity: SecIdentity
    let serverIdentity: SecIdentity
    let expiredServerIdentity: SecIdentity
    let authority: SecCertificate
    let wrongAuthority: SecCertificate

    static func load() throws -> TLSFixtures {
        let environment = ProcessInfo.processInfo.environment
        let password = try required("BEAKRNET_TEST_PKCS12_PASSWORD", in: environment)
        let clientData = try fixtureData(
            base64Name: "BEAKRNET_TEST_CLIENT_PKCS12_BASE64",
            pathName: "BEAKRNET_TEST_CLIENT_PKCS12",
            environment: environment
        )
        let serverData = try fixtureData(
            base64Name: "BEAKRNET_TEST_SERVER_PKCS12_BASE64",
            pathName: "BEAKRNET_TEST_SERVER_PKCS12",
            environment: environment
        )
        let expiredServerData = try fixtureData(
            base64Name: "BEAKRNET_TEST_EXPIRED_SERVER_PKCS12_BASE64",
            pathName: "BEAKRNET_TEST_EXPIRED_SERVER_PKCS12",
            environment: environment
        )
        let authorityData = try fixtureData(
            base64Name: "BEAKRNET_TEST_AUTHORITY_DER_BASE64",
            pathName: "BEAKRNET_TEST_AUTHORITY_DER",
            environment: environment
        )
        let wrongAuthorityData = try fixtureData(
            base64Name: "BEAKRNET_TEST_WRONG_AUTHORITY_DER_BASE64",
            pathName: "BEAKRNET_TEST_WRONG_AUTHORITY_DER",
            environment: environment
        )
        let client = try LANTLSIdentityLoader.importPKCS12(clientData, password: password)
        let server = try LANTLSIdentityLoader.importPKCS12(serverData, password: password)
        let expiredServer = try LANTLSIdentityLoader.importPKCS12(
            expiredServerData,
            password: password
        )
        guard let authority = SecCertificateCreateWithData(nil, authorityData as CFData) else {
            throw SignedIntegrationError.invalidAuthorityCertificate
        }
        guard let wrongAuthority = SecCertificateCreateWithData(
            nil,
            wrongAuthorityData as CFData
        ) else {
            throw SignedIntegrationError.invalidAuthorityCertificate
        }
        return TLSFixtures(
            clientIdentity: client.identity,
            serverIdentity: server.identity,
            expiredServerIdentity: expiredServer.identity,
            authority: authority,
            wrongAuthority: wrongAuthority
        )
    }

    private static func fixtureData(
        base64Name: String,
        pathName: String,
        environment: [String: String]
    ) throws -> Data {
        if let encoded = environment[base64Name],
           let data = Data(base64Encoded: encoded) {
            return data
        }
        let path = try required(pathName, in: environment)
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private static func required(
        _ name: String,
        in environment: [String: String]
    ) throws -> String {
        guard let value = environment[name], !value.isEmpty else {
            throw SignedIntegrationError.missingEnvironmentVariable(name)
        }
        return value
    }
}

private enum TLSFailureProbe {
    static func uncredentialedParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv13
        )
        sec_protocol_options_set_max_tls_protocol_version(
            tls.securityProtocolOptions,
            .TLSv13
        )
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue(label: "BeakrNet.UncredentialedTLSVerification")
        )
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    static func fails(
        clientParameters: NWParameters,
        serverParameters: NWParameters
    ) async throws -> Bool {
        let listener = try NWListener(using: serverParameters)
        let listenerStates = StateEvents<NWListener.State>()
        listener.stateUpdateHandler = { listenerStates.record($0) }
        let acceptedConnections = ConnectionEvents()
        listener.newConnectionHandler = { acceptedConnections.record($0) }
        listener.start(queue: DispatchQueue(label: "BeakrNet.TLSFailure.Listener"))
        defer { listener.cancel() }

        _ = try await listenerStates.next(
            where: { if case .ready = $0 { true } else { false } },
            timeout: .seconds(10)
        )
        guard let port = listener.port else {
            throw SignedIntegrationError.listenerNotReady
        }

        let client = NWConnection(host: .ipv4(.loopback), port: port, using: clientParameters)
        let clientStates = StateEvents<NWConnection.State>()
        client.stateUpdateHandler = { clientStates.record($0) }
        client.start(queue: DispatchQueue(label: "BeakrNet.TLSFailure.Client"))
        defer { client.cancel() }

        let server = try await acceptedConnections.next(timeout: .seconds(10))
        let serverStates = StateEvents<NWConnection.State>()
        server.stateUpdateHandler = { serverStates.record($0) }
        server.start(queue: DispatchQueue(label: "BeakrNet.TLSFailure.Server"))
        defer { server.cancel() }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await clientStates.reachesTerminalFailure() }
            group.addTask { await serverStates.reachesTerminalFailure() }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

private final class StateEvents<State: Sendable>: @unchecked Sendable {
    private let stream: AsyncStream<State>
    private let continuation: AsyncStream<State>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func record(_ state: State) {
        continuation.yield(state)
    }

    func reachesTerminalFailure() async -> Bool {
        for await state in stream {
            guard let connectionState = state as? NWConnection.State else { continue }
            switch connectionState {
            case .failed:
                return true
            case .ready:
                // TLS 1.3 can report a provisional ready state before the peer
                // finishes rejecting a missing client certificate.
                continue
            default:
                continue
            }
        }
        return false
    }

    func next(
        where predicate: @escaping @Sendable (State) -> Bool,
        timeout: Duration
    ) async throws -> State {
        try await withThrowingTaskGroup(of: State.self) { group in
            group.addTask { [stream] in
                for await state in stream {
                    if case .failed(let error) = state as? NWConnection.State {
                        throw error
                    }
                    if predicate(state) { return state }
                }
                throw SignedIntegrationError.eventStreamEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SignedIntegrationError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private final class ConnectionEvents: @unchecked Sendable {
    private let stream: AsyncStream<NWConnection>
    private let continuation: AsyncStream<NWConnection>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func record(_ connection: NWConnection) {
        continuation.yield(connection)
    }

    func next(timeout: Duration) async throws -> NWConnection {
        try await withThrowingTaskGroup(of: NWConnection.self) { group in
            group.addTask { [stream] in
                for await connection in stream { return connection }
                throw SignedIntegrationError.eventStreamEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SignedIntegrationError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private extension NWConnection {
    func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func receiveData(maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, any Error>) in
            receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
                data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: SignedIntegrationError.emptyReceive) }
            }
        }
    }

    func peerLeafCertificate() throws -> SecCertificate? {
        guard let metadata = metadata(definition: NWProtocolTLS.definition)
            as? NWProtocolTLS.Metadata else {
            return nil
        }
        var leaf: SecCertificate?
        _ = sec_protocol_metadata_access_peer_certificate_chain(
            metadata.securityProtocolMetadata
        ) { certificate in
            if leaf == nil {
                leaf = sec_certificate_copy_ref(certificate).takeRetainedValue()
            }
        }
        return leaf
    }
}

private enum SignedIntegrationError: Error {
    case emptyReceive
    case eventStreamEnded
    case invalidAuthorityCertificate
    case invalidIdentity
    case listenerNotReady
    case missingEnvironmentVariable(String)
    case timedOut
}
