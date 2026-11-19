import Foundation

public enum ContextArchiveReason: String, Codable, Sendable {
    case membershipRevoked
}

public struct ContextRecord: Codable, Equatable, Sendable {
    public let id: ContextID
    public let displayName: String
    public let knownNetworkIDs: [NetworkID]
    public let attachedProfileIDs: [NetworkProfileID]
    public let messageStoreID: StoreID
    public let createdAt: Date
    public let updatedAt: Date
    public let archiveReason: ContextArchiveReason?

    public init(
        id: ContextID = ContextID(),
        displayName: String,
        knownNetworkIDs: [NetworkID],
        attachedProfileIDs: [NetworkProfileID],
        messageStoreID: StoreID = StoreID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archiveReason: ContextArchiveReason? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.knownNetworkIDs = knownNetworkIDs
        self.attachedProfileIDs = attachedProfileIDs
        self.messageStoreID = messageStoreID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archiveReason = archiveReason
    }
}

public enum ContextRegistryError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case invalidDisplayName
    case capacityExceeded(maximumContexts: Int)
    case duplicateContextID(ContextID)
    case duplicateNetworkID(NetworkID)
    case duplicateProfileID(NetworkProfileID)
    case duplicateStoreID(StoreID)
    case unknownContext(ContextID)
    case noncanonicalContext(ContextID)
    case noncanonicalSnapshot
}

/// Persists durable user contexts independently from replaceable network profiles.
/// Known Network IDs remain associated after the last profile is detached so a
/// later enrollment can reconnect to the existing Context and message store.
public actor PersistentContextRegistry {
    private struct Snapshot: Codable, Equatable {
        static let currentFormatVersion = 1

        let formatVersion: Int
        let contexts: [ContextRecord]
    }

    public let fileURL: URL
    public let contextsRootURL: URL
    public let maximumContexts: Int

    private var contextsByID: [ContextID: ContextRecord]

    private init(
        fileURL: URL,
        contextsRootURL: URL,
        maximumContexts: Int,
        contexts: [ContextRecord]
    ) {
        self.fileURL = fileURL
        self.contextsRootURL = contextsRootURL
        self.maximumContexts = maximumContexts
        contextsByID = Dictionary(uniqueKeysWithValues: contexts.map { ($0.id, $0) })
    }

    public static func open(
        fileURL: URL,
        contextsRootURL: URL,
        maximumContexts: Int = 32
    ) throws -> PersistentContextRegistry {
        precondition(maximumContexts > 0)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PersistentContextRegistry(
                fileURL: fileURL,
                contextsRootURL: contextsRootURL,
                maximumContexts: maximumContexts,
                contexts: []
            )
        }

        let data = try Data(contentsOf: fileURL)
        let snapshot = try makeDecoder().decode(Snapshot.self, from: data)
        guard snapshot.formatVersion == Snapshot.currentFormatVersion else {
            throw ContextRegistryError.unsupportedFormatVersion(snapshot.formatVersion)
        }
        try validate(snapshot, maximumContexts: maximumContexts)
        guard try makeEncoder().encode(snapshot) == data else {
            throw ContextRegistryError.noncanonicalSnapshot
        }
        return PersistentContextRegistry(
            fileURL: fileURL,
            contextsRootURL: contextsRootURL,
            maximumContexts: maximumContexts,
            contexts: snapshot.contexts
        )
    }

    public func contexts() -> [ContextRecord] {
        contextsByID.values.sorted(by: Self.contextOrder)
    }

    public func context(id: ContextID) -> ContextRecord? {
        contextsByID[id]
    }

    public func context(networkID: NetworkID) -> ContextRecord? {
        contextsByID.values.first { $0.knownNetworkIDs.contains(networkID) }
    }

    public func context(profileID: NetworkProfileID) -> ContextRecord? {
        contextsByID.values.first { $0.attachedProfileIDs.contains(profileID) }
    }

    @discardableResult
    public func resolve(for profile: NetworkProfile, now: Date = Date()) throws -> ContextRecord {
        if let existing = context(networkID: profile.networkID) {
            guard !existing.attachedProfileIDs.contains(profile.id) else { return existing }
            let updated = ContextRecord(
                id: existing.id,
                displayName: existing.displayName,
                knownNetworkIDs: existing.knownNetworkIDs,
                attachedProfileIDs: Self.sorted(existing.attachedProfileIDs + [profile.id]),
                messageStoreID: existing.messageStoreID,
                createdAt: existing.createdAt,
                updatedAt: now
            )
            contextsByID[existing.id] = updated
            do { try persist() }
            catch { contextsByID[existing.id] = existing; throw error }
            return updated
        }

        guard contextsByID.count < maximumContexts else {
            throw ContextRegistryError.capacityExceeded(maximumContexts: maximumContexts)
        }
        let displayName = try Self.normalizedDisplayName(profile.displayName)
        let context = ContextRecord(
            displayName: displayName,
            knownNetworkIDs: [profile.networkID],
            attachedProfileIDs: [profile.id],
            createdAt: now,
            updatedAt: now
        )
        contextsByID[context.id] = context
        do {
            try FileManager.default.createDirectory(
                at: storageRoot(for: context.id),
                withIntermediateDirectories: true
            )
            try persist()
        } catch {
            contextsByID.removeValue(forKey: context.id)
            throw error
        }
        return context
    }

    public func detach(
        _ profileID: NetworkProfileID,
        now: Date = Date(),
        reason: ContextArchiveReason? = nil
    ) throws {
        guard let existing = context(profileID: profileID) else { return }
        let updated = ContextRecord(
            id: existing.id,
            displayName: existing.displayName,
            knownNetworkIDs: existing.knownNetworkIDs,
            attachedProfileIDs: existing.attachedProfileIDs.filter { $0 != profileID },
            messageStoreID: existing.messageStoreID,
            createdAt: existing.createdAt,
            updatedAt: now,
            archiveReason: existing.attachedProfileIDs == [profileID] ? reason : nil
        )
        contextsByID[existing.id] = updated
        do { try persist() }
        catch { contextsByID[existing.id] = existing; throw error }
    }

    public func remove(_ contextID: ContextID) throws {
        guard let removed = contextsByID.removeValue(forKey: contextID) else {
            throw ContextRegistryError.unknownContext(contextID)
        }
        do { try persist() }
        catch { contextsByID[contextID] = removed; throw error }
    }

    public func storageRoot(for contextID: ContextID) -> URL {
        contextsRootURL.appendingPathComponent(
            contextID.rawValue.uuidString.lowercased(),
            isDirectory: true
        )
    }

    public func messageStoreURL(for context: ContextRecord) -> URL {
        storageRoot(for: context.id)
            .appendingPathComponent("Stores", isDirectory: true)
            .appendingPathComponent(context.messageStoreID.rawValue.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("messages.json")
    }

    public func mailboxMetadataURL(for context: ContextRecord) -> URL {
        storageRoot(for: context.id)
            .appendingPathComponent("Mailbox", isDirectory: true)
            .appendingPathComponent("metadata.json")
    }

    private func persist() throws {
        let snapshot = Snapshot(
            formatVersion: Snapshot.currentFormatVersion,
            contexts: contexts()
        )
        let data = try Self.makeEncoder().encode(snapshot)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private static func validate(_ snapshot: Snapshot, maximumContexts: Int) throws {
        guard snapshot.contexts.count <= maximumContexts else {
            throw ContextRegistryError.capacityExceeded(maximumContexts: maximumContexts)
        }
        var contextIDs: Set<ContextID> = []
        var networkIDs: Set<NetworkID> = []
        var profileIDs: Set<NetworkProfileID> = []
        var storeIDs: Set<StoreID> = []
        for context in snapshot.contexts {
            guard contextIDs.insert(context.id).inserted else {
                throw ContextRegistryError.duplicateContextID(context.id)
            }
            guard storeIDs.insert(context.messageStoreID).inserted else {
                throw ContextRegistryError.duplicateStoreID(context.messageStoreID)
            }
            _ = try normalizedDisplayName(context.displayName)
            guard context.knownNetworkIDs == sorted(context.knownNetworkIDs),
                  Set(context.knownNetworkIDs).count == context.knownNetworkIDs.count else {
                throw ContextRegistryError.noncanonicalContext(context.id)
            }
            guard context.attachedProfileIDs == sorted(context.attachedProfileIDs),
                  Set(context.attachedProfileIDs).count == context.attachedProfileIDs.count else {
                throw ContextRegistryError.noncanonicalContext(context.id)
            }
            for networkID in context.knownNetworkIDs {
                guard networkIDs.insert(networkID).inserted else {
                    throw ContextRegistryError.duplicateNetworkID(networkID)
                }
            }
            for profileID in context.attachedProfileIDs {
                guard profileIDs.insert(profileID).inserted else {
                    throw ContextRegistryError.duplicateProfileID(profileID)
                }
            }
        }
    }

    private static func normalizedDisplayName(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= NetworkProfile.maximumDisplayNameBytes else {
            throw ContextRegistryError.invalidDisplayName
        }
        return normalized
    }

    private static func sorted(_ values: [NetworkID]) -> [NetworkID] {
        values.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    private static func sorted(_ values: [NetworkProfileID]) -> [NetworkProfileID] {
        values.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    private static func contextOrder(_ lhs: ContextRecord, _ rhs: ContextRecord) -> Bool {
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
