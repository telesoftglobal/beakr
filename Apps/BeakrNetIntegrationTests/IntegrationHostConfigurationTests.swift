import Foundation
import Testing

@Suite("Integration host configuration")
struct IntegrationHostConfigurationTests {
    @Test("Signed host exposes required Bonjour services")
    func requiredBonjourServices() throws {
        let services = try #require(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String])

        #expect(services.contains("_beakrnet._tcp"))
        #expect(services.contains("_beakrtest._tcp"))
    }
}
