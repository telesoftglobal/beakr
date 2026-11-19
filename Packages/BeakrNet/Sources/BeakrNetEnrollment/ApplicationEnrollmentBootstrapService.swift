import Foundation

public protocol EnrollmentColdStartRestoring: Sendable {
    func restore() async throws -> EnrollmentColdStartResult
}

extension EnrollmentColdStartRestorationCoordinator: EnrollmentColdStartRestoring {}

public enum EnrollmentApplicationRoute: Equatable, Sendable {
    case welcome
    case identityReady
    case waitingForAdministrator(requestID: UUID)
    case restoringMembership
    case member
    case locked
    case credentialRecovery
    case trustRecovery
    case certificateRecovery
    case leaving
    case recoveryRequired(EnrollmentColdStartRecoveryReason)
}

public actor ApplicationEnrollmentBootstrapService {
    private let restoration: any EnrollmentColdStartRestoring

    public init(restoration: any EnrollmentColdStartRestoring) {
        self.restoration = restoration
    }

    public func start() async throws -> EnrollmentApplicationRoute {
        switch try await restoration.restore() {
        case .unconfigured, .leaveCompleted:
            return .welcome
        case .waitingForAdministrator(let requestID, _):
            return .waitingForAdministrator(requestID: requestID)
        case .memberRuntimeStarted:
            return .member
        case .recoveryRequired(let reason):
            return .recoveryRequired(reason)
        case .restored(let state):
            return Self.route(for: state.node)
        }
    }

    private static func route(for state: NodeLifecycleState) -> EnrollmentApplicationRoute {
        switch state {
        case .unconfigured:
            return .welcome
        case .identityReady:
            return .identityReady
        case .waitingForAdministrator:
            return .recoveryRequired(.lifecycleRequiresRecovery)
        case .installingMembership:
            return .restoringMembership
        case .ready:
            return .member
        case .locked:
            return .locked
        case .credentialMissing, .credentialExpired, .credentialRevoked:
            return .credentialRecovery
        case .trustStateMissing, .trustStateStale, .trustStateInvalid:
            return .trustRecovery
        case .certificateRecoveryRequired:
            return .certificateRecovery
        case .leaving:
            return .leaving
        case .recoveryRequired:
            return .recoveryRequired(.invalidRestoredState(state))
        }
    }
}
