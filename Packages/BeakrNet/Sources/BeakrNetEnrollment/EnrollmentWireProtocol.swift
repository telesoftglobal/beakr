import CryptoKit
import Foundation
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

public struct EnrollmentInvitation: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let messageType = "invitation"

    public let type: String
    public let version: Int
    public let invitationID: UUID
    public let networkID: NetworkID
    public let authorityID: AuthorityID
    public let authorityPublicKey: Data
    public let networkDisplayName: String
    public let environment: String
    public let controlPlaneURL: URL?
    public let authorityCertificateDER: Data?
    public let serviceScopes: [String]
    public let invitationSecret: Data
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let authoritySignature: Data

    public init(
        type: String = Self.messageType,
        version: Int = Self.currentVersion,
        invitationID: UUID,
        networkID: NetworkID,
        authorityID: AuthorityID,
        authorityPublicKey: Data,
        networkDisplayName: String,
        environment: String,
        controlPlaneURL: URL?,
        authorityCertificateDER: Data? = nil,
        serviceScopes: [String] = ["lan.connect", "relay.connect"],
        invitationSecret: Data,
        issuedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        authoritySignature: Data
    ) {
        self.type = type
        self.version = version
        self.invitationID = invitationID
        self.networkID = networkID
        self.authorityID = authorityID
        self.authorityPublicKey = authorityPublicKey
        self.networkDisplayName = networkDisplayName
        self.environment = environment
        self.controlPlaneURL = controlPlaneURL
        self.authorityCertificateDER = authorityCertificateDER
        self.serviceScopes = serviceScopes
        self.invitationSecret = invitationSecret
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.authoritySignature = authoritySignature
    }
}

public struct EnrollmentRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let messageType = "request"

    public let type: String
    public let version: Int
    public let requestID: UUID
    public let invitation: EnrollmentInvitation
    public let nodeID: NodeID
    public let deviceDisplayName: String?
    public let nodePublicKey: Data
    public let requestNonce: Data
    public let requestedRole: DeviceRole
    public let nodeSignature: Data

    public init(
        type: String = Self.messageType,
        version: Int = Self.currentVersion,
        requestID: UUID,
        invitation: EnrollmentInvitation,
        nodeID: NodeID,
        deviceDisplayName: String? = nil,
        nodePublicKey: Data,
        requestNonce: Data,
        requestedRole: DeviceRole = .member,
        nodeSignature: Data
    ) {
        self.type = type
        self.version = version
        self.requestID = requestID
        self.invitation = invitation
        self.nodeID = nodeID
        self.deviceDisplayName = deviceDisplayName
        self.nodePublicKey = nodePublicKey
        self.requestNonce = requestNonce
        self.requestedRole = requestedRole
        self.nodeSignature = nodeSignature
    }
}

public struct EnrollmentApproval: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let messageType = "approval"

    public let type: String
    public let version: Int
    public let approvalID: UUID
    public let invitationID: UUID
    public let requestID: UUID
    public let networkID: NetworkID
    public let authorityID: AuthorityID
    public let nodeID: NodeID
    public let requestNonce: Data
    public let credential: NodeCredential
    public let membership: ProfileMembershipSnapshot
    public let revocations: CredentialRevocationSnapshot
    public let issuedAtMilliseconds: Int64
    public let authoritySignature: Data

    public init(
        type: String = Self.messageType,
        version: Int = Self.currentVersion,
        approvalID: UUID,
        invitationID: UUID,
        requestID: UUID,
        networkID: NetworkID,
        authorityID: AuthorityID,
        nodeID: NodeID,
        requestNonce: Data,
        credential: NodeCredential,
        membership: ProfileMembershipSnapshot,
        revocations: CredentialRevocationSnapshot,
        issuedAtMilliseconds: Int64,
        authoritySignature: Data
    ) {
        self.type = type
        self.version = version
        self.approvalID = approvalID
        self.invitationID = invitationID
        self.requestID = requestID
        self.networkID = networkID
        self.authorityID = authorityID
        self.nodeID = nodeID
        self.requestNonce = requestNonce
        self.credential = credential
        self.membership = membership
        self.revocations = revocations
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.authoritySignature = authoritySignature
    }
}

public enum EnrollmentRejectionReason: String, Codable, Sendable {
    case declined
    case expiredInvitation
    case invalidRequest
    case capacityExceeded
    case policyDenied
    case superseded
    case invitationSuperseded
}

public struct EnrollmentRejection: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let messageType = "rejection"

    public let type: String
    public let version: Int
    public let rejectionID: UUID
    public let invitationID: UUID
    public let requestID: UUID
    public let networkID: NetworkID
    public let authorityID: AuthorityID
    public let nodeID: NodeID
    public let requestNonce: Data
    public let reason: EnrollmentRejectionReason
    public let issuedAtMilliseconds: Int64
    public let authoritySignature: Data

    public init(
        type: String = Self.messageType,
        version: Int = Self.currentVersion,
        rejectionID: UUID,
        invitationID: UUID,
        requestID: UUID,
        networkID: NetworkID,
        authorityID: AuthorityID,
        nodeID: NodeID,
        requestNonce: Data,
        reason: EnrollmentRejectionReason,
        issuedAtMilliseconds: Int64,
        authoritySignature: Data
    ) {
        self.type = type
        self.version = version
        self.rejectionID = rejectionID
        self.invitationID = invitationID
        self.requestID = requestID
        self.networkID = networkID
        self.authorityID = authorityID
        self.nodeID = nodeID
        self.requestNonce = requestNonce
        self.reason = reason
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.authoritySignature = authoritySignature
    }
}

public struct EnrollmentCancellation: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let messageType = "cancellation"

    public let type: String
    public let version: Int
    public let cancellationID: UUID
    public let invitationID: UUID
    public let requestID: UUID
    public let networkID: NetworkID
    public let nodeID: NodeID
    public let requestNonce: Data
    public let issuedAtMilliseconds: Int64
    public let nodeSignature: Data

    public init(
        type: String = Self.messageType,
        version: Int = Self.currentVersion,
        cancellationID: UUID,
        invitationID: UUID,
        requestID: UUID,
        networkID: NetworkID,
        nodeID: NodeID,
        requestNonce: Data,
        issuedAtMilliseconds: Int64,
        nodeSignature: Data
    ) {
        self.type = type
        self.version = version
        self.cancellationID = cancellationID
        self.invitationID = invitationID
        self.requestID = requestID
        self.networkID = networkID
        self.nodeID = nodeID
        self.requestNonce = requestNonce
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.nodeSignature = nodeSignature
    }
}

public struct EnrollmentConfirmation: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let messageType = "confirmation"

    public let type: String
    public let version: Int
    public let confirmationID: UUID
    public let approvalID: UUID
    public let requestID: UUID
    public let credentialID: UUID
    public let networkID: NetworkID
    public let nodeID: NodeID
    public let nodeSignature: Data

    public init(
        type: String = Self.messageType,
        version: Int = Self.currentVersion,
        confirmationID: UUID,
        approvalID: UUID,
        requestID: UUID,
        credentialID: UUID,
        networkID: NetworkID,
        nodeID: NodeID,
        nodeSignature: Data
    ) {
        self.type = type
        self.version = version
        self.confirmationID = confirmationID
        self.approvalID = approvalID
        self.requestID = requestID
        self.credentialID = credentialID
        self.networkID = networkID
        self.nodeID = nodeID
        self.nodeSignature = nodeSignature
    }
}

public enum EnrollmentWireError: Error, Equatable, Sendable {
    case payloadTooLarge
    case malformedPayload
    case nonCanonicalPayload
    case wrongMessageType
    case unsupportedVersion
    case invalidField
    case wrongAuthority
    case wrongNetwork
    case wrongRequest
    case nodeIdentityMismatch
    case issuedInFuture
    case expired
    case invalidSignature
    case invalidCredential
    case invalidMembership
    case invalidRevocations
}

public enum EnrollmentWireCodec {
    public static let maximumPayloadBytes = 256 * 1_024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try canonicalEncoder().encode(value)
        guard data.count <= maximumPayloadBytes else { throw EnrollmentWireError.payloadTooLarge }
        return data
    }

    public static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumPayloadBytes else { throw EnrollmentWireError.payloadTooLarge }
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            throw EnrollmentWireError.malformedPayload
        }
        guard try encode(value) == data else { throw EnrollmentWireError.nonCanonicalPayload }
        return value
    }

    fileprivate static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public enum EnrollmentWireSigner {
    public static func invitation(
        authority: CredentialAuthority,
        invitationID: UUID = UUID(),
        networkID: NetworkID,
        networkDisplayName: String,
        environment: String,
        controlPlaneURL: URL?,
        authorityCertificateDER: Data? = nil,
        serviceScopes: [String] = ["lan.connect", "relay.connect"],
        invitationSecret: Data,
        issuedAt: Date,
        validity: TimeInterval
    ) throws -> EnrollmentInvitation {
        let issuedAtMilliseconds = milliseconds(issuedAt)
        let unsigned = EnrollmentInvitation(
            invitationID: invitationID,
            networkID: networkID,
            authorityID: authority.authorityID,
            authorityPublicKey: authority.publicKeyRepresentation,
            networkDisplayName: networkDisplayName,
            environment: environment,
            controlPlaneURL: controlPlaneURL,
            authorityCertificateDER: authorityCertificateDER,
            serviceScopes: serviceScopes,
            invitationSecret: invitationSecret,
            issuedAtMilliseconds: issuedAtMilliseconds,
            expiresAtMilliseconds: issuedAtMilliseconds + Int64(validity * 1_000),
            authoritySignature: Data()
        )
        try EnrollmentWireVerifier.validateInvitationFields(unsigned)
        return replacingSignature(unsigned, with: try authoritySignature(
            authority: authority,
            domain: "BeakrNet enrollment invitation v1\0",
            value: unsigned
        ))
    }

    public static func request(
        invitation: EnrollmentInvitation,
        identity: NodeIdentity,
        deviceDisplayName: String? = nil,
        requestID: UUID = UUID(),
        requestNonce: Data
    ) throws -> EnrollmentRequest {
        let unsigned = EnrollmentRequest(
            requestID: requestID,
            invitation: invitation,
            nodeID: identity.nodeID,
            deviceDisplayName: deviceDisplayName,
            nodePublicKey: identity.publicKeyRepresentation,
            requestNonce: requestNonce,
            nodeSignature: Data()
        )
        try EnrollmentWireVerifier.validateRequestFields(unsigned)
        return replacingSignature(unsigned, with: try identity.signature(
            forCertificateEnrollmentTranscript: transcript(
                domain: "BeakrNet enrollment request v1\0",
                value: unsigned
            )
        ))
    }

    public static func approval(
        request: EnrollmentRequest,
        approvalID: UUID = UUID(),
        credential: NodeCredential,
        membership: ProfileMembershipSnapshot,
        revocations: CredentialRevocationSnapshot,
        authority: CredentialAuthority,
        issuedAt: Date
    ) throws -> EnrollmentApproval {
        let unsigned = EnrollmentApproval(
            approvalID: approvalID,
            invitationID: request.invitation.invitationID,
            requestID: request.requestID,
            networkID: request.invitation.networkID,
            authorityID: authority.authorityID,
            nodeID: request.nodeID,
            requestNonce: request.requestNonce,
            credential: credential,
            membership: membership,
            revocations: revocations,
            issuedAtMilliseconds: milliseconds(issuedAt),
            authoritySignature: Data()
        )
        return replacingSignature(unsigned, with: try authoritySignature(
            authority: authority,
            domain: "BeakrNet enrollment approval v1\0",
            value: unsigned
        ))
    }

    public static func rejection(
        request: EnrollmentRequest,
        rejectionID: UUID = UUID(),
        reason: EnrollmentRejectionReason,
        authority: CredentialAuthority,
        issuedAt: Date
    ) throws -> EnrollmentRejection {
        let unsigned = EnrollmentRejection(
            rejectionID: rejectionID,
            invitationID: request.invitation.invitationID,
            requestID: request.requestID,
            networkID: request.invitation.networkID,
            authorityID: authority.authorityID,
            nodeID: request.nodeID,
            requestNonce: request.requestNonce,
            reason: reason,
            issuedAtMilliseconds: milliseconds(issuedAt),
            authoritySignature: Data()
        )
        return replacingSignature(unsigned, with: try authoritySignature(
            authority: authority,
            domain: "BeakrNet enrollment rejection v1\0",
            value: unsigned
        ))
    }

    public static func cancellation(
        request: EnrollmentRequest,
        identity: NodeIdentity,
        cancellationID: UUID = UUID(),
        issuedAt: Date = Date()
    ) throws -> EnrollmentCancellation {
        guard identity.nodeID == request.nodeID,
              identity.publicKeyRepresentation == request.nodePublicKey else {
            throw EnrollmentWireError.nodeIdentityMismatch
        }
        let unsigned = EnrollmentCancellation(
            cancellationID: cancellationID,
            invitationID: request.invitation.invitationID,
            requestID: request.requestID,
            networkID: request.invitation.networkID,
            nodeID: request.nodeID,
            requestNonce: request.requestNonce,
            issuedAtMilliseconds: milliseconds(issuedAt),
            nodeSignature: Data()
        )
        return replacingSignature(unsigned, with: try identity.signature(
            forCertificateEnrollmentTranscript: transcript(
                domain: "BeakrNet enrollment cancellation v1\0",
                value: unsigned
            )
        ))
    }

    public static func confirmation(
        approval: EnrollmentApproval,
        identity: NodeIdentity,
        confirmationID: UUID = UUID()
    ) throws -> EnrollmentConfirmation {
        let unsigned = EnrollmentConfirmation(
            confirmationID: confirmationID,
            approvalID: approval.approvalID,
            requestID: approval.requestID,
            credentialID: approval.credential.claims.credentialID,
            networkID: approval.networkID,
            nodeID: identity.nodeID,
            nodeSignature: Data()
        )
        return replacingSignature(unsigned, with: try identity.signature(
            forCertificateEnrollmentTranscript: transcript(
                domain: "BeakrNet enrollment confirmation v1\0",
                value: unsigned
            )
        ))
    }

    private static func authoritySignature<T: Encodable>(
        authority: CredentialAuthority,
        domain: String,
        value: T
    ) throws -> Data {
        let key = try P256.Signing.PrivateKey(rawRepresentation: authority.privateKeyRepresentation)
        return try key.signature(for: transcript(domain: domain, value: value)).derRepresentation
    }

    fileprivate static func transcript<T: Encodable>(domain: String, value: T) throws -> Data {
        Data(domain.utf8) + (try EnrollmentWireCodec.canonicalEncoder().encode(value))
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }

    private static func replacingSignature(_ value: EnrollmentInvitation, with signature: Data) -> EnrollmentInvitation {
        EnrollmentInvitation(invitationID: value.invitationID, networkID: value.networkID,
            authorityID: value.authorityID, authorityPublicKey: value.authorityPublicKey,
            networkDisplayName: value.networkDisplayName, environment: value.environment,
            controlPlaneURL: value.controlPlaneURL,
            authorityCertificateDER: value.authorityCertificateDER,
            serviceScopes: value.serviceScopes,
            invitationSecret: value.invitationSecret,
            issuedAtMilliseconds: value.issuedAtMilliseconds, expiresAtMilliseconds: value.expiresAtMilliseconds,
            authoritySignature: signature)
    }

    private static func replacingSignature(_ value: EnrollmentRequest, with signature: Data) -> EnrollmentRequest {
        EnrollmentRequest(requestID: value.requestID, invitation: value.invitation, nodeID: value.nodeID,
            deviceDisplayName: value.deviceDisplayName,
            nodePublicKey: value.nodePublicKey, requestNonce: value.requestNonce,
            requestedRole: value.requestedRole, nodeSignature: signature)
    }

    private static func replacingSignature(_ value: EnrollmentApproval, with signature: Data) -> EnrollmentApproval {
        EnrollmentApproval(approvalID: value.approvalID, invitationID: value.invitationID,
            requestID: value.requestID, networkID: value.networkID, authorityID: value.authorityID,
            nodeID: value.nodeID, requestNonce: value.requestNonce, credential: value.credential,
            membership: value.membership, revocations: value.revocations,
            issuedAtMilliseconds: value.issuedAtMilliseconds, authoritySignature: signature)
    }

    private static func replacingSignature(_ value: EnrollmentRejection, with signature: Data) -> EnrollmentRejection {
        EnrollmentRejection(rejectionID: value.rejectionID, invitationID: value.invitationID,
            requestID: value.requestID, networkID: value.networkID, authorityID: value.authorityID,
            nodeID: value.nodeID, requestNonce: value.requestNonce, reason: value.reason,
            issuedAtMilliseconds: value.issuedAtMilliseconds, authoritySignature: signature)
    }

    private static func replacingSignature(
        _ value: EnrollmentCancellation,
        with signature: Data
    ) -> EnrollmentCancellation {
        EnrollmentCancellation(
            cancellationID: value.cancellationID,
            invitationID: value.invitationID,
            requestID: value.requestID,
            networkID: value.networkID,
            nodeID: value.nodeID,
            requestNonce: value.requestNonce,
            issuedAtMilliseconds: value.issuedAtMilliseconds,
            nodeSignature: signature
        )
    }

    private static func replacingSignature(_ value: EnrollmentConfirmation, with signature: Data) -> EnrollmentConfirmation {
        EnrollmentConfirmation(confirmationID: value.confirmationID, approvalID: value.approvalID,
            requestID: value.requestID, credentialID: value.credentialID, networkID: value.networkID,
            nodeID: value.nodeID, nodeSignature: signature)
    }
}

public enum EnrollmentWireVerifier {
    public static func verifyInvitation(
        _ invitation: EnrollmentInvitation,
        now: Date,
        allowedClockSkew: TimeInterval
    ) throws {
        try validateInvitationFields(invitation)
        guard invitation.authorityID == CredentialVerifier.authorityID(for: invitation.authorityPublicKey) else {
            throw EnrollmentWireError.wrongAuthority
        }
        let nowMilliseconds = milliseconds(now)
        let skew = Int64(allowedClockSkew * 1_000)
        guard invitation.issuedAtMilliseconds <= nowMilliseconds + skew else {
            throw EnrollmentWireError.issuedInFuture
        }
        guard invitation.expiresAtMilliseconds > nowMilliseconds - skew else {
            throw EnrollmentWireError.expired
        }
        try verifyAuthoritySignature(
            invitation.authoritySignature,
            publicKey: invitation.authorityPublicKey,
            domain: "BeakrNet enrollment invitation v1\0",
            unsigned: EnrollmentInvitation(
                invitationID: invitation.invitationID, networkID: invitation.networkID,
                authorityID: invitation.authorityID, authorityPublicKey: invitation.authorityPublicKey,
                networkDisplayName: invitation.networkDisplayName, environment: invitation.environment,
                controlPlaneURL: invitation.controlPlaneURL,
                authorityCertificateDER: invitation.authorityCertificateDER,
                serviceScopes: invitation.serviceScopes,
                invitationSecret: invitation.invitationSecret,
                issuedAtMilliseconds: invitation.issuedAtMilliseconds,
                expiresAtMilliseconds: invitation.expiresAtMilliseconds, authoritySignature: Data()
            )
        )
    }

    public static func verifyRequest(
        _ request: EnrollmentRequest,
        expectedNetworkID: NetworkID,
        expectedAuthorityID: AuthorityID,
        now: Date,
        allowedClockSkew: TimeInterval
    ) throws {
        try validateRequestFields(request)
        try verifyInvitation(request.invitation, now: now, allowedClockSkew: allowedClockSkew)
        guard request.invitation.networkID == expectedNetworkID else { throw EnrollmentWireError.wrongNetwork }
        guard request.invitation.authorityID == expectedAuthorityID else { throw EnrollmentWireError.wrongAuthority }
        guard request.nodeID == NodeIdentity.nodeID(forPublicKeyRepresentation: request.nodePublicKey) else {
            throw EnrollmentWireError.nodeIdentityMismatch
        }
        let unsigned = EnrollmentRequest(
            requestID: request.requestID, invitation: request.invitation, nodeID: request.nodeID,
            deviceDisplayName: request.deviceDisplayName,
            nodePublicKey: request.nodePublicKey, requestNonce: request.requestNonce,
            requestedRole: request.requestedRole, nodeSignature: Data()
        )
        guard NodeIdentity.verifyCertificateEnrollmentSignature(
            publicKeyRepresentation: request.nodePublicKey,
            transcript: try EnrollmentWireSigner.transcript(
                domain: "BeakrNet enrollment request v1\0", value: unsigned
            ),
            signature: request.nodeSignature
        ) else { throw EnrollmentWireError.invalidSignature }
    }

    public static func verifyApproval(
        _ approval: EnrollmentApproval,
        for request: EnrollmentRequest,
        now: Date,
        allowedClockSkew: TimeInterval
    ) throws {
        guard approval.type == EnrollmentApproval.messageType else { throw EnrollmentWireError.wrongMessageType }
        guard approval.version == EnrollmentApproval.currentVersion else { throw EnrollmentWireError.unsupportedVersion }
        guard approval.invitationID == request.invitation.invitationID,
              approval.requestID == request.requestID,
              approval.nodeID == request.nodeID,
              approval.requestNonce == request.requestNonce else { throw EnrollmentWireError.wrongRequest }
        guard approval.networkID == request.invitation.networkID else { throw EnrollmentWireError.wrongNetwork }
        guard approval.authorityID == request.invitation.authorityID else { throw EnrollmentWireError.wrongAuthority }
        guard approval.credential.claims.nodeID == request.nodeID,
              approval.credential.claims.nodePublicKey == request.nodePublicKey else {
            throw EnrollmentWireError.nodeIdentityMismatch
        }
        let nowMilliseconds = milliseconds(now)
        guard approval.issuedAtMilliseconds <= nowMilliseconds + Int64(allowedClockSkew * 1_000) else {
            throw EnrollmentWireError.issuedInFuture
        }
        let unsigned = EnrollmentApproval(
            approvalID: approval.approvalID, invitationID: approval.invitationID,
            requestID: approval.requestID, networkID: approval.networkID,
            authorityID: approval.authorityID, nodeID: approval.nodeID,
            requestNonce: approval.requestNonce, credential: approval.credential,
            membership: approval.membership, revocations: approval.revocations,
            issuedAtMilliseconds: approval.issuedAtMilliseconds, authoritySignature: Data()
        )
        try verifyAuthoritySignature(
            approval.authoritySignature,
            publicKey: request.invitation.authorityPublicKey,
            domain: "BeakrNet enrollment approval v1\0",
            unsigned: unsigned
        )
        do {
            try CredentialVerifier.verify(
                approval.credential,
                trustedAuthorityPublicKey: request.invitation.authorityPublicKey,
                networkID: approval.networkID,
                environment: request.invitation.environment,
                now: now,
                allowedClockSkew: allowedClockSkew
            )
        } catch { throw EnrollmentWireError.invalidCredential }
        do {
            try ProfileMembershipVerifier.verify(
                approval.membership,
                networkID: approval.networkID,
                environment: request.invitation.environment,
                trustedAuthorityPublicKey: request.invitation.authorityPublicKey,
                revokedCredentialIDs: Set(approval.revocations.claims.revocations.map(\.credentialID)),
                now: now,
                allowedClockSkew: allowedClockSkew
            )
        } catch { throw EnrollmentWireError.invalidMembership }
        do {
            _ = try RevocationVerifier.verify(
                approval.revocations,
                trustedAuthorityPublicKey: request.invitation.authorityPublicKey,
                now: now,
                allowedClockSkew: allowedClockSkew
            )
        } catch { throw EnrollmentWireError.invalidRevocations }
    }

    public static func verifyRejection(_ rejection: EnrollmentRejection, for request: EnrollmentRequest) throws {
        guard rejection.type == EnrollmentRejection.messageType else { throw EnrollmentWireError.wrongMessageType }
        guard rejection.version == EnrollmentRejection.currentVersion else { throw EnrollmentWireError.unsupportedVersion }
        guard rejection.invitationID == request.invitation.invitationID,
              rejection.requestID == request.requestID,
              rejection.networkID == request.invitation.networkID,
              rejection.authorityID == request.invitation.authorityID,
              rejection.nodeID == request.nodeID,
              rejection.requestNonce == request.requestNonce else { throw EnrollmentWireError.wrongRequest }
        let unsigned = EnrollmentRejection(
            rejectionID: rejection.rejectionID, invitationID: rejection.invitationID,
            requestID: rejection.requestID, networkID: rejection.networkID,
            authorityID: rejection.authorityID, nodeID: rejection.nodeID,
            requestNonce: rejection.requestNonce, reason: rejection.reason,
            issuedAtMilliseconds: rejection.issuedAtMilliseconds, authoritySignature: Data()
        )
        try verifyAuthoritySignature(rejection.authoritySignature,
            publicKey: request.invitation.authorityPublicKey,
            domain: "BeakrNet enrollment rejection v1\0", unsigned: unsigned)
    }

    public static func verifyCancellation(
        _ cancellation: EnrollmentCancellation,
        for request: EnrollmentRequest,
        now: Date,
        allowedClockSkew: TimeInterval
    ) throws {
        guard cancellation.type == EnrollmentCancellation.messageType else {
            throw EnrollmentWireError.wrongMessageType
        }
        guard cancellation.version == EnrollmentCancellation.currentVersion else {
            throw EnrollmentWireError.unsupportedVersion
        }
        guard cancellation.invitationID == request.invitation.invitationID,
              cancellation.requestID == request.requestID,
              cancellation.networkID == request.invitation.networkID,
              cancellation.nodeID == request.nodeID,
              cancellation.requestNonce == request.requestNonce else {
            throw EnrollmentWireError.wrongRequest
        }
        let nowMilliseconds = milliseconds(now)
        let skew = Int64(allowedClockSkew * 1_000)
        guard cancellation.issuedAtMilliseconds <= nowMilliseconds + skew else {
            throw EnrollmentWireError.issuedInFuture
        }
        guard cancellation.issuedAtMilliseconds >= nowMilliseconds - skew else {
            throw EnrollmentWireError.expired
        }
        let unsigned = EnrollmentCancellation(
            cancellationID: cancellation.cancellationID,
            invitationID: cancellation.invitationID,
            requestID: cancellation.requestID,
            networkID: cancellation.networkID,
            nodeID: cancellation.nodeID,
            requestNonce: cancellation.requestNonce,
            issuedAtMilliseconds: cancellation.issuedAtMilliseconds,
            nodeSignature: Data()
        )
        guard NodeIdentity.verifyCertificateEnrollmentSignature(
            publicKeyRepresentation: request.nodePublicKey,
            transcript: try EnrollmentWireSigner.transcript(
                domain: "BeakrNet enrollment cancellation v1\0",
                value: unsigned
            ),
            signature: cancellation.nodeSignature
        ) else {
            throw EnrollmentWireError.invalidSignature
        }
    }

    public static func verifyConfirmation(
        _ confirmation: EnrollmentConfirmation,
        for approval: EnrollmentApproval,
        nodePublicKey: Data
    ) throws {
        guard confirmation.type == EnrollmentConfirmation.messageType else { throw EnrollmentWireError.wrongMessageType }
        guard confirmation.version == EnrollmentConfirmation.currentVersion else { throw EnrollmentWireError.unsupportedVersion }
        guard confirmation.approvalID == approval.approvalID,
              confirmation.requestID == approval.requestID,
              confirmation.credentialID == approval.credential.claims.credentialID,
              confirmation.networkID == approval.networkID,
              confirmation.nodeID == approval.nodeID else { throw EnrollmentWireError.wrongRequest }
        let unsigned = EnrollmentConfirmation(
            confirmationID: confirmation.confirmationID, approvalID: confirmation.approvalID,
            requestID: confirmation.requestID, credentialID: confirmation.credentialID,
            networkID: confirmation.networkID, nodeID: confirmation.nodeID, nodeSignature: Data()
        )
        guard NodeIdentity.verifyCertificateEnrollmentSignature(
            publicKeyRepresentation: nodePublicKey,
            transcript: try EnrollmentWireSigner.transcript(
                domain: "BeakrNet enrollment confirmation v1\0", value: unsigned
            ),
            signature: confirmation.nodeSignature
        ) else { throw EnrollmentWireError.invalidSignature }
    }

    fileprivate static func validateInvitationFields(_ invitation: EnrollmentInvitation) throws {
        guard invitation.type == EnrollmentInvitation.messageType else { throw EnrollmentWireError.wrongMessageType }
        guard invitation.version == EnrollmentInvitation.currentVersion else { throw EnrollmentWireError.unsupportedVersion }
        let name = invitation.networkDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = invitation.environment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name == invitation.networkDisplayName, !name.isEmpty,
              name.utf8.count <= NetworkProfile.maximumDisplayNameBytes,
              environment == invitation.environment, !environment.isEmpty,
              environment.utf8.count <= 128,
              invitation.authorityPublicKey.count == 65,
              invitation.authorityCertificateDER.map({ !$0.isEmpty }) ?? true,
              !invitation.serviceScopes.isEmpty,
              invitation.serviceScopes.count <= 64,
              invitation.serviceScopes.allSatisfy({ scope in
                  let normalized = scope.trimmingCharacters(in: .whitespacesAndNewlines)
                  return !normalized.isEmpty && normalized == scope && scope.utf8.count <= 128
              }),
              Set(invitation.serviceScopes).count == invitation.serviceScopes.count,
              invitation.invitationSecret.count == 32,
              invitation.invitationSecret.contains(where: { $0 != 0 }),
              invitation.expiresAtMilliseconds > invitation.issuedAtMilliseconds,
              invitation.controlPlaneURL.map({ $0.scheme?.lowercased() == "https" && $0.host != nil }) ?? true else {
            throw EnrollmentWireError.invalidField
        }
    }

    fileprivate static func validateRequestFields(_ request: EnrollmentRequest) throws {
        guard request.type == EnrollmentRequest.messageType else { throw EnrollmentWireError.wrongMessageType }
        guard request.version == EnrollmentRequest.currentVersion else { throw EnrollmentWireError.unsupportedVersion }
        guard request.requestedRole == .member,
              request.deviceDisplayName.map({ name in
                  let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
                  return !normalized.isEmpty && normalized == name && name.utf8.count <= 128
              }) ?? true,
              request.nodePublicKey.count == 65,
              request.requestNonce.count == 32,
              request.requestNonce.contains(where: { $0 != 0 }) else {
            throw EnrollmentWireError.invalidField
        }
    }

    private static func verifyAuthoritySignature<T: Encodable>(
        _ signatureData: Data,
        publicKey: Data,
        domain: String,
        unsigned: T
    ) throws {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
              key.isValidSignature(
                signature,
                for: try EnrollmentWireSigner.transcript(domain: domain, value: unsigned)
              ) else { throw EnrollmentWireError.invalidSignature }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}
