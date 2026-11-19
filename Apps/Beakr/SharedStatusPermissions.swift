import Foundation
import BeakrNetCore
import BeakrNetHost
import BeakrNetAuthority

nonisolated enum StatusPermissionOperation: String, Sendable, Hashable {
    case read = "beakr.status/read/v1"
    case monitor = "beakr.status.monitor/subscribe/v1"

    var filename: String {
        switch self {
        case .read: "shared-status-permissions.json"
        case .monitor: "status-monitor-permissions.json"
        }
    }
}

nonisolated enum SharedStatusPermissionError: Error, Equatable, Sendable {
    case invalidStore, persistenceFailed, staleRevision, unavailable
}

/// Pins membership authority, not a transport certificate or a connection/session identifier.
nonisolated struct SharedStatusPermissionIdentity: Codable, Equatable, Sendable {
    let authorityKey: Data
    let environment: String
    let localCredential: UUID
    let localKey: Data
    let remoteCredential: UUID
    let remoteKey: Data

    init?(snapshot: ProfileServiceAuthorizationSnapshot, local: NodeID, peer: NodeID) {
        guard let localClaims = snapshot.records[local]?.credential.claims,
              let peerClaims = snapshot.records[peer]?.credential.claims else { return nil }
        authorityKey = snapshot.authorityPublicKey
        environment = snapshot.environment
        localCredential = localClaims.credentialID
        localKey = localClaims.nodePublicKey
        remoteCredential = peerClaims.credentialID
        remoteKey = peerClaims.nodePublicKey
    }
}

nonisolated struct SharedStatusPermissionState: Equatable, Sendable {
    var sharing = false
    var needsConfirmation = false
    var saveFailed = false
    var revision = UUID()
}

/// One writer per profile. File operations do not suspend, so a completed older write
/// cannot overwrite a newer withdrawal. No credentials, snapshots or chat are stored here.
actor SharedStatusPermissionStore {
    nonisolated let profile: NetworkProfile
    private let fileURL: URL
    private let write: @Sendable (Data, URL) throws -> Void
    private struct Grant: Codable {
        let peer: UUID
        let operation: String
        let identity: SharedStatusPermissionIdentity
        var needsConfirmation: Bool
    }
    private struct Document: Codable {
        var version = 1
        let profileID: UUID
        let networkID: UUID
        let localNodeID: UUID
        var sessionOpen: Bool
        var grants: [Grant]
    }
    private var document: Document
    private var revision = UUID()
    private var saveFailed = false
    private var retired = false
    // Bounded, process-local evidence for explaining the end of an active monitor.
    // This is not authorization and is never persisted.
    private var explicitWithdrawals: [(peer: NodeID, revision: UUID)] = []

    func wasExplicitlyWithdrawn(peer: NodeID, revision: UUID) -> Bool {
        explicitWithdrawals.contains { $0.peer == peer && $0.revision == revision }
    }
    private var observers: [UUID: (UUID, AsyncStream<SharedStatusPermissionState>.Continuation)] = [:]
    nonisolated let operation: StatusPermissionOperation
    private static let maximumBytes = 1_048_576
    private static let maximumGrants = 1_024

    init(profile: NetworkProfile, fileURL: URL, operation: StatusPermissionOperation = .read,
         write: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
             try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
             try data.write(to: url, options: .atomic)
         }) throws {
        self.operation = operation
        self.profile = profile
        self.fileURL = fileURL
        self.write = write
        var loaded = Document(profileID: profile.id.rawValue, networkID: profile.networkID.rawValue,
                              localNodeID: profile.localNodeID.rawValue, sessionOpen: false, grants: [])
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumBytes else { throw SharedStatusPermissionError.invalidStore }
            let data = try Data(contentsOf: fileURL)
            guard data.count <= Self.maximumBytes else { throw SharedStatusPermissionError.invalidStore }
            loaded = try JSONDecoder().decode(Document.self, from: data)
            guard loaded.version == 1, loaded.profileID == profile.id.rawValue,
                  loaded.networkID == profile.networkID.rawValue, loaded.localNodeID == profile.localNodeID.rawValue,
                  loaded.grants.count <= Self.maximumGrants,
                  Set(loaded.grants.map(\.peer)).count == loaded.grants.count,
                  loaded.grants.allSatisfy({ $0.operation == operation.rawValue && $0.peer != profile.localNodeID.rawValue })
            else { throw SharedStatusPermissionError.invalidStore }
        }
        // An interrupted session might have withdrawn access without completing its save.
        if loaded.sessionOpen {
            for index in loaded.grants.indices { loaded.grants[index].needsConfirmation = true }
        }
        loaded.sessionOpen = true
        try write(JSONEncoder().encode(loaded), fileURL)
        document = loaded
    }

    func state(for peer: NodeID) -> SharedStatusPermissionState {
        let grant = document.grants.first { $0.peer == peer.rawValue }
        return SharedStatusPermissionState(
            sharing: grant != nil && grant?.needsConfirmation == false && !saveFailed && !retired,
            needsConfirmation: grant?.needsConfirmation == true,
            saveFailed: saveFailed, revision: revision
        )
    }

    func updates(for peer: NodeID) -> AsyncStream<SharedStatusPermissionState> {
        let (stream, continuation) = AsyncStream<SharedStatusPermissionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard observers.count < 64 else { continuation.finish(); return stream }
        let id = UUID()
        observers[id] = (peer.rawValue, continuation)
        continuation.yield(state(for: peer))
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    /// Withdrawal is independent of presence. Enable requires trusted current identity.
    func setSharing(_ enabled: Bool, peer: NodeID, identity: SharedStatusPermissionIdentity?,
                    expectedRevision: UUID) throws {
        guard !retired else { throw SharedStatusPermissionError.unavailable }
        guard revision == expectedRevision else { throw SharedStatusPermissionError.staleRevision }
        guard peer != profile.localNodeID else { throw SharedStatusPermissionError.unavailable }
        if enabled {
            guard let identity, !saveFailed else { throw SharedStatusPermissionError.unavailable }
            guard document.grants.count < Self.maximumGrants || document.grants.contains(where: { $0.peer == peer.rawValue })
            else { throw SharedStatusPermissionError.unavailable }
            try arm()
            var next = document
            next.grants.removeAll { $0.peer == peer.rawValue }
            next.grants.append(Grant(peer: peer.rawValue, operation: operation.rawValue,
                                     identity: identity, needsConfirmation: false))
            do {
                try persist(next)
                document = next
                changed()
            } catch {
                saveFailed = true
                changed()
                throw SharedStatusPermissionError.persistenceFailed
            }
        } else {
            // Arm before acknowledging a new command after a clean lifecycle checkpoint.
            try arm()
            let previousRevision = revision
            let hadGrant = document.grants.contains { $0.peer == peer.rawValue }
            document.grants.removeAll { $0.peer == peer.rawValue }
            changed()
            try saveCurrent()
            if operation == .monitor, hadGrant {
                explicitWithdrawals.append((peer, previousRevision))
                if explicitWithdrawals.count > 64 { explicitWithdrawals.removeFirst() }
            }
        }
    }

    /// A signed absence/replacement/revocation invalidates intent, while temporary expiry
    /// only affects eligibleSessions and therefore leaves intent intact.
    func reconcile(_ snapshot: ProfileServiceAuthorizationSnapshot) {
        guard !retired, snapshot.networkID == profile.networkID else { return }
        let retained = document.grants.filter { grant in
            guard let identity = SharedStatusPermissionIdentity(snapshot: snapshot, local: profile.localNodeID,
                                                                peer: NodeID(rawValue: grant.peer)),
                  identity == grant.identity else { return false }
            return !snapshot.invalidatedCredentialIDs.contains(identity.localCredential)
                && !snapshot.invalidatedCredentialIDs.contains(identity.remoteCredential)
        }
        guard retained.count != document.grants.count else { return }
        // Even if arming fails, block in memory. A failed arm never enables a capability.
        do { try arm() } catch { saveFailed = true }
        document.grants = retained
        changed()
        try? saveCurrent()
    }

    func authorization(for peer: NodeID, identity: SharedStatusPermissionIdentity) -> UUID? {
        guard !retired, !saveFailed, let grant = document.grants.first(where: { $0.peer == peer.rawValue }),
              !grant.needsConfirmation, grant.identity == identity else { return nil }
        do { try arm() } catch { return nil }
        return revision
    }

    /// The response commit point: validate and enqueue one submission without suspension.
    /// Withdrawal on this actor either precedes this method (no submission) or follows it
    /// (this response is already in flight). This does not promise transport delivery.
    func commitDisclosure(for peer: NodeID, expectedRevision: UUID,
                          submit: @escaping @Sendable () async -> HostDeliveryAttempt) -> Task<HostDeliveryAttempt, Never>? {
        guard !Task.isCancelled, !retired, !saveFailed, revision == expectedRevision,
              let grant = document.grants.first(where: { $0.peer == peer.rawValue }),
              !grant.needsConfirmation else { return nil }
        do { try arm() } catch { return nil }
        return Task {
            guard !Task.isCancelled else { return .routeUnavailable }
            return await submit()
        }
    }

    /// Called only after application runtimes stop, never on an individual peer disconnect.
    func checkpointStopped() {
        guard !retired, !saveFailed else { return } // Leave the durable guard armed after any failed mutation.
        var next = document
        next.sessionOpen = false
        do { try persist(next); document = next }
        catch { saveFailed = true; changed() }
    }

    func retire() {
        retired = true
        document.grants.removeAll()
        changed()
        try? saveCurrent()
        for (_, continuation) in observers.values { continuation.finish() }
        observers.removeAll()
    }

    private func arm() throws {
        guard !document.sessionOpen else { return }
        var next = document
        next.sessionOpen = true
        do { try persist(next); document = next }
        catch {
            saveFailed = true
            changed()
            throw SharedStatusPermissionError.persistenceFailed
        }
    }

    private func saveCurrent() throws {
        do {
            try persist(document)
            saveFailed = false
            changed()
        } catch {
            saveFailed = true
            changed()
            throw SharedStatusPermissionError.persistenceFailed
        }
    }

    private func persist(_ value: Document) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.maximumBytes else { throw SharedStatusPermissionError.invalidStore }
        try write(data, fileURL)
    }

    private func changed() {
        revision = UUID()
        for (peer, continuation) in observers.values {
            continuation.yield(state(for: NodeID(rawValue: peer)))
        }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}

/// App composition owns this object; every window and runtime obtains the same writer.
actor SharedStatusPermissionCoordinator {
    private struct Key: Hashable { let profile: NetworkProfileID; let operation: StatusPermissionOperation }
    private var stores: [Key: SharedStatusPermissionStore] = [:]

    func store(profile: NetworkProfile, rootURL: URL, operation: StatusPermissionOperation = .read) throws -> SharedStatusPermissionStore {
        let key = Key(profile: profile.id, operation: operation)
        if let store = stores[key] {
            guard store.profile.networkID == profile.networkID, store.profile.localNodeID == profile.localNodeID
            else { throw SharedStatusPermissionError.invalidStore }
            return store
        }
        let store = try SharedStatusPermissionStore(
            profile: profile, fileURL: rootURL.appendingPathComponent(operation.filename), operation: operation
        )
        stores[key] = store
        return store
    }

    func checkpointStopped() async {
        for store in stores.values { await store.checkpointStopped() }
    }

    func forget(_ id: NetworkProfileID) async {
        for key in Array(stores.keys) where key.profile == id {
            if let store = stores.removeValue(forKey: key) { await store.retire() }
        }
    }
}
