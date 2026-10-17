import Foundation
import Network
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetData
import BeakrNetHost

enum ApplicationLANRuntimeError: Error {
    case missingRevocationSnapshot
    case missingMembershipSnapshot
    case alreadyRunning
    case notRunning
}

actor ApplicationLANRuntimeManager: ApplicationLANRuntimeManaging, OutgoingProvenanceMessagingService {
    static let remembersPreviouslyConnectedDevicesKey = "net.beakr.settings.remembersPreviouslyConnectedDevices"
    private let inbox: ApplicationMessageInbox
    private let deliveryUpdates: ApplicationDeliveryUpdates
    private let mailboxMetadataAttachment: @MainActor @Sendable (URL?) -> Void
    private var runtime: ProfileBonjourRuntimeService?
    private var routePolicy: ProfileRoutePolicyController?
    private var trustMaintenance: ProfileTrustMaintenanceController?
    private var membership: ProfileMembershipDirectory?
    private var messaging: PersistentHostMessagingService?
    private var connections: ProfileConnectionRegistry?
    private var maintenanceTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var provenanceContext: MessageProvenanceContext?
    private var memberMetadataURL: URL?
    private var memberMetadata: [UUID: NetworkMemberMetadata] = [:]
    private var remembersPreviouslyConnectedDevices: Bool

    init(
        inbox: ApplicationMessageInbox = ApplicationMessageInbox(),
        deliveryUpdates: ApplicationDeliveryUpdates = ApplicationDeliveryUpdates(),
        mailboxMetadataAttachment: @escaping @MainActor @Sendable (URL?) -> Void = { _ in }
    ) {
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
        guard runtime == nil else { throw ApplicationLANRuntimeError.alreadyRunning }
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
                print("[Beakr Members] saved member metadata could not be opened: \(error)")
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
        let authorityTransport = try configuration.makeTransport()
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
            eventSink: { print("[Beakr Membership] \($0)") }
        )
        let revocationRefresh = RevocationRefreshController(
            distributor: distributor,
            requester: RevocationSnapshotNetworkClient(transport: authorityTransport),
            store: snapshotStore,
            policy: try RevocationRefreshPolicy()
        )
        let trustMaintenance = ProfileTrustMaintenanceController(
            revocationRefresh: revocationRefresh,
            revocations: distributor,
            membershipDirectory: membership,
            membershipRefresh: membershipRefresh
        )
        let restoredMembership = await membership.generation() != nil
        let initialMaintenance = await trustMaintenance.refreshNow(
            revocationTrigger: .startup,
            membershipTrigger: .startup
        )
        print("[Beakr Trust] revocations=\(initialMaintenance.revocations) membership=\(initialMaintenance.membership)")
        if !restoredMembership {
            switch initialMaintenance.membership {
            case .activated:
                break
            case .unchanged, .failed:
                throw ApplicationLANRuntimeError.missingMembershipSnapshot
            }
        }

        guard let currentRevocationSnapshot = try snapshotStore.loadSnapshot() else {
            throw ApplicationLANRuntimeError.missingRevocationSnapshot
        }

        let routePolicy = ProfileRoutePolicyController()
        let connections = ProfileConnectionRegistry(
            networkID: applicationRuntime.profile.networkID,
            localNodeID: applicationRuntime.profile.localNodeID,
            revocations: distributor,
            routePolicy: routePolicy,
            incomingEnvelopeSink: { [inbox] envelope in
                print("[Beakr Delivery] received \(envelope.messageID.rawValue)")
                await inbox.record(envelope)
            },
            deliveryAcknowledgementSink: { [deliveryUpdates] acknowledgement in
                let pending = try? await applicationRuntime.dataState.pending()
                let correlationID = pending?
                    .first(where: { $0.messageID == acknowledgement.messageID })
                    .flatMap { try? DataCodec().decode(envelope: $0).correlationID.rawValue }
                let removed = (try? await applicationRuntime.dataState.acknowledge(
                    acknowledgement.messageID
                )) ?? false
                if removed, let correlationID {
                    await deliveryUpdates.recordDelivered(correlationID: correlationID)
                }
                print("[Beakr Delivery] acknowledged \(acknowledgement.messageID.rawValue), removed=\(removed)")
            }
        )
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
                print("[Beakr Delivery] submit \(envelope.messageID.rawValue): \(result)")
                return result
            }
        )
        var generator = SystemRandomNumberGenerator()
        let advertisementNonce = Data(
            (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        )
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
                await membership.connectionSessionID(
                    localNodeID: applicationRuntime.profile.localNodeID,
                    peerNodeID: nodeID
                )
            },
            acceptedPeer: membership.acceptedPeerResolver(),
            bonjourDiagnosticSink: { print("[Beakr Bonjour] \($0)") },
            transportDiagnosticSink: { print("[Beakr LAN] \($0)") },
            runtimeDiagnosticSink: { print("[Beakr Runtime] \($0)") }
        )
        await routePolicy.setAllRoutesPermitted(true)
        await routePolicy.setLANPermitted(true)
        try Task.checkCancellation()
        await runtime.start()
        self.routePolicy = routePolicy
        self.trustMaintenance = trustMaintenance
        self.membership = membership
        self.messaging = messaging
        self.connections = connections
        self.runtime = runtime
        self.memberMetadataURL = memberMetadataURL
        self.memberMetadata = memberMetadata
        if !remembersPreviouslyConnectedDevices, let memberMetadataURL {
            do {
                try NetworkMemberMetadataStore.save([:], to: memberMetadataURL)
            } catch {
                print("[Beakr Members] saved member metadata could not be cleared: \(error)")
            }
        }
        try await messaging.retryPending()
        deliveryTask = Task { [weak self, messaging] in
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
                guard await self?.running() == true else { return }
            }
        }
        maintenanceTask = Task { [weak self, trustMaintenance] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15 * 60))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                _ = await trustMaintenance.refreshNow(
                    revocationTrigger: .scheduled,
                    membershipTrigger: .scheduled
                )
                guard await self?.running() == true else { return }
            }
        }
    }

    func stop() async {
        deliveryTask?.cancel()
        deliveryTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        await mailboxMetadataAttachment(nil)
        guard let runtime else { return }
        if let routePolicy {
            await routePolicy.setLANPermitted(false)
            await routePolicy.setAllRoutesPermitted(false)
        }
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
    }

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
        let authenticatedIDs = await authenticatedPeerIDs()
        let nodeIDs = await membership.memberNodeIDs()
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
                lastSeen: knownMetadata?.lastSeen
            )
        }

        if remembersPreviouslyConnectedDevices, metadataChanged, let memberMetadataURL {
            do {
                try NetworkMemberMetadataStore.save(memberMetadata, to: memberMetadataURL)
            } catch {
                print("[Beakr Members] member metadata could not be saved: \(error)")
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
            print("[Beakr Members] saved member metadata could not be cleared: \(error)")
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
                print("[Beakr Members] member metadata could not be saved after forgetting a device: \(error)")
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
