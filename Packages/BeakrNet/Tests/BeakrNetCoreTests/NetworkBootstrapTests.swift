import Foundation
import Testing
import BeakrNetCore
import BeakrNetSecurity
@testable import BeakrNetAuthority

@Suite("Network bootstrap transaction")
struct NetworkBootstrapTests {
    @Test("Creates a coherent administrator network bundle")
    func createsNetworkBundle() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakrnet-bootstrap-tests-\(UUID())", isDirectory: true)
        let bundleURL = root.appendingPathComponent("Red", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await NetworkBootstrap.create(
            at: bundleURL,
            displayName: "Red Network",
            environment: "production",
            serviceScopes: ["lan", "admin"],
            credentialValidity: 86_400,
            controlPlaneURL: URL(string: "https://authority.red.example")!,
            now: now
        )

        let manifest = try NetworkBootstrap.loadManifest(from: bundleURL)
        #expect(manifest == result.manifest)
        #expect(manifest.profile.networkID == result.credential.claims.networkID)
        #expect(manifest.profile.localNodeID == result.credential.claims.nodeID)
        #expect(manifest.authorityID == result.credential.claims.issuerID)

        let authority = try CredentialFiles.loadAuthority(
            privateKeyURL: bundleURL.appendingPathComponent(NetworkBootstrap.authorityPrivateKeyFilename)
        )
        let publicKey = try Data(
            contentsOf: bundleURL.appendingPathComponent(NetworkBootstrap.authorityPublicKeyFilename)
        )
        #expect(authority.publicKeyRepresentation == publicKey)
        try CredentialVerifier.verify(
            result.credential,
            trustedAuthorityPublicKey: publicKey,
            networkID: manifest.profile.networkID,
            environment: manifest.environment,
            now: now
        )

        let identity = try NodeIdentity(
            privateKeyRepresentation: Data(
                contentsOf: bundleURL.appendingPathComponent(NetworkBootstrap.nodePrivateKeyFilename)
            )
        )
        #expect(identity.nodeID == manifest.profile.localNodeID)

        let trust = try await AuthorityTrustStateCoordinator.open(
            authority: authority,
            networkID: manifest.profile.networkID,
            environment: manifest.environment,
            ledgerURL: bundleURL.appendingPathComponent(NetworkBootstrap.trustLedgerFilename),
            now: now
        )
        #expect(await trust.membershipSnapshot().claims.generation == 1)
        #expect(await trust.membershipSnapshot().claims.records.first?.credential == result.credential)
        #expect(await trust.revocationSnapshot().claims.revocations.isEmpty == true)
    }

    @Test("Does not replace an existing destination")
    func preservesExistingDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakrnet-bootstrap-tests-\(UUID())", isDirectory: true)
        let bundleURL = root.appendingPathComponent("Blue", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let sentinelURL = bundleURL.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinelURL)
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: NetworkBootstrapError.destinationAlreadyExists) {
            try await NetworkBootstrap.create(
                at: bundleURL,
                displayName: "Blue Network",
                environment: "production",
                serviceScopes: ["lan"],
                credentialValidity: 86_400
            )
        }
        #expect(try Data(contentsOf: sentinelURL) == Data("keep".utf8))
    }

    @Test("Rejects unsafe TLS packaging configuration before creating files")
    func rejectsInvalidTLSConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakrnet-bootstrap-tests-\(UUID())", isDirectory: true)
        let bundleURL = root.appendingPathComponent("Unsafe", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: NetworkBootstrapError.invalidTLSConfiguration) {
            try await NetworkBootstrap.create(
                at: bundleURL,
                displayName: "Unsafe",
                environment: "production",
                serviceScopes: ["lan"],
                credentialValidity: 86_400,
                tlsConfiguration: .init(
                    openSSLExecutableURL: URL(fileURLWithPath: "/usr/bin/openssl"),
                    serverHostname: "authority.test/../../escape",
                    pkcs12Password: "secret"
                )
            )
        }
        #expect(!FileManager.default.fileExists(atPath: bundleURL.path))
    }

    @Test("Can bind an existing identity without exporting its private key")
    func bindsExternalIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakrnet-bootstrap-tests-\(UUID())", isDirectory: true)
        let bundleURL = root.appendingPathComponent("Keychain", isDirectory: true)
        let identity = NodeIdentity()
        let profileID = NetworkProfileID()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await NetworkBootstrap.create(
            at: bundleURL,
            displayName: "Keychain Network",
            environment: "production",
            serviceScopes: ["lan", "admin"],
            credentialValidity: 86_400,
            profileID: profileID,
            initialNodeIdentity: identity,
            persistInitialNodePrivateKey: false,
            persistAuthorityPrivateKey: false
        )

        #expect(result.manifest.profile.id == profileID)
        #expect(result.manifest.profile.localNodeID == identity.nodeID)
        #expect(result.credential.claims.nodePublicKey == identity.publicKeyRepresentation)
        #expect(!FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent(NetworkBootstrap.nodePrivateKeyFilename).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent(NetworkBootstrap.authorityPrivateKeyFilename).path
        ))
        let restoredAuthority = try CredentialAuthority(
            privateKeyRepresentation: result.authorityPrivateKeyRepresentation
        )
        #expect(restoredAuthority.authorityID == result.manifest.authorityID)
    }
}
