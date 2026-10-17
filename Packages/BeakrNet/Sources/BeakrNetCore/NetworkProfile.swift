import Foundation

public struct NetworkProfile: Codable, Equatable, Sendable {
    public static let maximumDisplayNameBytes = 128

    public let id: NetworkProfileID
    public let networkID: NetworkID
    public let localNodeID: NodeID
    public let displayName: String
    public let createdAt: Date

    public init(
        id: NetworkProfileID = NetworkProfileID(),
        networkID: NetworkID,
        localNodeID: NodeID,
        displayName: String,
        createdAt: Date = Date()
    ) throws {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.utf8.count <= Self.maximumDisplayNameBytes else {
            throw NetworkProfileRegistryError.invalidDisplayName
        }
        self.id = id
        self.networkID = networkID
        self.localNodeID = localNodeID
        self.displayName = normalizedName
        self.createdAt = createdAt
    }
}

public enum NetworkProfileRegistryError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case invalidDisplayName
    case capacityExceeded(maximumProfiles: Int)
    case duplicateProfileID(NetworkProfileID)
    case duplicateNetworkID(NetworkID)
    case unknownProfile(NetworkProfileID)
    case activeProfileRemoval(NetworkProfileID)
    case noncanonicalSnapshot
}

/// Owns the bounded list of BeakrNet profiles and their isolated storage roots.
/// Credentials and application data remain in each profile's directory, never in this registry.
public actor PersistentNetworkProfileRegistry {
    private struct Snapshot: Codable, Equatable {
        static let currentFormatVersion = 1

        let formatVersion: Int
        let activeProfileID: NetworkProfileID?
        let profiles: [NetworkProfile]
    }

    public let fileURL: URL
    public let profilesRootURL: URL
    public let maximumProfiles: Int

    private var profilesByID: [NetworkProfileID: NetworkProfile]
    private var activeID: NetworkProfileID?

    private init(
        fileURL: URL,
        profilesRootURL: URL,
        maximumProfiles: Int,
        profiles: [NetworkProfile],
        activeProfileID: NetworkProfileID?
    ) {
        self.fileURL = fileURL
        self.profilesRootURL = profilesRootURL
        self.maximumProfiles = maximumProfiles
        profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        activeID = activeProfileID
    }

    public static func open(
        fileURL: URL,
        profilesRootURL: URL,
        maximumProfiles: Int = 8
    ) throws -> PersistentNetworkProfileRegistry {
        precondition(maximumProfiles > 0)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PersistentNetworkProfileRegistry(
                fileURL: fileURL,
                profilesRootURL: profilesRootURL,
                maximumProfiles: maximumProfiles,
                profiles: [],
                activeProfileID: nil
            )
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = makeDecoder()
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        guard snapshot.formatVersion == Snapshot.currentFormatVersion else {
            throw NetworkProfileRegistryError.unsupportedFormatVersion(snapshot.formatVersion)
        }
        try validate(snapshot, maximumProfiles: maximumProfiles)
        return PersistentNetworkProfileRegistry(
            fileURL: fileURL,
            profilesRootURL: profilesRootURL,
            maximumProfiles: maximumProfiles,
            profiles: snapshot.profiles,
            activeProfileID: snapshot.activeProfileID
        )
    }

    public func profiles() -> [NetworkProfile] {
        profilesByID.values.sorted(by: Self.profileOrder)
    }

    public func activeProfile() -> NetworkProfile? {
        activeID.flatMap { profilesByID[$0] }
    }

    public func profile(id: NetworkProfileID) -> NetworkProfile? {
        profilesByID[id]
    }

    public func profile(networkID: NetworkID) -> NetworkProfile? {
        profilesByID.values.first { $0.networkID == networkID }
    }

    public func add(_ profile: NetworkProfile, activate: Bool = false) throws {
        guard profilesByID.count < maximumProfiles else {
            throw NetworkProfileRegistryError.capacityExceeded(maximumProfiles: maximumProfiles)
        }
        guard profilesByID[profile.id] == nil else {
            throw NetworkProfileRegistryError.duplicateProfileID(profile.id)
        }
        guard profilesByID.values.allSatisfy({ $0.networkID != profile.networkID }) else {
            throw NetworkProfileRegistryError.duplicateNetworkID(profile.networkID)
        }

        let previousActiveID = activeID
        try FileManager.default.createDirectory(
            at: profilesRootURL
                .appendingPathComponent(profile.id.rawValue.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent(profile.networkID.rawValue.uuidString.lowercased(), isDirectory: true),
            withIntermediateDirectories: true
        )
        profilesByID[profile.id] = profile
        if activate || activeID == nil { activeID = profile.id }
        do {
            try persist()
        } catch {
            profilesByID.removeValue(forKey: profile.id)
            activeID = previousActiveID
            throw error
        }
    }

    public func activate(_ profileID: NetworkProfileID) throws {
        guard profilesByID[profileID] != nil else {
            throw NetworkProfileRegistryError.unknownProfile(profileID)
        }
        guard activeID != profileID else { return }
        let previous = activeID
        activeID = profileID
        do { try persist() }
        catch { activeID = previous; throw error }
    }

    public func rename(_ profileID: NetworkProfileID, to displayName: String) throws {
        guard let existing = profilesByID[profileID] else {
            throw NetworkProfileRegistryError.unknownProfile(profileID)
        }
        let renamed = try NetworkProfile(
            id: existing.id,
            networkID: existing.networkID,
            localNodeID: existing.localNodeID,
            displayName: displayName,
            createdAt: existing.createdAt
        )
        profilesByID[profileID] = renamed
        do { try persist() }
        catch {
            profilesByID[profileID] = existing
            throw error
        }
    }

    /// Removes registry membership only. Profile data is intentionally retained for explicit recovery or deletion.
    public func remove(_ profileID: NetworkProfileID) throws {
        guard profilesByID[profileID] != nil else {
            throw NetworkProfileRegistryError.unknownProfile(profileID)
        }
        guard activeID != profileID else {
            throw NetworkProfileRegistryError.activeProfileRemoval(profileID)
        }
        let removed = profilesByID.removeValue(forKey: profileID)
        do { try persist() }
        catch {
            if let removed { profilesByID[profileID] = removed }
            throw error
        }
    }

    /// Removes a profile even when it is active, leaving the registry with no
    /// active profile. Callers must stop the profile runtime before using this.
    public func removeActive(_ profileID: NetworkProfileID) throws {
        guard profilesByID[profileID] != nil else {
            throw NetworkProfileRegistryError.unknownProfile(profileID)
        }
        guard activeID == profileID else {
            try remove(profileID)
            return
        }
        let removed = profilesByID.removeValue(forKey: profileID)
        activeID = nil
        do {
            try persist()
        } catch {
            if let removed { profilesByID[profileID] = removed }
            activeID = profileID
            throw error
        }
    }

    public func storageRoot(for profileID: NetworkProfileID) throws -> URL {
        guard let profile = profilesByID[profileID] else {
            throw NetworkProfileRegistryError.unknownProfile(profileID)
        }
        return profilesRootURL
            .appendingPathComponent(profile.id.rawValue.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(profile.networkID.rawValue.uuidString.lowercased(), isDirectory: true)
    }

    private func persist() throws {
        let snapshot = Snapshot(
            formatVersion: Snapshot.currentFormatVersion,
            activeProfileID: activeID,
            profiles: profiles()
        )
        let data = try Self.makeEncoder().encode(snapshot)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private static func validate(_ snapshot: Snapshot, maximumProfiles: Int) throws {
        guard snapshot.profiles.count <= maximumProfiles else {
            throw NetworkProfileRegistryError.capacityExceeded(maximumProfiles: maximumProfiles)
        }
        var profileIDs: Set<NetworkProfileID> = []
        var networkIDs: Set<NetworkID> = []
        for profile in snapshot.profiles {
            guard profileIDs.insert(profile.id).inserted else {
                throw NetworkProfileRegistryError.duplicateProfileID(profile.id)
            }
            guard networkIDs.insert(profile.networkID).inserted else {
                throw NetworkProfileRegistryError.duplicateNetworkID(profile.networkID)
            }
            _ = try NetworkProfile(
                id: profile.id,
                networkID: profile.networkID,
                localNodeID: profile.localNodeID,
                displayName: profile.displayName,
                createdAt: profile.createdAt
            )
        }
        if let activeProfileID = snapshot.activeProfileID,
           !profileIDs.contains(activeProfileID) {
            throw NetworkProfileRegistryError.unknownProfile(activeProfileID)
        }
    }

    private static func profileOrder(_ lhs: NetworkProfile, _ rhs: NetworkProfile) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
