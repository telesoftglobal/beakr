import Foundation
import Testing
@testable import BeakrNetSecurity

@Suite("LAN mutual TLS configuration")
struct LANTLSConfigurationTests {
    @Test("Invalid PKCS 12 data fails closed")
    func invalidPKCS12() {
        #expect(throws: LANTLSConfigurationError.invalidPKCS12) {
            try LANTLSIdentityLoader.importPKCS12(
                Data("not-a-pkcs12-identity".utf8),
                password: "test"
            )
        }
    }
}
