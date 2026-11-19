import Foundation

public struct AuthorityPolicy: Codable, Equatable, Sendable {
    public static let maximumValidity: TimeInterval = 366 * 24 * 60 * 60
    public static let maximumClockSkew: TimeInterval = 5 * 60
    public static let maximumCollectionCapacity = 100_000
    public static let maximumWirePayloadBytes = 1_048_576

    public let credentialValidity: TimeInterval
    public let certificateValidity: TimeInterval
    public let invitationValidity: TimeInterval
    public let pendingRequestValidity: TimeInterval
    public let allowedClockSkew: TimeInterval
    public let maximumPendingInvitations: Int
    public let maximumPendingRequests: Int
    public let maximumEnrolledDevices: Int
    public let maximumPayloadBytes: Int
    public let defaultDeviceRole: DeviceRole
    public let permittedRequestedRoles: Set<DeviceRole>
    public let credentialServiceScopes: Set<String>
    public let requiresLocalAuthorizationForApproval: Bool
    public let requiresLocalAuthorizationForRevocation: Bool

    public init(
        credentialValidity: TimeInterval,
        certificateValidity: TimeInterval,
        invitationValidity: TimeInterval,
        pendingRequestValidity: TimeInterval,
        allowedClockSkew: TimeInterval,
        maximumPendingInvitations: Int,
        maximumPendingRequests: Int,
        maximumEnrolledDevices: Int,
        maximumPayloadBytes: Int,
        defaultDeviceRole: DeviceRole = .member,
        permittedRequestedRoles: Set<DeviceRole> = [.member],
        credentialServiceScopes: Set<String>,
        requiresLocalAuthorizationForApproval: Bool = true,
        requiresLocalAuthorizationForRevocation: Bool = true
    ) throws {
        self.credentialValidity = credentialValidity
        self.certificateValidity = certificateValidity
        self.invitationValidity = invitationValidity
        self.pendingRequestValidity = pendingRequestValidity
        self.allowedClockSkew = allowedClockSkew
        self.maximumPendingInvitations = maximumPendingInvitations
        self.maximumPendingRequests = maximumPendingRequests
        self.maximumEnrolledDevices = maximumEnrolledDevices
        self.maximumPayloadBytes = maximumPayloadBytes
        self.defaultDeviceRole = defaultDeviceRole
        self.permittedRequestedRoles = permittedRequestedRoles
        self.credentialServiceScopes = credentialServiceScopes
        self.requiresLocalAuthorizationForApproval = requiresLocalAuthorizationForApproval
        self.requiresLocalAuthorizationForRevocation = requiresLocalAuthorizationForRevocation
        try validate()
    }

    public func validate() throws {
        let validityValues = [credentialValidity, certificateValidity, invitationValidity, pendingRequestValidity]
        guard validityValues.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= Self.maximumValidity }) else {
            throw AuthorityPolicyError.invalidValidity
        }
        guard allowedClockSkew.isFinite,
              allowedClockSkew >= 0,
              allowedClockSkew <= Self.maximumClockSkew else {
            throw AuthorityPolicyError.invalidClockSkew
        }
        let capacities = [maximumPendingInvitations, maximumPendingRequests, maximumEnrolledDevices]
        guard capacities.allSatisfy({ $0 > 0 && $0 <= Self.maximumCollectionCapacity }),
              maximumPayloadBytes > 0,
              maximumPayloadBytes <= Self.maximumWirePayloadBytes else {
            throw AuthorityPolicyError.invalidResourceBounds
        }
        guard permittedRequestedRoles == [.member], defaultDeviceRole == .member else {
            throw AuthorityPolicyError.invalidRolePolicy
        }
        guard requiresLocalAuthorizationForApproval, requiresLocalAuthorizationForRevocation else {
            throw AuthorityPolicyError.localAuthorizationRequired
        }
        guard !credentialServiceScopes.isEmpty,
              credentialServiceScopes.count <= 64,
              credentialServiceScopes.allSatisfy({ scope in
                  let normalized = scope.trimmingCharacters(in: .whitespacesAndNewlines)
                  return !normalized.isEmpty && normalized == scope && scope.utf8.count <= 128
              }) else {
            throw AuthorityPolicyError.invalidServiceScopes
        }
    }
}

public enum AuthorityPolicyError: Error, Equatable, Sendable {
    case invalidValidity
    case invalidClockSkew
    case invalidResourceBounds
    case invalidRolePolicy
    case localAuthorizationRequired
    case invalidServiceScopes
}
