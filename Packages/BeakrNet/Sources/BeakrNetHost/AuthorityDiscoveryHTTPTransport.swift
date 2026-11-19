#if canImport(Network)
import Foundation
import Security
import BeakrNetAuthority
import BeakrNetCore

public enum AuthorityDiscoveryHTTPError: Error, Equatable, Sendable {
    case capacityExceeded
    case cacheBindingMismatch
}

/// Share one registry within a process so each durable cache has one writer.
public actor AuthorityEndpointCacheRegistry {
    private struct Entry {
        let publicKey: Data
        let networkID: NetworkID
        let environment: String
        let cache: PersistentAuthorityEndpointCache
    }
    private var entries: [URL: Entry] = [:]
    private var requests = 0
    private let makeDiscovery: @Sendable (PersistentAuthorityEndpointCache, NetworkID) -> AuthorityEndpointDiscovery

    public init() {
        makeDiscovery = { AuthorityEndpointDiscovery(cache: $0, networkID: $1) }
    }

    init(makeDiscovery: @escaping @Sendable (PersistentAuthorityEndpointCache, NetworkID) -> AuthorityEndpointDiscovery) {
        self.makeDiscovery = makeDiscovery
    }

    func send(_ request: CertificateEnrollmentHTTPRequest, configuration: AuthorityDiscoveryHTTPTransport)
        async throws -> CertificateEnrollmentHTTPResponse {
        try Task.checkCancellation()
        guard requests < 8 else { throw AuthorityDiscoveryHTTPError.capacityExceeded }
        let url = configuration.cacheURL.standardizedFileURL
        let cache: PersistentAuthorityEndpointCache
        if let entry = entries[url] {
            guard entry.publicKey == configuration.publicKey,
                  entry.networkID == configuration.networkID,
                  entry.environment == configuration.environment else {
                throw AuthorityDiscoveryHTTPError.cacheBindingMismatch
            }
            cache = entry.cache
        } else {
            guard entries.count < 64 else { throw AuthorityDiscoveryHTTPError.capacityExceeded }
            cache = try PersistentAuthorityEndpointCache.open(
                fileURL: url, trustedAuthorityPublicKey: configuration.publicKey,
                networkID: configuration.networkID, environment: configuration.environment
            )
            entries[url] = Entry(publicKey: configuration.publicKey, networkID: configuration.networkID,
                                 environment: configuration.environment, cache: cache)
        }
        requests += 1
        defer { requests -= 1 }
        let discovery = makeDiscovery(cache, configuration.networkID)
        let transport = DiscoveredAuthorityHTTPTransport(
            discovery: discovery, trustedAuthorityCertificateDER: configuration.certificate,
            requestTimeout: configuration.timeout,
            discoveryTimeout: .seconds(min(configuration.timeout, 5))
        )
        do {
            let response = try await transport.send(request)
            await discovery.stop()
            return response
        } catch {
            await discovery.stop()
            throw error
        }
    }
}

/// Immutable route trust plus a request-scoped browser. Never falls back to a
/// previously configured port or an authority inferred from UI selection.
public struct AuthorityDiscoveryHTTPTransport: CertificateEnrollmentHTTPTransport {
    private let registry: AuthorityEndpointCacheRegistry
    fileprivate let cacheURL: URL
    fileprivate let publicKey: Data
    fileprivate let networkID: NetworkID
    fileprivate let environment: String
    fileprivate let certificate: Data
    fileprivate let timeout: TimeInterval

    public init(registry: AuthorityEndpointCacheRegistry, cacheURL: URL, publicKey: Data,
                networkID: NetworkID, environment: String, certificate: Data,
                requestTimeout: TimeInterval = 15) throws {
        guard requestTimeout.isFinite, requestTimeout > 0, requestTimeout <= 30,
              cacheURL.isFileURL else { throw CertificateEnrollmentNetworkError.invalidConfiguration }
        // Validate the immutable TLS anchor before opening a browser or cache.
        guard SecCertificateCreateWithData(nil, certificate as CFData) != nil else {
            throw CertificateEnrollmentNetworkError.invalidTrustAnchor
        }
        self.registry = registry
        self.cacheURL = cacheURL
        self.publicKey = publicKey
        self.networkID = networkID
        self.environment = environment
        self.certificate = certificate
        timeout = requestTimeout
    }

    public func send(_ request: CertificateEnrollmentHTTPRequest) async throws -> CertificateEnrollmentHTTPResponse {
        try await registry.send(request, configuration: self)
    }
}
#endif
