#if canImport(Network)
import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
@testable import BeakrNetHost

@Suite("Authority discovery lifecycle")
struct AuthorityEndpointDiscoveryTests {
    @Test("A finished event source terminates waiting resolution")
    func finishedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = CredentialAuthority()
        let network = NetworkID()
        let cache = try PersistentAuthorityEndpointCache.open(
            fileURL: root.appendingPathComponent("cache.json"),
            trustedAuthorityPublicKey: authority.publicKeyRepresentation, networkID: network, environment: "test"
        )
        let source = AsyncStream<AuthorityEndpointBrowserEvent>.makeStream()
        source.continuation.finish()
        let discovery = AuthorityEndpointDiscovery(cache: cache, events: source.stream, start: {}, cancel: {})
        await #expect(throws: AuthorityEndpointDiscoveryError.stopped) { try await discovery.resolve() }
        await discovery.stop()
    }

    @Test("Failed persistence fails resolution without accepting an unrecorded route")
    func failedPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = CredentialAuthority()
        let network = NetworkID()
        let cache = try PersistentAuthorityEndpointCache.open(
            fileURL: root.appendingPathComponent("cache.json"),
            trustedAuthorityPublicKey: authority.publicKeyRepresentation, networkID: network, environment: "test"
        )
        // A regular file obstructs the cache's parent directory.
        try Data([1]).write(to: root)
        let source = AsyncStream<AuthorityEndpointBrowserEvent>.makeStream()
        let discovery = AuthorityEndpointDiscovery(cache: cache, events: source.stream, start: {},
                                                  cancel: { source.continuation.finish() })
        let record = try authority.issueAuthorityEndpoint(networkID: network, environment: "test",
                                                        hostname: "valid.local", port: 50100, generation: 1)
        source.continuation.yield(.candidates([record], truncated: false))
        await #expect(throws: CocoaError.self) { try await discovery.resolve() }
        #expect(try await cache.current() == nil)
        await discovery.stop()
    }

    @Test("Invalid advertisements cannot redirect discovery; stop closes cached resolution")
    func trustAndStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = CredentialAuthority()
        let network = NetworkID()
        let cache = try PersistentAuthorityEndpointCache.open(
            fileURL: root.appendingPathComponent("cache.json"),
            trustedAuthorityPublicKey: authority.publicKeyRepresentation, networkID: network, environment: "test"
        )
        let source = AsyncStream<AuthorityEndpointBrowserEvent>.makeStream()
        let discovery = AuthorityEndpointDiscovery(cache: cache, events: source.stream, start: {},
                                                  cancel: { source.continuation.finish() })
        try await discovery.start()
        try await discovery.start()
        let valid = try authority.issueAuthorityEndpoint(networkID: network, environment: "test",
                                                       hostname: "valid.local", port: 50100, generation: 2)
        let foreign = try CredentialAuthority().issueAuthorityEndpoint(networkID: network, environment: "test",
                                                                      hostname: "foreign.local", port: 50101, generation: 3)
        source.continuation.yield(.candidates([foreign, valid], truncated: false))
        #expect(try await discovery.resolve().claims == valid.claims)
        await discovery.stop()
        await #expect(throws: AuthorityEndpointDiscoveryError.stopped) { try await discovery.resolve() }
        #expect(try await cache.current()?.claims == valid.claims)
        await #expect(throws: AuthorityEndpointDiscoveryError.stopped) { try await discovery.start() }
    }

    @Test("Unavailable discovery is bounded and cancelled requests do not stop its owner")
    func timeoutAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = CredentialAuthority()
        let network = NetworkID()
        let cache = try PersistentAuthorityEndpointCache.open(
            fileURL: root.appendingPathComponent("cache.json"),
            trustedAuthorityPublicKey: authority.publicKeyRepresentation, networkID: network, environment: "test"
        )
        let source = AsyncStream<AuthorityEndpointBrowserEvent>.makeStream()
        let discovery = AuthorityEndpointDiscovery(cache: cache, events: source.stream, start: {},
                                                  cancel: { source.continuation.finish() })
        await #expect(throws: AuthorityEndpointDiscoveryError.unavailable) {
            try await discovery.resolve(timeout: .milliseconds(10))
        }
        let waiter = Task { try await discovery.resolve() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        let valid = try authority.issueAuthorityEndpoint(networkID: network, environment: "test",
                                                       hostname: "valid.local", port: 50100, generation: 1)
        source.continuation.yield(.candidates([valid], truncated: false))
        #expect(try await discovery.resolve().claims == valid.claims)
        await discovery.stop()
    }

    @Test("Stopping drains pending candidate writes before returning")
    func stopDrains() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = CredentialAuthority()
        let network = NetworkID()
        let cache = try PersistentAuthorityEndpointCache.open(
            fileURL: root.appendingPathComponent("cache.json"),
            trustedAuthorityPublicKey: authority.publicKeyRepresentation, networkID: network, environment: "test"
        )
        let source = AsyncStream<AuthorityEndpointBrowserEvent>.makeStream()
        let discovery = AuthorityEndpointDiscovery(cache: cache, events: source.stream, start: {},
                                                  cancel: { source.continuation.finish() })
        try await discovery.start()
        let valid = try authority.issueAuthorityEndpoint(networkID: network, environment: "test",
                                                       hostname: "valid.local", port: 50100, generation: 1)
        source.continuation.yield(.candidates([valid], truncated: false))
        await discovery.stop()
        let settled = try await cache.current()
        source.continuation.yield(.candidates([valid], truncated: false))
        #expect(try await cache.current() == settled)
        await #expect(throws: AuthorityEndpointDiscoveryError.stopped) { try await discovery.resolve() }
    }
}
#endif
