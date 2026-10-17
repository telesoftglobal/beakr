import Foundation
import Security
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetHost
import BeakrNetSecurity

nonisolated protocol ApplicationAuthorityRunning: Sendable {
    func stop() async
    func createInvitation(validity: TimeInterval) async throws -> NetworkInvitation
    func renameNetwork(to displayName: String) async throws
}

extension ApplicationAuthorityRunning {
    func renameNetwork(to displayName: String) async throws {}
}

#if os(macOS)
extension EmbeddedAuthorityNode: ApplicationAuthorityRunning {}
#endif

struct CreatedAuthoritativeNetwork: Sendable {
    let profile: NetworkProfile
    let configuration: DevelopmentAuthorityConfiguration
    let authority: any ApplicationAuthorityRunning
}

nonisolated protocol AuthoritativeNetworkCreating: Sendable {
    func create(displayName: String, hostname: String, port: UInt16) async throws
        -> CreatedAuthoritativeNetwork
    func restore(profile: NetworkProfile) async throws -> (any ApplicationAuthorityRunning)?
    func owns(profile: NetworkProfile) async throws -> Bool
    func authorityCertificateDER(profile: NetworkProfile) async throws -> Data
    func rename(profile: NetworkProfile, to displayName: String) async throws
    func delete(profile: NetworkProfile) async throws
}

actor SystemAuthoritativeNetworkCreator: AuthoritativeNetworkCreating {
    func create(displayName: String, hostname: String, port: UInt16) async throws
        -> CreatedAuthoritativeNetwork {
#if os(macOS)
        let profileID = NetworkProfileID()
        let namespace = ProfileKeychainNamespace(baseService: "net.beakr.app", profileID: profileID)
        let identityStore = KeychainNodeIdentityStore(namespace: namespace)
        let identity = try identityStore.loadOrCreate()
        let password = Self.randomPassword()
        let bundleURL = try authorityBundleURL(profileID: profileID)
        let openSSL = try openSSLExecutableURL()
        let controlPlaneURL = try controlPlaneURL(hostname: hostname, port: port)
        var bundleCreated = false
        let secretStore = AuthoritySecretStore(profileID: profileID)
        do {
            let result = try await NetworkBootstrap.create(
                at: bundleURL,
                displayName: displayName,
                environment: "production",
                serviceScopes: ["lan", "admin"],
                credentialValidity: 365 * 24 * 60 * 60,
                controlPlaneURL: controlPlaneURL,
                tlsConfiguration: .init(
                    openSSLExecutableURL: openSSL,
                    serverHostname: hostname,
                    pkcs12Password: password,
                    validityDays: 365
                ),
                profileID: profileID,
                initialNodeIdentity: identity,
                persistInitialNodePrivateKey: false,
                persistAuthorityPrivateKey: false,
                persistCertificateAuthorityPrivateKey: false
            )
            bundleCreated = true
            try Data().write(to: authorityMigrationMarkerURL(bundleURL: bundleURL), options: .atomic)
            guard let caPrivateKey = result.certificateAuthorityPrivateKeyPEM else {
                throw AuthoritativeNetworkCreationError.invalidPersistedAuthority
            }
            try secretStore.save(Data(password.utf8), account: .tlsPassword)
            try secretStore.save(result.authorityPrivateKeyRepresentation, account: .authoritySigningKey)
            try secretStore.save(caPrivateKey, account: .certificateAuthorityKey)
            let authority = try EmbeddedAuthorityNode(
                bundleURL: bundleURL,
                openSSLExecutableURL: openSSL,
                port: port,
                listenOnLAN: true,
                authorityPrivateKeyRepresentation: result.authorityPrivateKeyRepresentation,
                certificateAuthorityPrivateKeyPEM: caPrivateKey
            )
            try await authority.start(pkcs12Password: password)
            let configuration = DevelopmentAuthorityConfiguration(
                controlPlaneURL: controlPlaneURL,
                networkID: result.manifest.profile.networkID,
                authorityPublicKey: try Data(
                    contentsOf: bundleURL.appendingPathComponent(
                        NetworkBootstrap.authorityPublicKeyFilename
                    )
                ),
                authorityCertificateDER: try NetworkBootstrap.loadCertificateAuthorityDER(
                    from: bundleURL
                ),
                credential: result.credential
            )
            return CreatedAuthoritativeNetwork(
                profile: result.manifest.profile,
                configuration: configuration,
                authority: authority
            )
        } catch {
            try? secretStore.deleteAll()
            if bundleCreated { try? FileManager.default.removeItem(at: bundleURL) }
            try? identityStore.delete()
            throw error
        }
#else
        throw AuthoritativeNetworkCreationError.requiresMacOS
#endif
    }

    func restore(profile: NetworkProfile) async throws -> (any ApplicationAuthorityRunning)? {
#if os(macOS)
        let bundleURL = try authorityBundleURL(profileID: profile.id)
        guard FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent(NetworkBootstrap.manifestFilename).path
        ) else { return nil }
        let secretStore = AuthoritySecretStore(profileID: profile.id)
        guard let passwordData = try secretStore.load(account: .tlsPassword),
              let password = String(data: passwordData, encoding: .utf8) else {
            throw AuthoritativeNetworkCreationError.missingAuthorityPassword
        }
        guard let authoritySigningKey = try secretStore.load(account: .authoritySigningKey),
              var certificateAuthorityKey = try secretStore.load(account: .certificateAuthorityKey) else {
            throw AuthoritativeNetworkCreationError.missingAuthorityPrivateKeys
        }
        let manifest = try NetworkBootstrap.loadManifest(from: bundleURL)
        guard manifest.profile == profile,
              let hostname = manifest.controlPlaneURL?.host,
              let port = manifest.controlPlaneURL?.port,
              let authorityPort = UInt16(exactly: port) else {
            throw AuthoritativeNetworkCreationError.invalidPersistedAuthority
        }
        if !FileManager.default.fileExists(atPath: authorityMigrationMarkerURL(bundleURL: bundleURL).path) {
            certificateAuthorityKey = try replaceLegacyTLSAuthority(
                bundleURL: bundleURL,
                hostname: hostname,
                password: password,
                openSSLExecutableURL: try openSSLExecutableURL()
            )
            try secretStore.save(certificateAuthorityKey, account: .certificateAuthorityKey)
            try Data().write(to: authorityMigrationMarkerURL(bundleURL: bundleURL), options: .atomic)
        }
        let authority = try EmbeddedAuthorityNode(
            bundleURL: bundleURL,
            openSSLExecutableURL: try openSSLExecutableURL(),
            port: authorityPort,
            listenOnLAN: true,
            authorityPrivateKeyRepresentation: authoritySigningKey,
            certificateAuthorityPrivateKeyPEM: certificateAuthorityKey
        )
        try await authority.start(pkcs12Password: password)
        return authority
#else
        return nil
#endif
    }

    func owns(profile: NetworkProfile) async throws -> Bool {
#if os(macOS)
        let bundleURL = try authorityBundleURL(profileID: profile.id)
        guard FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent(NetworkBootstrap.manifestFilename).path
        ) else { return false }
        let secretStore = AuthoritySecretStore(profileID: profile.id)
        guard try secretStore.hasAllSecrets() else { return false }
        return try NetworkBootstrap.loadManifest(from: bundleURL).profile == profile
#else
        return false
#endif
    }

    func rename(profile: NetworkProfile, to displayName: String) async throws {
#if os(macOS)
        guard try await owns(profile: profile) else {
            throw AuthoritativeNetworkCreationError.notNetworkCreator
        }
        try NetworkBootstrap.renameNetwork(
            at: authorityBundleURL(profileID: profile.id),
            to: displayName
        )
#else
        throw AuthoritativeNetworkCreationError.requiresMacOS
#endif
    }

    func delete(profile: NetworkProfile) async throws {
#if os(macOS)
        guard try await owns(profile: profile) else {
            throw AuthoritativeNetworkCreationError.notNetworkCreator
        }
        let bundleURL = try authorityBundleURL(profileID: profile.id)
        try AuthoritySecretStore(profileID: profile.id).deleteAll()
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            try FileManager.default.removeItem(at: bundleURL)
        }
#else
        throw AuthoritativeNetworkCreationError.requiresMacOS
#endif
    }

    func authorityCertificateDER(profile: NetworkProfile) async throws -> Data {
#if os(macOS)
        guard try await owns(profile: profile) else {
            throw AuthoritativeNetworkCreationError.notNetworkCreator
        }
        return try NetworkBootstrap.loadCertificateAuthorityDER(
            from: authorityBundleURL(profileID: profile.id)
        )
#else
        throw AuthoritativeNetworkCreationError.requiresMacOS
#endif
    }

#if os(macOS)
    private func authorityBundleURL(profileID: NetworkProfileID) throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Beakr", isDirectory: true)
        .appendingPathComponent("Authorities", isDirectory: true)
        .appendingPathComponent(profileID.rawValue.uuidString.lowercased(), isDirectory: true)
    }

    private func openSSLExecutableURL() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/openssl",
            "/usr/local/bin/openssl",
            "/usr/bin/openssl"
        ]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw AuthoritativeNetworkCreationError.openSSLUnavailable
        }
        return URL(fileURLWithPath: path)
    }

    private func controlPlaneURL(hostname: String, port: UInt16) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = hostname
        components.port = Int(port)
        guard let url = components.url else {
            throw AuthoritativeNetworkCreationError.invalidHostname
        }
        return url
    }

    private func replaceLegacyTLSAuthority(
        bundleURL: URL,
        hostname: String,
        password: String,
        openSSLExecutableURL: URL
    ) throws -> Data {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "beakrnet-ca-repair-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let privateKeyURL = temporaryDirectory.appendingPathComponent("ca-private-key.pem")
        let certificateURL = temporaryDirectory.appendingPathComponent("ca-certificate.pem")
        let serverKeyURL = temporaryDirectory.appendingPathComponent("authority-server-private-key.pem")
        let serverRequestURL = temporaryDirectory.appendingPathComponent("authority-server.csr")
        let serverCertificateURL = temporaryDirectory.appendingPathComponent("authority-server-certificate.pem")
        let serverExtensionsURL = temporaryDirectory.appendingPathComponent("authority-server-extensions.cnf")
        let serverIdentityURL = temporaryDirectory.appendingPathComponent("authority-server.p12")
        try Data("subjectAltName=DNS:\(hostname)\nextendedKeyUsage=serverAuth\n".utf8)
            .write(to: serverExtensionsURL, options: .atomic)

        try runOpenSSL(
            executableURL: openSSLExecutableURL,
            arguments: [
                "ecparam", "-name", "prime256v1", "-genkey", "-noout",
                "-out", privateKeyURL.path
            ],
            in: temporaryDirectory
        )
        try runOpenSSL(
            executableURL: openSSLExecutableURL,
            arguments: [
                "req", "-batch", "-new", "-x509", "-key", privateKeyURL.path,
                "-sha256", "-days", "825", "-subj", "/CN=BeakrNet Authority CA",
                "-addext", "basicConstraints=critical,CA:TRUE",
                "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                "-addext", "subjectKeyIdentifier=hash", "-out", certificateURL.path
            ],
            in: temporaryDirectory
        )
        try runOpenSSL(
            executableURL: openSSLExecutableURL,
            arguments: [
                "req", "-batch", "-newkey", "rsa:2048", "-nodes",
                "-subj", "/CN=\(hostname)", "-addext", "subjectAltName=DNS:\(hostname)",
                "-keyout", serverKeyURL.path, "-out", serverRequestURL.path
            ],
            in: temporaryDirectory
        )
        try runOpenSSL(
            executableURL: openSSLExecutableURL,
            arguments: [
                "x509", "-req", "-in", serverRequestURL.path, "-CA", certificateURL.path,
                "-CAkey", privateKeyURL.path, "-set_serial", "0x\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                "-days", "825", "-sha256", "-extfile", serverExtensionsURL.path,
                "-out", serverCertificateURL.path
            ],
            in: temporaryDirectory
        )
        try runOpenSSL(
            executableURL: openSSLExecutableURL,
            arguments: [
                "pkcs12", "-export", "-keypbe", "PBE-SHA1-3DES", "-certpbe",
                "PBE-SHA1-3DES", "-macalg", "sha1", "-inkey", serverKeyURL.path,
                "-in", serverCertificateURL.path, "-certfile", certificateURL.path,
                "-passout", "env:BEAKRNET_BOOTSTRAP_TLS_PASSWORD", "-out", serverIdentityURL.path
            ],
            in: temporaryDirectory,
            environment: ["BEAKRNET_BOOTSTRAP_TLS_PASSWORD": password]
        )
        try Data(contentsOf: certificateURL).write(
            to: bundleURL.appendingPathComponent(NetworkBootstrap.certificateAuthorityCertificateFilename),
            options: .atomic
        )
        try Data(contentsOf: serverIdentityURL).write(
            to: bundleURL.appendingPathComponent(NetworkBootstrap.authorityServerIdentityFilename),
            options: .atomic
        )
        return try Data(contentsOf: privateKeyURL)
    }

    private func authorityMigrationMarkerURL(bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("named-curve-ca-v1")
    }

    private func runOpenSSL(
        executableURL: URL,
        arguments: [String],
        in directory: URL,
        environment: [String: String] = [:]
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let errors = Pipe()
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reason = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(16_384),
                as: UTF8.self
            )
            throw AuthoritativeNetworkCreationError.certificateRepairFailed(
                reason.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func randomPassword() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            .base64EncodedString()
    }
#endif
}

enum AuthoritativeNetworkCreationError: Error, Equatable, Sendable {
    case requiresMacOS
    case openSSLUnavailable
    case invalidHostname
    case missingAuthorityPassword
    case missingAuthorityPrivateKeys
    case invalidPersistedAuthority
    case notNetworkCreator
    case certificateRepairFailed(String)
    case keychain(OSStatus)
}

#if os(macOS)
private struct AuthoritySecretStore {
    enum Account: String, CaseIterable {
        case tlsPassword = "tls-password"
        case authoritySigningKey = "authority-signing-key"
        case certificateAuthorityKey = "certificate-authority-key"
    }

    let profileID: NetworkProfileID

    func save(_ data: Data, account: Account) throws {
        try delete(account: account)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthoritativeNetworkCreationError.keychain(status)
        }
    }

    func load(account: Account) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data else {
            throw AuthoritativeNetworkCreationError.keychain(status)
        }
        return data
    }

    func deleteAll() throws {
        for account in Account.allCases {
            try delete(account: account)
        }
    }

    func hasAllSecrets() throws -> Bool {
        for account in Account.allCases where try load(account: account) == nil {
            return false
        }
        return true
    }

    private func delete(account: Account) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthoritativeNetworkCreationError.keychain(status)
        }
    }

    private func baseQuery(account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "net.beakr.app.authority",
            kSecAttrAccount as String:
                "\(profileID.rawValue.uuidString.lowercased()).\(account.rawValue)"
        ]
    }
}
#endif
