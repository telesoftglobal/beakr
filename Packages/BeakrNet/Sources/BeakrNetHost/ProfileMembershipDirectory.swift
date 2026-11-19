import Foundation
import BeakrNetAuthority
import BeakrNetCore

public enum ProfileMembershipDirectoryError: Error, Equatable, Sendable {
    case snapshotTooLarge(maximumBytes: Int)
    case noncanonicalSnapshot
    case generationRollback
    case generationConflict
}

/// One actor-isolated observation of verified membership and current eligibility.
/// Records alone are historical authority evidence; only eligibleSessions authorizes use.
public struct ProfileServiceAuthorizationSnapshot: Sendable {
    public let networkID: NetworkID
    public let authorityPublicKey: Data
    public let environment: String
    public let records: [NodeID: ProfileMembershipRecord]
    public let eligibleSessions: [NodeID: SessionID]
    public let invalidatedCredentialIDs: Set<UUID>
}

public actor ProfileMembershipDirectory {
    public let fileURL: URL
    public let networkID: NetworkID
    public let maximumRecords: Int
    public let maximumSnapshotBytes: Int

    private let environment: String
    private let trustedAuthorityPublicKey: Data
    private let now: @Sendable () -> Date
    private var revokedCredentialIDs: Set<UUID>
    private var snapshot: ProfileMembershipSnapshot?
    private var recordsByCertificateKey: [Data: ProfileMembershipRecord] = [:]
    private var recordsByNodeID: [NodeID: ProfileMembershipRecord] = [:]
    private var removedCredentialIDs: Set<UUID> = []

    private init(
        fileURL: URL,
        networkID: NetworkID,
        environment: String,
        trustedAuthorityPublicKey: Data,
        revokedCredentialIDs: Set<UUID>,
        maximumRecords: Int,
        maximumSnapshotBytes: Int,
        now: @escaping @Sendable () -> Date
    ) {
        self.fileURL = fileURL
        self.networkID = networkID
        self.environment = environment
        self.trustedAuthorityPublicKey = trustedAuthorityPublicKey
        self.revokedCredentialIDs = revokedCredentialIDs
        self.maximumRecords = maximumRecords
        self.maximumSnapshotBytes = maximumSnapshotBytes
        self.now = now
    }

    public static func open(
        fileURL: URL,
        networkID: NetworkID,
        environment: String,
        trustedAuthorityPublicKey: Data,
        revokedCredentialIDs: Set<UUID>,
        maximumRecords: Int = 1_024,
        maximumSnapshotBytes: Int = 2_097_152,
        now: @escaping @Sendable () -> Date = Date.init
    ) async throws -> ProfileMembershipDirectory {
        precondition(maximumRecords > 0 && maximumSnapshotBytes > 0)
        let directory = ProfileMembershipDirectory(
            fileURL: fileURL,
            networkID: networkID,
            environment: environment,
            trustedAuthorityPublicKey: trustedAuthorityPublicKey,
            revokedCredentialIDs: revokedCredentialIDs,
            maximumRecords: maximumRecords,
            maximumSnapshotBytes: maximumSnapshotBytes,
            now: now
        )
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= maximumSnapshotBytes else {
                throw ProfileMembershipDirectoryError.snapshotTooLarge(
                    maximumBytes: maximumSnapshotBytes
                )
            }
            let decoded = try JSONDecoder().decode(ProfileMembershipSnapshot.self, from: data)
            guard try Self.encoder().encode(decoded) == data else {
                throw ProfileMembershipDirectoryError.noncanonicalSnapshot
            }
            try await directory.activate(decoded)
        }
        return directory
    }

    public func activate(_ proposed: ProfileMembershipSnapshot) throws {
        if let current = snapshot {
            guard proposed.claims.generation >= current.claims.generation else {
                throw ProfileMembershipDirectoryError.generationRollback
            }
            if proposed.claims.generation == current.claims.generation {
                guard proposed == current else {
                    throw ProfileMembershipDirectoryError.generationConflict
                }
                return
            }
        }
        try ProfileMembershipVerifier.verify(
            proposed,
            networkID: networkID,
            environment: environment,
            trustedAuthorityPublicKey: trustedAuthorityPublicKey,
            revokedCredentialIDs: revokedCredentialIDs,
            maximumRecords: maximumRecords,
            now: now()
        )
        let data = try Self.encoder().encode(proposed)
        guard data.count <= maximumSnapshotBytes else {
            throw ProfileMembershipDirectoryError.snapshotTooLarge(
                maximumBytes: maximumSnapshotBytes
            )
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        let nextCredentials = Set(proposed.claims.records.map { $0.credential.claims.credentialID })
        removedCredentialIDs.formUnion(recordsByNodeID.values.map { $0.credential.claims.credentialID }.filter {
            !nextCredentials.contains($0)
        })
        snapshot = proposed
        recordsByCertificateKey = Dictionary(
            uniqueKeysWithValues: proposed.claims.records.map {
                ($0.certificatePublicKey, $0)
            }
        )
        recordsByNodeID = Dictionary(
            uniqueKeysWithValues: proposed.claims.records.map {
                ($0.credential.claims.nodeID, $0)
            }
        )
    }

    public func updateRevokedCredentialIDs(_ revoked: Set<UUID>) {
        revokedCredentialIDs = revoked
    }

    public func resolve(certificatePublicKey: Data) -> ProfileAcceptedPeerContext? {
        guard let record = recordsByCertificateKey[certificatePublicKey],
              !revokedCredentialIDs.contains(record.credential.claims.credentialID),
              (try? CredentialVerifier.verify(
                record.credential,
                trustedAuthorityPublicKey: trustedAuthorityPublicKey,
                networkID: networkID,
                environment: environment,
                revokedCredentialIDs: revokedCredentialIDs,
                now: now()
              )) != nil
        else { return nil }
        return ProfileAcceptedPeerContext(
            expectedPeerNodeID: record.credential.claims.nodeID,
            sessionID: record.sessionID
        )
    }

    public func sessionID(for nodeID: NodeID) -> SessionID? {
        guard let record = recordsByNodeID[nodeID],
              resolve(certificatePublicKey: record.certificatePublicKey) != nil else {
            return nil
        }
        return record.sessionID
    }

    /// Returns the shared session identifier for a peer pair. Bonjour's
    /// canonical ordering makes the lower node ID initiate the connection, so
    /// both endpoints use the higher node ID's authority-issued session ID.
    public func connectionSessionID(localNodeID: NodeID, peerNodeID: NodeID) -> SessionID? {
        // Canonical session ownership does not establish the other endpoint's eligibility.
        guard let localSession = sessionID(for: localNodeID),
              let peerSession = sessionID(for: peerNodeID) else { return nil }
        return localNodeID.rawValue.uuidString < peerNodeID.rawValue.uuidString
            ? peerSession
            : localSession
    }

    /// Returns only currently valid, non-revoked members from the signed snapshot.
    public func memberNodeIDs() -> [NodeID] {
        recordsByNodeID.keys
            .filter { sessionID(for: $0) != nil }
            .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    public nonisolated func acceptedPeerResolver(
        refreshUnknownPeer: @escaping @Sendable () async -> Void = {}
    ) -> ProfileAcceptedPeerResolver {
        { [weak self] connection in
            guard let key = try? connection.peerCertificate().publicKeyRepresentation else {
                return nil
            }
            if let peer = await self?.resolve(certificatePublicKey: key) { return peer }
            await refreshUnknownPeer()
            guard !Task.isCancelled else { return nil }
            return await self?.resolve(certificatePublicKey: key)
        }
    }

    /// Identifiers from the verified snapshot, for matching revocation evidence in presentation.
    public func memberCredentialIDs() -> [NodeID: UUID] {
        recordsByNodeID.mapValues { $0.credential.claims.credentialID }
    }

    public func serviceAuthorizationSnapshot() -> ProfileServiceAuthorizationSnapshot? {
        guard snapshot != nil else { return nil }
        var sessions: [NodeID: SessionID] = [:]
        for node in recordsByNodeID.keys { sessions[node] = sessionID(for: node) }
        return ProfileServiceAuthorizationSnapshot(
            networkID: networkID, authorityPublicKey: trustedAuthorityPublicKey,
            environment: environment, records: recordsByNodeID, eligibleSessions: sessions,
            invalidatedCredentialIDs: revokedCredentialIDs.union(removedCredentialIDs)
        )
    }

    public func generation() -> UInt64? { snapshot?.claims.generation }
    public func networkDisplayName() -> String? { snapshot?.claims.networkDisplayName }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
