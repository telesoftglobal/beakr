import Foundation
import BeakrNetAuthority
import BeakrNetCore

public struct AuthorityControlPlanePolicy: Equatable, Sendable {
    public let maximumConcurrentRequests: Int
    public let maximumHeaderCount: Int
    public let maximumHeaderBytes: Int

    public init(
        maximumConcurrentRequests: Int = 64,
        maximumHeaderCount: Int = 32,
        maximumHeaderBytes: Int = 16_384
    ) {
        precondition(maximumConcurrentRequests > 0 && maximumHeaderCount > 0 && maximumHeaderBytes > 0)
        self.maximumConcurrentRequests = maximumConcurrentRequests
        self.maximumHeaderCount = maximumHeaderCount
        self.maximumHeaderBytes = maximumHeaderBytes
    }
}

/// Platform-neutral request boundary used by an HTTPS listener. Transport TLS
/// termination remains outside this type; every admitted request is bounded,
/// routed to one authority service, and recorded without request payload data.
public actor AuthorityControlPlaneRouter {
    private let enrollment: CertificateEnrollmentHTTPEndpoint
    private let joining: NetworkInvitationHTTPEndpoint?
    private let administration: AuthorityAdministrationHTTPEndpoint?
    private let membership: ProfileMembershipHTTPEndpoint
    private let revocations: RevocationSnapshotHTTPEndpoint
    private let admission: OperationalAdmissionController
    private let audit: OperationalAuditJournal
    private let policy: AuthorityControlPlanePolicy
    private let now: @Sendable () -> Date
    private var activeRequests = 0

    public init(
        enrollment: CertificateEnrollmentHTTPEndpoint,
        joining: NetworkInvitationHTTPEndpoint? = nil,
        administration: AuthorityAdministrationHTTPEndpoint? = nil,
        membership: ProfileMembershipHTTPEndpoint,
        revocations: RevocationSnapshotHTTPEndpoint,
        admission: OperationalAdmissionController,
        audit: OperationalAuditJournal,
        policy: AuthorityControlPlanePolicy = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.enrollment = enrollment
        self.joining = joining
        self.administration = administration
        self.membership = membership
        self.revocations = revocations
        self.admission = admission
        self.audit = audit
        self.policy = policy
        self.now = now
    }

    public func handle(
        _ request: CertificateEnrollmentHTTPRequest,
        source: String,
        authenticatedIdentity: NodeID? = nil,
        correlationID: UUID = UUID()
    ) async -> CertificateEnrollmentHTTPResponse {
        guard activeRequests < policy.maximumConcurrentRequests else {
            return await rejected(endpoint: endpoint(for: request.path), correlationID: correlationID, status: 503)
        }
        activeRequests += 1
        defer { activeRequests -= 1 }

        guard request.headers.count <= policy.maximumHeaderCount,
              request.headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count })
                <= policy.maximumHeaderBytes else {
            return await failed(endpoint: endpoint(for: request.path), correlationID: correlationID, status: 431)
        }
        guard let endpoint = endpoint(for: request.path) else {
            return .init(statusCode: 404, headers: ["cache-control": "no-store"])
        }
        let context = OperationalAdmissionContext(
            source: source,
            identity: authenticatedIdentity,
            endpoint: endpoint
        )
        switch await admission.admit(context) {
        case .rejected(_, let retryAfter):
            await audit.record(.init(
                timestamp: now(), endpoint: endpoint, outcome: .rejected,
                reason: .overloaded, correlationID: correlationID
            ), now: now())
            return .init(
                statusCode: 429,
                headers: [
                    "cache-control": "no-store",
                    "retry-after": String(max(1, Int(retryAfter.rounded(.up))))
                ]
            )
        case .admitted:
            break
        }

        let response: CertificateEnrollmentHTTPResponse
        switch endpoint {
        case .enrollmentChallenge, .enrollment:
            if request.path == NetworkInvitationHTTPEndpoint.joinPath, let joining {
                response = await joining.handle(request)
            } else {
                response = await enrollment.handle(request)
            }
        case .membershipRead:
            response = await membership.handle(request)
        case .revocationRead:
            response = await revocations.handle(request)
        case .administration:
            if let administration {
                response = await administration.handle(request)
            } else {
                response = .init(statusCode: 404, headers: ["cache-control": "no-store"])
            }
        case .revocationPublish:
            response = .init(statusCode: 404, headers: ["cache-control": "no-store"])
        }
        let accepted = (200..<400).contains(response.statusCode)
        await audit.record(.init(
            timestamp: now(),
            endpoint: endpoint,
            outcome: accepted ? .accepted : .rejected,
            reason: accepted ? .authorized : response.statusCode == 400 ? .malformed : .unauthorized,
            correlationID: correlationID
        ), now: now())
        return response
    }

    private func endpoint(for path: String) -> OperationalEndpoint? {
        switch path {
        case CertificateEnrollmentHTTPEndpoint.challengePath: .enrollmentChallenge
        case CertificateEnrollmentHTTPEndpoint.enrollmentPath: .enrollment
        case NetworkInvitationHTTPEndpoint.joinPath: .enrollment
        case ProfileMembershipHTTPEndpoint.path: .membershipRead
        case RevocationSnapshotHTTPEndpoint.path: .revocationRead
        case AuthorityAdministrationHTTPEndpoint.invitationPath: .administration
        default: nil
        }
    }

    private func rejected(
        endpoint: OperationalEndpoint?, correlationID: UUID, status: Int
    ) async -> CertificateEnrollmentHTTPResponse {
        if let endpoint {
            await audit.record(.init(
                timestamp: now(), endpoint: endpoint, outcome: .rejected,
                reason: .overloaded, correlationID: correlationID
            ), now: now())
        }
        return .init(statusCode: status, headers: ["cache-control": "no-store"])
    }

    private func failed(
        endpoint: OperationalEndpoint?, correlationID: UUID, status: Int
    ) async -> CertificateEnrollmentHTTPResponse {
        if let endpoint {
            await audit.record(.init(
                timestamp: now(), endpoint: endpoint, outcome: .rejected,
                reason: .malformed, correlationID: correlationID
            ), now: now())
        }
        return .init(statusCode: status, headers: ["cache-control": "no-store"])
    }
}
