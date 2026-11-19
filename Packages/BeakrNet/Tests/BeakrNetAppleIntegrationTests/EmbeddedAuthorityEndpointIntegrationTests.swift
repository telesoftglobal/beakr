#if os(macOS)
import Foundation
import Testing
import BeakrNetAuthority
@testable import BeakrNetHost

@Suite("Embedded dynamic authority endpoints", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["BEAKRNET_RUN_ENDPOINT_INTEGRATION"] == "1"))
struct EmbeddedAuthorityEndpointIntegrationTests {
    @Test("Two loopback authorities route independently and restart using signed bound ports",
          .timeLimit(.minutes(2)))
    func independentEndpoints() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("beakr-endpoints-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let openssl = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BEAKRNET_OPENSSL"]
                          ?? "/opt/homebrew/bin/openssl")
        let password = UUID().uuidString
        func fixture(_ name: String) async throws -> (NetworkBootstrapResult, EmbeddedAuthorityNode) {
            let result = try await NetworkBootstrap.create(
                at: root.appendingPathComponent(name), displayName: name, environment: "test",
                serviceScopes: ["lan"], credentialValidity: 3600,
                controlPlaneURL: URL(string: "https://localhost:443"),
                tlsConfiguration: .init(openSSLExecutableURL: openssl, serverHostname: "localhost",
                                        pkcs12Password: password),
                persistInitialNodePrivateKey: false, persistAuthorityPrivateKey: false,
                persistCertificateAuthorityPrivateKey: false
            )
            let node = try EmbeddedAuthorityNode(
                bundleURL: result.bundleURL, openSSLExecutableURL: openssl, listenOnLAN: false,
                authorityPrivateKeyRepresentation: result.authorityPrivateKeyRepresentation,
                certificateAuthorityPrivateKeyPEM: try #require(result.certificateAuthorityPrivateKeyPEM)
            )
            return (result, node)
        }
        let (firstBundle, first) = try await fixture("first")
        let (secondBundle, second) = try await fixture("second")
        do {
            try await first.start(pkcs12Password: password)
            try await second.start(pkcs12Password: password)
            let firstRecord = try #require(await first.currentEndpointRecord())
            let secondRecord = try #require(await second.currentEndpointRecord())
            #expect(firstRecord.claims.port != secondRecord.claims.port)
            #expect(try await first.createInvitation().controlPlaneURL.port == Int(firstRecord.claims.port))
            func client(_ bundle: NetworkBootstrapResult, record: SignedAuthorityEndpoint) async throws
                -> (ProfileMembershipNetworkClient, PersistentAuthorityEndpointCache) {
                let key = try CredentialAuthority(privateKeyRepresentation: bundle.authorityPrivateKeyRepresentation)
                let cache = try PersistentAuthorityEndpointCache.open(
                    fileURL: bundle.bundleURL.appendingPathComponent("client-endpoint.json"),
                    trustedAuthorityPublicKey: key.publicKeyRepresentation,
                    networkID: bundle.manifest.profile.networkID, environment: "test"
                )
                try await cache.accept(record)
                return (ProfileMembershipNetworkClient(transport: DiscoveredAuthorityHTTPTransport(
                    cache: cache,
                    trustedAuthorityCertificateDER: try NetworkBootstrap.loadCertificateAuthorityDER(from: bundle.bundleURL)
                )), cache)
            }
            let (firstClient, firstCache) = try await client(firstBundle, record: firstRecord)
            let (secondClient, _) = try await client(secondBundle, record: secondRecord)
            #expect(try await firstClient.fetchSnapshot(after: nil)?.claims.networkID == firstBundle.manifest.profile.networkID)
            #expect(try await secondClient.fetchSnapshot(after: nil)?.claims.networkID == secondBundle.manifest.profile.networkID)
            let lifecycle = EndpointBrowserLifecycleProbe()
            let registry = AuthorityEndpointCacheRegistry { cache, _ in
                let source = AsyncStream<AuthorityEndpointBrowserEvent>.makeStream()
                let id = UUID()
                return AuthorityEndpointDiscovery(cache: cache, events: source.stream, start: {
                    lifecycle.started(id)
                    source.continuation.yield(.candidates([firstRecord, secondRecord], truncated: false))
                }, cancel: {
                    lifecycle.cancelled(id)
                    source.continuation.finish()
                })
            }
            let key = try CredentialAuthority(privateKeyRepresentation: firstBundle.authorityPrivateKeyRepresentation)
            let cacheURL = root.appendingPathComponent("request-scoped.json")
            let scoped = try AuthorityDiscoveryHTTPTransport(
                registry: registry, cacheURL: cacheURL, publicKey: key.publicKeyRepresentation,
                networkID: firstBundle.manifest.profile.networkID, environment: "test",
                certificate: NetworkBootstrap.loadCertificateAuthorityDER(from: firstBundle.bundleURL)
            )
            let scopedClient = ProfileMembershipNetworkClient(transport: scoped)
            #expect(try await scopedClient.fetchSnapshot(after: nil)?.claims.networkID == firstBundle.manifest.profile.networkID)
            #expect(lifecycle.allStartedAreCancelled)
            let rebound = try AuthorityDiscoveryHTTPTransport(
                registry: registry, cacheURL: cacheURL, publicKey: key.publicKeyRepresentation,
                networkID: secondBundle.manifest.profile.networkID, environment: "test",
                certificate: NetworkBootstrap.loadCertificateAuthorityDER(from: firstBundle.bundleURL)
            )
            await #expect(throws: AuthorityDiscoveryHTTPError.cacheBindingMismatch) {
                try await ProfileMembershipNetworkClient(transport: rebound).fetchSnapshot(after: nil)
            }
            let scopedWrongAnchor = try AuthorityDiscoveryHTTPTransport(
                registry: registry, cacheURL: cacheURL, publicKey: key.publicKeyRepresentation,
                networkID: firstBundle.manifest.profile.networkID, environment: "test",
                certificate: NetworkBootstrap.loadCertificateAuthorityDER(from: secondBundle.bundleURL)
            )
            await #expect(throws: (any Error).self) {
                try await ProfileMembershipNetworkClient(transport: scopedWrongAnchor).fetchSnapshot(after: nil)
            }
            #expect(lifecycle.allStartedAreCancelled)
            let wrongAnchorClient = ProfileMembershipNetworkClient(transport: DiscoveredAuthorityHTTPTransport(
                cache: firstCache,
                trustedAuthorityCertificateDER: try NetworkBootstrap.loadCertificateAuthorityDER(from: secondBundle.bundleURL)
            ))
            await #expect(throws: (any Error).self) {
                try await wrongAnchorClient.fetchSnapshot(after: nil)
            }
            await first.stop()
            #expect(await first.currentEndpointRecord() == nil)
            #expect(try await secondClient.fetchSnapshot(after: nil) != nil)
            try await first.start(pkcs12Password: password)
            let restarted = try #require(await first.currentEndpointRecord())
            #expect(restarted.claims.generation >= firstRecord.claims.generation)
            if restarted.claims.port != firstRecord.claims.port {
                #expect(restarted.claims.generation > firstRecord.claims.generation)
            }
            try await firstCache.accept(restarted)
            #expect(try await firstClient.fetchSnapshot(after: nil)?.claims.networkID == firstBundle.manifest.profile.networkID)
        } catch {
            await first.stop()
            await second.stop()
            throw error
        }
        await first.stop()
        await second.stop()
    }
}

private final class EndpointBrowserLifecycleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: Set<UUID> = []
    private var cancellations: Set<UUID> = []
    func started(_ id: UUID) { lock.withLock { _ = starts.insert(id) } }
    func cancelled(_ id: UUID) { lock.withLock { _ = cancellations.insert(id) } }
    var allStartedAreCancelled: Bool {
        lock.withLock { !starts.isEmpty && starts.isSubset(of: cancellations) }
    }
}
#endif
