import Foundation
import CryptoKit

public struct OperationalBackupComponent: Codable, Equatable, Sendable {
    public let name: String
    public let byteCount: UInt64
    public let digest: Data
    public init(name: String, byteCount: UInt64, digest: Data) {
        self.name = name; self.byteCount = byteCount; self.digest = digest
    }
}

public struct OperationalBackupManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let environment: String
    public let authorityGeneration: UInt64
    public let sequence: UInt64
    public let createdAt: Date
    public let components: [OperationalBackupComponent]

    public init(version: Int = Self.currentVersion, environment: String, authorityGeneration: UInt64,
                sequence: UInt64, createdAt: Date, components: [OperationalBackupComponent]) {
        self.version = version; self.environment = environment; self.authorityGeneration = authorityGeneration
        self.sequence = sequence; self.createdAt = createdAt; self.components = components.sorted { $0.name < $1.name }
    }
}

public enum OperationalRestoreError: Error, Equatable, Sendable {
    case unsupportedVersion, wrongEnvironment, generationRollback, sequenceRollback
    case invalidComponent, resourceLimit, missingComponent(String), lengthMismatch(String), digestMismatch(String)
}

public struct OperationalBackupVerifier: Sendable {
    public let maximumComponents: Int
    public let maximumComponentBytes: UInt64
    public let maximumTotalBytes: UInt64

    public init(maximumComponents: Int = 64, maximumComponentBytes: UInt64 = 64 * 1_024 * 1_024,
                maximumTotalBytes: UInt64 = 512 * 1_024 * 1_024) {
        precondition(maximumComponents > 0 && maximumComponentBytes > 0 && maximumTotalBytes > 0)
        self.maximumComponents = maximumComponents
        self.maximumComponentBytes = maximumComponentBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    public func verify(manifest: OperationalBackupManifest, components: [String: Data],
                       expectedEnvironment: String, minimumAuthorityGeneration: UInt64,
                       minimumSequence: UInt64) throws {
        guard manifest.version == OperationalBackupManifest.currentVersion else { throw OperationalRestoreError.unsupportedVersion }
        guard manifest.environment == expectedEnvironment else { throw OperationalRestoreError.wrongEnvironment }
        guard manifest.authorityGeneration >= minimumAuthorityGeneration else { throw OperationalRestoreError.generationRollback }
        guard manifest.sequence > minimumSequence else { throw OperationalRestoreError.sequenceRollback }
        guard !manifest.components.isEmpty,
              manifest.components == manifest.components.sorted(by: { $0.name < $1.name }),
              Set(manifest.components.map(\.name)).count == manifest.components.count,
              manifest.components.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 128 && $0.digest.count == 32 }) else {
            throw OperationalRestoreError.invalidComponent
        }
        var totalBytes: UInt64 = 0
        guard manifest.components.count <= maximumComponents else { throw OperationalRestoreError.resourceLimit }
        for component in manifest.components {
            guard component.byteCount <= maximumComponentBytes,
                  component.byteCount <= maximumTotalBytes - totalBytes else {
                throw OperationalRestoreError.resourceLimit
            }
            totalBytes += component.byteCount
        }
        for component in manifest.components {
            guard let data = components[component.name] else { throw OperationalRestoreError.missingComponent(component.name) }
            guard UInt64(data.count) == component.byteCount else { throw OperationalRestoreError.lengthMismatch(component.name) }
            guard Data(SHA256.hash(data: data)) == component.digest else { throw OperationalRestoreError.digestMismatch(component.name) }
        }
        guard components.count == manifest.components.count else { throw OperationalRestoreError.invalidComponent }
    }
}

public protocol OperationalRestoreActivator: Sendable {
    func activate(manifest: OperationalBackupManifest, verifiedComponents: [String: Data]) async throws
}

public struct OperationalRestoreCoordinator: Sendable {
    private let verifier: OperationalBackupVerifier
    private let activator: any OperationalRestoreActivator
    public init(verifier: OperationalBackupVerifier = OperationalBackupVerifier(),
                activator: any OperationalRestoreActivator) {
        self.verifier = verifier
        self.activator = activator
    }

    public func restore(manifest: OperationalBackupManifest, components: [String: Data],
                        expectedEnvironment: String, minimumAuthorityGeneration: UInt64,
                        minimumSequence: UInt64) async throws {
        try verifier.verify(manifest: manifest, components: components, expectedEnvironment: expectedEnvironment,
                            minimumAuthorityGeneration: minimumAuthorityGeneration, minimumSequence: minimumSequence)
        try await activator.activate(manifest: manifest, verifiedComponents: components)
    }
}
