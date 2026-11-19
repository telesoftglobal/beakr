#if canImport(Security)
import Foundation
import Security
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

public struct AppleEnrollmentIdentityRestorer: EnrollmentIdentityRestoring {
    public let namespace: ProfileKeychainNamespace

    public init(namespace: ProfileKeychainNamespace) {
        self.namespace = namespace
    }

    public func restoreNodeIdentity(nodeID: NodeID) throws -> NodeIdentity? {
        guard let identity = try KeychainNodeIdentityStore(namespace: namespace).load(),
              identity.nodeID == nodeID else {
            return nil
        }
        return identity
    }
}

public struct AppleEnrollmentRuntimeInspector: EnrollmentRuntimeInspecting {
    public typealias TrustStateInspector = @Sendable (EnrollmentLifecycleRecord) async throws
        -> TrustStateHealth
    public typealias AuthorityKeyInspector = @Sendable (LocalAuthorityBinding) async throws -> Bool

    public let namespace: ProfileKeychainNamespace
    public let allowedClockSkew: TimeInterval
    private let now: @Sendable () -> Date
    private let revokedCredentialIDs: @Sendable () async throws -> Set<UUID>
    private let trustStateInspector: TrustStateInspector
    private let authorityKeyInspector: AuthorityKeyInspector

    public init(
        namespace: ProfileKeychainNamespace,
        allowedClockSkew: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = Date.init,
        revokedCredentialIDs: @escaping @Sendable () async throws -> Set<UUID>,
        trustStateInspector: @escaping TrustStateInspector,
        authorityKeyInspector: @escaping AuthorityKeyInspector = { _ in false }
    ) {
        precondition(allowedClockSkew >= 0)
        self.namespace = namespace
        self.allowedClockSkew = allowedClockSkew
        self.now = now
        self.revokedCredentialIDs = revokedCredentialIDs
        self.trustStateInspector = trustStateInspector
        self.authorityKeyInspector = authorityKeyInspector
    }

    public func runtimeFacts(for record: EnrollmentLifecycleRecord) async throws
        -> EnrollmentRuntimeFacts {
        do {
            let identity = try KeychainNodeIdentityStore(namespace: namespace).load()
            let nodeKeyAvailable = identity?.nodeID == record.nodeID
            let revoked = try await revokedCredentialIDs()
            let credentialHealth = try credentialHealth(
                record: record,
                identity: identity,
                revokedCredentialIDs: revoked
            )
            let trustHealth = try await trustStateInspector(record)
            let certificateHealth = try certificateHealth(nodeKeyAvailable: nodeKeyAvailable)
            let authorityKeyAvailable: Bool
            if let authority = record.authority {
                authorityKeyAvailable = try await authorityKeyInspector(authority)
            } else {
                authorityKeyAvailable = false
            }
            return EnrollmentRuntimeFacts(
                nodeKeyAvailable: nodeKeyAvailable,
                credentialHealth: credentialHealth,
                trustStateHealth: trustHealth,
                certificateHealth: certificateHealth,
                authorityKeyAvailable: authorityKeyAvailable
            )
        } catch let error as KeychainNodeIdentityStoreError where Self.isLocked(error) {
            return Self.lockedFacts(authorityPresent: record.authority != nil)
        } catch let error as ProfileKeychainCredentialError where Self.isLocked(error) {
            return Self.lockedFacts(authorityPresent: record.authority != nil)
        } catch let error as KeychainLANTLSIdentityStoreError where Self.isLocked(error) {
            return Self.lockedFacts(authorityPresent: record.authority != nil)
        }
    }

    private func credentialHealth(
        record: EnrollmentLifecycleRecord,
        identity: NodeIdentity?,
        revokedCredentialIDs: Set<UUID>
    ) throws -> CredentialHealth {
        guard let network = record.network,
              let nodeID = record.nodeID,
              let identity,
              identity.nodeID == nodeID else {
            return .missing
        }
        let profile = try NetworkProfile(
            id: namespace.profileID,
            networkID: network.networkID,
            localNodeID: nodeID,
            displayName: network.displayName
        )
        guard let credential = try KeychainNodeCredentialStore(namespace: namespace).load(for: profile) else {
            return .missing
        }
        if revokedCredentialIDs.contains(credential.claims.credentialID) { return .revoked }
        let nowMilliseconds = Int64((now().timeIntervalSince1970 * 1_000).rounded(.down))
        let skewMilliseconds = Int64(allowedClockSkew * 1_000)
        if credential.claims.expiresAtMilliseconds <= nowMilliseconds - skewMilliseconds {
            return .expired
        }
        do {
            try CredentialVerifier.verify(
                credential,
                trustedAuthorityPublicKey: network.authorityPublicKey,
                networkID: network.networkID,
                environment: network.environment,
                revokedCredentialIDs: revokedCredentialIDs,
                now: now(),
                allowedClockSkew: allowedClockSkew
            )
            return .valid
        } catch CredentialVerificationError.revoked {
            return .revoked
        } catch CredentialVerificationError.expired {
            return .expired
        } catch {
            return .missing
        }
    }

    private func certificateHealth(nodeKeyAvailable: Bool) throws -> CertificateHealth {
        guard nodeKeyAvailable else { return .missing }
        do {
            return try KeychainLANTLSIdentityStore(namespace: namespace).load() == nil
                ? .missing
                : .valid
        } catch let error as KeychainLANTLSIdentityStoreError {
            if Self.isLocked(error) { throw error }
            return .invalid
        }
    }

    private static func lockedFacts(authorityPresent: Bool) -> EnrollmentRuntimeFacts {
        EnrollmentRuntimeFacts(
            nodeKeyAvailable: false,
            credentialHealth: .missing,
            trustStateHealth: .missing,
            certificateHealth: .missing,
            authorityKeyAvailable: false,
            secureStorageLocked: true
        )
    }

    private static func isLocked(_ error: KeychainNodeIdentityStoreError) -> Bool {
        if case .unexpectedStatus(let status) = error { return isLocked(status) }
        return false
    }

    private static func isLocked(_ error: ProfileKeychainCredentialError) -> Bool {
        if case .unexpectedStatus(let status) = error { return isLocked(status) }
        return false
    }

    private static func isLocked(_ error: KeychainLANTLSIdentityStoreError) -> Bool {
        if case .unexpectedStatus(let status) = error { return isLocked(status) }
        return false
    }

    private static func isLocked(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecNotAvailable
    }
}
#endif
