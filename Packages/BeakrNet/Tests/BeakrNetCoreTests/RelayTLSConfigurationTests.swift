import Foundation
import Testing
@testable import BeakrNetSecurity

@Suite("Relay TLS configuration")
struct RelayTLSConfigurationTests {
    @Test("A 32-byte PSK is accepted")
    func validKey() throws {
        try RelayTLSConfiguration.validate(preSharedKey: Data(repeating: 0x42, count: 32))
    }

    @Test("A short PSK is rejected")
    func shortKey() {
        #expect(throws: RelayTLSConfigurationError.preSharedKeyTooShort) {
            try RelayTLSConfiguration.validate(
                preSharedKey: Data(repeating: 0x42, count: 31)
            )
        }
    }

    @Test("An oversized PSK is rejected")
    func oversizedKey() {
        #expect(throws: RelayTLSConfigurationError.preSharedKeyTooLarge) {
            try RelayTLSConfiguration.validate(
                preSharedKey: Data(repeating: 0x42, count: 65)
            )
        }
    }
}
