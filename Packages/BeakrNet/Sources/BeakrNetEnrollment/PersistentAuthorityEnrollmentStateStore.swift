import Foundation

public actor PersistentAuthorityEnrollmentStateStore: AuthorityEnrollmentStateStore {
    private struct Snapshot: Codable {
        static let currentVersion = 1

        let version: Int
        let invitations: [EnrollmentInvitation]
        let requests: [EnrollmentRequest]
        let consumedInvitationIDs: [UUID]
        let pendingApprovals: [PendingAuthorityApproval]
        let approvals: [EnrollmentApproval]
        let rejections: [EnrollmentRejection]?
        let cancellations: [EnrollmentCancellation]?
        let confirmations: [EnrollmentConfirmation]?
    }

    public let fileURL: URL
    private var invitations: [UUID: EnrollmentInvitation]
    private var requests: [UUID: EnrollmentRequest]
    private var requestIDByInvitationID: [UUID: UUID]
    private var consumedInvitationIDs: Set<UUID>
    private var pendingByRequestID: [UUID: PendingAuthorityApproval]
    private var approvalsByRequestID: [UUID: EnrollmentApproval]
    private var rejectionsByRequestID: [UUID: EnrollmentRejection]
    private var cancellationsByRequestID: [UUID: EnrollmentCancellation]
    private var confirmationsByRequestID: [UUID: EnrollmentConfirmation]

    private init(fileURL: URL, snapshot: Snapshot) {
        self.fileURL = fileURL
        invitations = Dictionary(uniqueKeysWithValues: snapshot.invitations.map { ($0.invitationID, $0) })
        requests = Dictionary(uniqueKeysWithValues: snapshot.requests.map { ($0.requestID, $0) })
        requestIDByInvitationID = Dictionary(uniqueKeysWithValues: snapshot.requests.map {
            ($0.invitation.invitationID, $0.requestID)
        })
        consumedInvitationIDs = Set(snapshot.consumedInvitationIDs)
        pendingByRequestID = Dictionary(uniqueKeysWithValues: snapshot.pendingApprovals.map {
            ($0.request.requestID, $0)
        })
        approvalsByRequestID = Dictionary(uniqueKeysWithValues: snapshot.approvals.map {
            ($0.requestID, $0)
        })
        rejectionsByRequestID = Dictionary(uniqueKeysWithValues: (snapshot.rejections ?? []).map {
            ($0.requestID, $0)
        })
        cancellationsByRequestID = Dictionary(uniqueKeysWithValues: (snapshot.cancellations ?? []).map {
            ($0.requestID, $0)
        })
        confirmationsByRequestID = Dictionary(uniqueKeysWithValues: (snapshot.confirmations ?? []).map {
            ($0.requestID, $0)
        })
    }

    public static func open(fileURL: URL) throws -> PersistentAuthorityEnrollmentStateStore {
        let snapshot = try EnrollmentPersistence.load(Snapshot.self, from: fileURL) ?? Snapshot(
            version: Snapshot.currentVersion,
            invitations: [],
            requests: [],
            consumedInvitationIDs: [],
            pendingApprovals: [],
            approvals: [],
            rejections: [],
            cancellations: [],
            confirmations: []
        )
        try validate(snapshot)
        return PersistentAuthorityEnrollmentStateStore(fileURL: fileURL, snapshot: snapshot)
    }

    public func registerInvitation(_ invitation: EnrollmentInvitation, maximumPending: Int) throws {
        guard invitations[invitation.invitationID] == nil else {
            throw AuthorityEnrollmentError.duplicateInvitation
        }
        guard invitations.keys.filter({ !consumedInvitationIDs.contains($0) }).count < maximumPending else {
            throw AuthorityEnrollmentError.invitationCapacityExceeded
        }
        let previous = snapshot()
        invitations[invitation.invitationID] = invitation
        try persistOrRestore(previous)
    }

    public func replaceActiveInvitations(
        with invitation: EnrollmentInvitation,
        superseding rejections: [EnrollmentRejection]
    ) throws {
        guard invitations[invitation.invitationID] == nil else {
            throw AuthorityEnrollmentError.duplicateInvitation
        }

        let rejectionIDs = Set(rejections.map(\.requestID))
        let supersedableIDs = Set(pendingRequests().compactMap { request in
            pendingByRequestID[request.requestID] == nil ? request.requestID : nil
        })
        guard rejectionIDs == supersedableIDs else {
            throw AuthorityEnrollmentError.approvalConflict
        }

        for rejection in rejections {
            guard let request = requests[rejection.requestID],
                  rejection.invitationID == request.invitation.invitationID,
                  rejection.networkID == request.invitation.networkID,
                  rejection.nodeID == request.nodeID,
                  rejection.requestNonce == request.requestNonce,
                  approvalsByRequestID[rejection.requestID] == nil,
                  pendingByRequestID[rejection.requestID] == nil,
                  cancellationsByRequestID[rejection.requestID] == nil else {
                throw AuthorityEnrollmentError.approvalConflict
            }
        }

        let previous = snapshot()
        consumedInvitationIDs.formUnion(invitations.keys)
        for rejection in rejections {
            rejectionsByRequestID[rejection.requestID] = rejection
        }
        invitations[invitation.invitationID] = invitation
        try persistOrRestore(previous)
    }

    public func expireInvitations(beforeMilliseconds: Int64) throws {
        let expiringIDs = invitations.values.compactMap { invitation -> UUID? in
            guard invitation.expiresAtMilliseconds <= beforeMilliseconds,
                  requestIDByInvitationID[invitation.invitationID] == nil,
                  !consumedInvitationIDs.contains(invitation.invitationID) else {
                return nil
            }
            return invitation.invitationID
        }
        guard !expiringIDs.isEmpty else { return }
        let previous = snapshot()
        consumedInvitationIDs.formUnion(expiringIDs)
        try persistOrRestore(previous)
    }

    public func submit(_ request: EnrollmentRequest, maximumPending: Int) throws -> EnrollmentRequestAdmission {
        let invitationID = request.invitation.invitationID
        guard invitations[invitationID] == request.invitation else {
            throw AuthorityEnrollmentError.invitationUnknown
        }
        guard !consumedInvitationIDs.contains(invitationID) else {
            throw AuthorityEnrollmentError.invitationConsumed
        }
        if let existing = requests[request.requestID] {
            guard existing == request else { throw AuthorityEnrollmentError.conflictingRequest }
            return .duplicate
        }
        if let existingID = requestIDByInvitationID[invitationID] {
            guard requests[existingID] == request else { throw AuthorityEnrollmentError.invitationInUse }
            return .duplicate
        }
        guard requests.count - approvalsByRequestID.count - rejectionsByRequestID.count
                - cancellationsByRequestID.count < maximumPending else {
            throw AuthorityEnrollmentError.requestCapacityExceeded
        }
        let previous = snapshot()
        requests[request.requestID] = request
        requestIDByInvitationID[invitationID] = request.requestID
        try persistOrRestore(previous)
        return .accepted
    }

    public func request(id: UUID) -> EnrollmentRequest? { requests[id] }
    public func pendingRequests() -> [EnrollmentRequest] {
        requests.values.filter {
            approvalsByRequestID[$0.requestID] == nil
                && rejectionsByRequestID[$0.requestID] == nil
                && cancellationsByRequestID[$0.requestID] == nil
        }.sorted {
            $0.requestID.uuidString < $1.requestID.uuidString
        }
    }
    public func auditRecords() -> [EnrollmentAuditRecord] {
        requests.values.map { request in
            if confirmationsByRequestID[request.requestID] != nil,
               let approval = approvalsByRequestID[request.requestID] {
                return EnrollmentAuditRecord(
                    request: request,
                    status: .confirmed,
                    updatedAtMilliseconds: approval.issuedAtMilliseconds
                )
            }
            if let approval = approvalsByRequestID[request.requestID] {
                return EnrollmentAuditRecord(
                    request: request,
                    status: .approved,
                    updatedAtMilliseconds: approval.issuedAtMilliseconds
                )
            }
            if let rejection = rejectionsByRequestID[request.requestID] {
                return EnrollmentAuditRecord(
                    request: request,
                    status: rejection.reason == .expiredInvitation ? .expired : .rejected,
                    updatedAtMilliseconds: rejection.issuedAtMilliseconds,
                    rejectionReason: rejection.reason
                )
            }
            if let cancellation = cancellationsByRequestID[request.requestID] {
                return EnrollmentAuditRecord(
                    request: request,
                    status: .cancelled,
                    updatedAtMilliseconds: cancellation.issuedAtMilliseconds
                )
            }
            return EnrollmentAuditRecord(
                request: request,
                status: .pending,
                updatedAtMilliseconds: request.invitation.issuedAtMilliseconds
            )
        }.sorted {
            if $0.updatedAtMilliseconds != $1.updatedAtMilliseconds {
                return $0.updatedAtMilliseconds > $1.updatedAtMilliseconds
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func pruneTerminalRecords(keepingMostRecent limit: Int) throws {
        let removedIDs = auditRecords()
            .filter { $0.status.isTerminal }
            .dropFirst(limit)
            .map(\.id)
        guard !removedIDs.isEmpty else { return }
        let previous = snapshot()
        for requestID in removedIDs {
            guard let request = requests.removeValue(forKey: requestID) else { continue }
            let invitationID = request.invitation.invitationID
            invitations.removeValue(forKey: invitationID)
            requestIDByInvitationID.removeValue(forKey: invitationID)
            consumedInvitationIDs.remove(invitationID)
            pendingByRequestID.removeValue(forKey: requestID)
            approvalsByRequestID.removeValue(forKey: requestID)
            rejectionsByRequestID.removeValue(forKey: requestID)
            cancellationsByRequestID.removeValue(forKey: requestID)
            confirmationsByRequestID.removeValue(forKey: requestID)
        }
        try persistOrRestore(previous)
    }

    public func approval(requestID: UUID) -> EnrollmentApproval? { approvalsByRequestID[requestID] }
    public func rejection(requestID: UUID) -> EnrollmentRejection? { rejectionsByRequestID[requestID] }
    public func cancellation(requestID: UUID) -> EnrollmentCancellation? { cancellationsByRequestID[requestID] }
    public func confirmation(requestID: UUID) -> EnrollmentConfirmation? { confirmationsByRequestID[requestID] }
    public func pendingApproval(requestID: UUID) -> PendingAuthorityApproval? { pendingByRequestID[requestID] }

    public func stageApproval(_ pending: PendingAuthorityApproval) throws {
        let requestID = pending.request.requestID
        guard requests[requestID] == pending.request else { throw AuthorityEnrollmentError.requestUnknown }
        if let existing = pendingByRequestID[requestID] {
            guard existing == pending else { throw AuthorityEnrollmentError.approvalConflict }
            return
        }
        guard approvalsByRequestID[requestID] == nil,
              rejectionsByRequestID[requestID] == nil,
              cancellationsByRequestID[requestID] == nil else {
            throw AuthorityEnrollmentError.approvalConflict
        }
        let previous = snapshot()
        consumedInvitationIDs.insert(pending.request.invitation.invitationID)
        pendingByRequestID[requestID] = pending
        try persistOrRestore(previous)
    }

    public func finalizeApproval(requestID: UUID, transactionID: UUID) throws {
        if approvalsByRequestID[requestID] != nil { return }
        guard let pending = pendingByRequestID[requestID], pending.transactionID == transactionID else {
            throw AuthorityEnrollmentError.invalidApprovalTransaction
        }
        let previous = snapshot()
        approvalsByRequestID[requestID] = pending.approval
        pendingByRequestID.removeValue(forKey: requestID)
        try persistOrRestore(previous)
    }

    public func finalizeRejection(_ rejection: EnrollmentRejection) throws {
        guard requests[rejection.requestID] != nil else { throw AuthorityEnrollmentError.requestUnknown }
        guard approvalsByRequestID[rejection.requestID] == nil,
              pendingByRequestID[rejection.requestID] == nil,
              cancellationsByRequestID[rejection.requestID] == nil else {
            throw AuthorityEnrollmentError.approvalConflict
        }
        if let existing = rejectionsByRequestID[rejection.requestID] {
            guard existing == rejection else { throw AuthorityEnrollmentError.approvalConflict }
            return
        }
        let previous = snapshot()
        consumedInvitationIDs.insert(rejection.invitationID)
        rejectionsByRequestID[rejection.requestID] = rejection
        try persistOrRestore(previous)
    }

    public func finalizeCancellation(_ cancellation: EnrollmentCancellation) throws {
        guard requests[cancellation.requestID] != nil else {
            throw AuthorityEnrollmentError.requestUnknown
        }
        guard approvalsByRequestID[cancellation.requestID] == nil,
              pendingByRequestID[cancellation.requestID] == nil,
              rejectionsByRequestID[cancellation.requestID] == nil else {
            throw AuthorityEnrollmentError.approvalConflict
        }
        if let existing = cancellationsByRequestID[cancellation.requestID] {
            guard existing == cancellation else {
                throw AuthorityEnrollmentError.approvalConflict
            }
            return
        }
        let previous = snapshot()
        consumedInvitationIDs.insert(cancellation.invitationID)
        cancellationsByRequestID[cancellation.requestID] = cancellation
        try persistOrRestore(previous)
    }

    public func finalizeConfirmation(_ confirmation: EnrollmentConfirmation) throws {
        guard approvalsByRequestID[confirmation.requestID] != nil else {
            throw AuthorityEnrollmentError.requestUnknown
        }
        if let existing = confirmationsByRequestID[confirmation.requestID] {
            guard existing == confirmation else { throw AuthorityEnrollmentError.approvalConflict }
            return
        }
        let previous = snapshot()
        confirmationsByRequestID[confirmation.requestID] = confirmation
        try persistOrRestore(previous)
    }

    public func pendingApprovals() -> [PendingAuthorityApproval] {
        pendingByRequestID.values.sorted { $0.request.requestID.uuidString < $1.request.requestID.uuidString }
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            version: Snapshot.currentVersion,
            invitations: invitations.values.sorted { $0.invitationID.uuidString < $1.invitationID.uuidString },
            requests: requests.values.sorted { $0.requestID.uuidString < $1.requestID.uuidString },
            consumedInvitationIDs: consumedInvitationIDs.sorted { $0.uuidString < $1.uuidString },
            pendingApprovals: pendingByRequestID.values.sorted {
                $0.request.requestID.uuidString < $1.request.requestID.uuidString
            },
            approvals: approvalsByRequestID.values.sorted { $0.requestID.uuidString < $1.requestID.uuidString },
            rejections: rejectionsByRequestID.values.sorted { $0.requestID.uuidString < $1.requestID.uuidString },
            cancellations: cancellationsByRequestID.values.sorted {
                $0.requestID.uuidString < $1.requestID.uuidString
            },
            confirmations: confirmationsByRequestID.values.sorted {
                $0.requestID.uuidString < $1.requestID.uuidString
            }
        )
    }

    private func persistOrRestore(_ previous: Snapshot) throws {
        do {
            try EnrollmentPersistence.persist(snapshot(), to: fileURL)
        } catch {
            restore(previous)
            throw error
        }
    }

    private func restore(_ snapshot: Snapshot) {
        invitations = Dictionary(uniqueKeysWithValues: snapshot.invitations.map { ($0.invitationID, $0) })
        requests = Dictionary(uniqueKeysWithValues: snapshot.requests.map { ($0.requestID, $0) })
        requestIDByInvitationID = Dictionary(uniqueKeysWithValues: snapshot.requests.map {
            ($0.invitation.invitationID, $0.requestID)
        })
        consumedInvitationIDs = Set(snapshot.consumedInvitationIDs)
        pendingByRequestID = Dictionary(uniqueKeysWithValues: snapshot.pendingApprovals.map {
            ($0.request.requestID, $0)
        })
        approvalsByRequestID = Dictionary(uniqueKeysWithValues: snapshot.approvals.map { ($0.requestID, $0) })
        rejectionsByRequestID = Dictionary(uniqueKeysWithValues: (snapshot.rejections ?? []).map {
            ($0.requestID, $0)
        })
        cancellationsByRequestID = Dictionary(uniqueKeysWithValues: (snapshot.cancellations ?? []).map {
            ($0.requestID, $0)
        })
        confirmationsByRequestID = Dictionary(uniqueKeysWithValues: (snapshot.confirmations ?? []).map {
            ($0.requestID, $0)
        })
    }

    private static func validate(_ snapshot: Snapshot) throws {
        guard snapshot.version == Snapshot.currentVersion else {
            throw EnrollmentPersistenceError.unsupportedVersion(snapshot.version)
        }
        let rejections = snapshot.rejections ?? []
        let cancellations = snapshot.cancellations ?? []
        let confirmations = snapshot.confirmations ?? []
        let counts = [snapshot.invitations.count, snapshot.requests.count,
                      snapshot.pendingApprovals.count, snapshot.approvals.count,
                      rejections.count, cancellations.count, confirmations.count]
        guard counts.allSatisfy({ $0 <= AuthorityPolicy.maximumCollectionCapacity }) else {
            throw EnrollmentPersistenceError.invalidSnapshot
        }
        guard Set(snapshot.invitations.map(\.invitationID)).count == snapshot.invitations.count,
              Set(snapshot.requests.map(\.requestID)).count == snapshot.requests.count,
              Set(snapshot.requests.map(\.invitation.invitationID)).count == snapshot.requests.count,
              Set(snapshot.consumedInvitationIDs).count == snapshot.consumedInvitationIDs.count,
              Set(snapshot.pendingApprovals.map(\.request.requestID)).count == snapshot.pendingApprovals.count,
              Set(snapshot.approvals.map(\.requestID)).count == snapshot.approvals.count,
              Set(rejections.map(\.requestID)).count == rejections.count,
              Set(cancellations.map(\.requestID)).count == cancellations.count,
              Set(confirmations.map(\.requestID)).count == confirmations.count else {
            throw EnrollmentPersistenceError.duplicateIdentifier
        }
        let invitationIDs = Set(snapshot.invitations.map(\.invitationID))
        let requestsByID = Dictionary(uniqueKeysWithValues: snapshot.requests.map { ($0.requestID, $0) })
        let approvalRequestIDs = Set(snapshot.approvals.map(\.requestID))
        let rejectionRequestIDs = Set(rejections.map(\.requestID))
        let cancellationRequestIDs = Set(cancellations.map(\.requestID))
        let terminalRequestIDs = approvalRequestIDs.union(rejectionRequestIDs)
        guard snapshot.requests.allSatisfy({ invitationIDs.contains($0.invitation.invitationID) }),
              Set(snapshot.consumedInvitationIDs).isSubset(of: invitationIDs),
              approvalRequestIDs.isDisjoint(with: rejectionRequestIDs),
              terminalRequestIDs.isDisjoint(with: cancellationRequestIDs),
              Set(confirmations.map(\.requestID)).isSubset(of: approvalRequestIDs),
              snapshot.approvals.allSatisfy({ requestsByID[$0.requestID] != nil }),
              rejections.allSatisfy({ rejection in
                  requestsByID[rejection.requestID]?.invitation.invitationID == rejection.invitationID
              }),
              cancellations.allSatisfy({ cancellation in
                  requestsByID[cancellation.requestID]?.invitation.invitationID == cancellation.invitationID
              }) else {
            throw EnrollmentPersistenceError.invalidSnapshot
        }
    }
}
