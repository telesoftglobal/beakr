import Foundation
import OSLog
import Network
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetControl
import BeakrNetData
import BeakrNetHost
import BeakrNetSecurity

/// Labels remain searchable in exported logs; severity drives Xcode's filtering.
nonisolated enum BeakrDiagnosticLevel: Sendable {
    case debug, info, failure, retry, recovered
}

nonisolated enum BeakrDiagnosticLog {
    static let connectivity = Logger(subsystem: "net.beakr.app", category: "Connectivity")
    static let enrollment = Logger(subsystem: "net.beakr.app", category: "Enrollment")
    static let runtime = Logger(subsystem: "net.beakr.app", category: "Runtime")
    static let delivery = Logger(subsystem: "net.beakr.app", category: "Delivery")
    static let runID = UUID()
    static let lifecycleJournal = RuntimeTraceJournal { event in
        // Only fixed stage/outcome labels and numeric timing are public.
        // Correlation/profile/peer identifiers stay private in persisted logs.
        guard let data = try? JSONEncoder().encode(event),
              let encoded = String(data: data, encoding: .utf8) else { return }
        let duration = event.durationMilliseconds.map { String($0) } ?? "unavailable"
        let parent = event.context.parentOperationID?.uuidString ?? "none"
        runtime.debug("[LIFECYCLE] \(beakrConsolePlatformPrefix(), privacy: .public) pid=\(ProcessInfo.processInfo.processIdentifier) run=\(event.context.runID.uuidString, privacy: .public) operation=\(event.context.operationID.uuidString, privacy: .public) parent=\(parent, privacy: .public) generation=\(event.context.generation) sequence=\(event.sequence) stage=\(event.stage.rawValue, privacy: .public) outcome=\(event.outcome.rawValue, privacy: .public) elapsedMs=\(event.elapsedMilliseconds) durationMs=\(duration, privacy: .public) event=\(encoded, privacy: .private)")
    }

    static func emit(_ message: String, level: BeakrDiagnosticLevel = .debug, logger: Logger) {
        // Diagnostic details may include device names, URLs, or error descriptions.
        // Keep those private in persisted logs; markers remain public and filterable.
        switch level {
        case .debug: logger.debug("[TRACE] \(message, privacy: .private)")
        case .info: logger.info("[INFO] \(message, privacy: .private)")
        case .failure: logger.error("🔴 [FAIL] \(message, privacy: .private)")
        case .retry: logger.notice("[RETRY] \(message, privacy: .private)")
        case .recovered: logger.notice("[RECOVERED] \(message, privacy: .private)")
        }
    }
}

// Runtime-scoped, so late callbacks cannot affect a different selected network.
nonisolated final class PeerTLSHealthMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var failedEndpoints: Set<BonjourEndpointID> = []
    private var subscribers: [UUID: AsyncStream<Int>.Continuation] = [:]

    func observe(endpoint: BonjourEndpointID, trusted: Bool) {
        lock.withLock {
            if trusted { failedEndpoints.remove(endpoint) }
            else { failedEndpoints.insert(endpoint) }
            for subscriber in subscribers.values { subscriber.yield(failedEndpoints.count) }
        }
    }

    func updates() -> AsyncStream<Int> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock {
            subscribers[id] = continuation
            continuation.yield(failedEndpoints.count)
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.subscribers.removeValue(forKey: id) }
        }
        return stream
    }
}

private actor LocalNetworkInfoReport {
    private(set) var address: String?
    func update(_ address: String?) { self.address = address }
}

/// Each runtime owns its monitor so callbacks from a stopped runtime cannot
/// overwrite the next runtime's permission state.
nonisolated final class LocalNetworkPermissionMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var deniedComponents: Set<String> = []
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    var isDenied: Bool { lock.withLock { !deniedComponents.isEmpty } }

    func observe(_ diagnostic: BonjourDiagnostic) {
        lock.withLock {
            let wasDenied = !deniedComponents.isEmpty
            switch diagnostic {
            case .permissionDenied(let component): deniedComponents.insert(component)
            case .browserState(.ready): deniedComponents.remove("browser")
            case .listenerState(.ready): deniedComponents.remove("listener")
            default: return
            }
            let denied = !deniedComponents.isEmpty
            if denied != wasDenied {
                for continuation in continuations.values { continuation.yield(denied) }
            }
        }
    }

    func updates() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock {
            continuations[id] = continuation
            continuation.yield(!deniedComponents.isEmpty)
        }
        continuation.onTermination = { [weak self] _ in
            self?.removeContinuation(id)
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        lock.withLock { _ = continuations.removeValue(forKey: id) }
    }
}

enum ApplicationLANRuntimeError: Error {
    case missingRevocationSnapshot
    case missingMembershipSnapshot
    case localMembershipRemoved
    case alreadyRunning
    case notRunning
}

actor ApplicationLANRuntimeManager: ApplicationLANRuntimeManaging, OutgoingProvenanceMessagingService {
    static let remembersPreviouslyConnectedDevicesKey = "net.beakr.settings.remembersPreviouslyConnectedDevices"
    private let inbox: ApplicationMessageInbox
    private let deliveryUpdates: ApplicationDeliveryUpdates
    private let mailboxMetadataAttachment: @MainActor @Sendable (URL?) -> Void
    private var runtime: ProfileBonjourRuntimeService?
    private var lifecycleTrace: RuntimeLifecycleTrace?
    private var tlsHealthMonitor = PeerTLSHealthMonitor()
    private var permissionMonitor = LocalNetworkPermissionMonitor()
    private var routePolicy: ProfileRoutePolicyController?
    private var trustMaintenance: ProfileTrustMaintenanceController?
    private var membership: ProfileMembershipDirectory?
    private var messaging: PersistentHostMessagingService?
    private var connections: ProfileConnectionRegistry?
    private let statusPermissions: SharedStatusPermissionCoordinator?
    private var sharedStatus: SharedStatusRuntime?
    private var statusPeersTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var networkInfoTask: Task<Void, Never>?
    private var provenanceContext: MessageProvenanceContext?
    private var memberMetadataURL: URL?
    private var memberMetadata: [UUID: NetworkMemberMetadata] = [:]
    private var disconnectDiagnostics: PeerDisconnectDiagnosticTracker?
    private var remembersPreviouslyConnectedDevices: Bool

    init(
        inbox: ApplicationMessageInbox = ApplicationMessageInbox(),
        deliveryUpdates: ApplicationDeliveryUpdates = ApplicationDeliveryUpdates(),
        statusPermissions: SharedStatusPermissionCoordinator? = nil,
        mailboxMetadataAttachment: @escaping @MainActor @Sendable (URL?) -> Void = { _ in }
    ) {
        self.statusPermissions = statusPermissions
        self.inbox = inbox
        self.deliveryUpdates = deliveryUpdates
        self.mailboxMetadataAttachment = mailboxMetadataAttachment
        self.remembersPreviouslyConnectedDevices = UserDefaults.standard.object(
            forKey: Self.remembersPreviouslyConnectedDevicesKey
        ) as? Bool ?? true
    }

    func start(
        configuration: DevelopmentAuthorityConfiguration,
        runtime applicationRuntime: ApplicationProfileRuntime,
        displayName: String
    ) async throws {
        let startID = UUID()
        let startBegan = ContinuousClock.now
        let profileID = applicationRuntime.profile.id.rawValue
        let trace: @Sendable (String) -> Void = { event in
            BeakrDiagnosticLog.emit("profile=\(profileID) start=\(startID) elapsed=\(startBegan.duration(to: .now)) \(event)", logger: BeakrDiagnosticLog.runtime)
        }
        trace("begin")
        defer { trace("return cancelled=\(Task.isCancelled)") }
        guard runtime == nil else { throw ApplicationLANRuntimeError.alreadyRunning }
        let lifecycleTrace = RuntimeLifecycleDiagnostics.current ?? RuntimeLifecycleTrace(
            context: RuntimeTraceContext(runID: BeakrDiagnosticLog.runID,
                                         profileID: applicationRuntime.profile.id.rawValue,
                                         networkID: applicationRuntime.profile.networkID.rawValue,
                                         generation: 0),
            journal: BeakrDiagnosticLog.lifecycleJournal
        )
        self.lifecycleTrace = lifecycleTrace
        let provenanceContext = MessageProvenanceContext(
            profileID: applicationRuntime.profile.id.rawValue,
            authorityID: configuration.credential.claims.issuerID.rawValue,
            authorityEndpoint: configuration.controlPlaneURL.absoluteString,
            localCredentialID: configuration.credential.claims.credentialID
        )
        let memberMetadataURL = applicationRuntime.mailboxMetadataURL?
            .deletingLastPathComponent()
            .appendingPathComponent("network-members.json")
        let memberMetadata: [UUID: NetworkMemberMetadata]
        if remembersPreviouslyConnectedDevices {
            do {
                memberMetadata = try memberMetadataURL.map(NetworkMemberMetadataStore.load) ?? [:]
            } catch {
                memberMetadata = [:]
                BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [Beakr Members] saved member metadata could not be opened: \(error)", level: .failure, logger: BeakrDiagnosticLog.runtime)
            }
        } else {
            memberMetadata = [:]
        }
        self.provenanceContext = provenanceContext
        await mailboxMetadataAttachment(applicationRuntime.mailboxMetadataURL)
        await inbox.attach(
            applicationRuntime.dataState,
            context: provenanceContext
        )
        let snapshotStore = FileRevocationSnapshotStore(
            fileURL: applicationRuntime.paths.revocationSnapshotURL
        )
        guard let revocationSnapshot = try snapshotStore.loadSnapshot() else {
            throw ApplicationLANRuntimeError.missingRevocationSnapshot
        }
        let revoked = try RevocationVerifier.verify(
            revocationSnapshot,
            trustedAuthorityPublicKey: configuration.authorityPublicKey
        )
        let distributor = RevocationSnapshotDistributor(
            trustedAuthorityPublicKey: configuration.authorityPublicKey
        )
        // Runtime startup may continue from already verified, signed trust state.
        // Bound authority reconciliation so an offline authority does not leave
        // peer discovery waiting on the shared URL session's long timeout.
        let authorityTransport = try configuration.makeTransport(profileID: applicationRuntime.profile.id, requestTimeout: 2)
        _ = try await distributor.publish(revocationSnapshot)
        let membership = try await ProfileMembershipDirectory.open(
            fileURL: applicationRuntime.paths.membershipSnapshotURL,
            networkID: applicationRuntime.profile.networkID,
            environment: configuration.credential.claims.environment,
            trustedAuthorityPublicKey: configuration.authorityPublicKey,
            revokedCredentialIDs: revoked
        )
        let membershipRefresh = ProfileMembershipRefreshController(
            directory: membership,
            requester: ProfileMembershipNetworkClient(transport: authorityTransport),
            policy: try ProfileMembershipRefreshPolicy(),
            eventSink: { diagnostic in
                let level: BeakrDiagnosticLevel
                switch diagnostic {
                case .failed: level = .retry
                case .activated: level = .info
                case .started, .unchanged: level = .debug
                }
                switch diagnostic {
                case .started: lifecycleTrace.record(.membershipRefresh, .began)
                case .activated: lifecycleTrace.record(.membershipRefresh, .completed, state: "activated")
                case .unchanged: lifecycleTrace.record(.membershipRefresh, .completed, state: "unchanged")
                case .failed: lifecycleTrace.record(.membershipRefresh, .failed, reason: .trustRefreshFailed)
                }
                BeakrDiagnosticLog.emit("membership \(diagnostic)", level: level, logger: BeakrDiagnosticLog.runtime)
            }
        )
        let revocationRefresh = RevocationRefreshController(
            distributor: distributor,
            requester: RevocationSnapshotNetworkClient(transport: authorityTransport),
            store: snapshotStore,
            policy: try RevocationRefreshPolicy(),
            eventSink: { diagnostic in
                let level: BeakrDiagnosticLevel
                switch diagnostic {
                case .failed: level = .retry
                case .activated(_, let failedConsumers):
                    level = failedConsumers == 0 ? .info : .failure
                case .started, .persisted, .unchanged: level = .debug
                }
                switch diagnostic {
                case .started: lifecycleTrace.record(.revocationRefresh, .began)
                case .persisted: break
                case .activated(_, let failedConsumers):
                    lifecycleTrace.record(.revocationRefresh, failedConsumers == 0 ? .completed : .failed,
                                          count: failedConsumers, state: "activated")
                case .unchanged: lifecycleTrace.record(.revocationRefresh, .completed, state: "unchanged")
                case .failed: lifecycleTrace.record(.revocationRefresh, .failed, reason: .trustRefreshFailed)
                }
                BeakrDiagnosticLog.emit("revocations \(diagnostic)", level: level, logger: BeakrDiagnosticLog.runtime)
            }
        )
        let trustMaintenance = ProfileTrustMaintenanceController(
            revocationRefresh: revocationRefresh,
            revocations: distributor,
            membershipDirectory: membership,
            membershipRefresh: membershipRefresh
        )
        let restoredMembership = await membership.generation() != nil
        let trustBegan = lifecycleTrace.instant()
        lifecycleTrace.record(.trustPreparation, .began)
        trace("trust-refresh-begin cachedMembership=\(restoredMembership) requestTimeoutSeconds=2 order=revocations,membership")
        let initialMaintenance = await trustMaintenance.refreshNow(
            revocationTrigger: .startup,
            membershipTrigger: .startup
        )
        lifecycleTrace.record(.trustPreparation, .completed, since: trustBegan)
        trace("trust-refresh-end")
        trace("trust-cache-check-begin")
        BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [Beakr Trust] revocations=\(initialMaintenance.revocations) membership=\(initialMaintenance.membership)", level: .debug, logger: BeakrDiagnosticLog.runtime)
        if !restoredMembership {
            switch initialMaintenance.membership {
            case .activated:
                break
            case .unchanged, .failed:
                throw ApplicationLANRuntimeError.missingMembershipSnapshot
            }
        }

        // A manual restart is also the user's explicit authority reconciliation.
        // Continue to use cached signed state when the authority is temporarily
        // unavailable, but never restart routes after a newer signed snapshot has
        // removed this device.
        guard await membership.sessionID(for: applicationRuntime.profile.localNodeID) != nil else {
            throw ApplicationLANRuntimeError.localMembershipRemoved
        }

        guard let currentRevocationSnapshot = try snapshotStore.loadSnapshot() else {
            throw ApplicationLANRuntimeError.missingRevocationSnapshot
        }

        trace("trust-cache-check-end localMembershipPresent=true")
        let routePolicy = ProfileRoutePolicyController()
        let disconnectDiagnostics = PeerDisconnectDiagnosticTracker()
        self.disconnectDiagnostics = disconnectDiagnostics
        let permissionStore = try? await statusPermissions?.store(
            profile: applicationRuntime.profile, rootURL: applicationRuntime.paths.rootURL
        )
        if let permissionStore, let snapshot = await membership.serviceAuthorizationSnapshot() {
            await permissionStore.reconcile(snapshot)
        }
        let sharedStatus = SharedStatusRuntime(
            profileID: profileID, networkID: applicationRuntime.profile.networkID,
            localNodeID: applicationRuntime.profile.localNodeID,
            permissions: permissionStore, persistentPermissions: true,
            authorizationSnapshot: { await membership.serviceAuthorizationSnapshot() },
            events: { event in
                BeakrDiagnosticLog.emit("[STATUS] runtime=\(event.runtimeID) request=\(String(describing: event.correlationID?.rawValue)) stage=\(event.stage.rawValue) outcome=\(event.outcome.rawValue) elapsed=\(String(describing: event.elapsed)) failure=\(String(describing: event.failure))", level: .debug, logger: BeakrDiagnosticLog.runtime)
            },
            sample: { [weak self] in
                guard let self else { throw SharedStatusError.unavailable }
                return try await self.sharedStatusSnapshot(profileID: profileID)
            }
        )
        let connections = ProfileConnectionRegistry(
            networkID: applicationRuntime.profile.networkID,
            localNodeID: applicationRuntime.profile.localNodeID,
            revocations: distributor,
            routePolicy: routePolicy,
            incomingEnvelopeSink: { [inbox] envelope in
                BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [Beakr Delivery] received \(envelope.messageID.rawValue)", level: .debug, logger: BeakrDiagnosticLog.runtime)
                return await inbox.record(envelope)
            },
            deliveryAcknowledgementSink: { [deliveryUpdates] acknowledgement in
                await ApplicationDeliveryPipeline.acknowledge(
                    acknowledgement, state: applicationRuntime.dataState, deliveryUpdates: deliveryUpdates
                )
            },
            peerLifecycleSink: { peerNodeID, notice in
                disconnectDiagnostics.recordLifecycleNotice(notice, from: peerNodeID)
                trace("peer-lifecycle peer=\(peerNodeID.rawValue) state=\(notice.state.rawValue) reason=\(notice.reason.rawValue)")
            },
            peerDiagnosticSink: { peers in
                lifecycleTrace.observePeers(Set(peers.map { $0.rawValue }))
            },
            authenticatedApplicationSink: { envelope, peer, route in
                await sharedStatus.receive(envelope, peer: peer, route: route)
            },
            peerRouteEnded: { peer, routeID in
                Task { await sharedStatus.routeEnded(peer: peer, routeID: routeID) }
            }
        )
        await sharedStatus.configure(
            resolve: { [weak connections] peer in
                guard let connections,
                      let session = await membership.connectionSessionID(
                        localNodeID: applicationRuntime.profile.localNodeID, peerNodeID: peer
                      ), let route = await connections.applicationRoute(for: peer),
                      route.sessionID == session else { return nil }
                return route
            },
            submit: { [weak connections] envelope, routeID in
                guard let connections else { return .routeUnavailable }
                return await connections.submit(envelope, expectedRouteID: routeID)
            },
            nextSequence: { [weak connections] peer in await connections?.nextSequenceNumber(for: peer) ?? 0 }
        )
        let monitorPermissions = try? await statusPermissions?.store(
            profile: applicationRuntime.profile, rootURL: applicationRuntime.paths.rootURL, operation: .monitor
        )
        await sharedStatus.configureMonitoring(permissions: monitorPermissions)
        let messaging = PersistentHostMessagingService(
            state: applicationRuntime.dataState,
            contextProvider: { destination in
                guard let sessionID = await membership.connectionSessionID(
                    localNodeID: applicationRuntime.profile.localNodeID,
                    peerNodeID: destination
                ) else {
                    throw ApplicationLANRuntimeError.missingMembershipSnapshot
                }
                let sequenceNumber = await connections.nextSequenceNumber(for: destination)
                return HostDeliveryContext(
                    networkID: applicationRuntime.profile.networkID,
                    sessionID: sessionID,
                    sourceNodeID: applicationRuntime.profile.localNodeID,
                    sequenceNumber: sequenceNumber
                )
            },
            submit: { envelope in
                let result = await connections.submit(envelope)
                BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [Beakr Delivery] submit \(envelope.messageID.rawValue): \(result)", level: .debug, logger: BeakrDiagnosticLog.runtime)
                return result
            }
        )
        var generator = SystemRandomNumberGenerator()
        let advertisementNonce = Data(
            (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        )
        let tlsHealthMonitor = PeerTLSHealthMonitor()
        self.tlsHealthMonitor = tlsHealthMonitor
        let permissionMonitor = LocalNetworkPermissionMonitor()
        self.permissionMonitor = permissionMonitor
        let runtime = try AppleProfileLANRuntimeFactory.make(
            profile: applicationRuntime.profile,
            keychainBaseService: "net.beakr.app",
            environment: configuration.credential.claims.environment,
            trustedAuthorityPublicKey: configuration.authorityPublicKey,
            revocationSnapshot: currentRevocationSnapshot,
            registry: connections,
            advertisementNonce: advertisementNonce,
            displayName: Self.validBonjourDisplayName(displayName),
            sessionID: { nodeID in
                await trustMaintenance.connectionSessionID(
                    localNodeID: applicationRuntime.profile.localNodeID,
                    peerNodeID: nodeID
                )
            },
            acceptedPeer: membership.acceptedPeerResolver {
                await trustMaintenance.recoverUnknownPeer()
            },
            tlsHealthSink: { endpoint, trusted in tlsHealthMonitor.observe(endpoint: endpoint, trusted: trusted) },
            tlsDiagnosticSink: { diagnostic in
                BeakrDiagnosticLog.emit(diagnostic, level: diagnostic.hasPrefix("tls-connection-attempt") ? .debug : .failure,
                                        logger: BeakrDiagnosticLog.connectivity)
            },
            bonjourDiagnosticSink: { diagnostic in
                permissionMonitor.observe(diagnostic)
                switch diagnostic {
                case .reconnectScheduled(_, let delay):
                    lifecycleTrace.record(.retryScheduled, .waiting,
                                          scheduledDelay: delay)
                case .connectionState(let id, let connectionState):
                    switch connectionState {
                    case .preparing: lifecycleTrace.record(.connectionAttempt, .began, subjectID: id)
                    case .ready: lifecycleTrace.record(.connectionAttempt, .ready, subjectID: id)
                    case .failed: lifecycleTrace.record(.connectionAttempt, .failed, subjectID: id, reason: .connectionFailed)
                    default: break
                    }
                case .browserState(.ready): lifecycleTrace.record(.browser, .ready)
                case .listenerState(.ready): lifecycleTrace.record(.listener, .ready)
                case .permissionDenied: lifecycleTrace.record(.discoveryStart, .denied, reason: .permissionDenied)
                case .staleCallbackIgnored: lifecycleTrace.record(.observation, .stale)
                case .connectionCreationFailed: lifecycleTrace.record(.connectionAttempt, .failed)
                default: break
                }
                let level: BeakrDiagnosticLevel
                switch diagnostic {
                case .reconnectScheduled: level = .retry
                case .permissionDenied, .connectionCreationFailed: level = .failure
                default: level = .debug
                }
                BeakrDiagnosticLog.emit("bonjour \(diagnostic)", level: level, logger: BeakrDiagnosticLog.runtime)
            },
            transportDiagnosticSink: { diagnostic in
                switch diagnostic {
                case .authenticating(let id, _):
                    lifecycleTrace.record(.authentication, .began, subjectID: id)
                case .authenticated(let id, _):
                    lifecycleTrace.record(.authentication, .completed, subjectID: id)
                case .authenticationFailed(let id, _):
                    lifecycleTrace.record(.authentication, .failed, subjectID: id, reason: .authenticationRejected)
                default: break
                }
                let level: BeakrDiagnosticLevel
                switch diagnostic {
                case .authenticationFailed, .permissionDenied: level = .failure
                case .authenticated, .peerRevoked: level = .info
                case .authenticating, .pathLost: level = .debug
                }
                BeakrDiagnosticLog.emit("transport \(diagnostic)", level: level, logger: BeakrDiagnosticLog.runtime)
                if case .peerRevoked(let peer) = diagnostic {
                    Task { await sharedStatus.authorizationEnded(peer: peer) }
                }
                if let event = disconnectDiagnostics.observe(diagnostic) {
                    trace(event)
                }
            },
            runtimeDiagnosticSink: { trace("runtime \($0)") }
        )
        await routePolicy.setAllRoutesPermitted(true)
        await routePolicy.setLANPermitted(true)
        try Task.checkCancellation()
        let discoveryBegan = lifecycleTrace.instant()
        lifecycleTrace.record(.discoveryStart, .began)
        trace("discovery-listener-start-begin")
        await runtime.start()
        lifecycleTrace.record(.discoveryStart, .completed, since: discoveryBegan)
        trace("discovery-listener-start-end")
        self.routePolicy = routePolicy
        self.trustMaintenance = trustMaintenance
        self.membership = membership
        self.messaging = messaging
        self.connections = connections
        self.runtime = runtime
        self.sharedStatus = sharedStatus
        statusPeersTask = Task {
            for await _ in await connections.peerNodeIDUpdates() {
                guard !Task.isCancelled else { return }
                await sharedStatus.revalidate()
            }
        }
        self.memberMetadataURL = memberMetadataURL
        self.memberMetadata = memberMetadata
        if !remembersPreviouslyConnectedDevices, let memberMetadataURL {
            do {
                try NetworkMemberMetadataStore.save([:], to: memberMetadataURL)
            } catch {
                BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [Beakr Members] saved member metadata could not be cleared: \(error)", level: .failure, logger: BeakrDiagnosticLog.runtime)
            }
        }
        // Diagnostic reports travel on authenticated, ephemeral Control traffic.
        // A separate path monitor avoids depending on any visible SwiftUI view.
        networkInfoTask = Task {
            await withTaskGroup(of: Void.self) { group in
                let report = LocalNetworkInfoReport()
                group.addTask {
                    for await path in CurrentInternetRouteProbe.updates() {
                        let snapshot = await AppleNetworkSnapshot.capture(path: path, includesWiFiName: false)
                        guard !Task.isCancelled else { return }
                        await report.update(snapshot.localIPv4Address)
                        await connections.publishNetworkInfo(PeerNetworkInfo(ipv4Address: snapshot.localIPv4Address))
                    }
                }
                group.addTask {
                    #if DEBUG && os(macOS)
                    // Bounded acceptance trace on the existing timer: 11 samples
                    // over about five minutes, with no additional monitoring task.
                    let resourceTraceID = UUID().uuidString
                    var resourceTraceTick = 0
                    #endif
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(5)) }
                        catch { return }
                        await connections.publishNetworkInfo(PeerNetworkInfo(ipv4Address: await report.address))
                        #if DEBUG && os(macOS)
                        if resourceTraceTick <= 60 {
                            if resourceTraceTick.isMultiple(of: 6) {
                                let snapshot = await runtime.resourceSnapshot()
                                guard !Task.isCancelled else { return }
                                // Only counts and a fresh trace ID are public; no
                                // profile IDs, peer addresses or credentials.
                                let line = "[RESOURCES] trace=\(resourceTraceID) sample=\(resourceTraceTick / 6 + 1)/11 discoveryConnections=\(snapshot.discovery.connections) activeTransports=\(snapshot.transports.activeTransports) pendingHandshakes=\(snapshot.transports.pendingHandshakes) reconnectTasks=\(snapshot.discovery.reconnectTasks) discoveryLossTasks=\(snapshot.discovery.discoveryLossTasks) connectionAttemptTasks=\(snapshot.discovery.connectionAttemptTasks)"
                                BeakrDiagnosticLog.runtime.notice("\(line, privacy: .public)")
                            }
                            resourceTraceTick += 1
                        }
                        #endif
                    }
                }
                await group.waitForAll()
            }
        }
        let retryBegan = lifecycleTrace.instant()
        lifecycleTrace.record(.pendingRetry, .began)
        trace("pending-retry-begin")
        try await messaging.retryPending()
        lifecycleTrace.record(.pendingRetry, .completed, since: retryBegan)
        trace("pending-retry-end")
        // Existing owner snapshots are counts of work, not atomic global state.
        let resources = await runtime.resourceSnapshot()
        lifecycleTrace.record(.resources, .changed, count: resources.discovery.connections, state: "discoveryConnections")
        lifecycleTrace.record(.resources, .changed, count: resources.transports.activeTransports, state: "activeTransports")
        lifecycleTrace.record(.resources, .changed, count: resources.transports.pendingHandshakes, state: "pendingHandshakes")
        lifecycleTrace.record(.resources, .changed, count: resources.discovery.reconnectTasks, state: "reconnectTasks")
        lifecycleTrace.record(.resources, .changed, count: resources.discovery.connectionAttemptTasks, state: "connectionAttemptTasks")
        lifecycleTrace.record(.resources, .changed, count: resources.discovery.discoveryLossTasks, state: "discoveryLossTasks")
        deliveryTask = Task { [weak self, messaging] in
            await ApplicationDeliveryPipeline.runRetries(messaging: messaging) { [weak self] in
                await sharedStatus.revalidate()
                return await self?.running() == true
            }
        }

        maintenanceTask = Task { [weak self, trustMaintenance] in
            while !Task.isCancelled {
                do {
                    let nextAttempt = await trustMaintenance.nextScheduledAttempt()
                    try await Task.sleep(for: .seconds(max(1, nextAttempt.timeIntervalSinceNow)))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                _ = await trustMaintenance.refreshNow(
                    revocationTrigger: .scheduled,
                    membershipTrigger: .scheduled
                )
                await sharedStatus.revalidate()
                guard await self?.running() == true else { return }
            }
        }
    }

    func stop() async {
        await stop(reason: .runtimeStopping)
    }

    func stop(reason: PeerLifecycleReason) async {
        let status = sharedStatus
        sharedStatus = nil
        statusPeersTask?.cancel()
        statusPeersTask = nil
        await status?.invalidate()
        // Close before route teardown, which is not a remote peer outage.
        lifecycleTrace?.close(.stopped)
        lifecycleTrace = nil
        let stopID = UUID()
        BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [Beakr Runtime Stop] time=\(beakrConsoleTime()) stop=\(stopID) begin", level: .debug, logger: BeakrDiagnosticLog.runtime)
        defer { BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [Beakr Runtime Stop] time=\(beakrConsoleTime()) stop=\(stopID) end", level: .debug, logger: BeakrDiagnosticLog.runtime) }
        networkInfoTask?.cancel()
        networkInfoTask = nil
        deliveryTask?.cancel()
        deliveryTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        await mailboxMetadataAttachment(nil)
        guard let runtime else { return }
        if let connections {
            let submitted = await connections.notifyPeers(PeerLifecycleNotice(reason: reason))
            BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [Beakr Runtime Stop] time=\(beakrConsoleTime()) stop=\(stopID) lifecycle-notice reason=\(reason.rawValue) submitted=\(submitted)", level: .debug, logger: BeakrDiagnosticLog.runtime)
        }
        if let routePolicy {
            await routePolicy.setLANPermitted(false)
            await routePolicy.setAllRoutesPermitted(false)
        }
        disconnectDiagnostics?.beginLocalShutdown()
        await runtime.stop()
        self.runtime = nil
        routePolicy = nil
        trustMaintenance = nil
        membership = nil
        messaging = nil
        connections = nil
        provenanceContext = nil
        memberMetadataURL = nil
        memberMetadata = [:]
        disconnectDiagnostics = nil
    }

    func peerTLSFailureUpdates() -> AsyncStream<Int> { tlsHealthMonitor.updates() }

    func localNetworkPermissionDenied() -> Bool { permissionMonitor.isDenied }

    func localNetworkPermissionUpdates() -> AsyncStream<Bool> { permissionMonitor.updates() }

    func localNetworkAvailable() async -> Bool {
        await LocalNetworkPathObserver().currentAvailability()
    }

    func localNetworkAvailabilityUpdates() -> AsyncStream<Bool> {
        LocalNetworkPathObserver().updates
    }

    func send(_ request: HostMessageRequest) async throws {
        _ = try await sendWithProvenance(request)
    }

    func sendWithProvenance(_ request: HostMessageRequest) async throws -> OutgoingMessageProvenance {
        guard let messaging else { throw ApplicationLANRuntimeError.notRunning }
        guard let provenanceContext else { throw ApplicationLANRuntimeError.notRunning }
        let envelope = try await messaging.sendRecordingEnvelope(request)
        return OutgoingMessageProvenance(
            storageMessageID: envelope.messageID.rawValue,
            correlationID: request.message.correlationID.rawValue,
            networkID: envelope.networkID.rawValue,
            profileID: provenanceContext.profileID,
            sourceDeviceID: envelope.sourceNodeID.rawValue,
            destinationDeviceID: envelope.destinationNodeID.rawValue,
            sessionID: envelope.sessionID.rawValue,
            envelopeCreatedAt: envelope.createdAt,
            queuedAt: Date(),
            authorityID: provenanceContext.authorityID,
            authorityEndpoint: provenanceContext.authorityEndpoint,
            localCredentialID: provenanceContext.localCredentialID
        )
    }

    func cancel(correlationID: DataCorrelationID) async throws {
        guard let messaging else { throw ApplicationLANRuntimeError.notRunning }
        try await messaging.cancel(correlationID: correlationID)
    }

    func running() -> Bool { runtime != nil }

    func sharedStatusRuntime(profileID: UUID) -> SharedStatusRuntime? {
        guard runtime != nil, sharedStatus?.profileID == profileID else { return nil }
        return sharedStatus
    }

    private func sharedStatusSnapshot(profileID: UUID) async throws -> SharedStatusSnapshot {
        guard let status = sharedStatus, status.profileID == profileID,
              let connections, runtime != nil else { throw SharedStatusError.invalidated }
        let count = await connections.peerCount()
        guard sharedStatus === status else { throw SharedStatusError.invalidated }
        return SharedStatusSnapshot(schemaVersion: 1, sampledAt: Date(),
                                    applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
                                    runtimeState: .running, authenticatedPeerCount: count)
    }

    func authenticatedPeerIDs() async -> Set<UUID> {
        guard let connections else { return [] }
        return Set(await connections.peerNodeIDs().map(\.rawValue))
    }

    func authenticatedPeerIDUpdates() async -> AsyncStream<Set<UUID>> {
        guard let connections else {
            return AsyncStream { continuation in
                continuation.yield([])
                continuation.finish()
            }
        }
        let nodeUpdates = await connections.peerNodeIDUpdates()
        return AsyncStream { continuation in
            let forwardingTask = Task {
                for await nodeIDs in nodeUpdates {
                    guard !Task.isCancelled else { break }
                    continuation.yield(Set(nodeIDs.map(\.rawValue)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in forwardingTask.cancel() }
        }
    }

    func memberSummaries() async -> [NetworkMemberSummary] {
        guard let membership else { return [] }
        let names = await runtime?.discoveredDisplayNames() ?? [:]
        let addresses = await runtime?.peerIPAddresses() ?? [:]
        let reportedAddresses = await connections?.peerReportedIPv4Addresses() ?? [:]
        let authenticatedIDs = await authenticatedPeerIDs()
        let nodeIDs = await membership.memberNodeIDs()
        let credentialIDs = await membership.memberCredentialIDs()
        let memberIDs = Set(nodeIDs.map(\.rawValue))
        var metadataChanged = false

        for id in memberMetadata.keys where !memberIDs.contains(id) {
            memberMetadata.removeValue(forKey: id)
            metadataChanged = true
        }

        let now = Date()
        let summaries = nodeIDs.map { nodeID in
            let id = nodeID.rawValue
            let authenticatedName = authenticatedIDs.contains(id) ? names[nodeID] : nil
            if remembersPreviouslyConnectedDevices, authenticatedIDs.contains(id) {
                var metadata = memberMetadata[id] ?? NetworkMemberMetadata(
                    id: id,
                    displayName: nil,
                    lastSeen: nil
                )
                if let authenticatedName, metadata.displayName != authenticatedName {
                    metadata.displayName = authenticatedName
                    metadataChanged = true
                }
                if metadata.lastSeen.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                    metadata.lastSeen = now
                    metadataChanged = true
                }
                memberMetadata[id] = metadata
            }

            let knownMetadata = memberMetadata[id]
            let displayName = authenticatedName ?? knownMetadata?.displayName
            return NetworkMemberSummary(
                id: id,
                displayName: displayName ?? "Network Device \(id.uuidString.suffix(8))",
                isPlaceholderName: displayName == nil,
                lastSeen: knownMetadata?.lastSeen,
                deviceIPAddress: authenticatedIDs.contains(id) ? reportedAddresses[nodeID] : nil,
                connectionIPAddress: authenticatedIDs.contains(id) ? addresses[nodeID] : nil,
                credentialID: credentialIDs[nodeID]
            )
        }

        if remembersPreviouslyConnectedDevices, metadataChanged, let memberMetadataURL {
            do {
                try NetworkMemberMetadataStore.save(memberMetadata, to: memberMetadataURL)
            } catch {
                BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [Beakr Members] member metadata could not be saved: \(error)", level: .failure, logger: BeakrDiagnosticLog.runtime)
            }
        }
        return summaries
    }

    func setRemembersPreviouslyConnectedDevices(_ enabled: Bool) async {
        guard remembersPreviouslyConnectedDevices != enabled else { return }
        remembersPreviouslyConnectedDevices = enabled
        guard !enabled else { return }
        memberMetadata.removeAll()
        guard let memberMetadataURL else { return }
        do {
            try NetworkMemberMetadataStore.save([:], to: memberMetadataURL)
        } catch {
            BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [Beakr Members] saved member metadata could not be cleared: \(error)", level: .failure, logger: BeakrDiagnosticLog.runtime)
        }
    }

    func forgetRememberedDevice(_ id: UUID) async -> Bool {
        let authenticatedIDs = await authenticatedPeerIDs()
        guard !authenticatedIDs.contains(id), memberMetadata.removeValue(forKey: id) != nil else {
            return false
        }
        if let memberMetadataURL {
            do {
                try NetworkMemberMetadataStore.save(memberMetadata, to: memberMetadataURL)
            } catch {
                BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [Beakr Members] member metadata could not be saved after forgetting a device: \(error)", level: .failure, logger: BeakrDiagnosticLog.runtime)
            }
        }
        return true
    }

    func refreshMemberSummaries() async -> [NetworkMemberSummary] {
        guard let trustMaintenance else { return [] }
        _ = await trustMaintenance.refreshNow(
            revocationTrigger: .manual,
            membershipTrigger: .manual
        )
        await sharedStatus?.revalidate()
        return await memberSummaries()
    }

    func networkDisplayName() async -> String? {
        await membership?.networkDisplayName()
    }

    private static func validBonjourDisplayName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= BonjourDiscoveryMetadata.maximumDisplayNameUTF8Length else { return nil }
        return trimmed
    }

}

private nonisolated final class LocalNetworkPathObserver: @unchecked Sendable {
    private func makeMonitor() -> NWPathMonitor {
        NWPathMonitor(prohibitedInterfaceTypes: [.cellular])
    }

    func currentAvailability() async -> Bool {
        let monitor = makeMonitor()
        let queue = DispatchQueue(label: "net.beakr.local-network-path-probe")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                monitor.pathUpdateHandler = { path in
                    monitor.cancel()
                    continuation.resume(returning: path.status == .satisfied)
                }
                monitor.start(queue: queue)
            }
        } onCancel: {
            monitor.cancel()
        }
    }

    var updates: AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = makeMonitor()
            let queue = DispatchQueue(label: "net.beakr.local-network-path-monitor")
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }
}

nonisolated private final class PeerDisconnectDiagnosticTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var peerByConnectionID: [UUID: NodeID] = [:]
    private var lifecycleReasonByPeer: [NodeID: PeerLifecycleReason] = [:]
    private var localShutdownIsInProgress = false

    func beginLocalShutdown() {
        lock.lock()
        localShutdownIsInProgress = true
        lock.unlock()
    }

    func recordLifecycleNotice(_ notice: PeerLifecycleNotice, from peer: NodeID) {
        lock.lock()
        lifecycleReasonByPeer[peer] = notice.reason
        lock.unlock()
    }

    func observe(_ diagnostic: LANTransportDiagnostic) -> String? {
        lock.lock()
        defer { lock.unlock() }

        switch diagnostic {
        case .authenticated(let connectionID, let peerNodeID):
            peerByConnectionID[connectionID] = peerNodeID
            lifecycleReasonByPeer.removeValue(forKey: peerNodeID)
            return nil
        case .authenticationFailed(let connectionID, _):
            peerByConnectionID.removeValue(forKey: connectionID)
            return nil
        case .pathLost(let connectionID, _):
            guard let peerNodeID = peerByConnectionID.removeValue(forKey: connectionID) else {
                return nil
            }
            guard !localShutdownIsInProgress else { return nil }
            if let reason = lifecycleReasonByPeer.removeValue(forKey: peerNodeID) {
                return "peer-disconnected peer=\(peerNodeID.rawValue) classification=announced reason=\(reason.rawValue)"
            }
            return "peer-disconnected peer=\(peerNodeID.rawValue) classification=abrupt-or-unannounced"
        case .authenticating, .permissionDenied, .peerRevoked:
            return nil
        }
    }
}

nonisolated func beakrConsoleTime() -> String {
    let components = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
    return String(
        format: "%02d:%02d:%02d",
        components.hour ?? 0,
        components.minute ?? 0,
        components.second ?? 0
    )
}

nonisolated func beakrConsolePlatformPrefix() -> String {
    #if os(macOS)
    "[macOS]"
    #else
    "[iOS]"
    #endif
}

/// Shared production delivery operations, independently exercisable without
/// starting discovery, trust services, or a live network profile.
nonisolated enum ApplicationDeliveryPipeline {
    static func acknowledge(
        _ acknowledgement: DeliveryAcknowledgement,
        state: PersistentDataState,
        deliveryUpdates: ApplicationDeliveryUpdates
    ) async {
        let pending = try? await state.pending()
        let correlationID = pending?
            .first(where: { $0.messageID == acknowledgement.messageID })
            .flatMap { try? DataCodec().decode(envelope: $0).correlationID.rawValue }
        let removed = (try? await state.acknowledge(
            acknowledgement.messageID
        )) ?? false
        if removed, let correlationID {
            await deliveryUpdates.recordDelivered(correlationID: correlationID)
        }
        BeakrDiagnosticLog.emit("\(beakrConsolePlatformPrefix()) [Beakr Delivery] acknowledged \(acknowledgement.messageID.rawValue), removed=\(removed)", level: .debug, logger: BeakrDiagnosticLog.runtime)
    }

    static func runRetries(
        messaging: PersistentHostMessagingService,
        isRunning: @escaping @Sendable () async -> Bool
    ) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(2))
                try await messaging.retryPending()
            } catch is CancellationError {
                return
            } catch {
                // A missing or changing LAN route is expected while peers appear,
                // disappear, or reconnect. The durable queue remains authoritative.
            }
            guard await isRunning() else { return }
        }
    }
}
