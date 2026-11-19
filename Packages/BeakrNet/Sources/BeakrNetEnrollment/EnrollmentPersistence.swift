import Foundation

public enum EnrollmentPersistenceError: Error, Equatable, Sendable {
    case fileTooLarge
    case malformedSnapshot
    case nonCanonicalSnapshot
    case unsupportedVersion(Int)
    case duplicateIdentifier
    case invalidSnapshot
    case missingInitialState
}

enum EnrollmentPersistence {
    static let maximumSnapshotBytes = 4 * 1_024 * 1_024

    static func load<T: Codable>(_ type: T.Type, from fileURL: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= maximumSnapshotBytes else { throw EnrollmentPersistenceError.fileTooLarge }
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw EnrollmentPersistenceError.malformedSnapshot
        }
        guard try encode(value) == data else { throw EnrollmentPersistenceError.nonCanonicalSnapshot }
        return value
    }

    static func persist<T: Encodable>(_ value: T, to fileURL: URL) throws {
        let data = try encode(value)
        guard data.count <= maximumSnapshotBytes else { throw EnrollmentPersistenceError.fileTooLarge }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

public actor PersistentEnrollmentLifecycleStore: EnrollmentLifecycleStore {
    public let fileURL: URL
    private var record: EnrollmentLifecycleRecord?

    private init(fileURL: URL, record: EnrollmentLifecycleRecord?) {
        self.fileURL = fileURL
        self.record = record
    }

    public static func open(fileURL: URL) throws -> PersistentEnrollmentLifecycleStore {
        let record = try EnrollmentPersistence.load(EnrollmentLifecycleRecord.self, from: fileURL)
        try record?.validate()
        return PersistentEnrollmentLifecycleStore(fileURL: fileURL, record: record)
    }

    public func load() -> EnrollmentLifecycleRecord? { record }

    public func save(_ record: EnrollmentLifecycleRecord, condition: LifecycleWriteCondition) throws {
        try record.validate()
        switch condition {
        case .create:
            guard self.record == nil else { throw EnrollmentLifecycleError.recordAlreadyExists }
        case .revision(let expected):
            guard self.record?.revision == expected else {
                throw EnrollmentLifecycleError.revisionConflict(
                    expected: expected,
                    actual: self.record?.revision
                )
            }
        }
        try EnrollmentPersistence.persist(record, to: fileURL)
        self.record = record
    }
}

public enum EnrollmentColdStartAction: Equatable, Sendable {
    case showUnconfigured
    case restoreIdentity
    case waitForAdministrator(requestID: UUID)
    case resumeNetworkCreation(transactionID: UUID)
    case resumeMembershipInstallation(transactionID: UUID)
    case startMemberRuntime
    case finishLeaving
    case requireRecovery
}

public enum EnrollmentColdStartPlanner {
    public static func action(for record: EnrollmentLifecycleRecord?) -> EnrollmentColdStartAction {
        guard let record else { return .showUnconfigured }
        switch record.phase {
        case .unconfigured:
            return .showUnconfigured
        case .identityReady:
            return .restoreIdentity
        case .joining:
            guard let requestID = record.pendingEnrollment?.requestID else { return .requireRecovery }
            return .waitForAdministrator(requestID: requestID)
        case .installingMembership:
            guard let transaction = record.transaction else { return .requireRecovery }
            switch transaction.kind {
            case .createNetwork:
                return .resumeNetworkCreation(transactionID: transaction.id)
            case .joinNetwork:
                return .resumeMembershipInstallation(transactionID: transaction.id)
            }
        case .member:
            return .startMemberRuntime
        case .leaving:
            return .finishLeaving
        case .recoveryRequired:
            return .requireRecovery
        }
    }
}
