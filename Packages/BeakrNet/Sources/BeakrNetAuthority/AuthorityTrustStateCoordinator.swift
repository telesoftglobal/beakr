import Foundation
import BeakrNetCore

private struct AuthorityTrustLedger: Codable, Equatable, Sendable {
    let membership: ProfileMembershipSnapshot
    let revocations: CredentialRevocationSnapshot
}

public enum AuthorityTrustStateError: Error, Equatable, Sendable {
    case noncanonicalLedger
    case ledgerTooLarge
    case nodeNotFound
}

/// Authority-host composition boundary. Membership and revocations are stored
/// in one canonical ledger so an operator mutation becomes durable as a unit
/// before either independently served endpoint advances.
public actor AuthorityTrustStateCoordinator: CertificateEnrollmentMembershipPublishing {
    public static let maximumLedgerBytes = 4_194_304

    public let membershipEndpoint: ProfileMembershipHTTPEndpoint
    public let revocationEndpoint: RevocationSnapshotHTTPEndpoint

    private let authority: CredentialAuthority
    private let networkID: NetworkID
    private let environment: String
    private let ledgerURL: URL
    private var ledger: AuthorityTrustLedger

    private init(
        authority: CredentialAuthority,
        networkID: NetworkID,
        environment: String,
        ledgerURL: URL,
        ledger: AuthorityTrustLedger,
        membershipEndpoint: ProfileMembershipHTTPEndpoint,
        revocationEndpoint: RevocationSnapshotHTTPEndpoint
    ) {
        self.authority = authority
        self.networkID = networkID
        self.environment = environment
        self.ledgerURL = ledgerURL
        self.ledger = ledger
        self.membershipEndpoint = membershipEndpoint
        self.revocationEndpoint = revocationEndpoint
    }

    public static func open(
        authority: CredentialAuthority,
        networkID: NetworkID,
        environment: String,
        networkDisplayName: String = "Network",
        ledgerURL: URL,
        now: Date = Date()
    ) async throws -> AuthorityTrustStateCoordinator {
        let ledger: AuthorityTrustLedger
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            let data = try Data(contentsOf: ledgerURL)
            guard data.count <= maximumLedgerBytes else { throw AuthorityTrustStateError.ledgerTooLarge }
            ledger = try JSONDecoder().decode(AuthorityTrustLedger.self, from: data)
            guard try encode(ledger) == data else { throw AuthorityTrustStateError.noncanonicalLedger }
        } else {
            let membership = try ProfileMembershipAuthority(
                privateKeyRepresentation: authority.privateKeyRepresentation
            ).sign(.init(
                networkID: networkID,
                networkDisplayName: networkDisplayName,
                generation: 0,
                generatedAtMilliseconds: milliseconds(now),
                records: []
            ))
            ledger = AuthorityTrustLedger(
                membership: membership,
                revocations: try authority.issueRevocationSnapshot(revocations: [], now: now)
            )
            try persist(ledger, to: ledgerURL)
        }
        try verify(ledger, authority: authority, networkID: networkID, environment: environment, now: now)
        return AuthorityTrustStateCoordinator(
            authority: authority,
            networkID: networkID,
            environment: environment,
            ledgerURL: ledgerURL,
            ledger: ledger,
            membershipEndpoint: .init(snapshot: ledger.membership),
            revocationEndpoint: .init(snapshot: ledger.revocations)
        )
    }

    public func publishEnrollment(
        request: CertificateEnrollmentRequest,
        response: CertificateEnrollmentResponse,
        now: Date
    ) async throws {
        try await approve(
            credential: request.credential,
            certificatePublicKey: response.nodePublicKey,
            now: now
        )
    }

    public func approve(
        credential: NodeCredential,
        certificatePublicKey: Data,
        now: Date = Date()
    ) async throws {
        try CredentialVerifier.verify(
            credential,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: networkID,
            environment: environment,
            revokedCredentialIDs: Set(ledger.revocations.claims.revocations.map(\.credentialID)),
            now: now
        )
        let nodeID = credential.claims.nodeID
        let session = ledger.membership.claims.records.first {
            $0.credential.claims.nodeID == nodeID
        }?.sessionID ?? SessionID()
        var records = ledger.membership.claims.records.filter {
            $0.credential.claims.nodeID != nodeID
        }
        records.append(.init(
            credential: credential,
            certificatePublicKey: certificatePublicKey,
            sessionID: session
        ))
        try await commit(records: records, revocations: ledger.revocations.claims.revocations, now: now)
    }

    public func removeAndRevoke(
        nodeID: NodeID,
        reason: String,
        now: Date = Date()
    ) async throws {
        guard let record = ledger.membership.claims.records.first(where: {
            $0.credential.claims.nodeID == nodeID
        }) else { throw AuthorityTrustStateError.nodeNotFound }
        var revocations = ledger.revocations.claims.revocations.filter {
            $0.credentialID != record.credential.claims.credentialID
        }
        revocations.append(.init(
            credentialID: record.credential.claims.credentialID,
            revokedAtMilliseconds: Self.milliseconds(now),
            reason: reason
        ))
        try await commit(
            records: ledger.membership.claims.records.filter {
                $0.credential.claims.nodeID != nodeID
            },
            revocations: revocations,
            now: now
        )
    }

    public func membershipSnapshot() -> ProfileMembershipSnapshot { ledger.membership }
    public func revocationSnapshot() -> CredentialRevocationSnapshot { ledger.revocations }

    /// Re-signs the current revocation set so peers can authenticate after the
    /// previous snapshot's freshness window has elapsed.
    public func refreshRevocationSnapshot(now: Date = Date()) async throws {
        let nextMilliseconds = max(
            Self.milliseconds(now),
            ledger.revocations.claims.generatedAtMilliseconds + 1
        )
        let snapshot = try authority.issueRevocationSnapshot(
            revocations: ledger.revocations.claims.revocations,
            now: Date(timeIntervalSince1970: TimeInterval(nextMilliseconds) / 1_000)
        )
        let proposed = AuthorityTrustLedger(
            membership: ledger.membership,
            revocations: snapshot
        )
        try Self.verify(
            proposed,
            authority: authority,
            networkID: networkID,
            environment: environment,
            now: now
        )
        try Self.persist(proposed, to: ledgerURL)
        try await revocationEndpoint.replaceSnapshot(snapshot)
        ledger = proposed
    }

    public func renameNetwork(to displayName: String, now: Date = Date()) async throws {
        try await commit(
            records: ledger.membership.claims.records,
            revocations: ledger.revocations.claims.revocations,
            networkDisplayName: displayName,
            now: now
        )
    }

    private func commit(
        records: [ProfileMembershipRecord],
        revocations: [CredentialRevocation],
        networkDisplayName: String? = nil,
        now: Date
    ) async throws {
        let membership = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        ).sign(.init(
            networkID: networkID,
            networkDisplayName: networkDisplayName ?? ledger.membership.claims.networkDisplayName,
            generation: ledger.membership.claims.generation + 1,
            generatedAtMilliseconds: Self.milliseconds(now),
            records: records
        ))
        let nextRevocationMilliseconds = max(
            Self.milliseconds(now),
            ledger.revocations.claims.generatedAtMilliseconds + 1
        )
        let revocationSnapshot = try authority.issueRevocationSnapshot(
            revocations: revocations,
            now: Date(timeIntervalSince1970: TimeInterval(nextRevocationMilliseconds) / 1_000)
        )
        let proposed = AuthorityTrustLedger(
            membership: membership,
            revocations: revocationSnapshot
        )
        try Self.verify(
            proposed,
            authority: authority,
            networkID: networkID,
            environment: environment,
            now: now
        )
        try Self.persist(proposed, to: ledgerURL)
        try await membershipEndpoint.replaceSnapshot(membership)
        try await revocationEndpoint.replaceSnapshot(revocationSnapshot)
        ledger = proposed
    }

    private static func verify(
        _ ledger: AuthorityTrustLedger,
        authority: CredentialAuthority,
        networkID: NetworkID,
        environment: String,
        now: Date
    ) throws {
        let revoked = try RevocationVerifier.verify(
            ledger.revocations,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            now: now
        )
        try ProfileMembershipVerifier.verify(
            ledger.membership,
            networkID: networkID,
            environment: environment,
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            revokedCredentialIDs: revoked,
            now: now
        )
    }

    private static func persist(_ ledger: AuthorityTrustLedger, to url: URL) throws {
        let data = try encode(ledger)
        guard data.count <= maximumLedgerBytes else { throw AuthorityTrustStateError.ledgerTooLarge }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func encode(_ ledger: AuthorityTrustLedger) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ledger)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}
