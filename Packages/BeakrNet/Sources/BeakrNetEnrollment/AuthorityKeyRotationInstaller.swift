import Foundation
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

public enum AuthorityKeyRotationInstallationPhase: String, Codable, Sendable {
    case prepared
    case keyActivated
    case metadataCommitted
}

public struct AuthorityKeyRotationInstallationRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let phase: AuthorityKeyRotationInstallationPhase
    public let statement: AuthorityKeyRotationStatement

    public init(phase: AuthorityKeyRotationInstallationPhase, statement: AuthorityKeyRotationStatement) {
        version = Self.currentVersion
        self.phase = phase
        self.statement = statement
    }
}

public enum AuthorityKeyRotationRecoveryAction: Equatable, Sendable {
    case none
    case activateStagedPrivateKey(replacementAuthorityID: AuthorityID)
    case commitMetadata(replacementAuthorityID: AuthorityID)
}

/// Crash-safe metadata half of authority-key replacement. Private-key custody stages
/// and activates the replacement separately, then calls `markKeyActivated`.
public enum AuthorityKeyRotationInstaller {
    public static let transactionFilename = "authority-key-rotation.json"
    public static let stagedManifestFilename = "network.json.rotation-next"
    public static let stagedPublicKeyFilename = "authority-public.key.rotation-next"
    public static let stagedKeyringFilename = "audit-verification-keys.json.rotation-next"
    public static let stagedAdministratorCredentialFilename = "administrator-credential.json.rotation-next"
    public static let stagedTrustLedgerFilename = "trust-ledger.json.rotation-next"

    public static func prepare(
        bundleURL: URL,
        statement: AuthorityKeyRotationStatement,
        replacementAuthority: CredentialAuthority,
        administratorIdentity: NodeIdentity,
        credentialValidity: TimeInterval = 365 * 24 * 60 * 60,
        now: Date = Date()
    ) throws {
        let manifest = try NetworkBootstrap.loadManifest(from: bundleURL)
        try statement.verify(networkID: manifest.profile.networkID)
        guard manifest.authorityID == statement.claims.retiringAuthorityID,
              replacementAuthority.authorityID == statement.claims.replacementAuthorityID,
              replacementAuthority.publicKeyRepresentation == statement.claims.replacementPublicKey,
              administratorIdentity.nodeID == manifest.profile.localNodeID,
              credentialValidity > 0 else {
            throw EnrollmentAuditExportVerificationError.invalidRotationStatement
        }
        let enrollmentURL = bundleURL.appendingPathComponent("enrollment", isDirectory: true)
        let keyringURL = enrollmentURL.appendingPathComponent("audit-verification-keys.json")
        let keyring = try EnrollmentAuditVerificationKeyring.open(
            fileURL: keyringURL,
            currentPublicKey: statement.claims.retiringPublicKey
        )
        let rotatedKeyring = try keyring.applyingVerifiedRotation(
            statement,
            networkID: manifest.profile.networkID
        )
        let replacementManifest = NetworkBootstrapManifest(
            profile: manifest.profile,
            authorityID: statement.claims.replacementAuthorityID,
            environment: manifest.environment,
            serviceScopes: manifest.serviceScopes,
            controlPlaneURL: manifest.controlPlaneURL
        )
        try write(replacementManifest, to: bundleURL.appendingPathComponent(stagedManifestFilename))
        try statement.claims.replacementPublicKey.write(
            to: bundleURL.appendingPathComponent(stagedPublicKeyFilename),
            options: .atomic
        )
        try rotatedKeyring.persist(to: enrollmentURL.appendingPathComponent(stagedKeyringFilename))
        let administratorCredential = try replacementAuthority.issue(
            nodeID: administratorIdentity.nodeID,
            nodePublicKey: administratorIdentity.publicKeyRepresentation,
            networkID: manifest.profile.networkID,
            environment: manifest.environment,
            validity: credentialValidity,
            serviceScopes: manifest.serviceScopes,
            now: now
        )
        try CredentialFiles.saveCredential(
            administratorCredential,
            to: bundleURL.appendingPathComponent(stagedAdministratorCredentialFilename)
        )
        try AuthorityTrustStateCoordinator.writeSingleMemberLedger(
            authority: replacementAuthority,
            networkID: manifest.profile.networkID,
            environment: manifest.environment,
            networkDisplayName: manifest.profile.displayName,
            administratorCredential: administratorCredential,
            certificatePublicKey: administratorIdentity.publicKeyRepresentation,
            to: bundleURL.appendingPathComponent(stagedTrustLedgerFilename),
            now: now
        )
        try write(
            AuthorityKeyRotationInstallationRecord(phase: .prepared, statement: statement),
            to: enrollmentURL.appendingPathComponent(transactionFilename)
        )
    }

    public static func markKeyActivated(bundleURL: URL) throws {
        let record = try loadRecord(bundleURL: bundleURL)
        guard record.phase == .prepared else {
            throw EnrollmentAuditExportVerificationError.invalidRotationStatement
        }
        try validate(record, bundleURL: bundleURL)
        try write(
            AuthorityKeyRotationInstallationRecord(phase: .keyActivated, statement: record.statement),
            to: transactionURL(bundleURL)
        )
    }

    public static func recover(bundleURL: URL) throws -> AuthorityKeyRotationRecoveryAction {
        guard let record = try optionalRecord(bundleURL: bundleURL) else { return .none }
        try validate(record, bundleURL: bundleURL)
        switch record.phase {
        case .prepared:
            return .activateStagedPrivateKey(
                replacementAuthorityID: record.statement.claims.replacementAuthorityID
            )
        case .keyActivated, .metadataCommitted:
            try commitMetadata(bundleURL: bundleURL, record: record)
            return .none
        }
    }

    private static func commitMetadata(
        bundleURL: URL,
        record: AuthorityKeyRotationInstallationRecord
    ) throws {
        let fileManager = FileManager.default
        let enrollmentURL = bundleURL.appendingPathComponent("enrollment", isDirectory: true)
        try promote(
            staged: bundleURL.appendingPathComponent(stagedPublicKeyFilename),
            destination: bundleURL.appendingPathComponent(NetworkBootstrap.authorityPublicKeyFilename),
            fileManager: fileManager
        )
        try promote(
            staged: bundleURL.appendingPathComponent(stagedManifestFilename),
            destination: bundleURL.appendingPathComponent(NetworkBootstrap.manifestFilename),
            fileManager: fileManager
        )
        try promote(
            staged: enrollmentURL.appendingPathComponent(stagedKeyringFilename),
            destination: enrollmentURL.appendingPathComponent("audit-verification-keys.json"),
            fileManager: fileManager
        )
        try promote(
            staged: bundleURL.appendingPathComponent(stagedAdministratorCredentialFilename),
            destination: bundleURL.appendingPathComponent(NetworkBootstrap.administratorCredentialFilename),
            fileManager: fileManager
        )
        try promote(
            staged: bundleURL.appendingPathComponent(stagedTrustLedgerFilename),
            destination: bundleURL.appendingPathComponent(NetworkBootstrap.trustLedgerFilename),
            fileManager: fileManager
        )
        try archiveRetiredEnrollmentState(
            enrollmentURL: enrollmentURL,
            retiringAuthorityID: record.statement.claims.retiringAuthorityID,
            fileManager: fileManager
        )
        try write(
            AuthorityKeyRotationInstallationRecord(phase: .metadataCommitted, statement: record.statement),
            to: transactionURL(bundleURL)
        )
        try? fileManager.removeItem(at: transactionURL(bundleURL))
    }

    private static func promote(staged: URL, destination: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: staged.path) else { return }
        _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
    }

    private static func archiveRetiredEnrollmentState(
        enrollmentURL: URL,
        retiringAuthorityID: AuthorityID,
        fileManager: FileManager
    ) throws {
        let suffix = retiringAuthorityID.rawValue.uuidString.lowercased()
        for filename in ["authority-state.json", "membership-transactions.json"] {
            let source = enrollmentURL.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let archive = enrollmentURL.appendingPathComponent("\(filename).retired-\(suffix)")
            if fileManager.fileExists(atPath: archive.path) {
                try fileManager.removeItem(at: source)
            } else {
                try fileManager.moveItem(at: source, to: archive)
            }
        }
    }

    private static func optionalRecord(bundleURL: URL) throws -> AuthorityKeyRotationInstallationRecord? {
        let url = transactionURL(bundleURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(AuthorityKeyRotationInstallationRecord.self, from: Data(contentsOf: url))
    }

    private static func validate(
        _ record: AuthorityKeyRotationInstallationRecord,
        bundleURL: URL
    ) throws {
        guard record.version == AuthorityKeyRotationInstallationRecord.currentVersion else {
            throw EnrollmentAuditExportVerificationError.invalidRotationStatement
        }
        let manifest = try NetworkBootstrap.loadManifest(from: bundleURL)
        try record.statement.verify(networkID: manifest.profile.networkID)
        let permittedAuthorityIDs: Set<AuthorityID>
        switch record.phase {
        case .prepared:
            permittedAuthorityIDs = [record.statement.claims.retiringAuthorityID]
        case .keyActivated, .metadataCommitted:
            permittedAuthorityIDs = [
                record.statement.claims.retiringAuthorityID,
                record.statement.claims.replacementAuthorityID
            ]
        }
        guard permittedAuthorityIDs.contains(manifest.authorityID) else {
            throw EnrollmentAuditExportVerificationError.invalidRotationStatement
        }
        if record.phase == .prepared {
            let enrollmentURL = bundleURL.appendingPathComponent("enrollment", isDirectory: true)
            let requiredURLs = [
                bundleURL.appendingPathComponent(stagedManifestFilename),
                bundleURL.appendingPathComponent(stagedPublicKeyFilename),
                bundleURL.appendingPathComponent(stagedAdministratorCredentialFilename),
                bundleURL.appendingPathComponent(stagedTrustLedgerFilename),
                enrollmentURL.appendingPathComponent(stagedKeyringFilename)
            ]
            guard requiredURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }),
                  try Data(contentsOf: bundleURL.appendingPathComponent(stagedPublicKeyFilename))
                    == record.statement.claims.replacementPublicKey else {
                throw EnrollmentAuditExportVerificationError.invalidRotationStatement
            }
        }
    }

    private static func loadRecord(bundleURL: URL) throws -> AuthorityKeyRotationInstallationRecord {
        guard let record = try optionalRecord(bundleURL: bundleURL) else {
            throw EnrollmentAuditExportVerificationError.invalidRotationStatement
        }
        return record
    }

    private static func transactionURL(_ bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("enrollment", isDirectory: true)
            .appendingPathComponent(transactionFilename)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
