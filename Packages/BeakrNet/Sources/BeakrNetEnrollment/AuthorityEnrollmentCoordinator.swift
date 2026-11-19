import CryptoKit
import Foundation
import BeakrNetAuthority
import BeakrNetCore

public struct LocalAuthorizationGrant: Equatable, Sendable {
    public let requestID: UUID
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let opaqueToken: Data

    public init(
        requestID: UUID,
        issuedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        opaqueToken: Data
    ) {
        self.requestID = requestID
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.opaqueToken = opaqueToken
    }
}

public protocol LocalAuthorizationVerifying: Sendable {
    func verifyApprovalGrant(_ grant: LocalAuthorizationGrant, requestID: UUID, now: Date) async throws
}

public struct PendingAuthorityApproval: Codable, Equatable, Sendable {
    public let transactionID: UUID
    public let request: EnrollmentRequest
    public let approval: EnrollmentApproval

    public init(transactionID: UUID, request: EnrollmentRequest, approval: EnrollmentApproval) {
        self.transactionID = transactionID
        self.request = request
        self.approval = approval
    }
}

public enum EnrollmentRequestAdmission: Equatable, Sendable {
    case accepted
    case duplicate
}

public enum EnrollmentAuditStatus: String, Codable, Equatable, Sendable {
    case pending
    case approved
    case rejected
    case cancelled
    case expired
    case confirmed

    var isTerminal: Bool {
        switch self {
        case .rejected, .cancelled, .expired, .confirmed: true
        case .pending, .approved: false
        }
    }
}

public struct EnrollmentAuditRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { request.requestID }
    public let request: EnrollmentRequest
    public let status: EnrollmentAuditStatus
    public let updatedAtMilliseconds: Int64
    public let accessExpiresAtMilliseconds: Int64?
    public let rejectionReason: EnrollmentRejectionReason?

    public init(
        request: EnrollmentRequest,
        status: EnrollmentAuditStatus,
        updatedAtMilliseconds: Int64,
        accessExpiresAtMilliseconds: Int64? = nil,
        rejectionReason: EnrollmentRejectionReason? = nil
    ) {
        self.request = request
        self.status = status
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.accessExpiresAtMilliseconds = accessExpiresAtMilliseconds
        self.rejectionReason = rejectionReason
    }
}

public struct EnrollmentAuditExport: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Record: Codable, Equatable, Sendable {
        public let requestID: UUID
        public let invitationID: UUID
        public let networkID: NetworkID
        public let nodeID: NodeID
        public let status: EnrollmentAuditStatus
        public let updatedAtMilliseconds: Int64
        public let rejectionReason: EnrollmentRejectionReason?
    }

    public let version: Int
    public let exportedAtMilliseconds: Int64
    public let records: [Record]

    public init(records: [EnrollmentAuditRecord], exportedAt: Date = Date()) {
        version = Self.currentVersion
        exportedAtMilliseconds = Int64((exportedAt.timeIntervalSince1970 * 1_000).rounded(.down))
        self.records = records.map {
            Record(
                requestID: $0.request.requestID,
                invitationID: $0.request.invitation.invitationID,
                networkID: $0.request.invitation.networkID,
                nodeID: $0.request.nodeID,
                status: $0.status,
                updatedAtMilliseconds: $0.updatedAtMilliseconds,
                rejectionReason: $0.rejectionReason
            )
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct SignedEnrollmentAuditExport: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumEncodedBytes = 4 * 1_024 * 1_024

    public let version: Int
    public let authorityID: AuthorityID
    public let authorityPublicKey: Data
    public let payload: EnrollmentAuditExport
    public let authoritySignature: Data

    public static func signed(
        records: [EnrollmentAuditRecord],
        authority: CredentialAuthority,
        exportedAt: Date = Date()
    ) throws -> Self {
        let payload = EnrollmentAuditExport(records: records, exportedAt: exportedAt)
        let signature = try P256.Signing.PrivateKey(
            rawRepresentation: authority.privateKeyRepresentation
        ).signature(for: transcript(payload)).derRepresentation
        return Self(
            version: currentVersion,
            authorityID: authority.authorityID,
            authorityPublicKey: authority.publicKeyRepresentation,
            payload: payload,
            authoritySignature: signature
        )
    }

    public func encoded() throws -> Data { try Self.canonicalData(self) }

    public func verify(trustedAuthorityPublicKey: Data) throws -> EnrollmentAuditExport {
        guard version == Self.currentVersion,
              payload.version == EnrollmentAuditExport.currentVersion,
              authorityPublicKey == trustedAuthorityPublicKey,
              authorityID == CredentialVerifier.authorityID(for: trustedAuthorityPublicKey),
              let key = try? P256.Signing.PublicKey(x963Representation: trustedAuthorityPublicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: authoritySignature),
              key.isValidSignature(signature, for: try Self.transcript(payload)) else {
            throw EnrollmentAuditExportVerificationError.invalidSignature
        }
        return payload
    }

    public static func decodeAndVerify(
        _ data: Data,
        trustedAuthorityPublicKey: Data
    ) throws -> EnrollmentAuditExport {
        try decodeCanonical(data).verify(trustedAuthorityPublicKey: trustedAuthorityPublicKey)
    }

    public static func decodeCanonical(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else {
            throw EnrollmentAuditExportVerificationError.fileTooLarge
        }
        let document: Self
        do {
            document = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw EnrollmentAuditExportVerificationError.malformedDocument
        }
        guard try document.encoded() == data else {
            throw EnrollmentAuditExportVerificationError.nonCanonicalDocument
        }
        return document
    }

    private static func transcript(_ payload: EnrollmentAuditExport) throws -> Data {
        var data = Data("BeakrNet enrollment audit export v1\0".utf8)
        data.append(try canonicalData(payload))
        return data
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

public enum EnrollmentAuditExportVerificationError: Error, Equatable, Sendable {
    case invalidSignature
    case fileTooLarge
    case malformedDocument
    case nonCanonicalDocument
    case invalidKeyring
    case untrustedAuthority
    case invalidRotationStatement
}

public struct EnrollmentAuditVerificationReport: Equatable, Sendable {
    public let authorityID: AuthorityID
    public let exportedAtMilliseconds: Int64
    public let recordCount: Int

    public init(authorityID: AuthorityID, exportedAtMilliseconds: Int64, recordCount: Int) {
        self.authorityID = authorityID
        self.exportedAtMilliseconds = exportedAtMilliseconds
        self.recordCount = recordCount
    }
}

public struct EnrollmentAuditVerificationKeyring: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumKeys = 32

    public struct Entry: Codable, Equatable, Sendable {
        public let authorityID: AuthorityID
        public let publicKey: Data
        public let retiredAtMilliseconds: Int64?

        public init(publicKey: Data, retiredAtMilliseconds: Int64? = nil) {
            authorityID = CredentialVerifier.authorityID(for: publicKey)
            self.publicKey = publicKey
            self.retiredAtMilliseconds = retiredAtMilliseconds
        }
    }

    public let version: Int
    public let entries: [Entry]
    public let rotationStatements: [AuthorityKeyRotationStatement]?

    public init(
        currentPublicKey: Data,
        historicalEntries: [Entry] = [],
        rotationStatements: [AuthorityKeyRotationStatement] = []
    ) throws {
        version = Self.currentVersion
        entries = historicalEntries + [Entry(publicKey: currentPublicKey)]
        self.rotationStatements = rotationStatements
        try validate(currentPublicKey: currentPublicKey)
    }

    public func publicKey(for authorityID: AuthorityID) -> Data? {
        entries.first { $0.authorityID == authorityID }?.publicKey
    }

    public func validate(currentPublicKey: Data) throws {
        guard version == Self.currentVersion,
              !entries.isEmpty, entries.count <= Self.maximumKeys,
              (rotationStatements?.count ?? 0) < Self.maximumKeys,
              Set(entries.map(\.authorityID)).count == entries.count,
              entries.filter({ $0.retiredAtMilliseconds == nil }).count == 1,
              entries.contains(where: {
                  $0.publicKey == currentPublicKey && $0.retiredAtMilliseconds == nil
              }),
              entries.allSatisfy({
                  $0.authorityID == CredentialVerifier.authorityID(for: $0.publicKey)
                      && (try? P256.Signing.PublicKey(x963Representation: $0.publicKey)) != nil
              }) else { throw EnrollmentAuditExportVerificationError.invalidKeyring }
    }

    public static func open(fileURL: URL, currentPublicKey: Data) throws -> Self {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let keyring = try JSONDecoder().decode(Self.self, from: Data(contentsOf: fileURL))
            try keyring.validate(currentPublicKey: currentPublicKey)
            return keyring
        }
        let keyring = try Self(currentPublicKey: currentPublicKey)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(keyring).write(to: fileURL, options: .atomic)
        return keyring
    }

    public func persist(to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: fileURL, options: .atomic)
    }

    public func applyingVerifiedRotation(
        _ statement: AuthorityKeyRotationStatement,
        networkID: NetworkID
    ) throws -> Self {
        try statement.verify(networkID: networkID)
        guard let current = entries.first(where: { $0.retiredAtMilliseconds == nil }),
              current.authorityID == statement.claims.retiringAuthorityID,
              current.publicKey == statement.claims.retiringPublicKey,
              publicKey(for: statement.claims.replacementAuthorityID) == nil else {
            throw EnrollmentAuditExportVerificationError.invalidKeyring
        }
        let history = entries
            .filter { $0.authorityID != current.authorityID }
            + [Entry(
                publicKey: current.publicKey,
                retiredAtMilliseconds: statement.claims.effectiveAtMilliseconds
            )]
        return try Self(
            currentPublicKey: statement.claims.replacementPublicKey,
            historicalEntries: history,
            rotationStatements: (rotationStatements ?? []) + [statement]
        )
    }
}

public struct AuthorityKeyRotationStatement: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Claims: Codable, Equatable, Sendable {
        public let version: Int
        public let networkID: NetworkID
        public let retiringAuthorityID: AuthorityID
        public let retiringPublicKey: Data
        public let replacementAuthorityID: AuthorityID
        public let replacementPublicKey: Data
        public let effectiveAtMilliseconds: Int64
    }

    public let claims: Claims
    public let retiringAuthoritySignature: Data
    public let replacementAuthoritySignature: Data

    public static func signed(
        networkID: NetworkID,
        retiringAuthority: CredentialAuthority,
        replacementAuthority: CredentialAuthority,
        effectiveAt: Date = Date()
    ) throws -> Self {
        let claims = Claims(
            version: currentVersion,
            networkID: networkID,
            retiringAuthorityID: retiringAuthority.authorityID,
            retiringPublicKey: retiringAuthority.publicKeyRepresentation,
            replacementAuthorityID: replacementAuthority.authorityID,
            replacementPublicKey: replacementAuthority.publicKeyRepresentation,
            effectiveAtMilliseconds: Int64((effectiveAt.timeIntervalSince1970 * 1_000).rounded(.down))
        )
        let transcript = try transcript(claims)
        let retiringSignature = try P256.Signing.PrivateKey(
            rawRepresentation: retiringAuthority.privateKeyRepresentation
        ).signature(for: transcript).derRepresentation
        let replacementSignature = try P256.Signing.PrivateKey(
            rawRepresentation: replacementAuthority.privateKeyRepresentation
        ).signature(for: transcript).derRepresentation
        return Self(
            claims: claims,
            retiringAuthoritySignature: retiringSignature,
            replacementAuthoritySignature: replacementSignature
        )
    }

    public func verify(networkID: NetworkID) throws {
        guard claims.version == Self.currentVersion,
              claims.networkID == networkID,
              claims.retiringAuthorityID == CredentialVerifier.authorityID(for: claims.retiringPublicKey),
              claims.replacementAuthorityID == CredentialVerifier.authorityID(for: claims.replacementPublicKey),
              claims.retiringAuthorityID != claims.replacementAuthorityID,
              let retiringKey = try? P256.Signing.PublicKey(x963Representation: claims.retiringPublicKey),
              let replacementKey = try? P256.Signing.PublicKey(x963Representation: claims.replacementPublicKey),
              let retiringSignature = try? P256.Signing.ECDSASignature(
                  derRepresentation: retiringAuthoritySignature
              ),
              let replacementSignature = try? P256.Signing.ECDSASignature(
                  derRepresentation: replacementAuthoritySignature
              ) else {
            throw EnrollmentAuditExportVerificationError.invalidRotationStatement
        }
        let transcript = try Self.transcript(claims)
        guard retiringKey.isValidSignature(retiringSignature, for: transcript),
              replacementKey.isValidSignature(replacementSignature, for: transcript) else {
            throw EnrollmentAuditExportVerificationError.invalidRotationStatement
        }
    }

    private static func transcript(_ claims: Claims) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data("BeakrNet authority key rotation v1\0".utf8)
        data.append(try encoder.encode(claims))
        return data
    }
}

public struct EnrollmentAuditRetentionPolicy: Equatable, Sendable {
    public static let release1 = EnrollmentAuditRetentionPolicy(maximumTerminalRecords: 1_000)

    public let maximumTerminalRecords: Int

    public init(maximumTerminalRecords: Int) {
        precondition(maximumTerminalRecords >= 0)
        self.maximumTerminalRecords = maximumTerminalRecords
    }
}

public protocol AuthorityEnrollmentStateStore: Sendable {
    func registerInvitation(_ invitation: EnrollmentInvitation, maximumPending: Int) async throws
    func replaceActiveInvitations(
        with invitation: EnrollmentInvitation,
        superseding rejections: [EnrollmentRejection]
    ) async throws
    func expireInvitations(beforeMilliseconds: Int64) async throws
    func submit(_ request: EnrollmentRequest, maximumPending: Int) async throws -> EnrollmentRequestAdmission
    func request(id: UUID) async -> EnrollmentRequest?
    func pendingRequests() async -> [EnrollmentRequest]
    func auditRecords() async -> [EnrollmentAuditRecord]
    func pruneTerminalRecords(keepingMostRecent limit: Int) async throws
    func approval(requestID: UUID) async -> EnrollmentApproval?
    func rejection(requestID: UUID) async -> EnrollmentRejection?
    func cancellation(requestID: UUID) async -> EnrollmentCancellation?
    func confirmation(requestID: UUID) async -> EnrollmentConfirmation?
    func pendingApproval(requestID: UUID) async -> PendingAuthorityApproval?
    func stageApproval(_ pending: PendingAuthorityApproval) async throws
    func finalizeApproval(requestID: UUID, transactionID: UUID) async throws
    func finalizeRejection(_ rejection: EnrollmentRejection) async throws
    func finalizeCancellation(_ cancellation: EnrollmentCancellation) async throws
    func finalizeConfirmation(_ confirmation: EnrollmentConfirmation) async throws
    func pendingApprovals() async -> [PendingAuthorityApproval]
}

public protocol AuthorityMembershipPublishing: Sendable {
    func currentMembership() async throws -> ProfileMembershipSnapshot
    func currentRevocations() async throws -> CredentialRevocationSnapshot
    func stageMembership(
        _ membership: ProfileMembershipSnapshot,
        transactionID: UUID
    ) async throws
    func activateMembership(transactionID: UUID) async throws
    func discardStagedMembership(transactionID: UUID) async throws
}

public enum AuthorityEnrollmentError: Error, Equatable, Sendable {
    case invitationCapacityExceeded
    case requestCapacityExceeded
    case duplicateInvitation
    case invitationUnknown
    case invitationConsumed
    case invitationInUse
    case conflictingRequest
    case requestUnknown
    case approvalConflict
    case invalidApprovalTransaction
    case deviceCapacityExceeded
    case invalidLocalAuthorization
}

public actor InMemoryAuthorityEnrollmentStateStore: AuthorityEnrollmentStateStore {
    private var invitations: [UUID: EnrollmentInvitation] = [:]
    private var requests: [UUID: EnrollmentRequest] = [:]
    private var requestIDByInvitationID: [UUID: UUID] = [:]
    private var consumedInvitationIDs: Set<UUID> = []
    private var pendingByRequestID: [UUID: PendingAuthorityApproval] = [:]
    private var approvalsByRequestID: [UUID: EnrollmentApproval] = [:]
    private var rejectionsByRequestID: [UUID: EnrollmentRejection] = [:]
    private var cancellationsByRequestID: [UUID: EnrollmentCancellation] = [:]
    private var confirmationsByRequestID: [UUID: EnrollmentConfirmation] = [:]

    public init() {}

    public func registerInvitation(_ invitation: EnrollmentInvitation, maximumPending: Int) throws {
        guard invitations[invitation.invitationID] == nil else {
            throw AuthorityEnrollmentError.duplicateInvitation
        }
        let pendingCount = invitations.keys.filter { !consumedInvitationIDs.contains($0) }.count
        guard pendingCount < maximumPending else {
            throw AuthorityEnrollmentError.invitationCapacityExceeded
        }
        invitations[invitation.invitationID] = invitation
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

        consumedInvitationIDs.formUnion(invitations.keys)
        for rejection in rejections {
            rejectionsByRequestID[rejection.requestID] = rejection
        }
        invitations[invitation.invitationID] = invitation
    }

    public func expireInvitations(beforeMilliseconds: Int64) {
        for invitation in invitations.values where
            invitation.expiresAtMilliseconds <= beforeMilliseconds
                && requestIDByInvitationID[invitation.invitationID] == nil {
            consumedInvitationIDs.insert(invitation.invitationID)
        }
    }

    public func submit(_ request: EnrollmentRequest, maximumPending: Int) throws -> EnrollmentRequestAdmission {
        let invitationID = request.invitation.invitationID
        guard let invitation = invitations[invitationID], invitation == request.invitation else {
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
        requests[request.requestID] = request
        requestIDByInvitationID[invitationID] = request.requestID
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
                    updatedAtMilliseconds: approval.issuedAtMilliseconds,
                    accessExpiresAtMilliseconds: approval.credential.claims.expiresAtMilliseconds
                )
            }
            if let approval = approvalsByRequestID[request.requestID] {
                return EnrollmentAuditRecord(
                    request: request,
                    status: .approved,
                    updatedAtMilliseconds: approval.issuedAtMilliseconds,
                    accessExpiresAtMilliseconds: approval.credential.claims.expiresAtMilliseconds
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

    public func pruneTerminalRecords(keepingMostRecent limit: Int) {
        let removedIDs = auditRecords()
            .filter { $0.status.isTerminal }
            .dropFirst(limit)
            .map(\.id)
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
            guard existing.approval == pending.approval,
                  existing.transactionID == pending.transactionID else {
                throw AuthorityEnrollmentError.approvalConflict
            }
            return
        }
        guard approvalsByRequestID[requestID] == nil,
              rejectionsByRequestID[requestID] == nil,
              cancellationsByRequestID[requestID] == nil else {
            throw AuthorityEnrollmentError.approvalConflict
        }
        consumedInvitationIDs.insert(pending.request.invitation.invitationID)
        pendingByRequestID[requestID] = pending
    }

    public func finalizeApproval(requestID: UUID, transactionID: UUID) throws {
        if approvalsByRequestID[requestID] != nil { return }
        guard let pending = pendingByRequestID[requestID], pending.transactionID == transactionID else {
            throw AuthorityEnrollmentError.invalidApprovalTransaction
        }
        approvalsByRequestID[requestID] = pending.approval
        pendingByRequestID.removeValue(forKey: requestID)
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
        consumedInvitationIDs.insert(rejection.invitationID)
        rejectionsByRequestID[rejection.requestID] = rejection
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
        consumedInvitationIDs.insert(cancellation.invitationID)
        cancellationsByRequestID[cancellation.requestID] = cancellation
    }

    public func finalizeConfirmation(_ confirmation: EnrollmentConfirmation) throws {
        guard approvalsByRequestID[confirmation.requestID] != nil else {
            throw AuthorityEnrollmentError.requestUnknown
        }
        if let existing = confirmationsByRequestID[confirmation.requestID] {
            guard existing == confirmation else { throw AuthorityEnrollmentError.approvalConflict }
            return
        }
        confirmationsByRequestID[confirmation.requestID] = confirmation
    }

    public func pendingApprovals() -> [PendingAuthorityApproval] {
        pendingByRequestID.values.sorted {
            $0.request.requestID.uuidString < $1.request.requestID.uuidString
        }
    }
}

public actor AuthorityEnrollmentCoordinator {
    private let authority: CredentialAuthority
    private let networkID: NetworkID
    private let environment: String
    private let policy: AuthorityPolicy
    private let stateStore: any AuthorityEnrollmentStateStore
    private let membershipPublisher: any AuthorityMembershipPublishing
    private let localAuthorizationVerifier: any LocalAuthorizationVerifying
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID
    private let auditRetentionPolicy: EnrollmentAuditRetentionPolicy
    private let trustedAuditPublicKeys: [AuthorityID: Data]
    private let makeSecret: @Sendable () -> Data

    public init(
        authority: CredentialAuthority,
        networkID: NetworkID,
        environment: String,
        policy: AuthorityPolicy,
        stateStore: any AuthorityEnrollmentStateStore,
        membershipPublisher: any AuthorityMembershipPublishing,
        localAuthorizationVerifier: any LocalAuthorizationVerifying,
        now: @escaping @Sendable () -> Date = Date.init,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        auditRetentionPolicy: EnrollmentAuditRetentionPolicy = .release1,
        historicalAuditPublicKeys: [Data] = [],
        makeSecret: @escaping @Sendable () -> Data
    ) {
        self.authority = authority
        self.networkID = networkID
        self.environment = environment
        self.policy = policy
        self.stateStore = stateStore
        self.membershipPublisher = membershipPublisher
        self.localAuthorizationVerifier = localAuthorizationVerifier
        self.now = now
        self.makeUUID = makeUUID
        self.auditRetentionPolicy = auditRetentionPolicy
        self.trustedAuditPublicKeys = Dictionary(uniqueKeysWithValues:
            (historicalAuditPublicKeys + [authority.publicKeyRepresentation]).map {
                (CredentialVerifier.authorityID(for: $0), $0)
            }
        )
        self.makeSecret = makeSecret
    }

    public func createInvitation(
        networkDisplayName: String,
        controlPlaneURL: URL?,
        authorityCertificateDER: Data? = nil
    ) async throws -> EnrollmentInvitation {
        try await stateStore.expireInvitations(beforeMilliseconds: Self.milliseconds(now()))
        let invitation = try EnrollmentWireSigner.invitation(
            authority: authority,
            invitationID: makeUUID(),
            networkID: networkID,
            networkDisplayName: networkDisplayName,
            environment: environment,
            controlPlaneURL: controlPlaneURL,
            authorityCertificateDER: authorityCertificateDER,
            serviceScopes: policy.credentialServiceScopes.sorted(),
            invitationSecret: makeSecret(),
            issuedAt: now(),
            validity: policy.invitationValidity
        )
        let timestamp = now()
        var supersedingRejections: [EnrollmentRejection] = []
        for request in await stateStore.pendingRequests() {
            guard await stateStore.pendingApproval(requestID: request.requestID) == nil else { continue }
            supersedingRejections.append(try EnrollmentWireSigner.rejection(
                request: request,
                reason: .invitationSuperseded,
                authority: authority,
                issuedAt: timestamp
            ))
        }
        try await stateStore.replaceActiveInvitations(
            with: invitation,
            superseding: supersedingRejections
        )
        try await stateStore.pruneTerminalRecords(
            keepingMostRecent: auditRetentionPolicy.maximumTerminalRecords
        )
        return invitation
    }

    public func submit(_ request: EnrollmentRequest) async throws -> EnrollmentRequestAdmission {
        try EnrollmentWireVerifier.verifyRequest(
            request,
            expectedNetworkID: networkID,
            expectedAuthorityID: authority.authorityID,
            now: now(),
            allowedClockSkew: policy.allowedClockSkew
        )
        return try await stateStore.submit(request, maximumPending: policy.maximumPendingRequests)
    }

    public func request(id: UUID) async -> EnrollmentRequest? {
        await stateStore.request(id: id)
    }

    public func approval(requestID: UUID) async -> EnrollmentApproval? {
        await stateStore.approval(requestID: requestID)
    }

    public func rejection(requestID: UUID) async -> EnrollmentRejection? {
        await stateStore.rejection(requestID: requestID)
    }

    public func cancellation(requestID: UUID) async -> EnrollmentCancellation? {
        await stateStore.cancellation(requestID: requestID)
    }

    public func confirmation(requestID: UUID) async -> EnrollmentConfirmation? {
        await stateStore.confirmation(requestID: requestID)
    }

    public func confirm(_ confirmation: EnrollmentConfirmation) async throws {
        if let existing = await stateStore.confirmation(requestID: confirmation.requestID) {
            guard existing == confirmation else { throw AuthorityEnrollmentError.approvalConflict }
            return
        }
        guard let approval = await stateStore.approval(requestID: confirmation.requestID),
              let request = await stateStore.request(id: confirmation.requestID) else {
            throw AuthorityEnrollmentError.requestUnknown
        }
        try EnrollmentWireVerifier.verifyConfirmation(
            confirmation,
            for: approval,
            nodePublicKey: request.nodePublicKey
        )
        try await stateStore.finalizeConfirmation(confirmation)
        await pruneTerminalAuditRecords()
    }

    public func cancel(_ cancellation: EnrollmentCancellation) async throws {
        try await expirePendingRequests()
        if let existing = await stateStore.cancellation(requestID: cancellation.requestID) {
            guard existing == cancellation else {
                throw AuthorityEnrollmentError.approvalConflict
            }
            return
        }
        guard await stateStore.approval(requestID: cancellation.requestID) == nil,
              await stateStore.pendingApproval(requestID: cancellation.requestID) == nil,
              await stateStore.rejection(requestID: cancellation.requestID) == nil else {
            throw AuthorityEnrollmentError.approvalConflict
        }
        guard let request = await stateStore.request(id: cancellation.requestID) else {
            throw AuthorityEnrollmentError.requestUnknown
        }
        try EnrollmentWireVerifier.verifyCancellation(
            cancellation,
            for: request,
            now: now(),
            allowedClockSkew: policy.allowedClockSkew
        )
        try await stateStore.finalizeCancellation(cancellation)
        await pruneTerminalAuditRecords()
    }

    public func reject(
        requestID: UUID,
        reason: EnrollmentRejectionReason,
        localAuthorization: LocalAuthorizationGrant
    ) async throws -> EnrollmentRejection {
        try await expirePendingRequests()
        if let existing = await stateStore.rejection(requestID: requestID) { return existing }
        guard await stateStore.approval(requestID: requestID) == nil,
              await stateStore.pendingApproval(requestID: requestID) == nil else {
            throw AuthorityEnrollmentError.approvalConflict
        }
        guard let request = await stateStore.request(id: requestID) else {
            throw AuthorityEnrollmentError.requestUnknown
        }
        do {
            try await localAuthorizationVerifier.verifyApprovalGrant(
                localAuthorization,
                requestID: requestID,
                now: now()
            )
        } catch { throw AuthorityEnrollmentError.invalidLocalAuthorization }
        let rejection = try EnrollmentWireSigner.rejection(
            request: request,
            reason: reason,
            authority: authority,
            issuedAt: now()
        )
        try await stateStore.finalizeRejection(rejection)
        await pruneTerminalAuditRecords()
        return rejection
    }

    @discardableResult
    public func expirePendingRequests() async throws -> [EnrollmentRejection] {
        let timestamp = now()
        let nowMilliseconds = Self.milliseconds(timestamp)
        let pendingValidityMilliseconds = Int64(policy.pendingRequestValidity * 1_000)
        var expirations: [EnrollmentRejection] = []
        for request in await stateStore.pendingRequests() {
            // A durable approval awaiting publication is already decided. It must
            // remain recoverable, even after the pending-request deadline passes.
            guard await stateStore.pendingApproval(requestID: request.requestID) == nil else { continue }
            let deadline = request.invitation.expiresAtMilliseconds + pendingValidityMilliseconds
            guard deadline <= nowMilliseconds else { continue }
            let rejection = try EnrollmentWireSigner.rejection(
                request: request,
                reason: .expiredInvitation,
                authority: authority,
                issuedAt: timestamp
            )
            do {
                try await stateStore.finalizeRejection(rejection)
            } catch AuthorityEnrollmentError.approvalConflict {
                // Actor calls above can yield to approval, rejection, or cancellation.
                // Preserve a decision that won that race, but don't hide other conflicts.
                if await stateStore.pendingApproval(requestID: request.requestID) != nil { continue }
                if await stateStore.approval(requestID: request.requestID) != nil { continue }
                if await stateStore.rejection(requestID: request.requestID) != nil { continue }
                if await stateStore.cancellation(requestID: request.requestID) != nil { continue }
                throw AuthorityEnrollmentError.approvalConflict
            }
            expirations.append(rejection)
        }
        if !expirations.isEmpty { await pruneTerminalAuditRecords() }
        return expirations
    }

    public func pendingRequests() async -> [EnrollmentRequest] {
        _ = try? await expirePendingRequests()
        _ = try? await retireRequestsSupersededByExistingApprovals()
        return await stateStore.pendingRequests()
    }

    private func retireRequestsSupersededByExistingApprovals() async throws {
        let approvedRecords = await stateStore.auditRecords().filter {
            $0.status == .approved || $0.status == .confirmed
        }
        guard !approvedRecords.isEmpty else { return }

        let timestamp = now()
        var retiredAny = false
        for request in await stateStore.pendingRequests() {
            let wasAlreadyApproved = approvedRecords.contains {
                $0.request.nodeID == request.nodeID
                    && $0.request.nodePublicKey == request.nodePublicKey
                    && $0.updatedAtMilliseconds >= request.invitation.issuedAtMilliseconds
            }
            guard wasAlreadyApproved else { continue }
            let rejection = try EnrollmentWireSigner.rejection(
                request: request,
                reason: .superseded,
                authority: authority,
                issuedAt: timestamp
            )
            try await stateStore.finalizeRejection(rejection)
            retiredAny = true
        }
        if retiredAny { await pruneTerminalAuditRecords() }
    }

    public func auditRecords() async -> [EnrollmentAuditRecord] {
        _ = try? await expirePendingRequests()
        try? await stateStore.pruneTerminalRecords(
            keepingMostRecent: auditRetentionPolicy.maximumTerminalRecords
        )
        return await stateStore.auditRecords()
    }

    public func signedAuditExport() async throws -> Data {
        try SignedEnrollmentAuditExport.signed(
            records: await auditRecords(),
            authority: authority,
            exportedAt: now()
        ).encoded()
    }

    public func verifyAuditExport(_ data: Data) throws -> EnrollmentAuditVerificationReport {
        let document = try SignedEnrollmentAuditExport.decodeCanonical(data)
        guard let trustedKey = trustedAuditPublicKeys[document.authorityID] else {
            throw EnrollmentAuditExportVerificationError.untrustedAuthority
        }
        let payload = try document.verify(trustedAuthorityPublicKey: trustedKey)
        return EnrollmentAuditVerificationReport(
            authorityID: document.authorityID,
            exportedAtMilliseconds: payload.exportedAtMilliseconds,
            recordCount: payload.records.count
        )
    }

    public func approve(
        requestID: UUID,
        localAuthorization: LocalAuthorizationGrant
    ) async throws -> EnrollmentApproval {
        try await expirePendingRequests()
        if let approval = await stateStore.approval(requestID: requestID) { return approval }
        guard await stateStore.rejection(requestID: requestID) == nil else {
            throw AuthorityEnrollmentError.approvalConflict
        }
        if let pending = await stateStore.pendingApproval(requestID: requestID) {
            try await complete(pending)
            return pending.approval
        }
        guard let request = await stateStore.request(id: requestID) else {
            throw AuthorityEnrollmentError.requestUnknown
        }
        do {
            try await localAuthorizationVerifier.verifyApprovalGrant(
                localAuthorization,
                requestID: requestID,
                now: now()
            )
        } catch { throw AuthorityEnrollmentError.invalidLocalAuthorization }

        let currentMembership = try await membershipPublisher.currentMembership()
        let existingRecordIndex = currentMembership.claims.records.firstIndex {
            $0.credential.claims.nodeID == request.nodeID
        }
        if let existingRecordIndex {
            guard currentMembership.claims.records[existingRecordIndex].certificatePublicKey
                    == request.nodePublicKey else {
                throw AuthorityEnrollmentError.conflictingRequest
            }
        } else if currentMembership.claims.records.count >= policy.maximumEnrolledDevices {
            throw AuthorityEnrollmentError.deviceCapacityExceeded
        }
        let timestamp = now()
        let credential = try authority.issue(
            nodeID: request.nodeID,
            nodePublicKey: request.nodePublicKey,
            networkID: networkID,
            environment: environment,
            validity: policy.credentialValidity,
            serviceScopes: policy.credentialServiceScopes.sorted(),
            now: timestamp
        )
        var records = currentMembership.claims.records
        let refreshedRecord = ProfileMembershipRecord(
            credential: credential,
            certificatePublicKey: request.nodePublicKey,
            sessionID: existingRecordIndex.map { records[$0].sessionID } ?? SessionID()
        )
        if let existingRecordIndex {
            records[existingRecordIndex] = refreshedRecord
        } else {
            records.append(refreshedRecord)
        }
        let membership = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        ).sign(ProfileMembershipClaims(
            networkID: networkID,
            networkDisplayName: currentMembership.claims.networkDisplayName,
            generation: currentMembership.claims.generation + 1,
            generatedAtMilliseconds: Self.milliseconds(timestamp),
            records: records
        ))
        let revocations = try await membershipPublisher.currentRevocations()
        let approval = try EnrollmentWireSigner.approval(
            request: request,
            approvalID: makeUUID(),
            credential: credential,
            membership: membership,
            revocations: revocations,
            authority: authority,
            issuedAt: timestamp
        )
        let pending = PendingAuthorityApproval(
            transactionID: makeUUID(),
            request: request,
            approval: approval
        )
        do {
            try await membershipPublisher.stageMembership(membership, transactionID: pending.transactionID)
            try await stateStore.stageApproval(pending)
        } catch {
            if await stateStore.pendingApproval(requestID: requestID) == nil {
                try? await membershipPublisher.discardStagedMembership(transactionID: pending.transactionID)
            }
            throw error
        }
        try await complete(pending)
        try await supersedeDuplicateRequests(matching: request)
        return approval
    }

    private func supersedeDuplicateRequests(matching approvedRequest: EnrollmentRequest) async throws {
        let timestamp = now()
        var retiredAny = false
        for request in await stateStore.pendingRequests() where
            request.requestID != approvedRequest.requestID
                && request.nodeID == approvedRequest.nodeID
                && request.nodePublicKey == approvedRequest.nodePublicKey {
            let rejection = try EnrollmentWireSigner.rejection(
                request: request,
                reason: .superseded,
                authority: authority,
                issuedAt: timestamp
            )
            try await stateStore.finalizeRejection(rejection)
            retiredAny = true
        }
        if retiredAny { await pruneTerminalAuditRecords() }
    }

    public func resumePendingApprovals() async throws -> [EnrollmentApproval] {
        let pending = await stateStore.pendingApprovals()
        for item in pending { try await complete(item) }
        return pending.map(\.approval)
    }

    private func pruneTerminalAuditRecords() async {
        try? await stateStore.pruneTerminalRecords(
            keepingMostRecent: auditRetentionPolicy.maximumTerminalRecords
        )
    }

    private func complete(_ pending: PendingAuthorityApproval) async throws {
        try await membershipPublisher.activateMembership(transactionID: pending.transactionID)
        try await stateStore.finalizeApproval(
            requestID: pending.request.requestID,
            transactionID: pending.transactionID
        )
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}
