import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetEnrollment
import BeakrNetSecurity

@Suite("Authority key rotation installation")
struct AuthorityKeyRotationInstallerTests {
    @Test("Prepared reset requests private-key activation without changing live trust")
    func preparedResetWaitsForKeyActivation() async throws {
        let fixture = try await RotationFixture.make()
        defer { fixture.remove() }

        try fixture.prepare()

        #expect(
            try AuthorityKeyRotationInstaller.recover(bundleURL: fixture.bundleURL)
                == .activateStagedPrivateKey(replacementAuthorityID: fixture.replacement.authorityID)
        )
        #expect(try NetworkBootstrap.loadManifest(from: fixture.bundleURL).authorityID == fixture.retiring.authorityID)
        #expect(
            try CredentialFiles.loadCredential(
                from: fixture.bundleURL.appendingPathComponent(NetworkBootstrap.administratorCredentialFilename)
            ) == fixture.originalCredential
        )
    }

    @Test("Committed reset installs one replacement administrator and rejects the retired credential")
    func committedResetReplacesTrust() async throws {
        let fixture = try await RotationFixture.make()
        defer { fixture.remove() }
        let retiredInvitation = try fixture.retiring.issueNetworkInvitation(
            networkID: fixture.originalCredential.claims.networkID,
            environment: fixture.originalCredential.claims.environment,
            controlPlaneURL: URL(string: "https://authority.example")!,
            authorityCertificateDER: Data([1]),
            now: fixture.now
        )

        try fixture.prepare()
        try AuthorityKeyRotationInstaller.markKeyActivated(bundleURL: fixture.bundleURL)
        #expect(try AuthorityKeyRotationInstaller.recover(bundleURL: fixture.bundleURL) == .none)

        let manifest = try NetworkBootstrap.loadManifest(from: fixture.bundleURL)
        let publicKey = try Data(
            contentsOf: fixture.bundleURL.appendingPathComponent(NetworkBootstrap.authorityPublicKeyFilename)
        )
        let credential = try CredentialFiles.loadCredential(
            from: fixture.bundleURL.appendingPathComponent(NetworkBootstrap.administratorCredentialFilename)
        )
        #expect(manifest.authorityID == fixture.replacement.authorityID)
        #expect(publicKey == fixture.replacement.publicKeyRepresentation)
        #expect(credential.claims.nodeID == fixture.identity.nodeID)
        #expect(Set(credential.claims.serviceScopes) == ["lan", "admin"])
        try CredentialVerifier.verify(
            credential,
            trustedAuthorityPublicKey: publicKey,
            networkID: manifest.profile.networkID,
            environment: manifest.environment,
            now: fixture.now
        )
        #expect(throws: CredentialVerificationError.wrongIssuer) {
            try CredentialVerifier.verify(
                fixture.originalCredential,
                trustedAuthorityPublicKey: publicKey,
                networkID: manifest.profile.networkID,
                environment: manifest.environment,
                now: fixture.now
            )
        }

        let trust = try await AuthorityTrustStateCoordinator.open(
            authority: fixture.replacement,
            networkID: manifest.profile.networkID,
            environment: manifest.environment,
            ledgerURL: fixture.bundleURL.appendingPathComponent(NetworkBootstrap.trustLedgerFilename),
            now: fixture.now
        )
        let records = await trust.membershipSnapshot().claims.records
        #expect(records.count == 1)
        #expect(records.first?.credential == credential)

        let joiningIdentity = NodeIdentity()
        let retiredRequest = try NetworkJoinRequest.signed(
            invitation: retiredInvitation,
            identity: joiningIdentity
        )
        let invitationService = try NetworkInvitationService(
            authority: fixture.replacement,
            networkID: manifest.profile.networkID,
            environment: manifest.environment
        )
        await #expect(throws: NetworkInvitationError.wrongAuthority) {
            try await invitationService.join(retiredRequest, now: fixture.now)
        }
    }

    @Test("Prepared recovery fails closed when a staged authority artifact is missing")
    func missingStagedArtifactFailsClosed() async throws {
        let fixture = try await RotationFixture.make()
        defer { fixture.remove() }
        try fixture.prepare()
        try FileManager.default.removeItem(
            at: fixture.bundleURL.appendingPathComponent(
                AuthorityKeyRotationInstaller.stagedTrustLedgerFilename
            )
        )

        #expect(throws: EnrollmentAuditExportVerificationError.invalidRotationStatement) {
            try AuthorityKeyRotationInstaller.recover(bundleURL: fixture.bundleURL)
        }
    }

    @Test("Commit archives retired enrollment work and restart recovery is idempotent")
    func archivesEnrollmentAndRecoversIdempotently() async throws {
        let fixture = try await RotationFixture.make()
        defer { fixture.remove() }
        let enrollmentURL = fixture.bundleURL.appendingPathComponent("enrollment", isDirectory: true)
        try FileManager.default.createDirectory(at: enrollmentURL, withIntermediateDirectories: true)
        let stateURL = enrollmentURL.appendingPathComponent("authority-state.json")
        let transactionsURL = enrollmentURL.appendingPathComponent("membership-transactions.json")
        try Data("pending".utf8).write(to: stateURL)
        try Data("transactions".utf8).write(to: transactionsURL)

        try fixture.prepare()
        try AuthorityKeyRotationInstaller.markKeyActivated(bundleURL: fixture.bundleURL)
        #expect(try AuthorityKeyRotationInstaller.recover(bundleURL: fixture.bundleURL) == .none)
        #expect(try AuthorityKeyRotationInstaller.recover(bundleURL: fixture.bundleURL) == .none)

        let suffix = fixture.retiring.authorityID.rawValue.uuidString.lowercased()
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
        #expect(!FileManager.default.fileExists(atPath: transactionsURL.path))
        #expect(FileManager.default.fileExists(
            atPath: enrollmentURL.appendingPathComponent("authority-state.json.retired-\(suffix)").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: enrollmentURL.appendingPathComponent("membership-transactions.json.retired-\(suffix)").path
        ))
    }
}

private struct RotationFixture {
    let rootURL: URL
    let bundleURL: URL
    let now: Date
    let identity: NodeIdentity
    let retiring: CredentialAuthority
    let replacement: CredentialAuthority
    let originalCredential: NodeCredential
    let statement: AuthorityKeyRotationStatement

    static func make() async throws -> Self {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakrnet-rotation-tests-\(UUID())", isDirectory: true)
        let bundleURL = rootURL.appendingPathComponent("Network", isDirectory: true)
        let result = try await NetworkBootstrap.create(
            at: bundleURL,
            displayName: "Rotation Test",
            environment: "production",
            serviceScopes: ["lan", "admin"],
            credentialValidity: 365 * 24 * 60 * 60,
            now: now
        )
        let retiring = try CredentialAuthority(
            privateKeyRepresentation: result.authorityPrivateKeyRepresentation
        )
        let replacement = CredentialAuthority()
        let identity = try NodeIdentity(
            privateKeyRepresentation: Data(
                contentsOf: bundleURL.appendingPathComponent(NetworkBootstrap.nodePrivateKeyFilename)
            )
        )
        return try Self(
            rootURL: rootURL,
            bundleURL: bundleURL,
            now: now,
            identity: identity,
            retiring: retiring,
            replacement: replacement,
            originalCredential: result.credential,
            statement: AuthorityKeyRotationStatement.signed(
                networkID: result.manifest.profile.networkID,
                retiringAuthority: retiring,
                replacementAuthority: replacement,
                effectiveAt: now
            )
        )
    }

    func prepare() throws {
        try AuthorityKeyRotationInstaller.prepare(
            bundleURL: bundleURL,
            statement: statement,
            replacementAuthority: replacement,
            administratorIdentity: identity,
            now: now
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
