import Foundation
import BeakrNetCore

public protocol CertificateEnrollmentMembershipPublishing: Sendable {
    func publishEnrollment(
        request: CertificateEnrollmentRequest,
        response: CertificateEnrollmentResponse,
        now: Date
    ) async throws
}

public enum ProfileMembershipPublicationError: Error, Equatable, Sendable {
    case noncanonicalState
    case wrongNetwork
    case generationExhausted
    case snapshotTooLarge
}

/// Owns the authority's durable membership state and its served snapshot.
/// Every successful mutation is signed, atomically persisted, and only then
/// made visible through the HTTP endpoint.
public actor ProfileMembershipPublisher: CertificateEnrollmentMembershipPublishing {
    public static let maximumSnapshotBytes = ProfileMembershipHTTPEndpoint.maximumBodySize

    public let networkID: NetworkID
    public let environment: String
    public let fileURL: URL
    public let endpoint: ProfileMembershipHTTPEndpoint

    private let signer: ProfileMembershipAuthority
    private let trustedAuthorityPublicKey: Data
    private var snapshot: ProfileMembershipSnapshot

    private init(
        networkID: NetworkID,
        environment: String,
        fileURL: URL,
        signer: ProfileMembershipAuthority,
        trustedAuthorityPublicKey: Data,
        snapshot: ProfileMembershipSnapshot,
        endpoint: ProfileMembershipHTTPEndpoint
    ) {
        self.networkID = networkID
        self.environment = environment
        self.fileURL = fileURL
        self.signer = signer
        self.trustedAuthorityPublicKey = trustedAuthorityPublicKey
        self.snapshot = snapshot
        self.endpoint = endpoint
    }

    public static func open(
        networkID: NetworkID,
        environment: String,
        fileURL: URL,
        authorityPrivateKey: Data,
        authorityPublicKey: Data,
        now: Date = Date()
    ) async throws -> ProfileMembershipPublisher {
        let signer = try ProfileMembershipAuthority(privateKeyRepresentation: authorityPrivateKey)
        let snapshot: ProfileMembershipSnapshot
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= maximumSnapshotBytes else {
                throw ProfileMembershipPublicationError.snapshotTooLarge
            }
            snapshot = try ProfileMembershipWireCodec.decode(data)
            try ProfileMembershipVerifier.verify(
                snapshot,
                networkID: networkID,
                environment: environment,
                trustedAuthorityPublicKey: authorityPublicKey,
                revokedCredentialIDs: [],
                now: now
            )
        } else {
            snapshot = try signer.sign(.init(
                networkID: networkID,
                generation: 0,
                generatedAtMilliseconds: milliseconds(now),
                records: []
            ))
            try persist(snapshot, to: fileURL)
        }
        guard snapshot.claims.networkID == networkID else {
            throw ProfileMembershipPublicationError.wrongNetwork
        }
        let endpoint = ProfileMembershipHTTPEndpoint(snapshot: snapshot)
        return ProfileMembershipPublisher(
            networkID: networkID,
            environment: environment,
            fileURL: fileURL,
            signer: signer,
            trustedAuthorityPublicKey: authorityPublicKey,
            snapshot: snapshot,
            endpoint: endpoint
        )
    }

    public func publishEnrollment(
        request: CertificateEnrollmentRequest,
        response: CertificateEnrollmentResponse,
        now: Date
    ) async throws {
        let existing = snapshot.claims.records.first {
            $0.credential.claims.nodeID == request.nodeID
        }
        let record = ProfileMembershipRecord(
            credential: request.credential,
            certificatePublicKey: response.nodePublicKey,
            sessionID: existing?.sessionID ?? SessionID()
        )
        try CredentialVerifier.verify(
            request.credential,
            trustedAuthorityPublicKey: trustedAuthorityPublicKey,
            networkID: networkID,
            environment: environment,
            now: now
        )
        var records = snapshot.claims.records.filter {
            $0.credential.claims.nodeID != request.nodeID
        }
        records.append(record)
        try await publish(records: records, now: now)
    }

    public func remove(nodeID: NodeID, now: Date = Date()) async throws {
        try await publish(
            records: snapshot.claims.records.filter { $0.credential.claims.nodeID != nodeID },
            now: now
        )
    }

    /// Used after explicit approval or authority recovery to install the complete
    /// authoritative set through the same monotonic durable publication path.
    public func replaceAll(records: [ProfileMembershipRecord], now: Date = Date()) async throws {
        try await publish(records: records, now: now)
    }

    public func latestSnapshot() -> ProfileMembershipSnapshot { snapshot }

    private func publish(records: [ProfileMembershipRecord], now: Date) async throws {
        guard snapshot.claims.generation < UInt64.max else {
            throw ProfileMembershipPublicationError.generationExhausted
        }
        let proposed = try signer.sign(.init(
            networkID: networkID,
            generation: snapshot.claims.generation + 1,
            generatedAtMilliseconds: Self.milliseconds(now),
            records: records
        ))
        try ProfileMembershipVerifier.verify(
            proposed,
            networkID: networkID,
            environment: environment,
            trustedAuthorityPublicKey: trustedAuthorityPublicKey,
            revokedCredentialIDs: [],
            now: now
        )
        try Self.persist(proposed, to: fileURL)
        try await endpoint.replaceSnapshot(proposed)
        snapshot = proposed
    }

    private static func persist(_ snapshot: ProfileMembershipSnapshot, to fileURL: URL) throws {
        let data = try ProfileMembershipWireCodec.encode(snapshot)
        guard data.count <= maximumSnapshotBytes else {
            throw ProfileMembershipPublicationError.snapshotTooLarge
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}
