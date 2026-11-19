import Foundation
import BeakrNetCore

public enum AuthorityHostingPreferencesError: Error, Equatable, Sendable {
    case invalidSnapshot, unsupportedVersion, capacityExceeded, profileBindingMismatch
    case notInitialized
}

/// Persists hosting intent, never actual availability or messaging selection.
/// The caller must establish local authority ownership before adding a profile.
public actor AuthorityHostingPreferences {
    public struct Record: Codable, Equatable, Sendable {
        public let profileID: NetworkProfileID
        public let networkID: NetworkID
        public let localNodeID: NodeID
        public let isEnabled: Bool
        public let explicitlyStopped: Bool?

        fileprivate init(profile: NetworkProfile, isEnabled: Bool, explicitlyStopped: Bool = false) {
            profileID = profile.id
            networkID = profile.networkID
            localNodeID = profile.localNodeID
            self.isEnabled = isEnabled
            self.explicitlyStopped = explicitlyStopped
        }
    }

    private struct Snapshot: Codable {
        var version = 1
        var initialized = false
        var records: [Record] = []
    }

    private let fileURL: URL
    private let maximumAuthorities: Int
    private var snapshot: Snapshot
    private static var maximumFileBytes: Int { 65_536 }

    private init(fileURL: URL, maximumAuthorities: Int, snapshot: Snapshot) {
        self.fileURL = fileURL
        self.maximumAuthorities = maximumAuthorities
        self.snapshot = snapshot
    }

    public static func open(
        fileURL: URL, maximumAuthorities: Int = 8
    ) throws -> AuthorityHostingPreferences {
        precondition(maximumAuthorities > 0)
        var snapshot = Snapshot()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
            guard data.count <= maximumFileBytes else {
                throw AuthorityHostingPreferencesError.invalidSnapshot
            }
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        }
        try validate(snapshot, maximumAuthorities: maximumAuthorities)
        return AuthorityHostingPreferences(
            fileURL: fileURL, maximumAuthorities: maximumAuthorities, snapshot: snapshot
        )
    }

    public func records() -> [Record] { snapshot.records }
    public func isInitialized() -> Bool { snapshot.initialized }

    /// Runs once, including for an empty registry. Only the active owned authority
    /// starts enabled. Subsequent preparation applies the persisted explicit-stop policy.
    public func initialize(
        ownedProfiles: [NetworkProfile], activeProfileID: NetworkProfileID?
    ) throws {
        guard !snapshot.initialized else { return }
        let records = ownedProfiles.map {
            Record(profile: $0, isEnabled: $0.id == activeProfileID)
        }
        try commit(Snapshot(initialized: true, records: records))
    }

    public func isEnabled(for profile: NetworkProfile) throws -> Bool {
        try validateBinding(profile)
        return snapshot.records.first { $0.profileID == profile.id }?.isEnabled ?? false
    }

    public func wasExplicitlyStopped(for profile: NetworkProfile) throws -> Bool {
        try validateBinding(profile)
        return snapshot.records.first { $0.profileID == profile.id }?.explicitlyStopped == true
    }

    public func setEnabled(_ enabled: Bool, for profile: NetworkProfile) throws {
        guard snapshot.initialized else { throw AuthorityHostingPreferencesError.notInitialized }
        try validateBinding(profile)
        let record = Record(profile: profile, isEnabled: enabled, explicitlyStopped: !enabled)
        if snapshot.records.contains(record) { return }
        var candidate = snapshot
        candidate.records.removeAll { $0.profileID == profile.id }
        candidate.records.append(record)
        try commit(candidate)
    }

    public func removeStoppedProfile(_ profile: NetworkProfile) throws {
        try validateBinding(profile)
        guard !snapshot.records.contains(where: { $0.profileID == profile.id && $0.isEnabled }) else {
            throw AuthorityHostingPreferencesError.invalidSnapshot
        }
        var candidate = snapshot
        candidate.records.removeAll { $0.profileID == profile.id }
        try commit(candidate)
    }

    private func validateBinding(_ profile: NetworkProfile) throws {
        if let record = snapshot.records.first(where: { $0.profileID == profile.id }) {
            guard record.networkID == profile.networkID, record.localNodeID == profile.localNodeID else {
                throw AuthorityHostingPreferencesError.profileBindingMismatch
            }
        }
        guard !snapshot.records.contains(where: {
            $0.networkID == profile.networkID && $0.profileID != profile.id
        }) else { throw AuthorityHostingPreferencesError.profileBindingMismatch }
    }

    private func commit(_ candidate: Snapshot) throws {
        var candidate = candidate
        candidate.records.sort { $0.profileID.rawValue.uuidString < $1.profileID.rawValue.uuidString }
        try Self.validate(candidate, maximumAuthorities: maximumAuthorities)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(candidate)
        guard data.count <= Self.maximumFileBytes else {
            throw AuthorityHostingPreferencesError.invalidSnapshot
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        // Do not change in-memory intent if persistence failed.
        snapshot = candidate
    }

    private static func validate(_ snapshot: Snapshot, maximumAuthorities: Int) throws {
        guard snapshot.version == 1 else { throw AuthorityHostingPreferencesError.unsupportedVersion }
        guard snapshot.initialized || snapshot.records.isEmpty else {
            throw AuthorityHostingPreferencesError.invalidSnapshot
        }
        guard snapshot.records.count <= maximumAuthorities else {
            throw AuthorityHostingPreferencesError.capacityExceeded
        }
        guard Set(snapshot.records.map(\.profileID)).count == snapshot.records.count,
              Set(snapshot.records.map(\.networkID)).count == snapshot.records.count else {
            throw AuthorityHostingPreferencesError.profileBindingMismatch
        }
    }
}
