import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetHost

@Suite("Durable authority endpoint tracking")
struct PersistentAuthorityEndpointTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Publisher preserves generation on renewal and advances after a port change across restart")
    func publisherRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("publisher.json")
        let authority = CredentialAuthority()
        let network = NetworkID()
        let publisher = try PersistentAuthorityEndpointPublisher.open(
            fileURL: url, authority: authority, networkID: network, environment: "test"
        )
        let first = try await publisher.publish(hostname: "fixture.local", boundPort: 50_101, now: now)
        let renewal = try await publisher.publish(
            hostname: "fixture.local", boundPort: 50_101, now: now.addingTimeInterval(30)
        )
        #expect(first.claims.generation == 1)
        #expect(renewal.claims.generation == 1)
        #expect(renewal.claims.expiresAtMilliseconds > first.claims.expiresAtMilliseconds)
        let reopened = try PersistentAuthorityEndpointPublisher.open(
            fileURL: url, authority: authority, networkID: network, environment: "test"
        )
        let changed = try await reopened.publish(
            hostname: "fixture.local", boundPort: 50_102, now: now.addingTimeInterval(60)
        )
        #expect(changed.claims.generation == 2)
        #expect(try SignedAuthorityEndpoint.decode(Data(contentsOf: url)) == changed)
    }

    @Test("Mixed-case Mac hostnames publish canonical claims without spurious generation changes")
    func mixedCaseHostname() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("publisher.json")
        let authority = CredentialAuthority()
        let network = NetworkID()
        let publisher = try PersistentAuthorityEndpointPublisher.open(
            fileURL: url, authority: authority, networkID: network, environment: "test"
        )
        let first = try await publisher.publish(hostname: "MacMini-Ice-9.local", boundPort: 50_101, now: now)
        #expect(first.claims.hostname == "macmini-ice-9.local")
        let reopened = try PersistentAuthorityEndpointPublisher.open(
            fileURL: url, authority: authority, networkID: network, environment: "test"
        )
        let renewal = try await reopened.publish(
            hostname: "MACMINI-ICE-9.LOCAL", boundPort: 50_101, now: now.addingTimeInterval(30)
        )
        #expect(renewal.claims.hostname == first.claims.hostname)
        #expect(renewal.claims.generation == first.claims.generation)
        let cache = try PersistentAuthorityEndpointCache.open(
            fileURL: directory.appendingPathComponent("cache.json"),
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: network, environment: "test"
        )
        #expect(try await cache.accept(renewal, now: now.addingTimeInterval(30)).controlPlaneURL.host == "macmini-ice-9.local")
        await #expect(throws: AuthorityEndpointError.invalidRecord) {
            try await publisher.publish(hostname: "bad host.local", boundPort: 50_101, now: now)
        }
    }

    @Test("Expired cached records retain rollback protection after reopening")
    func expiredHighWater() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cache.json")
        let authority = CredentialAuthority()
        let network = NetworkID()
        let record = try authority.issueAuthorityEndpoint(
            networkID: network, environment: "test", hostname: "fixture.local",
            port: 50_102, generation: 2, now: now
        )
        let cache = try PersistentAuthorityEndpointCache.open(
            fileURL: url, trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: network, environment: "test"
        )
        try await cache.accept(record, now: now)
        let reopened = try PersistentAuthorityEndpointCache.open(
            fileURL: url, trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: network, environment: "test"
        )
        let later = now.addingTimeInterval(200)
        #expect(try await reopened.current(now: later) == nil)
        let olderGeneration = try authority.issueAuthorityEndpoint(
            networkID: network, environment: "test", hostname: "fixture.local",
            port: 50_101, generation: 1, now: later
        )
        await #expect(throws: AuthorityEndpointError.staleGeneration) {
            try await reopened.accept(olderGeneration, now: later)
        }
        let newest = try authority.issueAuthorityEndpoint(
            networkID: network, environment: "test", hostname: "fixture.local",
            port: 50_103, generation: 3, now: later
        )
        #expect(try await reopened.accept(newest, now: later).controlPlaneURL.port == 50_103)
    }

    @Test("Same-generation endpoint conflict and publication rollback leave cache unchanged")
    func conflictingRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cache.json")
        let authority = CredentialAuthority()
        let network = NetworkID()
        let original = try authority.issueAuthorityEndpoint(
            networkID: network, environment: "test", hostname: "fixture.local",
            port: 50_101, generation: 1, now: now
        )
        let cache = try PersistentAuthorityEndpointCache.open(
            fileURL: url, trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: network, environment: "test"
        )
        try await cache.accept(original, now: now)
        let before = try Data(contentsOf: url)
        let conflicting = try authority.issueAuthorityEndpoint(
            networkID: network, environment: "test", hostname: "fixture.local",
            port: 50_102, generation: 1, now: now
        )
        await #expect(throws: AuthorityEndpointPersistenceError.conflictingEndpoint) {
            try await cache.accept(conflicting, now: now)
        }
        let older = try authority.issueAuthorityEndpoint(
            networkID: network, environment: "test", hostname: "fixture.local",
            port: 50_101, generation: 1, now: now.addingTimeInterval(-10)
        )
        await #expect(throws: AuthorityEndpointPersistenceError.olderPublication) {
            try await cache.accept(older, now: now)
        }
        let invalid = SignedAuthorityEndpoint(claims: original.claims, signature: Data([0]))
        await #expect(throws: AuthorityEndpointError.invalidSignature) {
            try await cache.accept(invalid, now: now)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(try await cache.current(now: now)?.claims == original.claims)
    }

    @Test("Failed publication and cache writes do not advance in-memory state")
    func failedWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authority = CredentialAuthority()
        let network = NetworkID()
        let publisher = try PersistentAuthorityEndpointPublisher.open(
            fileURL: directory.appendingPathComponent("publisher.json"),
            authority: authority, networkID: network, environment: "test"
        )
        let cache = try PersistentAuthorityEndpointCache.open(
            fileURL: directory.appendingPathComponent("cache.json"),
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            networkID: network, environment: "test"
        )
        let first = try await publisher.publish(hostname: "fixture.local", boundPort: 50_101, now: now)
        try await cache.accept(first, now: now)
        let second = try authority.issueAuthorityEndpoint(
            networkID: network, environment: "test", hostname: "fixture.local",
            port: 50_102, generation: 2, now: now
        )
        try FileManager.default.removeItem(at: directory)
        try Data("block".utf8).write(to: directory)
        await #expect(throws: (any Error).self) {
            try await publisher.publish(hostname: "fixture.local", boundPort: 50_102, now: now)
        }
        await #expect(throws: (any Error).self) { try await cache.accept(second, now: now) }
        #expect(try await cache.current(now: now)?.claims == first.claims)
        try FileManager.default.removeItem(at: directory)
        let retried = try await publisher.publish(hostname: "fixture.local", boundPort: 50_102, now: now)
        #expect(retried.claims.generation == 2)
        try await cache.accept(retried, now: now)
        #expect(try await cache.current(now: now)?.claims.port == 50_102)
    }

    @Test("Corrupt state and wrong trust bindings fail without replacing evidence")
    func failedOpen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("publisher.json")
        let authority = CredentialAuthority()
        let network = NetworkID()
        let publisher = try PersistentAuthorityEndpointPublisher.open(
            fileURL: url, authority: authority, networkID: network, environment: "test"
        )
        _ = try await publisher.publish(hostname: "fixture.local", boundPort: 50_101, now: now)
        let before = try Data(contentsOf: url)
        #expect(throws: AuthorityEndpointError.wrongAuthority) {
            try PersistentAuthorityEndpointPublisher.open(
                fileURL: url, authority: CredentialAuthority(), networkID: network, environment: "test"
            )
        }
        #expect(throws: AuthorityEndpointError.wrongNetwork) {
            try PersistentAuthorityEndpointCache.open(
                fileURL: url, trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                networkID: NetworkID(), environment: "test"
            )
        }
        #expect(try Data(contentsOf: url) == before)
        let corrupt = Data(repeating: 0, count: 4_097)
        try corrupt.write(to: url)
        #expect(throws: AuthorityEndpointError.invalidRecord) {
            try PersistentAuthorityEndpointPublisher.open(
                fileURL: url, authority: authority, networkID: network, environment: "test"
            )
        }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test("Generation exhaustion never wraps to a previously used generation")
    func generationExhaustion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("publisher.json")
        let authority = CredentialAuthority()
        let network = NetworkID()
        let last = try authority.issueAuthorityEndpoint(
            networkID: network, environment: "test", hostname: "fixture.local",
            port: 50_101, generation: .max, now: now
        )
        try last.encoded().write(to: url)
        let publisher = try PersistentAuthorityEndpointPublisher.open(
            fileURL: url, authority: authority, networkID: network, environment: "test"
        )
        await #expect(throws: AuthorityEndpointPersistenceError.generationExhausted) {
            try await publisher.publish(hostname: "fixture.local", boundPort: 50_102, now: now)
        }
        #expect(try SignedAuthorityEndpoint.decode(Data(contentsOf: url)) == last)
    }
}
