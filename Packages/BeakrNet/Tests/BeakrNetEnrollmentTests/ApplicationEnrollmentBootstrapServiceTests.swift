import Foundation
import Testing
import BeakrNetEnrollment

@Suite("Application enrollment bootstrap routing")
struct ApplicationEnrollmentBootstrapServiceTests {
    @Test("Cold-start outcomes select stable application routes", arguments: [
        BootstrapRouteFixture(.unconfigured, .welcome),
        BootstrapRouteFixture(.leaveCompleted, .welcome),
        BootstrapRouteFixture(.restored(.init(node: .identityReady, authority: .unavailable)), .identityReady),
        BootstrapRouteFixture(.restored(.init(node: .locked, authority: .locked)), .locked),
        BootstrapRouteFixture(.restored(.init(node: .credentialExpired, authority: .unavailable)), .credentialRecovery),
        BootstrapRouteFixture(.restored(.init(node: .trustStateStale, authority: .unavailable)), .trustRecovery),
        BootstrapRouteFixture(.restored(.init(node: .certificateRecoveryRequired, authority: .unavailable)), .certificateRecovery),
        BootstrapRouteFixture(.memberRuntimeStarted(.init(node: .ready, authority: .ready)), .member)
    ])
    fileprivate func routes(fixture: BootstrapRouteFixture) async throws {
        let service = ApplicationEnrollmentBootstrapService(
            restoration: FixedColdStartRestoration(result: fixture.result)
        )
        #expect(try await service.start() == fixture.route)
    }

    @Test("Waiting preserves the durable request identifier")
    func waitingRoute() async throws {
        let requestID = UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!
        let service = ApplicationEnrollmentBootstrapService(
            restoration: FixedColdStartRestoration(result: .waitingForAdministrator(
                requestID: requestID,
                state: .init(node: .waitingForAdministrator, authority: .unavailable)
            ))
        )
        #expect(try await service.start() == .waitingForAdministrator(requestID: requestID))
    }

    @Test("Explicit recovery reasons remain visible to the application")
    func recoveryRoute() async throws {
        let service = ApplicationEnrollmentBootstrapService(
            restoration: FixedColdStartRestoration(result: .recoveryRequired(.missingNodeIdentity))
        )
        #expect(try await service.start() == .recoveryRequired(.missingNodeIdentity))
    }
}

private struct BootstrapRouteFixture: Sendable {
    let result: EnrollmentColdStartResult
    let route: EnrollmentApplicationRoute

    init(_ result: EnrollmentColdStartResult, _ route: EnrollmentApplicationRoute) {
        self.result = result
        self.route = route
    }
}

private struct FixedColdStartRestoration: EnrollmentColdStartRestoring {
    let result: EnrollmentColdStartResult
    func restore() -> EnrollmentColdStartResult { result }
}
