import Foundation

public enum CredentialHealth: Sendable {
    case valid
    case missing
    case expired
    case revoked
}

public enum TrustStateHealth: Sendable {
    case valid
    case missing
    case stale
    case invalid
}

public enum CertificateHealth: Sendable {
    case valid
    case missing
    case expired
    case invalid
}

public struct EnrollmentRuntimeFacts: Sendable {
    public let nodeKeyAvailable: Bool
    public let credentialHealth: CredentialHealth
    public let trustStateHealth: TrustStateHealth
    public let certificateHealth: CertificateHealth
    public let authorityKeyAvailable: Bool
    public let secureStorageLocked: Bool

    public init(
        nodeKeyAvailable: Bool,
        credentialHealth: CredentialHealth,
        trustStateHealth: TrustStateHealth,
        certificateHealth: CertificateHealth,
        authorityKeyAvailable: Bool = false,
        secureStorageLocked: Bool = false
    ) {
        self.nodeKeyAvailable = nodeKeyAvailable
        self.credentialHealth = credentialHealth
        self.trustStateHealth = trustStateHealth
        self.certificateHealth = certificateHealth
        self.authorityKeyAvailable = authorityKeyAvailable
        self.secureStorageLocked = secureStorageLocked
    }
}

public enum NodeLifecycleState: Equatable, Sendable {
    case unconfigured
    case identityReady
    case waitingForAdministrator
    case installingMembership
    case ready
    case locked
    case credentialMissing
    case credentialExpired
    case credentialRevoked
    case trustStateMissing
    case trustStateStale
    case trustStateInvalid
    case certificateRecoveryRequired
    case leaving
    case recoveryRequired
}

public enum AuthorityLifecycleState: Equatable, Sendable {
    case unavailable
    case locked
    case ready
    case recoveryRequired
}

public struct DerivedEnrollmentState: Equatable, Sendable {
    public let node: NodeLifecycleState
    public let authority: AuthorityLifecycleState

    public init(node: NodeLifecycleState, authority: AuthorityLifecycleState) {
        self.node = node
        self.authority = authority
    }
}

public enum EnrollmentStateDeriver {
    public static func derive(
        record: EnrollmentLifecycleRecord?,
        facts: EnrollmentRuntimeFacts
    ) -> DerivedEnrollmentState {
        guard let record else {
            return DerivedEnrollmentState(node: .unconfigured, authority: .unavailable)
        }
        if facts.secureStorageLocked {
            return DerivedEnrollmentState(
                node: record.phase == .unconfigured ? .unconfigured : .locked,
                authority: record.authority == nil ? .unavailable : .locked
            )
        }

        let authorityState: AuthorityLifecycleState
        if record.authority == nil {
            authorityState = .unavailable
        } else if facts.authorityKeyAvailable {
            authorityState = .ready
        } else {
            authorityState = .recoveryRequired
        }

        guard record.phase == .member else {
            let nodeState: NodeLifecycleState
            switch record.phase {
            case .unconfigured: nodeState = .unconfigured
            case .identityReady: nodeState = facts.nodeKeyAvailable ? .identityReady : .recoveryRequired
            case .joining: nodeState = facts.nodeKeyAvailable ? .waitingForAdministrator : .recoveryRequired
            case .installingMembership: nodeState = facts.nodeKeyAvailable ? .installingMembership : .recoveryRequired
            case .leaving: nodeState = .leaving
            case .recoveryRequired, .member: nodeState = .recoveryRequired
            }
            return DerivedEnrollmentState(node: nodeState, authority: authorityState)
        }

        guard facts.nodeKeyAvailable else {
            return DerivedEnrollmentState(node: .recoveryRequired, authority: authorityState)
        }
        let nodeState: NodeLifecycleState
        switch facts.credentialHealth {
        case .missing: nodeState = .credentialMissing
        case .expired: nodeState = .credentialExpired
        case .revoked: nodeState = .credentialRevoked
        case .valid:
            switch facts.trustStateHealth {
            case .missing: nodeState = .trustStateMissing
            case .stale: nodeState = .trustStateStale
            case .invalid: nodeState = .trustStateInvalid
            case .valid:
                switch facts.certificateHealth {
                case .valid: nodeState = .ready
                case .missing, .expired, .invalid: nodeState = .certificateRecoveryRequired
                }
            }
        }
        return DerivedEnrollmentState(node: nodeState, authority: authorityState)
    }
}
