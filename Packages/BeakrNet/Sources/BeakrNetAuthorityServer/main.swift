import Foundation

#if os(macOS)
import Network
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetOperations
import BeakrNetSecurity

@main
struct BeakrNetAuthorityServerMain {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let listenOnLAN = arguments.count == 10 && arguments[9] == "--lan"
        guard (arguments.count == 9 || listenOnLAN),
              let portValue = UInt16(arguments[0]),
              let port = NWEndpoint.Port(rawValue: portValue),
              let networkUUID = UUID(uuidString: arguments[4]),
              let password = ProcessInfo.processInfo.environment["BEAKRNET_AUTHORITY_TLS_PASSWORD"] else {
            print("Usage: BeakrNetAuthorityServer <port> <server.p12> <authority-private-key> <trust-ledger> <network-id> <environment> <openssl> <ca-cert-pem> <ca-key-pem> [--lan]")
            print("Set BEAKRNET_AUTHORITY_TLS_PASSWORD for the PKCS#12 identity.")
            return
        }
        let authority = try CredentialFiles.loadAuthority(
            privateKeyURL: URL(fileURLWithPath: arguments[2])
        )
        let networkID = NetworkID(rawValue: networkUUID)
        let environment = arguments[5]
        let trust = try await AuthorityTrustStateCoordinator.open(
            authority: authority,
            networkID: networkID,
            environment: environment,
            ledgerURL: URL(fileURLWithPath: arguments[3])
        )
        let enrollment = CertificateEnrollmentHTTPEndpoint(
            challenges: try .init(authorityID: authority.authorityID, environment: environment),
            enrollment: .init(
                validator: .init(
                    trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                    networkID: networkID,
                    environment: environment
                ),
                authority: authority,
                issuer: OpenSSLDevelopmentCertificateIssuer(
                    executableURL: URL(fileURLWithPath: arguments[6]),
                    authorityCertificateURL: URL(fileURLWithPath: arguments[7]),
                    authorityPrivateKeyURL: URL(fileURLWithPath: arguments[8])
                )
            ),
            membershipPublisher: trust
        )
        let profile = BeakrNetProductionProfile(
            environment: "production",
            enrollmentURL: URL(string: "https://authority.invalid/v1/certificate-enrollment")!,
            revocationURL: URL(string: "https://authority.invalid/v1/credential-revocations")!,
            keyCustody: .externalKMS(provider: "operator", keyIdentifier: "authority"),
            serviceAuthentication: .mutualTLS,
            perSourceLimit: .init(capacity: 30, refillPerSecond: 1),
            perIdentityLimit: .init(capacity: 60, refillPerSecond: 2),
            globalLimit: .init(capacity: 300, refillPerSecond: 10),
            maximumTrackedLimiters: 4_096,
            offlineRevocationGrace: 60,
            auditRetention: 30 * 24 * 60 * 60,
            maximumAuditEvents: 100_000,
            backup: .init(retentionCount: 7, maximumAge: 24 * 60 * 60, encryptionProvider: "operator")
        )
        let router = AuthorityControlPlaneRouter(
            enrollment: enrollment,
            membership: await trust.membershipEndpoint,
            revocations: await trust.revocationEndpoint,
            admission: try .init(
                profile: profile,
                operationLimit: .init(capacity: 120, refillPerSecond: 4)
            ),
            audit: .init(maximumEvents: 100_000, retention: 30 * 24 * 60 * 60)
        )
        let p12 = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let identity = try LANTLSIdentityLoader.importPKCS12(p12, password: password).identity
        let server = try AuthorityHTTPSServer(
            port: port,
            parameters: AuthorityServerTLSConfiguration.parameters(localIdentity: identity),
            router: router,
            listenOnLAN: listenOnLAN
        )
        try await server.run()
    }
}

private actor AuthorityHTTPSServer {
    private let listener: NWListener
    private let router: AuthorityControlPlaneRouter
    private let port: NWEndpoint.Port
    private let listenOnLAN: Bool

    init(port: NWEndpoint.Port, parameters: NWParameters, router: AuthorityControlPlaneRouter, listenOnLAN: Bool) throws {
        self.port = port
        self.router = router
        self.listenOnLAN = listenOnLAN
        if listenOnLAN {
            listener = try NWListener(using: parameters, on: port)
        } else {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            listener = try NWListener(using: parameters)
        }
    }

    func run() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection) }
        }
        listener.start(queue: DispatchQueue(label: "BeakrNetAuthorityServer.listener"))
        print("BeakrNet authority listening on \(listenOnLAN ? "all local interfaces" : "127.0.0.1"):\(port.rawValue)")
        try await withTaskCancellationHandler {
            while !Task.isCancelled { try await Task.sleep(for: .seconds(3_600)) }
        } onCancel: { listener.cancel() }
    }

    private func handle(_ connection: NWConnection) async {
        connection.start(queue: DispatchQueue(label: "BeakrNetAuthorityServer.connection"))
        do {
            var data = Data()
            while true {
                let chunk = try await receive(connection)
                data.append(chunk)
                guard data.count <= 278_532 else { throw AuthorityHTTP1CodecError.bodyTooLarge }
                do {
                    let request = try AuthorityHTTP1Codec.decodeRequest(data)
                    let response = await router.handle(
                        request,
                        source: String(describing: connection.endpoint)
                    )
                    try await send(AuthorityHTTP1Codec.encodeResponse(response), over: connection)
                    connection.cancel()
                    return
                } catch AuthorityHTTP1CodecError.incomplete {
                    continue
                }
            }
        } catch {
            try? await send(AuthorityHTTP1Codec.encodeResponse(.init(
                statusCode: 400,
                headers: ["cache-control": "no-store"]
            )), over: connection)
            connection.cancel()
        }
    }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(throwing: AuthorityServerError.connectionClosed) }
                else { continuation.resume(throwing: AuthorityServerError.emptyRead) }
            }
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            })
        }
    }
}

private enum AuthorityServerError: Error { case connectionClosed, emptyRead }
#else
@main
struct BeakrNetAuthorityServerMain {
    static func main() { print("BeakrNetAuthorityServer requires macOS") }
}
#endif
