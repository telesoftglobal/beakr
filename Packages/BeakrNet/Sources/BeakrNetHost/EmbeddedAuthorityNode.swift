#if os(macOS)
import Foundation
import Network
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetOperations
import BeakrNetSecurity

public actor EmbeddedAuthorityNode {
    private let bundleURL: URL
    private let openSSLExecutableURL: URL
    private let port: NWEndpoint.Port
    private let listenOnLAN: Bool
    private let authorityPrivateKeyRepresentation: Data
    private let certificateAuthorityPrivateKeyPEM: Data
    private var server: EmbeddedAuthorityHTTPSServer?
    private var trust: AuthorityTrustStateCoordinator?
    private var runtimeSecretsURL: URL?

    public init(
        bundleURL: URL,
        openSSLExecutableURL: URL,
        port: UInt16,
        listenOnLAN: Bool = true,
        authorityPrivateKeyRepresentation: Data,
        certificateAuthorityPrivateKeyPEM: Data
    ) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw EmbeddedAuthorityNodeError.invalidPort
        }
        self.bundleURL = bundleURL
        self.openSSLExecutableURL = openSSLExecutableURL
        self.port = port
        self.listenOnLAN = listenOnLAN
        self.authorityPrivateKeyRepresentation = authorityPrivateKeyRepresentation
        self.certificateAuthorityPrivateKeyPEM = certificateAuthorityPrivateKeyPEM
    }

    public func start(pkcs12Password: String) async throws {
        guard server == nil else { throw EmbeddedAuthorityNodeError.alreadyRunning }
        guard !pkcs12Password.isEmpty else { throw EmbeddedAuthorityNodeError.missingPassword }
        let manifest = try NetworkBootstrap.loadManifest(from: bundleURL)
        let authority = try CredentialAuthority(
            privateKeyRepresentation: authorityPrivateKeyRepresentation
        )
        guard authority.authorityID == manifest.authorityID else {
            throw EmbeddedAuthorityNodeError.authorityMismatch
        }
        let trust = try await AuthorityTrustStateCoordinator.open(
            authority: authority,
            networkID: manifest.profile.networkID,
            environment: manifest.environment,
            networkDisplayName: manifest.profile.displayName,
            ledgerURL: bundleURL.appendingPathComponent(NetworkBootstrap.trustLedgerFilename)
        )
        try await trust.refreshRevocationSnapshot()
        let secretsURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "beakrnet-authority-runtime-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: secretsURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let runtimeCAKeyURL = secretsURL.appendingPathComponent("ca-private-key.pem")
        do {
            try certificateAuthorityPrivateKeyPEM.write(to: runtimeCAKeyURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: runtimeCAKeyURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: secretsURL)
            throw error
        }
        do {
        let enrollment = CertificateEnrollmentHTTPEndpoint(
            challenges: try .init(authorityID: authority.authorityID, environment: manifest.environment),
            enrollment: .init(
                validator: .init(
                    trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                    networkID: manifest.profile.networkID,
                    environment: manifest.environment
                ),
                authority: authority,
                issuer: OpenSSLDevelopmentCertificateIssuer(
                    executableURL: openSSLExecutableURL,
                    authorityCertificateURL: bundleURL.appendingPathComponent(
                        NetworkBootstrap.certificateAuthorityCertificateFilename
                    ),
                    authorityPrivateKeyURL: runtimeCAKeyURL
                )
            ),
            membershipPublisher: trust
        )
        let productionProfile = BeakrNetProductionProfile(
            environment: "production",
            enrollmentURL: manifest.controlPlaneURL
                ?? URL(string: "https://authority.invalid/v1/certificate-enrollment")!,
            revocationURL: manifest.controlPlaneURL
                ?? URL(string: "https://authority.invalid/v1/credential-revocations")!,
            keyCustody: .externalKMS(
                provider: "local-authority-bundle",
                keyIdentifier: manifest.authorityID.rawValue.uuidString.lowercased()
            ),
            serviceAuthentication: .mutualTLS,
            perSourceLimit: .init(capacity: 30, refillPerSecond: 1),
            perIdentityLimit: .init(capacity: 60, refillPerSecond: 2),
            globalLimit: .init(capacity: 300, refillPerSecond: 10),
            maximumTrackedLimiters: 4_096,
            offlineRevocationGrace: 60,
            auditRetention: 30 * 24 * 60 * 60,
            maximumAuditEvents: 100_000,
            backup: .init(
                retentionCount: 7,
                maximumAge: 24 * 60 * 60,
                encryptionProvider: "device-keychain"
            )
        )
        let joining = NetworkInvitationHTTPEndpoint(service: try .init(
            authority: authority,
            networkID: manifest.profile.networkID,
            environment: manifest.environment,
            consumptionLedgerURL: bundleURL.appendingPathComponent("invitation-consumption.json")
        ))
        let authorityCertificateDER = try NetworkBootstrap.loadCertificateAuthorityDER(from: bundleURL)
        let administration = AuthorityAdministrationHTTPEndpoint(service: .init(
            authorityPublicKey: authority.publicKeyRepresentation,
            networkID: manifest.profile.networkID,
            environment: manifest.environment,
            issueInvitation: { validity in
                try authority.issueNetworkInvitation(
                    networkID: manifest.profile.networkID,
                    networkDisplayName: manifest.profile.displayName,
                    environment: manifest.environment,
                    controlPlaneURL: manifest.controlPlaneURL ?? URL(string: "https://authority.invalid")!,
                    authorityCertificateDER: authorityCertificateDER,
                    serviceScopes: ["lan"],
                    validity: validity
                )
            }
        ))
        let router = AuthorityControlPlaneRouter(
            enrollment: enrollment,
            joining: joining,
            administration: administration,
            membership: await trust.membershipEndpoint,
            revocations: await trust.revocationEndpoint,
            admission: try .init(
                profile: productionProfile,
                operationLimit: .init(capacity: 120, refillPerSecond: 4)
            ),
            audit: .init(maximumEvents: 100_000, retention: 30 * 24 * 60 * 60)
        )
        let pkcs12 = try Data(
            contentsOf: bundleURL.appendingPathComponent(NetworkBootstrap.authorityServerIdentityFilename)
        )
        let identity = try LANTLSIdentityLoader.importPKCS12(
            pkcs12,
            password: pkcs12Password
        ).identity
        let proposed = try EmbeddedAuthorityHTTPSServer(
            port: port,
            parameters: AuthorityServerTLSConfiguration.parameters(localIdentity: identity),
            router: router,
            listenOnLAN: listenOnLAN
        )
        try await proposed.start()
        server = proposed
        self.trust = trust
        runtimeSecretsURL = secretsURL
        } catch {
            try? FileManager.default.removeItem(at: secretsURL)
            throw error
        }
    }

    public func stop() async {
        await server?.stop()
        server = nil
        trust = nil
        if let runtimeSecretsURL {
            try? FileManager.default.removeItem(at: runtimeSecretsURL)
            self.runtimeSecretsURL = nil
        }
    }

    public func isRunning() -> Bool { server != nil }

    public func renameNetwork(to displayName: String) async throws {
        guard let trust else { throw EmbeddedAuthorityNodeError.notRunning }
        try await trust.renameNetwork(to: displayName)
    }

    public func createInvitation(validity: TimeInterval = 10 * 60) throws -> NetworkInvitation {
        guard server != nil else { throw EmbeddedAuthorityNodeError.notRunning }
        let manifest = try NetworkBootstrap.loadManifest(from: bundleURL)
        guard let controlPlaneURL = manifest.controlPlaneURL else {
            throw EmbeddedAuthorityNodeError.missingControlPlaneURL
        }
        let authority = try CredentialAuthority(
            privateKeyRepresentation: authorityPrivateKeyRepresentation
        )
        return try authority.issueNetworkInvitation(
            networkID: manifest.profile.networkID,
            networkDisplayName: manifest.profile.displayName,
            environment: manifest.environment,
            controlPlaneURL: controlPlaneURL,
            authorityCertificateDER: try NetworkBootstrap.loadCertificateAuthorityDER(from: bundleURL),
            serviceScopes: ["lan"],
            validity: validity
        )
    }
}

public enum EmbeddedAuthorityNodeError: Error, Equatable, Sendable {
    case invalidPort
    case alreadyRunning
    case missingPassword
    case authorityMismatch
    case notRunning
    case missingControlPlaneURL
    case listenerFailed(String)
    case connectionClosed
    case emptyRead
}

private actor EmbeddedAuthorityHTTPSServer {
    private let listener: NWListener
    private let router: AuthorityControlPlaneRouter
    private var started = false

    init(
        port: NWEndpoint.Port,
        parameters: NWParameters,
        router: AuthorityControlPlaneRouter,
        listenOnLAN: Bool
    ) throws {
        self.router = router
        if listenOnLAN {
            listener = try NWListener(using: parameters, on: port)
        } else {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            listener = try NWListener(using: parameters)
        }
    }

    func start() async throws {
        guard !started else { return }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection) }
        }
        try await withCheckedThrowingContinuation { continuation in
            let gate = ListenerStartGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.perform { continuation.resume() }
                case .failed(let error):
                    gate.perform {
                        continuation.resume(throwing: EmbeddedAuthorityNodeError.listenerFailed(
                            String(describing: error)
                        ))
                    }
                case .cancelled:
                    gate.perform { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "BeakrNet.embedded-authority.listener"))
        }
        started = true
    }

    func stop() {
        listener.cancel()
        started = false
    }

    private func handle(_ connection: NWConnection) async {
        connection.start(queue: DispatchQueue(label: "BeakrNet.embedded-authority.connection"))
        do {
            var data = Data()
            while true {
                data.append(try await receive(connection))
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
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
                data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete {
                    continuation.resume(throwing: EmbeddedAuthorityNodeError.connectionClosed)
                } else {
                    continuation.resume(throwing: EmbeddedAuthorityNodeError.emptyRead)
                }
            }
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}

private final class ListenerStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func perform(_ operation: () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        operation()
    }
}
#endif
