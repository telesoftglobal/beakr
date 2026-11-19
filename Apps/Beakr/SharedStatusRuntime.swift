import Foundation
import BeakrNetCore
import BeakrNetData
import BeakrNetHost

nonisolated struct SharedStatusAvailability: Equatable, Sendable {
    var bindingID: UUID?
    var sharing = false
    static let unavailable = SharedStatusAvailability()
}

/// Selected-runtime adapter. Its closures are supplied by trusted app composition, never by a peer.
actor SharedStatusRuntime {
    typealias Resolve = @Sendable (NodeID) async -> ProfileApplicationRoute?
    typealias Submit = @Sendable (BeakrNetEnvelope, UUID) async -> HostDeliveryAttempt
    private struct Slot {
        let bindingID = UUID()
        let route: ProfileApplicationRoute
        let client: SharedStatusClient
        let responder: SharedStatusResponder
        var sharing = false
        var revision = UUID()
    }
    private struct Observer {
        let peer: NodeID
        let continuation: AsyncStream<SharedStatusAvailability>.Continuation
    }

    nonisolated let profileID: UUID
    private let runtimeID = UUID()
    private let networkID: NetworkID
    private let localNodeID: NodeID
    private let sample: @Sendable () async throws -> SharedStatusSnapshot
    private let events: @Sendable (SharedStatusEvent) -> Void
    private var resolve: Resolve = { _ in nil }
    private var submit: Submit = { _, _ in .routeUnavailable }
    private var nextSequence: @Sendable (NodeID) async -> UInt64 = { _ in 0 }
    private var slots: [NodeID: Slot] = [:]
    private var observers: [UUID: Observer] = [:]
    private var active = true
    private let capacity = 64
    private let permissions: SharedStatusPermissionStore?
    private let persistentPermissions: Bool
    private let authorizationSnapshot: @Sendable () async -> ProfileServiceAuthorizationSnapshot?
    private var permissionTask: Task<Void, Never>?
    private(set) var monitoring: StatusMonitor?
    private let beforeDisclosureCommit: (@Sendable () async -> Void)?

    init(profileID: UUID, networkID: NetworkID, localNodeID: NodeID,
         permissions: SharedStatusPermissionStore? = nil,
         persistentPermissions: Bool = false,
         authorizationSnapshot: @escaping @Sendable () async -> ProfileServiceAuthorizationSnapshot? = { nil },
         beforeDisclosureCommit: (@Sendable () async -> Void)? = nil,
         events: @escaping @Sendable (SharedStatusEvent) -> Void = { _ in },
         sample: @escaping @Sendable () async throws -> SharedStatusSnapshot) {
        self.beforeDisclosureCommit = beforeDisclosureCommit
        self.permissions = permissions
        self.persistentPermissions = persistentPermissions
        self.authorizationSnapshot = authorizationSnapshot
        self.profileID = profileID
        self.networkID = networkID
        self.localNodeID = localNodeID
        self.events = events
        self.sample = sample
    }

    func configure(resolve: @escaping Resolve, submit: @escaping Submit,
                   nextSequence: @escaping @Sendable (NodeID) async -> UInt64) {
        guard active else { return }
        self.resolve = resolve
        self.submit = submit
        self.nextSequence = nextSequence
        if let permissions, permissionTask == nil {
            let local = localNodeID
            permissionTask = Task { [weak self] in
                for await _ in await permissions.updates(for: local) {
                    guard !Task.isCancelled else { return }
                    await self?.revalidate()
                }
            }
        }
    }

    func configureMonitoring(permissions: SharedStatusPermissionStore?) async {
        guard active, monitoring == nil else { return }
        let service = StatusMonitor(profileID: profileID, network: networkID, local: localNodeID,
            permissions: permissions, authorization: authorizationSnapshot, resolve: resolve,
            submit: submit, nextSequence: nextSequence, sample: sample)
        monitoring = service
        await service.observePermissions()
    }

    func updates(for peer: NodeID) async -> AsyncStream<SharedStatusAvailability> {
        let (stream, continuation) = AsyncStream<SharedStatusAvailability>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard active, observers.count < capacity else {
            continuation.yield(.unavailable); continuation.finish(); return stream
        }
        let id = UUID()
        observers[id] = Observer(peer: peer, continuation: continuation)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        _ = await slot(for: peer)
        publish(peer)
        return stream
    }

    func availability(for peer: NodeID) async -> SharedStatusAvailability {
        _ = await slot(for: peer)
        return current(peer)
    }

    func setSharing(_ enabled: Bool, peer: NodeID, bindingID: UUID) async throws {
        guard var slot = await slot(for: peer), slot.bindingID == bindingID else { throw SharedStatusError.unavailable }
        if persistentPermissions {
            guard let permissions else { throw SharedStatusPermissionError.unavailable }
            let state = await permissions.state(for: peer)
            try await setSavedSharing(enabled, peer: peer, expectedRevision: state.revision)
            return
        }
        slot.sharing = enabled
        slot.revision = UUID()
        slots[peer] = slot
        await slot.responder.setEnabled(enabled)
        publish(peer)
    }

    func setSavedSharing(_ enabled: Bool, peer: NodeID, expectedRevision: UUID) async throws {
        guard active, let permissions, permissions.operation == .read,
              permissions.profile.id.rawValue == profileID, permissions.profile.networkID == networkID,
              permissions.profile.localNodeID == localNodeID,
              let snapshot = await authorizationSnapshot(), active, snapshot.networkID == networkID,
              let identity = SharedStatusPermissionIdentity(snapshot: snapshot, local: localNodeID, peer: peer),
              snapshot.eligibleSessions[localNodeID] != nil, snapshot.eligibleSessions[peer] != nil,
              !snapshot.invalidatedCredentialIDs.contains(identity.localCredential),
              !snapshot.invalidatedCredentialIDs.contains(identity.remoteCredential)
        else { throw SharedStatusPermissionError.unavailable }
        // Saving deliberate intent needs verified membership, not an online transport.
        // Disclosure still checks the current authenticated route and permission revision.
        await permissions.reconcile(snapshot)
        try await permissions.setSharing(enabled, peer: peer, identity: identity, expectedRevision: expectedRevision)
        await revalidate()
    }

    /// Rechecks both endpoints using one verified directory snapshot. No saved display data.
    private func permissionRevision(peer: NodeID, route: ProfileApplicationRoute) async -> UUID? {
        guard active, let permissions, permissions.operation == .read,
              permissions.profile.id.rawValue == profileID, permissions.profile.networkID == networkID,
              permissions.profile.localNodeID == localNodeID,
              let snapshot = await authorizationSnapshot(), active,
              snapshot.networkID == networkID else { return nil }
        await permissions.reconcile(snapshot)
        guard let localSession = snapshot.eligibleSessions[localNodeID],
              let peerSession = snapshot.eligibleSessions[peer],
              let identity = SharedStatusPermissionIdentity(snapshot: snapshot, local: localNodeID, peer: peer),
              route.sessionID == (localNodeID.rawValue.uuidString < peer.rawValue.uuidString ? peerSession : localSession)
        else { return nil }
        return await permissions.authorization(for: peer, identity: identity)
    }

    func request(peer: NodeID, bindingID: UUID) async throws -> SharedStatusResult {
        guard let slot = await slot(for: peer), slot.bindingID == bindingID else { throw SharedStatusError.unavailable }
        let sequence = await nextSequence(peer)
        guard active, slots[peer]?.route == slot.route else { throw SharedStatusError.invalidated }
        return try await slot.client.request(sequence: sequence) { [weak self] envelope in
            guard let self else { return .routeUnavailable }
            return await self.send(envelope, peer: peer, route: slot.route, disclosureRevision: nil)
        }
    }

    /// Returns nil for ordinary inbox traffic, false for all status traffic (no durable storage ACK).
    func receive(_ envelope: BeakrNetEnvelope, peer: NodeID, route: ProfileApplicationRoute) async -> Bool? {
        if let monitoring, let handled = await monitoring.receive(envelope, peer: peer, route: route) { return handled }
        guard envelope.payloadType == DataMessage.payloadType,
              let message = try? DataCodec().decode(envelope: envelope),
              message.operation.namespace == SharedStatusProtocol.operation.namespace else { return nil }
        guard let slot = await slot(for: peer), slot.route == route else { return false }
        if message.kind == .request {
            let revision = slot.revision
            guard let response = await slot.responder.receive(envelope, authenticatedPeer: peer),
                  active, slots[peer]?.route == route else { return false }
            let sequence = await nextSequence(peer)
            let now = Date()
            guard let deadline = envelope.deliveryPolicy.expiresAt,
                  let reply = try? SharedStatusProtocol.envelope(
                    response, binding: binding(peer, route), sequence: sequence,
                    now: now, expiresAt: deadline
                  ) else { return false }
            // Error replies disclose no snapshot and may explain default-denied access.
            _ = await send(reply, peer: peer, route: route,
                           disclosureRevision: response.kind == .response ? revision : nil)
        } else {
            await slot.client.receive(envelope, authenticatedPeer: peer)
        }
        return false
    }

    func routeEnded(peer: NodeID, routeID: UUID) async {
        await monitoring?.disconnected(peer: peer)
        guard slots[peer]?.route.id == routeID else { return }
        await discard(peer)
    }

    func authorizationEnded(peer: NodeID) async {
        await monitoring?.disconnected(peer: peer)
        if let permissions, let snapshot = await authorizationSnapshot() { await permissions.reconcile(snapshot) }
        await discard(peer)
    }

    /// Uses existing runtime maintenance/peer events, not an additional polling timer.
    func revalidate() async {
        await monitoring?.revalidate()
        if let permissions, let snapshot = await authorizationSnapshot(), active {
            await permissions.reconcile(snapshot)
        }
        let peers = Set(slots.keys).union(observers.values.map(\.peer))
        for peer in peers { _ = await slot(for: peer); publish(peer) }
    }

    func invalidate() async {
        active = false
        await monitoring?.invalidate()
        monitoring = nil
        permissionTask?.cancel()
        permissionTask = nil
        resolve = { _ in nil }
        submit = { _, _ in .routeUnavailable }
        nextSequence = { _ in 0 }
        let old = slots
        slots.removeAll()
        for observer in observers.values {
            observer.continuation.yield(.unavailable)
            observer.continuation.finish()
        }
        observers.removeAll()
        for slot in old.values {
            await slot.client.invalidate()
            await slot.responder.invalidate()
        }
    }

    private func binding(_ peer: NodeID, _ route: ProfileApplicationRoute) -> SharedStatusBinding {
        SharedStatusBinding(runtimeID: runtimeID, networkID: networkID, localNodeID: localNodeID,
                            peerNodeID: peer, sessionID: route.sessionID)
    }

    private func slot(for peer: NodeID) async -> Slot? {
        guard active, peer != localNodeID else { return nil }
        let route = await resolve(peer)
        guard active else { return nil }
        guard let route else { await discard(peer); return nil }
        if let slot = slots[peer], slot.route == route { return await refreshPermission(peer, slot: slot) }
        // Remove and invalidate old capabilities before creating a new default-denied one.
        if slots[peer] != nil { await discard(peer) }
        guard active, slots.count < capacity else { return nil }
        // Another caller may have installed this route while invalidation suspended.
        if let installed = slots[peer] { return installed.route == route ? installed : nil }
        let binding = binding(peer, route)
        let slot = Slot(route: route,
                        client: SharedStatusClient(binding: binding, enabled: true, eventSink: events),
                        responder: SharedStatusResponder(binding: binding, eventSink: events, sample: sample))
        slots[peer] = slot
        publish(peer)
        return await refreshPermission(peer, slot: slot)
    }

    private func refreshPermission(_ peer: NodeID, slot: Slot) async -> Slot? {
        guard persistentPermissions else { return slot }
        let revision = await permissionRevision(peer: peer, route: slot.route)
        guard active, var current = slots[peer], current.bindingID == slot.bindingID else { return nil }
        let enabled = revision != nil
        if current.sharing != enabled || (enabled && current.revision != revision) {
            current.sharing = enabled
            current.revision = revision ?? UUID()
            slots[peer] = current
            await current.responder.setEnabled(enabled)
            publish(peer)
        }
        return slots[peer]
    }

    private func send(_ envelope: BeakrNetEnvelope, peer: NodeID, route: ProfileApplicationRoute,
                      disclosureRevision: UUID?) async -> HostDeliveryAttempt {
        guard active, await resolve(peer) == route, active,
              let slot = slots[peer], slot.route == route else { return .routeUnavailable }
        if let disclosureRevision {
            if persistentPermissions {
                guard await permissionRevision(peer: peer, route: route) == disclosureRevision,
                      active, slots[peer]?.bindingID == slot.bindingID else { return .routeUnavailable }
            }
            guard slot.sharing, slot.revision == disclosureRevision else { return .routeUnavailable }
        }
        guard !Task.isCancelled, (try? envelope.validate()) != nil else { return .routeUnavailable }
        if let disclosureRevision, persistentPermissions {
            // Optional scheduling seam for deterministic handoff tests; nil in production.
            if let beforeDisclosureCommit { await beforeDisclosureCommit() }
            guard active, !Task.isCancelled, slots[peer]?.bindingID == slot.bindingID,
                  let permissions,
                  let committed = await permissions.commitDisclosure(for: peer, expectedRevision: disclosureRevision,
                      submit: { [weak self] in
                          guard let self else { return .routeUnavailable }
                          return await self.submitCommitted(envelope, peer: peer, route: route, bindingID: slot.bindingID)
                      }) else { return .routeUnavailable }
            return await withTaskCancellationHandler {
                await committed.value
            } onCancel: {
                committed.cancel()
            }
        }
        return await submit(envelope, route.id)
    }

    private func submitCommitted(_ envelope: BeakrNetEnvelope, peer: NodeID,
                                 route: ProfileApplicationRoute, bindingID: UUID) async -> HostDeliveryAttempt {
        guard active, !Task.isCancelled, slots[peer]?.bindingID == bindingID,
              await resolve(peer) == route, active, slots[peer]?.bindingID == bindingID,
              !Task.isCancelled else { return .routeUnavailable }
        return await submit(envelope, route.id)
    }

    private func discard(_ peer: NodeID) async {
        guard let old = slots.removeValue(forKey: peer) else { return }
        publish(peer)
        await old.client.invalidate()
        await old.responder.invalidate()
    }

    private func current(_ peer: NodeID) -> SharedStatusAvailability {
        guard active, let slot = slots[peer] else { return .unavailable }
        return SharedStatusAvailability(bindingID: slot.bindingID, sharing: slot.sharing)
    }

    private func publish(_ peer: NodeID) {
        for observer in observers.values where observer.peer == peer { observer.continuation.yield(current(peer)) }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}
