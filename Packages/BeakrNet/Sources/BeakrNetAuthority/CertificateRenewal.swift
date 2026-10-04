import Foundation
import BeakrNetSecurity

public struct CertificateRenewalPolicy: Equatable, Sendable {
    public let renewalFraction: Double
    public let scheduleJitterFraction: Double
    public let initialRetryDelay: TimeInterval
    public let maximumRetryDelay: TimeInterval
    public let retryJitterFraction: Double
    public let expirySafetyMargin: TimeInterval

    public init(
        renewalFraction: Double = 2.0 / 3.0,
        scheduleJitterFraction: Double = 0.05,
        initialRetryDelay: TimeInterval = 30,
        maximumRetryDelay: TimeInterval = 3_600,
        retryJitterFraction: Double = 0.2,
        expirySafetyMargin: TimeInterval = 300
    ) throws {
        guard renewalFraction > 0, renewalFraction < 1,
              scheduleJitterFraction >= 0, scheduleJitterFraction < 0.5,
              initialRetryDelay > 0,
              maximumRetryDelay >= initialRetryDelay,
              retryJitterFraction >= 0, retryJitterFraction < 1,
              expirySafetyMargin >= 0 else {
            throw CertificateRenewalError.invalidPolicy
        }
        self.renewalFraction = renewalFraction
        self.scheduleJitterFraction = scheduleJitterFraction
        self.initialRetryDelay = initialRetryDelay
        self.maximumRetryDelay = maximumRetryDelay
        self.retryJitterFraction = retryJitterFraction
        self.expirySafetyMargin = expirySafetyMargin
    }

    public func scheduledRenewalDate(
        for response: CertificateEnrollmentResponse,
        jitterUnit: Double
    ) -> Date {
        let issued = date(milliseconds: response.issuedAtMilliseconds)
        let expires = date(milliseconds: response.expiresAtMilliseconds)
        let validity = max(0, expires.timeIntervalSince(issued))
        let boundedJitter = min(1, max(-1, jitterUnit))
        let baseOffset = validity * renewalFraction
        let jitter = validity * scheduleJitterFraction * boundedJitter
        let latest = max(issued, expires.addingTimeInterval(-expirySafetyMargin))
        return min(max(issued, issued.addingTimeInterval(baseOffset + jitter)), latest)
    }

    public func retryDate(
        after failureCount: Int,
        now: Date,
        expiresAt: Date,
        jitterUnit: Double
    ) -> Date {
        let exponent = min(max(0, failureCount - 1), 30)
        let base = min(maximumRetryDelay, initialRetryDelay * pow(2, Double(exponent)))
        let boundedJitter = min(1, max(-1, jitterUnit))
        let delay = max(0, base * (1 + retryJitterFraction * boundedJitter))
        let latest = expiresAt.addingTimeInterval(-expirySafetyMargin)
        return min(now.addingTimeInterval(delay), max(now, latest))
    }

    private func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}

public struct CertificateRenewalExchange: Sendable {
    public let request: CertificateEnrollmentRequest
    public let response: CertificateEnrollmentResponse

    public init(request: CertificateEnrollmentRequest, response: CertificateEnrollmentResponse) {
        self.request = request
        self.response = response
    }
}

public protocol CertificateRenewalRequesting: Sendable {
    func renewCertificate() async throws -> CertificateRenewalExchange
}

public protocol CertificateIdentityInstalling: Sendable {
    func install(
        response: CertificateEnrollmentResponse,
        nodeIdentity: NodeIdentity
    ) throws
}

extension KeychainLANTLSIdentityStore: CertificateIdentityInstalling {
    public func install(
        response: CertificateEnrollmentResponse,
        nodeIdentity: NodeIdentity
    ) throws {
        _ = try install(
            leafCertificateDER: response.leafCertificateDER,
            certificateChainDER: response.certificateChainDER,
            nodeIdentity: nodeIdentity
        )
    }
}

public enum CertificateRenewalOutcome: Equatable, Sendable {
    case installed(expiresAt: Date)
    case retryScheduled(at: Date, failureCount: Int)
}

public actor CertificateRenewalScheduler {
    private let nodeIdentity: NodeIdentity
    private let trustedAuthorityPublicKey: Data
    private let requester: any CertificateRenewalRequesting
    private let installer: any CertificateIdentityInstalling
    private let policy: CertificateRenewalPolicy
    private var currentResponse: CertificateEnrollmentResponse
    private var failureCount = 0
    private var retryAt: Date?

    public init(
        currentResponse: CertificateEnrollmentResponse,
        nodeIdentity: NodeIdentity,
        trustedAuthorityPublicKey: Data,
        requester: any CertificateRenewalRequesting,
        installer: any CertificateIdentityInstalling,
        policy: CertificateRenewalPolicy
    ) {
        self.currentResponse = currentResponse
        self.nodeIdentity = nodeIdentity
        self.trustedAuthorityPublicKey = trustedAuthorityPublicKey
        self.requester = requester
        self.installer = installer
        self.policy = policy
    }

    public func nextAttemptDate(jitterUnit: Double) -> Date {
        retryAt ?? policy.scheduledRenewalDate(for: currentResponse, jitterUnit: jitterUnit)
    }

    @discardableResult
    public func attemptRenewal(
        now: Date = Date(),
        retryJitterUnit: Double = 0
    ) async -> CertificateRenewalOutcome {
        do {
            let exchange = try await requester.renewCertificate()
            try CertificateEnrollmentResponseVerifier.verify(
                exchange.response,
                for: exchange.request,
                trustedAuthorityPublicKey: trustedAuthorityPublicKey
            )
            guard exchange.response.nodeID == nodeIdentity.nodeID,
                  exchange.response.nodePublicKey == nodeIdentity.publicKeyRepresentation else {
                throw CertificateRenewalError.nodeIdentityMismatch
            }
            try installer.install(response: exchange.response, nodeIdentity: nodeIdentity)
            currentResponse = exchange.response
            failureCount = 0
            retryAt = nil
            return .installed(expiresAt: date(milliseconds: exchange.response.expiresAtMilliseconds))
        } catch {
            failureCount += 1
            let expiry = date(milliseconds: currentResponse.expiresAtMilliseconds)
            let scheduled = policy.retryDate(
                after: failureCount,
                now: now,
                expiresAt: expiry,
                jitterUnit: retryJitterUnit
            )
            retryAt = scheduled
            return .retryScheduled(at: scheduled, failureCount: failureCount)
        }
    }

    public func activeResponse() -> CertificateEnrollmentResponse {
        currentResponse
    }

    private func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}

public enum CertificateRenewalError: Error, Equatable, Sendable {
    case invalidPolicy
    case nodeIdentityMismatch
}
