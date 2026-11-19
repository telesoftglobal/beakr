import Foundation

public actor PersistentJoiningEnrollmentStore: JoiningEnrollmentStore {
    private struct ApprovalEntry: Codable {
        let transactionID: UUID
        let approval: EnrollmentApproval
    }

    private struct Snapshot: Codable {
        static let currentVersion = 1

        let version: Int
        let requests: [EnrollmentRequest]
        let stagedApprovals: [ApprovalEntry]
        let activeApprovals: [ApprovalEntry]
        let confirmations: [EnrollmentConfirmation]?
    }

    public let fileURL: URL
    private var requests: [UUID: EnrollmentRequest]
    private var staged: [UUID: EnrollmentApproval]
    private var active: [UUID: EnrollmentApproval]
    private var confirmations: [UUID: EnrollmentConfirmation]

    private init(fileURL: URL, snapshot: Snapshot) {
        self.fileURL = fileURL
        requests = Dictionary(uniqueKeysWithValues: snapshot.requests.map { ($0.requestID, $0) })
        staged = Dictionary(uniqueKeysWithValues: snapshot.stagedApprovals.map {
            ($0.transactionID, $0.approval)
        })
        active = Dictionary(uniqueKeysWithValues: snapshot.activeApprovals.map {
            ($0.transactionID, $0.approval)
        })
        confirmations = Dictionary(uniqueKeysWithValues: (snapshot.confirmations ?? []).map {
            ($0.requestID, $0)
        })
    }

    public static func open(fileURL: URL) throws -> PersistentJoiningEnrollmentStore {
        let snapshot = try EnrollmentPersistence.load(Snapshot.self, from: fileURL) ?? Snapshot(
            version: Snapshot.currentVersion,
            requests: [],
            stagedApprovals: [],
            activeApprovals: [],
            confirmations: []
        )
        try validate(snapshot)
        return PersistentJoiningEnrollmentStore(fileURL: fileURL, snapshot: snapshot)
    }

    public func stageRequest(_ request: EnrollmentRequest) throws {
        if let existing = requests[request.requestID] {
            guard existing == request else { throw JoiningEnrollmentError.conflictingRequest }
            return
        }
        guard requests.count < AuthorityPolicy.maximumCollectionCapacity else {
            throw EnrollmentPersistenceError.invalidSnapshot
        }
        let previous = snapshot()
        requests[request.requestID] = request
        try persistOrRestore(previous)
    }

    public func request(id: UUID) -> EnrollmentRequest? { requests[id] }

    public func discardRequest(id: UUID) throws {
        guard requests[id] != nil else { return }
        let previous = snapshot()
        requests.removeValue(forKey: id)
        try persistOrRestore(previous)
    }

    public func stageApproval(_ approval: EnrollmentApproval, transactionID: UUID) throws {
        if let existing = staged[transactionID] {
            guard existing == approval else { throw JoiningEnrollmentError.conflictingApproval }
            return
        }
        if let existing = active[transactionID] {
            guard existing == approval else { throw JoiningEnrollmentError.conflictingApproval }
            return
        }
        let previous = snapshot()
        staged[transactionID] = approval
        try persistOrRestore(previous)
    }

    public func stagedApproval(transactionID: UUID) -> EnrollmentApproval? {
        staged[transactionID] ?? active[transactionID]
    }

    public func activateApproval(transactionID: UUID) throws {
        if active[transactionID] != nil { return }
        guard let approval = staged[transactionID] else {
            throw JoiningEnrollmentError.missingStagedApproval
        }
        let previous = snapshot()
        active[transactionID] = approval
        staged.removeValue(forKey: transactionID)
        try persistOrRestore(previous)
    }

    public func discardStagedApproval(transactionID: UUID) throws {
        guard staged[transactionID] != nil else { return }
        let previous = snapshot()
        staged.removeValue(forKey: transactionID)
        try persistOrRestore(previous)
    }

    public func stageConfirmation(_ confirmation: EnrollmentConfirmation) throws {
        if let existing = confirmations[confirmation.requestID] {
            guard existing == confirmation else { throw JoiningEnrollmentError.conflictingApproval }
            return
        }
        let previous = snapshot()
        confirmations[confirmation.requestID] = confirmation
        try persistOrRestore(previous)
    }

    public func pendingConfirmations() -> [EnrollmentConfirmation] {
        confirmations.values.sorted { $0.requestID.uuidString < $1.requestID.uuidString }
    }

    public func discardConfirmation(requestID: UUID) throws {
        guard confirmations[requestID] != nil else { return }
        let previous = snapshot()
        confirmations.removeValue(forKey: requestID)
        try persistOrRestore(previous)
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            version: Snapshot.currentVersion,
            requests: requests.values.sorted { $0.requestID.uuidString < $1.requestID.uuidString },
            stagedApprovals: staged.map { ApprovalEntry(transactionID: $0.key, approval: $0.value) }
                .sorted { $0.transactionID.uuidString < $1.transactionID.uuidString },
            activeApprovals: active.map { ApprovalEntry(transactionID: $0.key, approval: $0.value) }
                .sorted { $0.transactionID.uuidString < $1.transactionID.uuidString },
            confirmations: confirmations.values.sorted { $0.requestID.uuidString < $1.requestID.uuidString }
        )
    }

    private func persistOrRestore(_ previous: Snapshot) throws {
        do { try EnrollmentPersistence.persist(snapshot(), to: fileURL) }
        catch { restore(previous); throw error }
    }

    private func restore(_ snapshot: Snapshot) {
        requests = Dictionary(uniqueKeysWithValues: snapshot.requests.map { ($0.requestID, $0) })
        staged = Dictionary(uniqueKeysWithValues: snapshot.stagedApprovals.map {
            ($0.transactionID, $0.approval)
        })
        active = Dictionary(uniqueKeysWithValues: snapshot.activeApprovals.map {
            ($0.transactionID, $0.approval)
        })
        confirmations = Dictionary(uniqueKeysWithValues: (snapshot.confirmations ?? []).map {
            ($0.requestID, $0)
        })
    }

    private static func validate(_ snapshot: Snapshot) throws {
        guard snapshot.version == Snapshot.currentVersion else {
            throw EnrollmentPersistenceError.unsupportedVersion(snapshot.version)
        }
        guard snapshot.requests.count <= AuthorityPolicy.maximumCollectionCapacity,
              snapshot.stagedApprovals.count <= AuthorityPolicy.maximumCollectionCapacity,
              snapshot.activeApprovals.count <= AuthorityPolicy.maximumCollectionCapacity,
              (snapshot.confirmations ?? []).count <= AuthorityPolicy.maximumCollectionCapacity,
              Set(snapshot.requests.map(\.requestID)).count == snapshot.requests.count,
              Set(snapshot.stagedApprovals.map(\.transactionID)).count == snapshot.stagedApprovals.count,
              Set(snapshot.activeApprovals.map(\.transactionID)).count == snapshot.activeApprovals.count,
              Set((snapshot.confirmations ?? []).map(\.requestID)).count == (snapshot.confirmations ?? []).count,
              Set(snapshot.stagedApprovals.map(\.transactionID)).isDisjoint(
                with: Set(snapshot.activeApprovals.map(\.transactionID))
              ) else {
            throw EnrollmentPersistenceError.invalidSnapshot
        }
    }
}
