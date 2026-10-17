import Foundation
import BeakrNetCore
import BeakrNetSecurity

public struct NetworkBootstrapManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let profile: NetworkProfile
    public let authorityID: AuthorityID
    public let environment: String
    public let serviceScopes: [String]
    public let controlPlaneURL: URL?

    public init(
        profile: NetworkProfile,
        authorityID: AuthorityID,
        environment: String,
        serviceScopes: [String],
        controlPlaneURL: URL?
    ) {
        formatVersion = Self.currentFormatVersion
        self.profile = profile
        self.authorityID = authorityID
        self.environment = environment
        self.serviceScopes = serviceScopes
        self.controlPlaneURL = controlPlaneURL
    }
}

public struct NetworkBootstrapResult: Sendable {
    public let manifest: NetworkBootstrapManifest
    public let bundleURL: URL
    public let credential: NodeCredential
    public let authorityPrivateKeyRepresentation: Data
    public let certificateAuthorityPrivateKeyPEM: Data?

    public init(
        manifest: NetworkBootstrapManifest,
        bundleURL: URL,
        credential: NodeCredential,
        authorityPrivateKeyRepresentation: Data,
        certificateAuthorityPrivateKeyPEM: Data?
    ) {
        self.manifest = manifest
        self.bundleURL = bundleURL
        self.credential = credential
        self.authorityPrivateKeyRepresentation = authorityPrivateKeyRepresentation
        self.certificateAuthorityPrivateKeyPEM = certificateAuthorityPrivateKeyPEM
    }
}

public struct NetworkBootstrapTLSConfiguration: Sendable {
    public let openSSLExecutableURL: URL
    public let serverHostname: String
    public let pkcs12Password: String
    public let validityDays: Int

    public init(
        openSSLExecutableURL: URL,
        serverHostname: String,
        pkcs12Password: String,
        validityDays: Int = 365
    ) {
        self.openSSLExecutableURL = openSSLExecutableURL
        self.serverHostname = serverHostname
        self.pkcs12Password = pkcs12Password
        self.validityDays = validityDays
    }
}

public enum NetworkBootstrapError: Error, Equatable, Sendable {
    case destinationAlreadyExists
    case invalidEnvironment
    case invalidServiceScopes
    case invalidValidity
    case invalidControlPlaneURL
    case invalidTLSConfiguration
    case openSSLUnavailable
    case openSSLFailed(status: Int32, reason: String)
    case tlsPackagingRequiresMacOS
}

/// Creates the complete signing and trust-state foundation for a new network.
/// All files are assembled in a sibling staging directory and become visible
/// only when the finished directory is atomically moved into place.
public enum NetworkBootstrap {
    public static let manifestFilename = "network.json"
    public static let authorityPrivateKeyFilename = "authority-private.key"
    public static let authorityPublicKeyFilename = "authority-public.key"
    public static let nodePrivateKeyFilename = "node-private.key"
    public static let administratorCredentialFilename = "administrator-credential.json"
    public static let trustLedgerFilename = "trust-ledger.json"
    public static let certificateAuthorityPrivateKeyFilename = "ca-private-key.pem"
    public static let certificateAuthorityCertificateFilename = "ca-certificate.pem"
    public static let authorityServerIdentityFilename = "authority-server.p12"

    public static func renameNetwork(at bundleURL: URL, to displayName: String) throws {
        let manifest = try loadManifest(from: bundleURL)
        let renamedProfile = try NetworkProfile(
            id: manifest.profile.id,
            networkID: manifest.profile.networkID,
            localNodeID: manifest.profile.localNodeID,
            displayName: displayName,
            createdAt: manifest.profile.createdAt
        )
        let renamedManifest = NetworkBootstrapManifest(
            profile: renamedProfile,
            authorityID: manifest.authorityID,
            environment: manifest.environment,
            serviceScopes: manifest.serviceScopes,
            controlPlaneURL: manifest.controlPlaneURL
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(renamedManifest).write(
            to: bundleURL.appendingPathComponent(manifestFilename),
            options: .atomic
        )
    }

    public static func create(
        at bundleURL: URL,
        displayName: String,
        environment: String,
        serviceScopes: [String],
        credentialValidity: TimeInterval,
        controlPlaneURL: URL? = nil,
        tlsConfiguration: NetworkBootstrapTLSConfiguration? = nil,
        profileID: NetworkProfileID = NetworkProfileID(),
        initialNodeIdentity: NodeIdentity? = nil,
        persistInitialNodePrivateKey: Bool = true,
        persistAuthorityPrivateKey: Bool = true,
        persistCertificateAuthorityPrivateKey: Bool = true,
        now: Date = Date()
    ) async throws -> NetworkBootstrapResult {
        let normalizedEnvironment = environment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEnvironment.isEmpty else {
            throw NetworkBootstrapError.invalidEnvironment
        }
        let normalizedScopes = serviceScopes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !normalizedScopes.isEmpty,
              normalizedScopes.allSatisfy({ !$0.isEmpty }),
              Set(normalizedScopes).count == normalizedScopes.count else {
            throw NetworkBootstrapError.invalidServiceScopes
        }
        guard credentialValidity > 0 else {
            throw NetworkBootstrapError.invalidValidity
        }
        if let controlPlaneURL {
            guard controlPlaneURL.scheme == "https", controlPlaneURL.host != nil else {
                throw NetworkBootstrapError.invalidControlPlaneURL
            }
        }
        if let tlsConfiguration {
            try validate(tlsConfiguration)
        }

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: bundleURL.path) else {
            throw NetworkBootstrapError.destinationAlreadyExists
        }
        let parentURL = bundleURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let stagingURL = parentURL.appendingPathComponent(
            ".beakrnet-bootstrap-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var committed = false
        defer {
            if !committed { try? fileManager.removeItem(at: stagingURL) }
        }

        let networkID = NetworkID()
        let identity = initialNodeIdentity ?? NodeIdentity()
        let profile = try NetworkProfile(
            id: profileID,
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: displayName,
            createdAt: now
        )
        let authority = CredentialAuthority()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: normalizedEnvironment,
            validity: credentialValidity,
            serviceScopes: normalizedScopes,
            now: now
        )
        let manifest = NetworkBootstrapManifest(
            profile: profile,
            authorityID: authority.authorityID,
            environment: normalizedEnvironment,
            serviceScopes: normalizedScopes,
            controlPlaneURL: controlPlaneURL
        )

        let authorityPublicKeyURL = stagingURL.appendingPathComponent(authorityPublicKeyFilename)
        if persistAuthorityPrivateKey {
            try CredentialFiles.saveAuthority(
                authority,
                privateKeyURL: stagingURL.appendingPathComponent(authorityPrivateKeyFilename),
                publicKeyURL: authorityPublicKeyURL
            )
        } else {
            try authority.publicKeyRepresentation.write(to: authorityPublicKeyURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: authorityPublicKeyURL.path)
        }
        if persistInitialNodePrivateKey {
            try writePrivateKey(
                identity.privateKeyRepresentation,
                to: stagingURL.appendingPathComponent(nodePrivateKeyFilename)
            )
        }
        try CredentialFiles.saveCredential(
            credential,
            to: stagingURL.appendingPathComponent(administratorCredentialFilename)
        )
        let trust = try await AuthorityTrustStateCoordinator.open(
            authority: authority,
            networkID: networkID,
            environment: normalizedEnvironment,
            networkDisplayName: profile.displayName,
            ledgerURL: stagingURL.appendingPathComponent(trustLedgerFilename),
            now: now
        )
        try await trust.approve(
            credential: credential,
            certificatePublicKey: identity.publicKeyRepresentation,
            now: now
        )
        try writeManifest(manifest, to: stagingURL.appendingPathComponent(manifestFilename))
        let certificateAuthorityPrivateKeyPEM: Data?
        if let tlsConfiguration {
            certificateAuthorityPrivateKeyPEM = try packageAuthorityTLS(
                in: stagingURL,
                configuration: tlsConfiguration,
                persistPrivateKey: persistCertificateAuthorityPrivateKey
            )
        } else {
            certificateAuthorityPrivateKeyPEM = nil
        }

        try fileManager.moveItem(at: stagingURL, to: bundleURL)
        committed = true
        return NetworkBootstrapResult(
            manifest: manifest,
            bundleURL: bundleURL,
            credential: credential,
            authorityPrivateKeyRepresentation: authority.privateKeyRepresentation,
            certificateAuthorityPrivateKeyPEM: certificateAuthorityPrivateKeyPEM
        )
    }

    public static func loadManifest(from bundleURL: URL) throws -> NetworkBootstrapManifest {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent(manifestFilename))
        return try makeDecoder().decode(NetworkBootstrapManifest.self, from: data)
    }

    public static func loadCertificateAuthorityDER(from bundleURL: URL) throws -> Data {
        let url = bundleURL.appendingPathComponent(certificateAuthorityCertificateFilename)
        let text = try String(contentsOf: url, encoding: .utf8)
        let base64 = text
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .filter { !$0.isWhitespace }
        guard let certificate = Data(base64Encoded: base64), !certificate.isEmpty else {
            throw NetworkBootstrapError.invalidTLSConfiguration
        }
        return certificate
    }

    private static func writePrivateKey(_ key: Data, to url: URL) throws {
        try key.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func writeManifest(_ manifest: NetworkBootstrapManifest, to url: URL) throws {
        try makeEncoder().encode(manifest).write(to: url, options: .atomic)
    }

    private static func validate(_ configuration: NetworkBootstrapTLSConfiguration) throws {
        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !configuration.serverHostname.isEmpty,
              configuration.serverHostname.unicodeScalars.allSatisfy(permitted.contains),
              !configuration.serverHostname.hasPrefix("."),
              !configuration.serverHostname.hasSuffix("."),
              !configuration.pkcs12Password.isEmpty,
              (1...825).contains(configuration.validityDays) else {
            throw NetworkBootstrapError.invalidTLSConfiguration
        }
    }

    private static func packageAuthorityTLS(
        in directory: URL,
        configuration: NetworkBootstrapTLSConfiguration,
        persistPrivateKey: Bool
    ) throws -> Data {
#if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: configuration.openSSLExecutableURL.path) else {
            throw NetworkBootstrapError.openSSLUnavailable
        }
        let caKey = directory.appendingPathComponent(certificateAuthorityPrivateKeyFilename)
        let caCertificate = directory.appendingPathComponent(certificateAuthorityCertificateFilename)
        let serverKey = directory.appendingPathComponent("authority-server-private-key.pem")
        let serverRequest = directory.appendingPathComponent("authority-server.csr")
        let serverCertificate = directory.appendingPathComponent("authority-server-certificate.pem")
        let serverExtensions = directory.appendingPathComponent("authority-server-extensions.cnf")
        let serverIdentity = directory.appendingPathComponent(authorityServerIdentityFilename)
        let hostname = configuration.serverHostname
        try Data("subjectAltName=DNS:\(hostname)\nextendedKeyUsage=serverAuth\n".utf8)
            .write(to: serverExtensions, options: .atomic)

        try runOpenSSL(configuration, arguments: [
            "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-pkeyopt", "ec_param_enc:named_curve",
            "-nodes", "-sha256", "-days", String(configuration.validityDays),
            "-subj", "/CN=BeakrNet Authority CA", "-keyout", caKey.path,
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            "-addext", "subjectKeyIdentifier=hash",
            "-out", caCertificate.path
        ], in: directory)
        try runOpenSSL(configuration, arguments: [
            "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=\(hostname)",
            "-addext", "subjectAltName=DNS:\(hostname)", "-keyout", serverKey.path,
            "-out", serverRequest.path
        ], in: directory)
        try runOpenSSL(configuration, arguments: [
            "x509", "-req", "-in", serverRequest.path, "-CA", caCertificate.path,
            "-CAkey", caKey.path, "-set_serial", randomCertificateSerial(),
            "-days", String(configuration.validityDays), "-sha256", "-extfile",
            serverExtensions.path, "-out", serverCertificate.path
        ], in: directory)
        try runOpenSSL(configuration, arguments: [
            "pkcs12", "-export", "-keypbe", "PBE-SHA1-3DES", "-certpbe",
            "PBE-SHA1-3DES", "-macalg", "sha1", "-inkey", serverKey.path,
            "-in", serverCertificate.path, "-certfile", caCertificate.path,
            "-passout", "env:BEAKRNET_BOOTSTRAP_TLS_PASSWORD", "-out", serverIdentity.path
        ], in: directory)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKey.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: serverKey.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: serverIdentity.path)
        let certificateAuthorityPrivateKeyPEM = try Data(contentsOf: caKey)
        if !persistPrivateKey {
            try FileManager.default.removeItem(at: caKey)
        }
        try? FileManager.default.removeItem(at: serverRequest)
        try? FileManager.default.removeItem(at: serverExtensions)
        return certificateAuthorityPrivateKeyPEM
#else
        throw NetworkBootstrapError.tlsPackagingRequiresMacOS
#endif
    }

#if os(macOS)
    private static func runOpenSSL(
        _ configuration: NetworkBootstrapTLSConfiguration,
        arguments: [String],
        in directory: URL
    ) throws {
        let errorsURL = directory.appendingPathComponent(".openssl-errors-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errorsURL.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorsURL)
        defer {
            try? errors.close()
            try? FileManager.default.removeItem(at: errorsURL)
        }
        let process = Process()
        process.executableURL = configuration.openSSLExecutableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.environment = ProcessInfo.processInfo.environment.merging([
            "BEAKRNET_BOOTSTRAP_TLS_PASSWORD": configuration.pkcs12Password
        ]) { _, new in new }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try errors.synchronize()
            let data = try Data(contentsOf: errorsURL).prefix(16_384)
            throw NetworkBootstrapError.openSSLFailed(
                status: process.terminationStatus,
                reason: String(decoding: data, as: UTF8.self)
            )
        }
    }

    private static func randomCertificateSerial() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }
#endif

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
