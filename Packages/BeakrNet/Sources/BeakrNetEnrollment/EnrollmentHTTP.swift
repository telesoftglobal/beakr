import Foundation
import OSLog
import BeakrNetAuthority

private let enrollmentLogger = Logger(subsystem: "net.beakr.app", category: "Enrollment")

public enum EnrollmentRequestStatus: Codable, Equatable, Sendable {
    case pending(requestID: UUID)
    case approved(EnrollmentApproval)
    case rejected(EnrollmentRejection)

    private enum CodingKeys: String, CodingKey { case status, requestID, approval, rejection }
    private enum Status: String, Codable { case pending, approved, rejected }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Status.self, forKey: .status) {
        case .pending:
            self = .pending(requestID: try values.decode(UUID.self, forKey: .requestID))
        case .approved:
            self = .approved(try values.decode(EnrollmentApproval.self, forKey: .approval))
        case .rejected:
            self = .rejected(try values.decode(EnrollmentRejection.self, forKey: .rejection))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending(let requestID):
            try values.encode(Status.pending, forKey: .status)
            try values.encode(requestID, forKey: .requestID)
        case .approved(let approval):
            try values.encode(Status.approved, forKey: .status)
            try values.encode(approval, forKey: .approval)
        case .rejected(let rejection):
            try values.encode(Status.rejected, forKey: .status)
            try values.encode(rejection, forKey: .rejection)
        }
    }
}

public actor EnrollmentRequestHTTPEndpoint {
    public static let path = "/v1/enrollment-requests"
    public static let contentType = "application/vnd.beakrnet.enrollment+json"

    private let coordinator: AuthorityEnrollmentCoordinator

    public init(coordinator: AuthorityEnrollmentCoordinator) {
        self.coordinator = coordinator
    }

    public func handles(path: String) -> Bool {
        path == Self.path || path.hasPrefix(Self.path + "/")
    }

    public func handle(_ request: CertificateEnrollmentHTTPRequest) async
        -> CertificateEnrollmentHTTPResponse {
        guard handles(path: request.path) else { return response(status: 404) }
        switch request.method {
        case "POST":
            if request.path == Self.path { return await submit(request) }
            if request.path.hasSuffix("/confirmation") { return await confirm(request) }
            return response(status: 404)
        case "GET":
            return await status(request)
        case "DELETE":
            return await cancel(request)
        default:
            return response(status: 405)
        }
    }

    private func submit(_ request: CertificateEnrollmentHTTPRequest) async
        -> CertificateEnrollmentHTTPResponse {
        guard contentType(in: request) == Self.contentType else { return response(status: 415) }
        do {
            let enrollment = try EnrollmentWireCodec.decode(EnrollmentRequest.self, from: request.body)
            _ = try await coordinator.submit(enrollment)
            return try await statusResponse(requestID: enrollment.requestID)
        } catch let error as EnrollmentWireError {
            return response(status: 400, reason: error == .expired ? .invitationExpired : nil)
        } catch let error as AuthorityEnrollmentError {
            switch error {
            case .requestCapacityExceeded: return response(status: 503)
            case .conflictingRequest, .invitationConsumed, .invitationInUse:
                return response(status: 409)
            case .invitationUnknown:
                return response(status: 403, reason: .invitationUnknown)
            default: return response(status: 403)
            }
        } catch {
            return response(status: 500)
        }
    }

    private func confirm(_ request: CertificateEnrollmentHTTPRequest) async
        -> CertificateEnrollmentHTTPResponse {
        guard contentType(in: request) == Self.contentType else { return response(status: 415) }
        do {
            let confirmation = try EnrollmentWireCodec.decode(EnrollmentConfirmation.self, from: request.body)
            let expectedPath = Self.path + "/" + confirmation.requestID.uuidString.lowercased() + "/confirmation"
            guard request.path == expectedPath else { return response(status: 400) }
            try await coordinator.confirm(confirmation)
            return response(status: 204)
        } catch is EnrollmentWireError {
            return response(status: 400)
        } catch let error as AuthorityEnrollmentError {
            return response(status: error == .requestUnknown ? 404 : 409)
        } catch {
            return response(status: 500)
        }
    }

    private func cancel(_ request: CertificateEnrollmentHTTPRequest) async
        -> CertificateEnrollmentHTTPResponse {
        guard contentType(in: request) == Self.contentType else { return response(status: 415) }
        let prefix = Self.path + "/"
        guard request.path.hasPrefix(prefix),
              let requestID = UUID(uuidString: String(request.path.dropFirst(prefix.count))) else {
            return response(status: 404)
        }
        do {
            let cancellation = try EnrollmentWireCodec.decode(EnrollmentCancellation.self, from: request.body)
            guard cancellation.requestID == requestID else { return response(status: 400) }
            try await coordinator.cancel(cancellation)
            return response(status: 204)
        } catch is EnrollmentWireError {
            return response(status: 400)
        } catch let error as AuthorityEnrollmentError {
            switch error {
            case .approvalConflict: return response(status: 409)
            case .requestUnknown: return response(status: 404)
            default: return response(status: 403)
            }
        } catch {
            return response(status: 500)
        }
    }

    private func status(_ request: CertificateEnrollmentHTTPRequest) async
        -> CertificateEnrollmentHTTPResponse {
        let prefix = Self.path + "/"
        guard request.path.hasPrefix(prefix),
              let requestID = UUID(uuidString: String(request.path.dropFirst(prefix.count))),
              await coordinator.request(id: requestID) != nil else {
            return response(status: 404)
        }
        do {
            return try await statusResponse(requestID: requestID)
        } catch {
            return response(status: 500)
        }
    }

    private func statusResponse(requestID: UUID) async throws -> CertificateEnrollmentHTTPResponse {
        do {
            try await coordinator.expirePendingRequests()
        } catch {
            logStatusFailure(error, requestID: requestID, stage: "expire-pending")
            throw error
        }
        let value: EnrollmentRequestStatus
        if let approval = await coordinator.approval(requestID: requestID) {
            value = .approved(approval)
        } else if let rejection = await coordinator.rejection(requestID: requestID) {
            value = .rejected(rejection)
        } else {
            value = .pending(requestID: requestID)
        }
        do {
            return response(
                status: value.isApproved ? 200 : 202,
                body: try EnrollmentWireCodec.encode(value)
            )
        } catch {
            logStatusFailure(error, requestID: requestID, stage: "encode-status")
            throw error
        }
    }

    private func logStatusFailure(_ error: Error, requestID: UUID, stage: String) {
        // Do not log the request, approval, error userInfo, or encoding context:
        // those can contain invitation secrets and credential material.
        let nsError = error as NSError
        let reason: String
        if let wireError = error as? EnrollmentWireError {
            reason = String(describing: wireError)
        } else if let authorityError = error as? AuthorityEnrollmentError {
            reason = String(describing: authorityError)
        } else {
            reason = "unspecified"
        }
        enrollmentLogger.error("🔴 [FAIL] [Beakr Enrollment] status-failed request=\(requestID.uuidString) stage=\(stage) type=\(String(reflecting: type(of: error))) domain=\(nsError.domain) code=\(nsError.code) reason=\(reason)")
    }

    private func contentType(in request: CertificateEnrollmentHTTPRequest) -> String? {
        request.headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased()
    }

    private func response(
        status: Int, body: Data = Data(), reason: EnrollmentRequestHTTPError.Reason? = nil
    ) -> CertificateEnrollmentHTTPResponse {
        var headers = ["content-type": Self.contentType, "cache-control": "no-store"]
        if let reason { headers["x-beakr-enrollment-error"] = reason.rawValue }
        return .init(
            statusCode: status,
            headers: headers,
            body: body
        )
    }
}

private extension EnrollmentRequestStatus {
    var isApproved: Bool {
        switch self {
        case .approved, .rejected: true
        case .pending: false
        }
    }
}

public struct EnrollmentRequestHTTPClient: Sendable {
    private let transport: any CertificateEnrollmentHTTPTransport

    public init(transport: any CertificateEnrollmentHTTPTransport) {
        self.transport = transport
    }

    public func submit(_ request: EnrollmentRequest) async throws -> EnrollmentRequestStatus {
        try await send(.init(
            method: "POST",
            path: EnrollmentRequestHTTPEndpoint.path,
            headers: ["content-type": EnrollmentRequestHTTPEndpoint.contentType],
            body: try EnrollmentWireCodec.encode(request)
        ))
    }

    /// Recover an ambiguous submission without creating another request or invitation.
    public func resume(_ request: EnrollmentRequest) async throws -> EnrollmentRequestStatus {
        do {
            return try await status(requestID: request.requestID)
        } catch let error as EnrollmentRequestHTTPError where error.statusCode == 404 {
            // Only an unknown request permits replay of the exact persisted, signed request.
            return try await submit(request)
        }
    }

    public func confirm(_ confirmation: EnrollmentConfirmation) async throws {
        let response = try await transport.send(.init(
            method: "POST",
            path: EnrollmentRequestHTTPEndpoint.path + "/"
                + confirmation.requestID.uuidString.lowercased() + "/confirmation",
            headers: ["content-type": EnrollmentRequestHTTPEndpoint.contentType],
            body: try EnrollmentWireCodec.encode(confirmation)
        ))
        guard response.statusCode == 204 else {
            throw EnrollmentRequestHTTPError(statusCode: response.statusCode)
        }
    }

    public func cancel(_ cancellation: EnrollmentCancellation) async throws {
        let response = try await transport.send(.init(
            method: "DELETE",
            path: EnrollmentRequestHTTPEndpoint.path + "/" + cancellation.requestID.uuidString.lowercased(),
            headers: ["content-type": EnrollmentRequestHTTPEndpoint.contentType],
            body: try EnrollmentWireCodec.encode(cancellation)
        ))
        // An absent request is already cancelled from the joining device's perspective.
        // The caller still clears its local checkpoint and ignores later decisions.
        guard response.statusCode == 204 || response.statusCode == 404 else {
            throw EnrollmentRequestHTTPError(statusCode: response.statusCode)
        }
    }

    public func status(requestID: UUID) async throws -> EnrollmentRequestStatus {
        try await send(.init(
            method: "GET",
            path: EnrollmentRequestHTTPEndpoint.path + "/" + requestID.uuidString.lowercased()
        ))
    }

    private func send(_ request: CertificateEnrollmentHTTPRequest) async throws
        -> EnrollmentRequestStatus {
        let response = try await transport.send(request)
        guard response.statusCode == 200 || response.statusCode == 202 else {
            let reason = response.headers.first {
                $0.key.lowercased() == "x-beakr-enrollment-error"
            }.flatMap { EnrollmentRequestHTTPError.Reason(rawValue: $0.value) }
            throw EnrollmentRequestHTTPError(statusCode: response.statusCode, reason: reason)
        }
        return try EnrollmentWireCodec.decode(EnrollmentRequestStatus.self, from: response.body)
    }
}

public struct EnrollmentRequestHTTPError: Error, LocalizedError, Equatable, Sendable {
    public enum Reason: String, Sendable {
        case invitationUnknown = "invitation-unknown"
        case invitationExpired = "invitation-expired"
    }

    public let statusCode: Int
    public let reason: Reason?

    public init(statusCode: Int, reason: Reason? = nil) {
        self.statusCode = statusCode
        self.reason = reason
    }

    public var isRetryable: Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    public var errorDescription: String? {
        if statusCode == 403, reason == .invitationUnknown {
            return "The contacted authority does not recognize this invitation (HTTP 403). Check that the invitation was created by the authority serving this network."
        }
        if statusCode == 400, reason == .invitationExpired {
            return "This invitation has expired (HTTP 400). Cancel this pending request and use a fresh invitation."
        }
        switch statusCode {
        case 403:
            return "The authority refused this enrollment request (HTTP 403)."
        case 409:
            return "The enrollment request conflicts with an existing request or an invitation already in use (HTTP 409)."
        case 404:
            return "The authority could not find this enrollment request or endpoint (HTTP 404)."
        default:
            return "The enrollment authority returned HTTP \(statusCode)."
        }
    }
}
