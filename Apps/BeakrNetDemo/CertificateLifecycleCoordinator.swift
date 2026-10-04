import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity
import Foundation
import Observation

@MainActor
@Observable
final class CertificateLifecycleCoordinator {
    private(set) var status = "Not configured"
    private(set) var snapshotGeneration: Int64?
    private(set) var lastRefreshAt: Date?
    private(set) var nextRefreshAt: Date?
    private(set) var lastError: String?

    private(set) var certificateStatus = "Not configured"
    private(set) var certificateExpiresAt: Date?
    private(set) var nextRenewalAt: Date?

    private var distributor: RevocationSnapshotDistributor?
    private var controller: RevocationRefreshController?
    private var refreshTask: Task<Void, Never>?
    private var renewalScheduler: CertificateRenewalScheduler?
    private var renewalRequester: RecordingRenewalRequester?
    private var renewalTask: Task<Void, Never>?
    private var identity: NodeIdentity?
    private var credential: NodeCredential?
    private var authorityPublicKey: Data?
    private var controlPlaneBaseURL: URL?

    func start(
        authorityPublicKeyBase64: String,
        controlPlaneURL: String,
        identity: NodeIdentity?,
        credential: NodeCredential?
    ) async {
        stop()
        guard let authorityKey = Data(base64Encoded: authorityPublicKeyBase64),
              let baseURL = URL(string: controlPlaneURL),
              baseURL.scheme?.lowercased() == "https" else {
            status = "Not configured"
            certificateStatus = "Not configured"
            lastError = nil
            return
        }

        self.identity = identity
        self.credential = credential
        authorityPublicKey = authorityKey
        controlPlaneBaseURL = baseURL
        await startRevocation(authorityKey: authorityKey, baseURL: baseURL)
        await restoreCertificateLifecycle(
            authorityKey: authorityKey,
            baseURL: baseURL,
            identity: identity,
            credential: credential
        )
    }

    func enrollCertificate() async {
        guard let identity,
              let credential,
              let authorityPublicKey,
              let controlPlaneBaseURL else {
            certificateStatus = "Enrollment unavailable"
            return
        }

        certificateStatus = "Enrolling"
        do {
            let client = try makeEnrollmentClient(
                baseURL: controlPlaneBaseURL,
                identity: identity,
                credential: credential
            )
            let exchange = try await client.renewCertificate()
            try CertificateEnrollmentResponseVerifier.verify(
                exchange.response,
                for: exchange.request,
                trustedAuthorityPublicKey: authorityPublicKey
            )
            try identityStore.install(response: exchange.response, nodeIdentity: identity)
            try saveExchange(exchange)
            try configureRenewal(
                currentExchange: exchange,
                client: client,
                authorityKey: authorityPublicKey,
                identity: identity
            )
            certificateStatus = "Enrolled"
            certificateExpiresAt = date(milliseconds: exchange.response.expiresAtMilliseconds)
            scheduleRenewal()
        } catch {
            certificateStatus = "Enrollment failed"
            lastError = error.localizedDescription
        }
    }

    func renewCertificateNow() async {
        renewalTask?.cancel()
        renewalTask = nil
        await attemptRenewal()
        scheduleRenewal()
    }

    func register(_ consumer: any RevocationSnapshotConsumer) async {
        guard let distributor else { return }
        let outcome = await distributor.register(consumer)
        if case .failed(let reason) = outcome {
            lastError = reason
        }
    }

    func unregister(consumerID: TransportID) async {
        await distributor?.unregister(consumerID: consumerID)
    }

    func refreshManually() async {
        await refresh(trigger: .manual)
        scheduleNextRefresh()
    }

    func handlePushHint() async {
        await refresh(trigger: .pushNotification)
        scheduleNextRefresh()
    }

    func stop() {
        refreshTask?.cancel()
        renewalTask?.cancel()
        refreshTask = nil
        renewalTask = nil
        distributor = nil
        controller = nil
        renewalScheduler = nil
        renewalRequester = nil
        nextRefreshAt = nil
        nextRenewalAt = nil
    }

    private var identityStore: KeychainLANTLSIdentityStore {
        KeychainLANTLSIdentityStore(service: "net.beakr.demo")
    }

    private func startRevocation(authorityKey: Data, baseURL: URL) async {
        do {
            let distributor = RevocationSnapshotDistributor(
                trustedAuthorityPublicKey: authorityKey
            )
            let requester = try RevocationSnapshotNetworkClient(baseURL: baseURL)
            let controller = RevocationRefreshController(
                distributor: distributor,
                requester: requester,
                store: FileRevocationSnapshotStore(fileURL: try snapshotFileURL()),
                policy: try RevocationRefreshPolicy()
            )
            self.distributor = distributor
            self.controller = controller
            status = "Restoring"
            if let restored = try await controller.restorePersistedSnapshot() {
                snapshotGeneration = restored.generatedAtMilliseconds
            }
            await refresh(trigger: .startup)
            scheduleNextRefresh()
        } catch {
            status = "Refresh unavailable"
            lastError = error.localizedDescription
        }
    }

    private func restoreCertificateLifecycle(
        authorityKey: Data,
        baseURL: URL,
        identity: NodeIdentity?,
        credential: NodeCredential?
    ) async {
        guard let identity, let credential else {
            certificateStatus = "Identity unavailable"
            return
        }
        do {
            guard let exchange = try loadExchange() else {
                certificateStatus = "Enrollment required"
                return
            }
            try CertificateEnrollmentResponseVerifier.verify(
                exchange.response,
                for: exchange.request,
                trustedAuthorityPublicKey: authorityKey
            )
            guard exchange.response.nodeID == identity.nodeID,
                  exchange.response.nodePublicKey == identity.publicKeyRepresentation else {
                throw DemoLifecycleError.identityMismatch
            }
            guard try identityStore.load() != nil else {
                throw DemoLifecycleError.identityUnavailable
            }
            let client = try makeEnrollmentClient(
                baseURL: baseURL,
                identity: identity,
                credential: credential
            )
            try configureRenewal(
                currentExchange: exchange,
                client: client,
                authorityKey: authorityKey,
                identity: identity
            )
            certificateExpiresAt = date(milliseconds: exchange.response.expiresAtMilliseconds)
            certificateStatus = certificateExpiresAt.map { $0 > .now } == true
                ? "Enrolled"
                : "Certificate expired"
            scheduleRenewal()
        } catch {
            certificateStatus = "Enrollment required"
            lastError = error.localizedDescription
        }
    }

    private func makeEnrollmentClient(
        baseURL: URL,
        identity: NodeIdentity,
        credential: NodeCredential
    ) throws -> CertificateEnrollmentNetworkClient {
        try CertificateEnrollmentNetworkClient(
            transport: URLSessionCertificateEnrollmentTransport(baseURL: baseURL),
            identity: identity,
            credential: credential,
            environment: credential.claims.environment,
            requestedValidity: CertificateEnrollmentValidator.maximumCertificateValidity
        )
    }

    private func configureRenewal(
        currentExchange: CertificateRenewalExchange,
        client: CertificateEnrollmentNetworkClient,
        authorityKey: Data,
        identity: NodeIdentity
    ) throws {
        let requester = RecordingRenewalRequester(base: client)
        renewalRequester = requester
        renewalScheduler = CertificateRenewalScheduler(
            currentResponse: currentExchange.response,
            nodeIdentity: identity,
            trustedAuthorityPublicKey: authorityKey,
            requester: requester,
            installer: identityStore,
            policy: try CertificateRenewalPolicy()
        )
    }

    private func scheduleRenewal() {
        renewalTask?.cancel()
        guard let renewalScheduler else { return }
        renewalTask = Task { [weak self] in
            guard let self else { return }
            let attempt = await renewalScheduler.nextAttemptDate(jitterUnit: 0)
            self.nextRenewalAt = attempt
            do {
                try await Task.sleep(for: .seconds(max(0, attempt.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                await self.attemptRenewal()
                self.scheduleRenewal()
            } catch {}
        }
    }

    private func attemptRenewal() async {
        guard let renewalScheduler else { return }
        certificateStatus = "Renewing"
        let outcome = await renewalScheduler.attemptRenewal()
        switch outcome {
        case .installed(let expiresAt):
            if let exchange = await renewalRequester?.latestExchange() {
                do {
                    try saveExchange(exchange)
                } catch {
                    lastError = error.localizedDescription
                }
            }
            certificateExpiresAt = expiresAt
            certificateStatus = "Enrolled"
        case .retryScheduled(let retryAt, _):
            nextRenewalAt = retryAt
            certificateStatus = "Using current certificate"
        }
    }

    private func refresh(trigger: RevocationRefreshTrigger) async {
        guard let controller else { return }
        status = "Refreshing"
        let outcome = await controller.refreshNow(trigger: trigger)
        lastRefreshAt = .now
        switch outcome {
        case .unchanged(let nextAttemptAt):
            status = "Current"
            nextRefreshAt = nextAttemptAt
            lastError = nil
        case .activated(let report, let nextAttemptAt):
            status = report.outcomes.values.contains { outcome in
                if case .failed = outcome { return true }
                return false
            } ? "Current with route warning" : "Current"
            snapshotGeneration = report.generatedAtMilliseconds
            nextRefreshAt = nextAttemptAt
            lastError = nil
        case .failed(let retryAt, _, let reason):
            status = snapshotGeneration == nil ? "No trusted snapshot" : "Using cached snapshot"
            nextRefreshAt = retryAt
            lastError = reason
        }
    }

    private func scheduleNextRefresh() {
        refreshTask?.cancel()
        guard let nextRefreshAt else { return }
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, nextRefreshAt.timeIntervalSinceNow)))
                guard !Task.isCancelled, let self else { return }
                await self.refresh(trigger: .scheduled)
                self.scheduleNextRefresh()
            } catch {}
        }
    }

    private func snapshotFileURL() throws -> URL {
        try applicationSupportDirectory()
            .appendingPathComponent("RevocationSnapshot.json", isDirectory: false)
    }

    private func exchangeFileURL() throws -> URL {
        try applicationSupportDirectory()
            .appendingPathComponent("CertificateEnrollment.json", isDirectory: false)
    }

    private func applicationSupportDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("BeakrNetDemo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func saveExchange(_ exchange: CertificateRenewalExchange) throws {
        let stored = StoredEnrollmentExchange(
            request: exchange.request,
            response: exchange.response
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(stored).write(to: exchangeFileURL(), options: .atomic)
    }

    private func loadExchange() throws -> CertificateRenewalExchange? {
        let url = try exchangeFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stored = try JSONDecoder().decode(
            StoredEnrollmentExchange.self,
            from: Data(contentsOf: url)
        )
        return CertificateRenewalExchange(
            request: stored.request,
            response: stored.response
        )
    }

    private func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}

private struct StoredEnrollmentExchange: Codable {
    let request: CertificateEnrollmentRequest
    let response: CertificateEnrollmentResponse
}

private actor RecordingRenewalRequester: CertificateRenewalRequesting {
    private let base: CertificateEnrollmentNetworkClient
    private var latest: CertificateRenewalExchange?

    init(base: CertificateEnrollmentNetworkClient) {
        self.base = base
    }

    func renewCertificate() async throws -> CertificateRenewalExchange {
        let exchange = try await base.renewCertificate()
        latest = exchange
        return exchange
    }

    func latestExchange() -> CertificateRenewalExchange? {
        latest
    }
}

private enum DemoLifecycleError: Error {
    case identityMismatch
    case identityUnavailable
}
