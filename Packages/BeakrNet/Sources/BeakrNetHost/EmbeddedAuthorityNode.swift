#if os(macOS)
import Foundation
import OSLog
import Network
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetEnrollment
import BeakrNetOperations
import BeakrNetSecurity

private let authorityLogger = Logger(subsystem: "net.beakr.app", category: "Authority")

public actor EmbeddedAuthorityNode {
    private let bundleURL: URL
    private let openSSLExecutableURL: URL
    private let port: NWEndpoint.Port
    private let listenOnLAN: Bool
    private let authorityPrivateKeyRepresentation: Data
    private let certificateAuthorityPrivateKeyPEM: Data
    private var server: EmbeddedAuthorityHTTPSServer?
    private var trust: AuthorityTrustStateCoordinator?
    private var enrollmentCoordinator: AuthorityEnrollmentCoordinator?
    private var localAuthorizationGrants: LocalAuthorizationGrantAuthority?
    private var runtimeSecretsURL: URL?
    private var pendingServer: EmbeddedAuthorityHTTPSServer?
    private var isStarting = false
    private var lifecycleGeneration: UInt64 = 0
    private var endpointPublisher: PersistentAuthorityEndpointPublisher?
    private var publishedRecord: SignedAuthorityEndpoint?
    private var endpointRenewalTask: Task<Void, Never>?
    private let runtimeEndpoint = AuthorityRuntimeEndpoint()

    public init(
        bundleURL: URL,
        openSSLExecutableURL: URL,
        port: UInt16? = nil,
        listenOnLAN: Bool = true,
        authorityPrivateKeyRepresentation: Data,
        certificateAuthorityPrivateKeyPEM: Data
    ) throws {
        if let port {
            guard port != 0, NWEndpoint.Port(rawValue: port) != nil else {
                throw EmbeddedAuthorityNodeError.invalidPort
            }
        }
        self.bundleURL = bundleURL
        self.openSSLExecutableURL = openSSLExecutableURL
        self.port = port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        self.listenOnLAN = listenOnLAN
        self.authorityPrivateKeyRepresentation = authorityPrivateKeyRepresentation
        self.certificateAuthorityPrivateKeyPEM = certificateAuthorityPrivateKeyPEM
    }

    public func start(pkcs12Password: String) async throws {
        guard server == nil, !isStarting else { throw EmbeddedAuthorityNodeError.alreadyRunning }
        guard !pkcs12Password.isEmpty else { throw EmbeddedAuthorityNodeError.missingPassword }
        isStarting = true
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        defer { isStarting = false }
        switch try AuthorityKeyRotationInstaller.recover(bundleURL: bundleURL) {
        case .none:
            break
        case .activateStagedPrivateKey:
            throw EmbeddedAuthorityNodeError.rotationRequiresPrivateKeyActivation
        case .commitMetadata:
            throw EmbeddedAuthorityNodeError.authorityMismatch
        }
        let manifest = try NetworkBootstrap.loadManifest(from: bundleURL)
        guard let hostname = manifest.controlPlaneURL?.host else {
            throw EmbeddedAuthorityNodeError.missingControlPlaneURL
        }
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
        try checkStart(generation)
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
        let enrollmentDirectory = bundleURL.appendingPathComponent("enrollment", isDirectory: true)
        let auditKeyring = try EnrollmentAuditVerificationKeyring.open(
            fileURL: enrollmentDirectory.appendingPathComponent("audit-verification-keys.json"),
            currentPublicKey: authority.publicKeyRepresentation
        )
        let enrollmentState = try PersistentAuthorityEnrollmentStateStore.open(
            fileURL: enrollmentDirectory.appendingPathComponent("authority-state.json")
        )
        let enrollmentMembership = try AuthorityTrustEnrollmentPublisher.open(
            fileURL: enrollmentDirectory.appendingPathComponent("membership-transactions.json"),
            trust: trust
        )
        let localAuthorizationGrants = LocalAuthorizationGrantAuthority()
        let enrollmentCoordinator = AuthorityEnrollmentCoordinator(
            authority: authority,
            networkID: manifest.profile.networkID,
            environment: manifest.environment,
            policy: try AuthorityPolicy(
                credentialValidity: 30 * 24 * 60 * 60,
                certificateValidity: 30 * 24 * 60 * 60,
                invitationValidity: 15 * 60,
                pendingRequestValidity: 24 * 60 * 60,
                allowedClockSkew: 60,
                maximumPendingInvitations: 256,
                maximumPendingRequests: 256,
                maximumEnrolledDevices: 256,
                maximumPayloadBytes: EnrollmentWireCodec.maximumPayloadBytes,
                credentialServiceScopes: ["lan"]
            ),
            stateStore: enrollmentState,
            membershipPublisher: enrollmentMembership,
            localAuthorizationVerifier: localAuthorizationGrants,
            historicalAuditPublicKeys: auditKeyring.entries
                .filter { $0.authorityID != authority.authorityID }
                .map(\.publicKey),
            makeSecret: { Self.randomSecret() }
        )
        let releaseEnrollment = EnrollmentRequestHTTPEndpoint(
            coordinator: enrollmentCoordinator
        )
        let authorityCertificateDER = try NetworkBootstrap.loadCertificateAuthorityDER(from: bundleURL)
        let endpointLocation = runtimeEndpoint
        let administration = AuthorityAdministrationHTTPEndpoint(service: .init(
            authorityPublicKey: authority.publicKeyRepresentation,
            networkID: manifest.profile.networkID,
            environment: manifest.environment,
            issueInvitation: { validity in
                guard let endpoint = endpointLocation.current() else {
                    throw EmbeddedAuthorityNodeError.notRunning
                }
                return try authority.issueNetworkInvitation(
                    networkID: manifest.profile.networkID,
                    networkDisplayName: manifest.profile.displayName,
                    environment: manifest.environment,
                    controlPlaneURL: endpoint,
                    authorityCertificateDER: authorityCertificateDER,
                    serviceScopes: ["lan"],
                    validity: validity
                )
            }
        ))
        let router = AuthorityControlPlaneRouter(
            enrollment: enrollment,
            releaseEnrollment: releaseEnrollment,
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
            password: pkcs12Password,
            memoryOnly: true
        ).identity
        try checkStart(generation)
        let proposed = try EmbeddedAuthorityHTTPSServer(
            port: port,
            parameters: AuthorityServerTLSConfiguration.parameters(localIdentity: identity),
            router: router,
            listenOnLAN: listenOnLAN,
            profileDisplayName: manifest.profile.displayName,
            networkID: manifest.profile.networkID
        )
        pendingServer = proposed
        try await proposed.start()
        try checkStart(generation)
        let publisher = try PersistentAuthorityEndpointPublisher.open(
            fileURL: bundleURL.appendingPathComponent("authority-endpoint-\(authority.authorityID.rawValue.uuidString).json"),
            authority: authority, networkID: manifest.profile.networkID, environment: manifest.environment
        )
        let boundPort = try await proposed.boundPort()
        let record = try await publisher.publish(hostname: hostname, boundPort: boundPort)
        let verified = try AuthorityEndpointVerifier.verify(
            record, trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: manifest.profile.networkID, environment: manifest.environment
        )
        try checkStart(generation)
        if listenOnLAN { try await proposed.advertise(record) }
        try checkStart(generation)
        runtimeEndpoint.set(verified.controlPlaneURL)
        endpointPublisher = publisher
        publishedRecord = record
        server = proposed
        pendingServer = nil
        self.trust = trust
        self.enrollmentCoordinator = enrollmentCoordinator
        self.localAuthorizationGrants = localAuthorizationGrants
        runtimeSecretsURL = secretsURL
        endpointRenewalTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                await self.renewEndpoint(generation: generation)
            }
        }
        } catch {
            await pendingServer?.stop()
            pendingServer = nil
            runtimeEndpoint.set(nil)
            try? FileManager.default.removeItem(at: secretsURL)
            throw error
        }
    }

    public func stop() async {
        lifecycleGeneration += 1
        let renewal = endpointRenewalTask
        endpointRenewalTask = nil
        renewal?.cancel()
        await renewal?.value
        await pendingServer?.stop()
        pendingServer = nil
        await server?.stop()
        server = nil
        endpointPublisher = nil
        publishedRecord = nil
        runtimeEndpoint.set(nil)
        trust = nil
        enrollmentCoordinator = nil
        localAuthorizationGrants = nil
        if let runtimeSecretsURL {
            try? FileManager.default.removeItem(at: runtimeSecretsURL)
            self.runtimeSecretsURL = nil
        }
    }

    public func isRunning() -> Bool { server != nil }

    public func currentEndpointRecord() -> SignedAuthorityEndpoint? { publishedRecord }

    private func checkStart(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == lifecycleGeneration else { throw CancellationError() }
    }

    private func renewEndpoint(generation: UInt64) async {
        guard generation == lifecycleGeneration, let server,
              let endpointPublisher, let previous = publishedRecord else { return }
        do {
            let record = try await endpointPublisher.publish(
                hostname: previous.claims.hostname, boundPort: previous.claims.port
            )
            guard generation == lifecycleGeneration, !Task.isCancelled else { return }
            if listenOnLAN { try await server.advertise(record) }
            guard generation == lifecycleGeneration else { return }
            publishedRecord = record
        } catch {
            guard generation == lifecycleGeneration else { return }
            await server.withdrawAdvertisement()
            authorityLogger.error("Authority endpoint renewal failed; advertisement withdrawn.")
        }
    }

    public func renameNetwork(to displayName: String) async throws {
        guard let trust else { throw EmbeddedAuthorityNodeError.notRunning }
        try await trust.renameNetwork(to: displayName)
        await server?.setProfileDisplayName(displayName)
    }

    public func removeMember(nodeID: NodeID, reason: String) async throws {
        guard let trust else { throw EmbeddedAuthorityNodeError.notRunning }
        try await trust.removeAndRevoke(nodeID: nodeID, reason: reason)
    }

    public func createInvitation(validity: TimeInterval = 10 * 60) throws -> NetworkInvitation {
        guard server != nil else { throw EmbeddedAuthorityNodeError.notRunning }
        let manifest = try NetworkBootstrap.loadManifest(from: bundleURL)
        guard let controlPlaneURL = runtimeEndpoint.current() else {
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

    public func createEnrollmentInvitation() async throws -> EnrollmentInvitation {
        guard let enrollmentCoordinator else { throw EmbeddedAuthorityNodeError.notRunning }
        guard let controlPlaneURL = runtimeEndpoint.current() else {
            throw EmbeddedAuthorityNodeError.notRunning
        }
        let manifest = try NetworkBootstrap.loadManifest(from: bundleURL)
        let invitation = try await enrollmentCoordinator.createInvitation(
            networkDisplayName: manifest.profile.displayName,
            controlPlaneURL: controlPlaneURL,
            authorityCertificateDER: try NetworkBootstrap.loadCertificateAuthorityDER(from: bundleURL)
        )
        authorityLogger.info("[INFO] [macOS] [Beakr Authority] network=\(manifest.profile.networkID.rawValue.uuidString) invitation-created id=\(invitation.invitationID.uuidString) host=\(invitation.controlPlaneURL?.host ?? "none")")
        return invitation
    }

    public func pendingEnrollmentRequests() async throws -> [EnrollmentRequest] {
        guard let enrollmentCoordinator else { throw EmbeddedAuthorityNodeError.notRunning }
        return await enrollmentCoordinator.pendingRequests()
    }

    public func enrollmentAuditRecords() async throws -> [EnrollmentAuditRecord] {
        guard let enrollmentCoordinator else { throw EmbeddedAuthorityNodeError.notRunning }
        return await enrollmentCoordinator.auditRecords()
    }

    public func signedEnrollmentAuditExport() async throws -> Data {
        guard let enrollmentCoordinator else { throw EmbeddedAuthorityNodeError.notRunning }
        return try await enrollmentCoordinator.signedAuditExport()
    }

    public func verifyEnrollmentAuditExport(_ data: Data) async throws -> EnrollmentAuditVerificationReport {
        guard let enrollmentCoordinator else { throw EmbeddedAuthorityNodeError.notRunning }
        return try await enrollmentCoordinator.verifyAuditExport(data)
    }

    public func approveEnrollment(requestID: UUID) async throws -> EnrollmentApproval {
        guard let enrollmentCoordinator, let localAuthorizationGrants else {
            throw EmbeddedAuthorityNodeError.notRunning
        }
        let grant = try await localAuthorizationGrants.issue(requestID: requestID)
        return try await enrollmentCoordinator.approve(
            requestID: requestID,
            localAuthorization: grant
        )
    }

    public func rejectEnrollment(requestID: UUID) async throws -> EnrollmentRejection {
        guard let enrollmentCoordinator, let localAuthorizationGrants else {
            throw EmbeddedAuthorityNodeError.notRunning
        }
        let grant = try await localAuthorizationGrants.issue(requestID: requestID)
        return try await enrollmentCoordinator.reject(
            requestID: requestID,
            reason: .declined,
            localAuthorization: grant
        )
    }

    private static func randomSecret() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }
}

public enum EmbeddedAuthorityNodeError: Error, Equatable, Sendable {
    case invalidPort
    case alreadyRunning
    case missingPassword
    case authorityMismatch
    case rotationRequiresPrivateKeyActivation
    case notRunning
    case missingControlPlaneURL
    case listenerFailed(String)
    case connectionClosed
    case emptyRead
}

// The router's synchronous invitation callback reads the endpoint only after
// listener startup has published its actual bound port.
private final class AuthorityRuntimeEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    func current() -> URL? { lock.withLock { url } }
    func set(_ value: URL?) { lock.withLock { url = value } }
}

private actor EmbeddedAuthorityHTTPSServer {
    private let listener: NWListener
    private let router: AuthorityControlPlaneRouter
    private var profileDisplayName: String
    private let networkID: NetworkID
    private var started = false
    private var stopped = false
    private var connections: [UUID: NWConnection] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]

    init(
        port: NWEndpoint.Port,
        parameters: NWParameters,
        router: AuthorityControlPlaneRouter,
        listenOnLAN: Bool,
        profileDisplayName: String,
        networkID: NetworkID
    ) throws {
        self.router = router
        self.profileDisplayName = profileDisplayName
        self.networkID = networkID
        if listenOnLAN {
            listener = try NWListener(using: parameters, on: port)
        } else {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            listener = try NWListener(using: parameters)
        }
    }

    func start() async throws {
        guard !stopped else { throw CancellationError() }
        guard !started else { return }
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                guard let self else { connection.cancel(); return }
                await self.accept(connection)
            }
        }
        let listener = self.listener
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            listener.cancel()
        }
        defer { deadline.cancel() }
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
        guard !stopped else { throw CancellationError() }
        started = true
    }

    func stop() async {
        stopped = true
        started = false
        listener.service = nil
        listener.cancel()
        let tasks = Array(connectionTasks.values)
        for connection in connections.values { connection.cancel() }
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    func boundPort() throws -> UInt16 {
        guard started, let port = listener.port else { throw EmbeddedAuthorityNodeError.notRunning }
        return port.rawValue
    }

    func advertise(_ record: SignedAuthorityEndpoint) throws {
        guard started else { throw EmbeddedAuthorityNodeError.notRunning }
        try AuthorityEndpointBonjourAdvertisement.publish(record, on: listener)
    }

    func withdrawAdvertisement() { listener.service = nil }

    private func accept(_ connection: NWConnection) {
        guard started, connections.count < 64 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connectionTasks[id] = Task {
            await self.handle(connection)
            self.connections.removeValue(forKey: id)
            self.connectionTasks.removeValue(forKey: id)
        }
    }

    func setProfileDisplayName(_ displayName: String) {
        profileDisplayName = displayName
    }

    private func handle(_ connection: NWConnection) async {
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            connection.cancel()
        }
        defer { deadline.cancel(); connection.cancel() }
        connection.start(queue: DispatchQueue(label: "BeakrNet.embedded-authority.connection"))
        do {
            var data = Data()
            while true {
                data.append(try await receive(connection))
                guard data.count <= 278_532 else {
                    await sendBadRequest(over: connection)
                    return
                }
                let request: CertificateEnrollmentHTTPRequest
                do {
                    request = try AuthorityHTTP1Codec.decodeRequest(data)
                } catch AuthorityHTTP1CodecError.incomplete {
                    continue
                } catch {
                    await sendBadRequest(over: connection)
                    return
                }
                authorityLogger.debug("[TRACE] [macOS] [Beakr Authority] profile=\(self.profileDisplayName) network=\(self.networkID.rawValue.uuidString) operation=\(Self.operationName(for: request.path))")
                let response = await router.handle(
                    request,
                    source: String(describing: connection.endpoint)
                )
                if response.statusCode >= 400 {
                    let reason = response.headers["x-beakr-enrollment-error"] ?? "unspecified"
                    authorityLogger.error("🔴 [FAIL] [macOS] [Beakr Authority] profile=\(self.profileDisplayName) network=\(self.networkID.rawValue.uuidString) operation=\(Self.operationName(for: request.path)) status=\(response.statusCode) reason=\(reason)")
                }
                try await send(AuthorityHTTP1Codec.encodeResponse(response), over: connection)
                connection.cancel()
                return
            }
        } catch {
            // A peer that rejects this authority's TLS identity can close before
            // sending an HTTP request. There is no established request to reject,
            // and attempting a 400 write only targets an already-closed socket.
            connection.cancel()
        }
    }

    private func sendBadRequest(over connection: NWConnection) async {
        try? await send(AuthorityHTTP1Codec.encodeResponse(.init(
            statusCode: 400,
            headers: ["cache-control": "no-store"]
        )), over: connection)
        connection.cancel()
    }

    private static func operationName(for path: String) -> String {
        switch path {
        case RevocationSnapshotHTTPEndpoint.path:
            return "credential-revocations"
        case ProfileMembershipHTTPEndpoint.path:
            return "profile-membership"
        case CertificateEnrollmentHTTPEndpoint.challengePath:
            return "enrollment-challenge"
        case CertificateEnrollmentHTTPEndpoint.enrollmentPath:
            return "certificate-enrollment"
        default:
            return path
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
