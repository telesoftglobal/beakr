import Foundation
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetHost

nonisolated struct NetworkMemberMetadata: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var displayName: String?
    var lastSeen: Date?
}

nonisolated enum NetworkMemberMetadataStoreError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
}

nonisolated enum NetworkMemberMetadataStore {
    private nonisolated struct Document: Codable {
        let version: Int
        let members: [NetworkMemberMetadata]
    }

    private static let currentVersion = 1

    nonisolated static func load(from fileURL: URL) throws -> [UUID: NetworkMemberMetadata] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let document = try decoder.decode(Document.self, from: Data(contentsOf: fileURL))
        guard document.version == currentVersion else {
            throw NetworkMemberMetadataStoreError.unsupportedVersion(document.version)
        }
        return Dictionary(uniqueKeysWithValues: document.members.map { ($0.id, $0) })
    }

    nonisolated static func save(_ members: [UUID: NetworkMemberMetadata], to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let document = Document(
            version: currentVersion,
            members: members.values.sorted { $0.id.uuidString < $1.id.uuidString }
        )
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

// Presentation-only saved membership. Never used to authorize connections.
nonisolated struct SavedNetworkMembership: Equatable, Sendable {
    enum State: Equatable, Sendable { case saved, stale, unavailable }
    let members: [NetworkMemberSummary]
    let state: State
    let recordedAt: Date?

    static let unavailable = SavedNetworkMembership(members: [], state: .unavailable, recordedAt: nil)

    var notice: LocalizedStringResource {
        switch state {
        case .saved: "Saved membership · UnObserved"
        case .stale: "Saved membership needs refresh · UnObserved"
        case .unavailable: "Saved membership unavailable · UnObserved"
        }
    }
}

nonisolated enum SavedNetworkMembershipLoader {
    static func load(
        paths: ProfileRuntimePaths,
        profile: NetworkProfile,
        configuration: DevelopmentAuthorityConfiguration,
        metadata: [UUID: NetworkMemberMetadata],
        now: Date = Date()
    ) -> SavedNetworkMembership {
        do {
            let url = paths.membershipSnapshotURL
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2_097_152 else { return .unavailable }
            let data = try Data(contentsOf: url)
            guard data.count <= 2_097_152 else { return .unavailable }
            let snapshot = try JSONDecoder().decode(ProfileMembershipSnapshot.self, from: data)
            let recordedAt = Date(timeIntervalSince1970: Double(snapshot.claims.generatedAtMilliseconds) / 1_000)
            guard recordedAt <= now.addingTimeInterval(60) else { return .unavailable }
            // Verify historical authenticity at the signed snapshot date. Expired
            // credentials may describe saved membership but grant no live access.
            try ProfileMembershipVerifier.verify(
                snapshot, networkID: profile.networkID,
                environment: configuration.credential.claims.environment,
                trustedAuthorityPublicKey: configuration.authorityPublicKey,
                revokedCredentialIDs: [], now: recordedAt
            )
            let revocations = try? CredentialFiles.loadRevocationSnapshot(from: paths.revocationSnapshotURL)
            let revoked = revocations.flatMap {
                try? RevocationVerifier.verify($0, trustedAuthorityPublicKey: configuration.authorityPublicKey)
            }
            let currentlyValid = (try? ProfileMembershipVerifier.verify(
                snapshot, networkID: profile.networkID,
                environment: configuration.credential.claims.environment,
                trustedAuthorityPublicKey: configuration.authorityPublicKey,
                revokedCredentialIDs: revoked ?? [], now: now
            )) != nil
            let members = snapshot.claims.records.compactMap { record -> NetworkMemberSummary? in
                let credential = record.credential.claims
                guard credential.nodeID != profile.localNodeID,
                      !(revoked ?? []).contains(credential.credentialID) else { return nil }
                let id = credential.nodeID.rawValue
                let saved = metadata[id]
                return NetworkMemberSummary(
                    id: id, displayName: saved?.displayName ?? "Network Device \(id.uuidString.suffix(8))",
                    isPlaceholderName: saved?.displayName == nil,
                    lastSeen: saved?.lastSeen, credentialID: credential.credentialID
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            return SavedNetworkMembership(members: members,
                state: currentlyValid && revoked != nil ? .saved : .stale, recordedAt: recordedAt)
        } catch {
            return .unavailable
        }
    }
}
