import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
@testable import BeakrNetHost

@Suite("Profile membership refresh")
struct ProfileMembershipRefreshTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("A signed advancing snapshot is durably activated")
    func activation() async throws {
        let fixture = try await makeFixture(results: [.success(nil)])
        await fixture.requester.replaceFirst(with: .success(fixture.snapshot))

        let outcome = await fixture.controller.refreshNow(trigger: .startup)

        #expect(outcome == .activated(generation: 1, nextAttemptAt: now.addingTimeInterval(60)))
        #expect(await fixture.directory.generation() == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    @Test("Failures back off and no-change resets the normal cadence")
    func retryCadence() async throws {
        let fixture = try await makeFixture(results: [
            .failure(MembershipRefreshTestError.offline),
            .failure(MembershipRefreshTestError.offline),
            .success(nil)
        ])

        #expect(await fixture.controller.refreshNow(trigger: .manual).retryDate == now.addingTimeInterval(5))
        #expect(await fixture.controller.refreshNow(trigger: .scheduled).retryDate == now.addingTimeInterval(10))
        #expect(await fixture.controller.refreshNow(trigger: .scheduled) == .unchanged(
            nextAttemptAt: now.addingTimeInterval(60)
        ))
    }

    @Test("An invalid snapshot is not persisted or activated")
    func invalidSnapshotFailsClosed() async throws {
        let fixture = try await makeFixture(results: [.success(nil)])
        let otherAuthority = CredentialAuthority()
        let invalid = try ProfileMembershipAuthority(
            privateKeyRepresentation: otherAuthority.privateKeyRepresentation
        ).sign(fixture.snapshot.claims)
        await fixture.requester.replaceFirst(with: .success(invalid))

        guard case .failed(_, let count, _) = await fixture.controller.refreshNow(trigger: .scheduled) else {
            Issue.record("Expected failure")
            return
        }
        #expect(count == 1)
        #expect(await fixture.directory.generation() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    private func makeFixture(
        results: [Result<ProfileMembershipSnapshot?, Error>]
    ) async throws -> MembershipRefreshFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakr-membership-refresh-\(UUID())", isDirectory: true)
        let fileURL = root.appendingPathComponent("membership.json")
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let snapshot = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        ).sign(.init(
            networkID: networkID,
            generation: 1,
            generatedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            records: []
        ))
        let directory = try await ProfileMembershipDirectory.open(
            fileURL: fileURL,
            networkID: networkID,
            environment: "test",
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            revokedCredentialIDs: [],
            now: { now }
        )
        let requester = MembershipSequenceRequester(results: results)
        let controller = ProfileMembershipRefreshController(
            directory: directory,
            requester: requester,
            policy: try .init(refreshInterval: 60, initialRetryDelay: 5, maximumRetryDelay: 20),
            now: { now }
        )
        return .init(fileURL: fileURL, snapshot: snapshot, directory: directory, requester: requester, controller: controller)
    }
}

private extension ProfileMembershipRefreshOutcome {
    var retryDate: Date? {
        if case .failed(let date, _, _) = self { return date }
        return nil
    }
}

private struct MembershipRefreshFixture {
    let fileURL: URL
    let snapshot: ProfileMembershipSnapshot
    let directory: ProfileMembershipDirectory
    let requester: MembershipSequenceRequester
    let controller: ProfileMembershipRefreshController
}

private actor MembershipSequenceRequester: ProfileMembershipSnapshotRequesting {
    private var results: [Result<ProfileMembershipSnapshot?, Error>]
    init(results: [Result<ProfileMembershipSnapshot?, Error>]) { self.results = results }
    func replaceFirst(with result: Result<ProfileMembershipSnapshot?, Error>) {
        results[0] = result
    }
    func fetchSnapshot(after generation: UInt64?) async throws -> ProfileMembershipSnapshot? {
        try results.removeFirst().get()
    }
}

private enum MembershipRefreshTestError: Error { case offline }
