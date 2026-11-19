import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetHost
#if canImport(Network)
import Network
#endif

@Suite("Authority Bonjour record framing")
struct AuthorityEndpointBonjourTests {
    private func record() throws -> SignedAuthorityEndpoint {
        try CredentialAuthority().issueAuthorityEndpoint(
            networkID: NetworkID(), environment: "test", hostname: "fixture.local",
            port: 50_101, generation: 1
        )
    }

    @Test("TXT chunks roundtrip the signed record within the wire bound")
    func roundtrip() throws {
        let original = try record()
        let fields = try AuthorityEndpointBonjourCodec.encode(original)
        #expect(try AuthorityEndpointBonjourCodec.decode(fields) == original)
        #expect(fields.allSatisfy { $0.key.utf8.count + $0.value.utf8.count + 1 <= 255 })
        #expect(fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 2 } <= 1_300)
    }

    @Test("Missing, extra, oversized, unsupported and malformed chunks are rejected")
    func malformedRecords() throws {
        let fields = try AuthorityEndpointBonjourCodec.encode(record())
        var missing = fields
        missing.removeValue(forKey: "d0")
        var extra = fields
        extra["extra"] = "ignored?"
        var oversized = fields
        oversized["d0"] = String(repeating: "a", count: 256)
        var unsupported = fields
        unsupported["v"] = "2"
        var malformed = fields
        malformed["d0"] = String(repeating: "!", count: 200)
        for bad in [missing, extra, oversized, unsupported, malformed] {
            #expect(throws: (any Error).self) { try AuthorityEndpointBonjourCodec.decode(bad) }
        }
    }

    #if canImport(Network)
    @Test("Service construction uses the bound port and preserves record bytes")
    func service() throws {
        let original = try record()
        let service = try AuthorityEndpointBonjourAdvertisement.service(original, boundPort: 50_101)
        #expect(service.type == AuthorityEndpointBonjourCodec.serviceType)
        let txt = try #require(service.txtRecordObject)
        #expect(try AuthorityEndpointBonjourCodec.decode(txt.dictionary) == original)
        #expect(throws: AuthorityEndpointBonjourError.listenerPortMismatch) {
            try AuthorityEndpointBonjourAdvertisement.service(original, boundPort: 50_102)
        }
    }

    @Test("An unstarted browser can be cancelled without browsing or leaving an open stream")
    func cancelledBeforeStart() async {
        let browser = AuthorityEndpointBonjourBrowser(networkID: NetworkID())
        browser.cancel()
        browser.start()
        var iterator = browser.events.makeAsyncIterator()
        if case .stopped? = await iterator.next() {} else { Issue.record("Expected cancellation") }
        #expect(await iterator.next() == nil)
    }
    #endif
}
