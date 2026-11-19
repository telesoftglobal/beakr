import Foundation
import BeakrNetAuthority

public enum DiscoveredAuthorityHTTPTransportError: Error, Sendable {
    case endpointUnavailable
    case invalidRequestPath
}

/// Resolves every request through the authenticated, durable endpoint cache.
/// Discovery supplies signed candidates to the cache; it never supplies TLS trust.
public struct DiscoveredAuthorityHTTPTransport: CertificateEnrollmentHTTPTransport {
    private let resolve: @Sendable () async throws -> VerifiedAuthorityEndpoint
    private let trustedAuthorityCertificateDER: Data
    private var requestTimeout: TimeInterval = 15

    public init(cache: PersistentAuthorityEndpointCache, trustedAuthorityCertificateDER: Data) {
        resolve = {
            guard let endpoint = try await cache.current() else {
                throw DiscoveredAuthorityHTTPTransportError.endpointUnavailable
            }
            return endpoint
        }
        self.trustedAuthorityCertificateDER = trustedAuthorityCertificateDER
    }

    #if canImport(Network)
    public init(discovery: AuthorityEndpointDiscovery, trustedAuthorityCertificateDER: Data,
                requestTimeout: TimeInterval = 15, discoveryTimeout: Duration = .seconds(5)) {
        resolve = { try await discovery.resolve(timeout: discoveryTimeout) }
        self.trustedAuthorityCertificateDER = trustedAuthorityCertificateDER
        self.requestTimeout = min(max(requestTimeout, 0.1), 30)
    }
    #endif

    public func send(_ request: CertificateEnrollmentHTTPRequest) async throws
        -> CertificateEnrollmentHTTPResponse {
        // Only origin-relative API paths may use the selected authority's trust.
        guard request.path.hasPrefix("/"), !request.path.hasPrefix("//"),
              !request.path.contains("\\") else {
            throw DiscoveredAuthorityHTTPTransportError.invalidRequestPath
        }
        let endpoint = try await resolve()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = try URLSessionCertificateEnrollmentTransport(
            baseURL: endpoint.controlPlaneURL,
            session: session,
            trustedAuthorityCertificateDER: trustedAuthorityCertificateDER
        )
        return try await transport.send(request)
    }
}
