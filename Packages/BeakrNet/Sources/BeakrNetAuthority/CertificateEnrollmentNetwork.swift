import Foundation
import Security
import OSLog
import CryptoKit
import BeakrNetCore
import BeakrNetSecurity

public struct CertificateEnrollmentHTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct CertificateEnrollmentHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol CertificateEnrollmentHTTPTransport: Sendable {
    func send(_ request: CertificateEnrollmentHTTPRequest) async throws
        -> CertificateEnrollmentHTTPResponse
}

public struct CertificateEnrollmentChallengeRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let environment: String

    public init(version: Int = Self.currentVersion, environment: String) {
        self.version = version
        self.environment = environment
    }
}

public actor CertificateEnrollmentChallengeService {
    public static let maximumLifetime: TimeInterval = 5 * 60
    public static let maximumOutstandingChallenges = 4_096

    private let authorityID: AuthorityID
    private let environment: String
    private let lifetime: TimeInterval
    private var outstanding: [UUID: CertificateEnrollmentChallenge] = [:]

    public init(
        authorityID: AuthorityID,
        environment: String,
        lifetime: TimeInterval = 2 * 60
    ) throws {
        guard !environment.isEmpty, lifetime > 0, lifetime <= Self.maximumLifetime else {
            throw CertificateEnrollmentNetworkError.invalidConfiguration
        }
        self.authorityID = authorityID
        self.environment = environment
        self.lifetime = lifetime
    }

    public func issue(environment requestedEnvironment: String, now: Date = Date()) throws
        -> CertificateEnrollmentChallenge {
        guard requestedEnvironment == environment else {
            throw CertificateEnrollmentNetworkError.wrongEnvironment
        }
        let issuedAt = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        outstanding = outstanding.filter { $0.value.expiresAtMilliseconds > issuedAt }
        guard outstanding.count < Self.maximumOutstandingChallenges else {
            throw CertificateEnrollmentNetworkError.challengeCapacityExceeded
        }
        var generator = SystemRandomNumberGenerator()
        let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let challenge = CertificateEnrollmentChallenge(
            authorityID: authorityID,
            environment: environment,
            nonce: nonce,
            issuedAtMilliseconds: issuedAt,
            expiresAtMilliseconds: issuedAt + Int64(lifetime * 1_000)
        )
        outstanding[challenge.challengeID] = challenge
        return challenge
    }

    public func validateIssued(_ challenge: CertificateEnrollmentChallenge, now: Date) throws {
        let nowMilliseconds = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        guard outstanding[challenge.challengeID] == challenge,
              challenge.expiresAtMilliseconds > nowMilliseconds else {
            throw CertificateEnrollmentNetworkError.challengeNotIssued
        }
    }

    public func consume(_ challengeID: UUID) {
        outstanding.removeValue(forKey: challengeID)
    }
}

public actor CertificateEnrollmentHTTPEndpoint {
    public static let challengePath = "/v1/certificate-enrollment/challenge"
    public static let enrollmentPath = "/v1/certificate-enrollment"
    public static let contentType = "application/vnd.beakrnet.certificate-enrollment+json"
    public static let maximumChallengeBodySize = 4 * 1_024
    public static let maximumEnrollmentBodySize = 256 * 1_024

    private let challenges: CertificateEnrollmentChallengeService
    private let enrollment: CertificateEnrollmentService
    private let membershipPublisher: (any CertificateEnrollmentMembershipPublishing)?
    private let now: @Sendable () -> Date

    public init(
        challenges: CertificateEnrollmentChallengeService,
        enrollment: CertificateEnrollmentService,
        membershipPublisher: (any CertificateEnrollmentMembershipPublishing)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.challenges = challenges
        self.enrollment = enrollment
        self.membershipPublisher = membershipPublisher
        self.now = now
    }

    public func handle(_ request: CertificateEnrollmentHTTPRequest) async
        -> CertificateEnrollmentHTTPResponse {
        guard request.method == "POST" else { return response(status: 405) }
        let contentType = request.headers.first { $0.key.lowercased() == "content-type" }?.value
        guard contentType?.lowercased() == Self.contentType else {
            return response(status: 415)
        }

        switch request.path {
        case Self.challengePath:
            guard request.body.count <= Self.maximumChallengeBodySize else {
                return response(status: 413)
            }
            do {
                let decoded = try CanonicalJSON.decode(
                    CertificateEnrollmentChallengeRequest.self,
                    from: request.body
                )
                guard decoded.version == CertificateEnrollmentChallengeRequest.currentVersion else {
                    return response(status: 400)
                }
                let challenge = try await challenges.issue(
                    environment: decoded.environment,
                    now: now()
                )
                return response(status: 200, body: try CanonicalJSON.encode(challenge))
            } catch let error as CertificateEnrollmentNetworkError where error == .wrongEnvironment {
                return response(status: 403)
            } catch {
                return response(status: 400)
            }

        case Self.enrollmentPath:
            guard request.body.count <= Self.maximumEnrollmentBodySize else {
                return response(status: 413)
            }
            do {
                let enrollmentRequest = try CertificateEnrollmentWireCodec.decode(request.body)
                try await challenges.validateIssued(enrollmentRequest.challenge, now: now())
                let result = try await enrollment.enroll(enrollmentRequest, now: now())
                try await membershipPublisher?.publishEnrollment(
                    request: enrollmentRequest,
                    response: result,
                    now: now()
                )
                await challenges.consume(enrollmentRequest.challenge.challengeID)
                return response(
                    status: 200,
                    body: try CertificateEnrollmentResponseWireCodec.encode(result)
                )
            } catch is CertificateEnrollmentError {
                return response(status: 403)
            } catch let error as CertificateEnrollmentNetworkError
                where error == .challengeNotIssued {
                return response(status: 403)
            } catch is CertificateEnrollmentWireError {
                return response(status: 400)
            } catch {
                return response(status: 500)
            }

        default:
            return response(status: 404)
        }
    }

    private func response(status: Int, body: Data = Data()) -> CertificateEnrollmentHTTPResponse {
        CertificateEnrollmentHTTPResponse(
            statusCode: status,
            headers: ["content-type": Self.contentType, "cache-control": "no-store"],
            body: body
        )
    }
}

public actor CertificateEnrollmentNetworkClient: CertificateRenewalRequesting {
    private let transport: any CertificateEnrollmentHTTPTransport
    private let identity: NodeIdentity
    private let credential: NodeCredential
    private let environment: String
    private let requestedValidity: TimeInterval

    public init(
        transport: any CertificateEnrollmentHTTPTransport,
        identity: NodeIdentity,
        credential: NodeCredential,
        environment: String,
        requestedValidity: TimeInterval
    ) throws {
        guard credential.claims.nodeID == identity.nodeID,
              credential.claims.nodePublicKey == identity.publicKeyRepresentation,
              credential.claims.environment == environment,
              requestedValidity > 0,
              requestedValidity <= CertificateEnrollmentValidator.maximumCertificateValidity else {
            throw CertificateEnrollmentNetworkError.invalidConfiguration
        }
        self.transport = transport
        self.identity = identity
        self.credential = credential
        self.environment = environment
        self.requestedValidity = requestedValidity
    }

    public func renewCertificate() async throws -> CertificateRenewalExchange {
        let challengeRequest = CertificateEnrollmentChallengeRequest(environment: environment)
        let challengeResponse = try await transport.send(CertificateEnrollmentHTTPRequest(
            method: "POST",
            path: CertificateEnrollmentHTTPEndpoint.challengePath,
            headers: ["content-type": CertificateEnrollmentHTTPEndpoint.contentType],
            body: try CanonicalJSON.encode(challengeRequest)
        ))
        guard challengeResponse.statusCode == 200 else {
            throw CertificateEnrollmentNetworkError.serverRejected(challengeResponse.statusCode)
        }
        guard challengeResponse.body.count <= CertificateEnrollmentHTTPEndpoint.maximumChallengeBodySize else {
            throw CertificateEnrollmentNetworkError.responseTooLarge
        }
        let challenge = try CanonicalJSON.decode(
            CertificateEnrollmentChallenge.self,
            from: challengeResponse.body
        )
        guard challenge.authorityID == credential.claims.issuerID,
              challenge.environment == environment,
              challenge.nonce.count == 32,
              challenge.expiresAtMilliseconds > challenge.issuedAtMilliseconds,
              challenge.expiresAtMilliseconds - challenge.issuedAtMilliseconds
                <= Int64(CertificateEnrollmentChallengeService.maximumLifetime * 1_000) else {
            throw CertificateEnrollmentNetworkError.invalidChallenge
        }
        let request = try CertificateEnrollmentRequest.signed(
            identity: identity,
            credential: credential,
            environment: environment,
            challenge: challenge,
            requestedValidity: requestedValidity
        )
        let response = try await transport.send(CertificateEnrollmentHTTPRequest(
            method: "POST",
            path: CertificateEnrollmentHTTPEndpoint.enrollmentPath,
            headers: ["content-type": CertificateEnrollmentHTTPEndpoint.contentType],
            body: try CertificateEnrollmentWireCodec.encode(request)
        ))
        guard response.statusCode == 200 else {
            throw CertificateEnrollmentNetworkError.serverRejected(response.statusCode)
        }
        guard response.body.count <= CertificateEnrollmentHTTPEndpoint.maximumEnrollmentBodySize else {
            throw CertificateEnrollmentNetworkError.responseTooLarge
        }
        return CertificateRenewalExchange(
            request: request,
            response: try CertificateEnrollmentResponseWireCodec.decode(response.body)
        )
    }
}

public final class URLSessionCertificateEnrollmentTransport: CertificateEnrollmentHTTPTransport,
    @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let trustedAuthorityCertificateDER: Data?

    public init(
        baseURL: URL,
        session: URLSession? = nil,
        trustedAuthorityCertificateDER: Data? = nil
    ) throws {
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil else {
            throw CertificateEnrollmentNetworkError.insecureBaseURL
        }
        if let trustedAuthorityCertificateDER,
           SecCertificateCreateWithData(nil, trustedAuthorityCertificateDER as CFData) == nil {
            throw CertificateEnrollmentNetworkError.invalidTrustAnchor
        }
        self.baseURL = baseURL
        self.session = session ?? Self.makeUncachedSession()
        self.trustedAuthorityCertificateDER = trustedAuthorityCertificateDER
    }

    private static func makeUncachedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    public func send(_ request: CertificateEnrollmentHTTPRequest) async throws
        -> CertificateEnrollmentHTTPResponse {
        guard let url = URL(string: request.path, relativeTo: baseURL)?.absoluteURL else {
            throw CertificateEnrollmentNetworkError.invalidURL
        }
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == baseURL.host?.lowercased() else {
            throw CertificateEnrollmentNetworkError.invalidURL
        }
        // Authority state is security-sensitive and network-scoped. Different Beakr
        // networks can legitimately reuse the same local hostname and port, so a
        // shared URL cache must never supply another network's trust snapshot.
        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.setValue("no-cache, no-store", forHTTPHeaderField: "cache-control")
        request.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        let delegate = AuthorityRequestDelegate(
            expectedHostname: baseURL.host!,
            trustedAuthorityCertificateDER: trustedAuthorityCertificateDER
        )
        let (data, response) = try await session.data(for: urlRequest, delegate: delegate)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == baseURL.host?.lowercased() else {
            throw CertificateEnrollmentNetworkError.invalidResponse
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String, let value = entry.value as? String else { return }
            result[key.lowercased()] = value
        }
        return CertificateEnrollmentHTTPResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: data
        )
    }
}

private final class AuthorityRequestDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    private static let logger = Logger(subsystem: "net.beakr", category: "AuthorityTrust")
    private let expectedHostname: String
    private let trustedAuthorityCertificateDER: Data?

    init(expectedHostname: String, trustedAuthorityCertificateDER: Data?) {
        self.expectedHostname = expectedHostname
        self.trustedAuthorityCertificateDER = trustedAuthorityCertificateDER
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trustedAuthorityCertificateDER else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.protectionSpace.host.caseInsensitiveCompare(expectedHostname) == .orderedSame else {
            Self.logRejection(
                task: task,
                reason: "hostnameMismatch",
                detail: "expectedHost=\(expectedHostname) presentedHost=\(challenge.protectionSpace.host)"
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let anchor = SecCertificateCreateWithData(nil, trustedAuthorityCertificateDER as CFData) else {
            Self.logRejection(task: task, reason: "trustMaterialUnavailable")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, expectedHostname as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            Self.logRejection(task: task, reason: "trustPolicyConfigurationFailed")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            let chainDER = (SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? [])
                .map { SecCertificateCopyData($0) as Data }
            let expectedAnchorIsPresented = chainDER.contains(trustedAuthorityCertificateDER)
            let reason = expectedAnchorIsPresented ? "invalidCertificate" : "authorityIdentityMismatch"
            let expectedFingerprint = Self.shortFingerprint(trustedAuthorityCertificateDER)
            let presentedFingerprint = chainDER.last.map(Self.shortFingerprint) ?? "unavailable"
            let errorCode = trustError.map { CFErrorGetCode($0) }
            let detail = "expectedAuthority=\(expectedFingerprint) presentedAuthority=\(presentedFingerprint)" +
                (errorCode.map { " trustError=\($0)" } ?? "")
            Self.logRejection(task: task, reason: reason, detail: detail)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private static func logRejection(
        task: URLSessionTask,
        reason: String,
        detail: String? = nil
    ) {
        let operation = operationName(for: task.originalRequest?.url?.path)
        let suffix = detail.map { " \($0)" } ?? ""
        logger.error("\(platformPrefix, privacy: .public) [Beakr Trust] \(operation, privacy: .public) rejected reason=\(reason, privacy: .public)\(suffix, privacy: .public)")
    }

    private static func operationName(for path: String?) -> String {
        switch path {
        case RevocationSnapshotHTTPEndpoint.path, ProfileMembershipHTTPEndpoint.path:
            return "authority-refresh"
        case CertificateEnrollmentHTTPEndpoint.challengePath,
             CertificateEnrollmentHTTPEndpoint.enrollmentPath:
            return "enrollment"
        default:
            return "authority-request"
        }
    }

    private static func shortFingerprint(_ certificateDER: Data) -> String {
        SHA256.hash(data: certificateDER).prefix(6).map { String(format: "%02X", $0) }.joined()
    }

    private static var platformPrefix: String {
#if os(iOS)
        "[iOS]"
#elseif os(macOS)
        "[macOS]"
#else
        "[Apple]"
#endif
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public enum CertificateEnrollmentNetworkError: Error, Equatable, Sendable {
    case invalidConfiguration
    case wrongEnvironment
    case insecureBaseURL
    case invalidTrustAnchor
    case invalidURL
    case invalidResponse
    case responseTooLarge
    case invalidChallenge
    case challengeNotIssued
    case challengeCapacityExceeded
    case serverRejected(Int)
    case malformedJSON
    case nonCanonicalJSON
}

private enum CanonicalJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        let value: T
        do {
            value = try JSONDecoder().decode(type, from: data)
        } catch {
            throw CertificateEnrollmentNetworkError.malformedJSON
        }
        guard try encode(value) == data else {
            throw CertificateEnrollmentNetworkError.nonCanonicalJSON
        }
        return value
    }
}
