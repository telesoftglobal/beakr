#if os(macOS)
import Foundation
import Security
import Testing
import BeakrNetAuthority
import BeakrNetSecurity

@Suite(
    "OpenSSL development certificate issuer integration",
    .enabled(if: ProcessInfo.processInfo.environment["BEAKRNET_RUN_CERTIFICATE_ISSUER_INTEGRATION"] == "1"),
    .serialized
)
struct OpenSSLCertificateIssuerIntegrationTests {
    @Test("A real CA issues a verifiable certificate bound to the node key")
    func issueAndVerify() async throws {
        let openssl = try opensslURL()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakrnet-openssl-issuer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let authorityKey = directory.appendingPathComponent("authority-key.pem")
        let authorityCertificate = directory.appendingPathComponent("authority-cert.pem")
        try run(openssl, [
            "req", "-x509", "-newkey", "ec",
            "-pkeyopt", "ec_paramgen_curve:P-256",
            "-nodes", "-sha256", "-days", "2",
            "-subj", "/CN=BeakrNet Issuer Integration CA",
            "-keyout", authorityKey.path,
            "-out", authorityCertificate.path
        ])

        let identity = NodeIdentity()
        let issuer = OpenSSLDevelopmentCertificateIssuer(
            executableURL: openssl,
            authorityCertificateURL: authorityCertificate,
            authorityPrivateKeyURL: authorityKey
        )
        let material = try await issuer.issueCertificate(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            validity: 86_400,
            now: Date()
        )

        #expect(material.certificateChainDER.count == 1)
        let certificate = try #require(SecCertificateCreateWithData(nil, material.leafCertificateDER as CFData))
        let certificateKey = try #require(SecCertificateCopyKey(certificate))
        var keyError: Unmanaged<CFError>?
        let externalKey = try #require(SecKeyCopyExternalRepresentation(certificateKey, &keyError) as Data?)
        #expect(externalKey == identity.publicKeyRepresentation)

        let leafDER = directory.appendingPathComponent("leaf.der")
        let leafPEM = directory.appendingPathComponent("leaf.pem")
        try material.leafCertificateDER.write(to: leafDER, options: .atomic)
        try run(openssl, [
            "x509", "-inform", "DER", "-in", leafDER.path,
            "-outform", "PEM", "-out", leafPEM.path
        ])
        try run(openssl, [
            "verify", "-CAfile", authorityCertificate.path, leafPEM.path
        ])

        if ProcessInfo.processInfo.environment["BEAKRNET_RUN_KEYCHAIN_IDENTITY_INTEGRATION"] == "1" {
            try await verifyKeychainInstallation(material: material, issuer: issuer, identity: identity)
        }
    }

    private func verifyKeychainInstallation(
        material: IssuedCertificateMaterial,
        issuer: OpenSSLDevelopmentCertificateIssuer,
        identity: NodeIdentity
    ) async throws {
        let keychainStore = KeychainLANTLSIdentityStore(
            service: "org.beakrnet.tests.lan-tls.\(UUID().uuidString)"
        )
        defer { try? keychainStore.delete() }
        #expect(throws: KeychainLANTLSIdentityStoreError.certificateKeyMismatch) {
            try keychainStore.install(
                leafCertificateDER: material.leafCertificateDER,
                certificateChainDER: material.certificateChainDER,
                nodeIdentity: NodeIdentity()
            )
        }
        let installed = try keychainStore.install(
            leafCertificateDER: material.leafCertificateDER,
            certificateChainDER: material.certificateChainDER,
            nodeIdentity: identity
        )
        #expect(SecCertificateCopyData(installed.leafCertificate) as Data == material.leafCertificateDER)
        #expect(installed.certificateChain.count == 1)

        let replacement = try await issuer.issueCertificate(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            validity: 86_400,
            now: Date()
        )
        #expect(replacement.leafCertificateDER != material.leafCertificateDER)
        _ = try keychainStore.install(
            leafCertificateDER: replacement.leafCertificateDER,
            certificateChainDER: replacement.certificateChainDER,
            nodeIdentity: identity
        )
        let loaded = try #require(try keychainStore.load())
        #expect(SecCertificateCopyData(loaded.leafCertificate) as Data == replacement.leafCertificateDER)
        #expect(loaded.certificateChain.count == 1)
    }

    private func opensslURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["BEAKRNET_TEST_OPENSSL"],
            "/opt/homebrew/bin/openssl",
            "/usr/local/bin/openssl",
            "/usr/bin/openssl"
        ].compactMap { $0 }
        return try #require(
            candidates.map(URL.init(fileURLWithPath:)).first {
                FileManager.default.isExecutableFile(atPath: $0.path)
            },
            "Set BEAKRNET_TEST_OPENSSL to an OpenSSL executable"
        )
    }

    private func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let reason = String(data: data, encoding: .utf8) ?? "unknown OpenSSL error"
            Issue.record("OpenSSL failed: \(reason)")
            throw OpenSSLIntegrationError.commandFailed
        }
    }
}

private enum OpenSSLIntegrationError: Error {
    case commandFailed
}
#endif
