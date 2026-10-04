import Foundation
import Observation
import Security
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetSecurity

enum NodeBootstrapState: Equatable {
    case starting
    case needsConfiguration
    case identityReady
    case enrolling
    case ready
    case failed
}

struct DevelopmentAuthorityConfiguration: Equatable, Sendable {
    let controlPlaneURL: URL
    let authorityPublicKey: Data
    let credential: NodeCredential
}

protocol NodeIdentityLoading: Sendable {
    func loadOrCreateNodeID() throws -> NodeID
}

protocol DevelopmentAuthorityConfigurationStoring: Sendable {
    func load() throws -> DevelopmentAuthorityConfiguration?
    func save(_ configuration: DevelopmentAuthorityConfiguration) throws
}

protocol NodeTrustBootstrapping: Sendable {
    func enrollAndRecover(using configuration: DevelopmentAuthorityConfiguration) async throws
}

struct KeychainNodeIdentityLoader: NodeIdentityLoading {
    private let store = KeychainNodeIdentityStore(service: "net.beakr.app")

    func loadOrCreateNodeID() throws -> NodeID {
        try store.loadOrCreate().nodeID
    }
}

struct DevelopmentAuthorityConfigurationStore: DevelopmentAuthorityConfigurationStoring {
    private let defaults = UserDefaults.standard
    private let service = "net.beakr.app.development-authority"
    private let credentialAccount = "node-credential"

    func load() throws -> DevelopmentAuthorityConfiguration? {
        guard let urlString = defaults.string(forKey: "developmentControlPlaneURL"),
              let controlPlaneURL = URL(string: urlString),
              let authorityKeyString = defaults.string(forKey: "developmentAuthorityPublicKey"),
              let authorityPublicKey = Data(base64Encoded: authorityKeyString),
              let credentialData = try loadCredentialData() else { return nil }
        return DevelopmentAuthorityConfiguration(
            controlPlaneURL: controlPlaneURL,
            authorityPublicKey: authorityPublicKey,
            credential: try JSONDecoder().decode(NodeCredential.self, from: credentialData)
        )
    }

    func save(_ configuration: DevelopmentAuthorityConfiguration) throws {
        let credentialData = try JSONEncoder().encode(configuration.credential)
        try saveCredentialData(credentialData)
        defaults.set(configuration.controlPlaneURL.absoluteString, forKey: "developmentControlPlaneURL")
        defaults.set(configuration.authorityPublicKey.base64EncodedString(), forKey: "developmentAuthorityPublicKey")
    }

    private func loadCredentialData() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case let status:
            throw NodeBootstrapError.keychain(status)
        }
    }

    private func saveCredentialData(_ data: Data) throws {
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw NodeBootstrapError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw NodeBootstrapError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialAccount
        ]
    }
}

struct DevelopmentNodeTrustBootstrapper: NodeTrustBootstrapping {
    func enrollAndRecover(using configuration: DevelopmentAuthorityConfiguration) async throws {
        let identity = try KeychainNodeIdentityStore(service: "net.beakr.app").loadOrCreate()
        guard identity.nodeID == configuration.credential.claims.nodeID,
              identity.publicKeyRepresentation == configuration.credential.claims.nodePublicKey else {
            throw NodeBootstrapError.credentialIdentityMismatch
        }

        let transport = try URLSessionCertificateEnrollmentTransport(
            baseURL: configuration.controlPlaneURL
        )
        let client = try CertificateEnrollmentNetworkClient(
            transport: transport,
            identity: identity,
            credential: configuration.credential,
            environment: configuration.credential.claims.environment,
            requestedValidity: CertificateEnrollmentValidator.maximumCertificateValidity
        )
        let exchange = try await client.renewCertificate()
        try CertificateEnrollmentResponseVerifier.verify(
            exchange.response,
            for: exchange.request,
            trustedAuthorityPublicKey: configuration.authorityPublicKey
        )
        try KeychainLANTLSIdentityStore(service: "net.beakr.app").install(
            response: exchange.response,
            nodeIdentity: identity
        )

        let distributor = RevocationSnapshotDistributor(
            trustedAuthorityPublicKey: configuration.authorityPublicKey
        )
        let controller = RevocationRefreshController(
            distributor: distributor,
            requester: try RevocationSnapshotNetworkClient(baseURL: configuration.controlPlaneURL),
            store: FileRevocationSnapshotStore(fileURL: try revocationSnapshotURL()),
            policy: try RevocationRefreshPolicy()
        )
        let restored = try await controller.restorePersistedSnapshot() != nil
        let outcome = await controller.refreshNow(trigger: .startup)
        switch outcome {
        case .activated:
            return
        case .unchanged where restored:
            return
        case .failed where restored:
            return
        case .unchanged, .failed:
            throw NodeBootstrapError.noTrustedRevocationState
        }
    }

    private func revocationSnapshotURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Beakr", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("RevocationSnapshot.json")
    }
}

enum NodeBootstrapError: Error {
    case invalidURL
    case invalidAuthorityKey
    case invalidCredential
    case credentialIdentityMismatch
    case noTrustedRevocationState
    case keychain(OSStatus)
}

@MainActor
@Observable
final class NodeBootstrapModel {
    var controlPlaneURL = ""
    var authorityPublicKeyBase64 = ""
    var credentialJSON = ""
    private(set) var state: NodeBootstrapState = .starting
    private(set) var nodeID: UUID?
    private(set) var statusMessage = "Restoring this device’s node identity."

    private let identityLoader: any NodeIdentityLoading
    private let configurationStore: any DevelopmentAuthorityConfigurationStoring
    private let trustBootstrapper: any NodeTrustBootstrapping
    private var activeConfiguration: DevelopmentAuthorityConfiguration?

    init() {
        identityLoader = KeychainNodeIdentityLoader()
        configurationStore = DevelopmentAuthorityConfigurationStore()
        trustBootstrapper = DevelopmentNodeTrustBootstrapper()
    }

    init(identityLoader: any NodeIdentityLoading) {
        self.identityLoader = identityLoader
        configurationStore = DevelopmentAuthorityConfigurationStore()
        trustBootstrapper = DevelopmentNodeTrustBootstrapper()
    }

    init(identityLoader: any NodeIdentityLoading,
         configurationStore: any DevelopmentAuthorityConfigurationStoring) {
        self.identityLoader = identityLoader
        self.configurationStore = configurationStore
        trustBootstrapper = DevelopmentNodeTrustBootstrapper()
    }

    init(identityLoader: any NodeIdentityLoading,
         configurationStore: any DevelopmentAuthorityConfigurationStoring,
         trustBootstrapper: any NodeTrustBootstrapping) {
        self.identityLoader = identityLoader
        self.configurationStore = configurationStore
        self.trustBootstrapper = trustBootstrapper
    }

    func start() async {
        state = .starting
        statusMessage = "Restoring this device’s node identity."
        do {
            let restoredNodeID = try identityLoader.loadOrCreateNodeID()
            nodeID = restoredNodeID.rawValue
            if let configuration = try configurationStore.load() {
                try validate(configuration, nodeID: restoredNodeID)
                controlPlaneURL = configuration.controlPlaneURL.absoluteString
                authorityPublicKeyBase64 = configuration.authorityPublicKey.base64EncodedString()
                activeConfiguration = configuration
                state = .identityReady
                statusMessage = "Development authority configuration is verified. Certificate enrollment is next."
            } else {
                state = .needsConfiguration
                statusMessage = "Identity is secure. Development authority configuration is required."
            }
        } catch {
            nodeID = nil
            state = .failed
            statusMessage = "Secure bootstrap could not be completed."
        }
    }

    func saveDevelopmentConfiguration() {
        guard let nodeID = nodeID.map(NodeID.init(rawValue:)) else {
            state = .failed
            statusMessage = "Restore the node identity before configuring an authority."
            return
        }
        do {
            let configuration = try configuration()
            try validate(configuration, nodeID: nodeID)
            try configurationStore.save(configuration)
            credentialJSON = ""
            activeConfiguration = configuration
            state = .identityReady
            statusMessage = "Development authority configuration is verified. Certificate enrollment is next."
        } catch {
            state = .needsConfiguration
            statusMessage = "Configuration rejected. Verify the HTTPS URL, authority key, and node credential."
        }
    }

    func enrollAndRecoverTrust() async {
        guard let activeConfiguration else {
            state = .needsConfiguration
            statusMessage = "Verify development authority configuration before enrollment."
            return
        }
        state = .enrolling
        statusMessage = "Enrolling certificate and recovering revocation state."
        do {
            try await trustBootstrapper.enrollAndRecover(using: activeConfiguration)
            state = .ready
            statusMessage = "Identity, certificate, and revocation state are ready."
        } catch {
            state = .identityReady
            statusMessage = "Enrollment or revocation recovery failed. Routes remain disabled."
        }
    }

    private func configuration() throws -> DevelopmentAuthorityConfiguration {
        guard let url = URL(string: controlPlaneURL),
              url.scheme?.lowercased() == "https",
              url.host != nil else { throw NodeBootstrapError.invalidURL }
        guard let authorityKey = Data(base64Encoded: authorityPublicKeyBase64),
              !authorityKey.isEmpty else { throw NodeBootstrapError.invalidAuthorityKey }
        guard let credentialData = credentialJSON.data(using: .utf8),
              let credential = try? JSONDecoder().decode(NodeCredential.self, from: credentialData) else {
            throw NodeBootstrapError.invalidCredential
        }
        return DevelopmentAuthorityConfiguration(
            controlPlaneURL: url,
            authorityPublicKey: authorityKey,
            credential: credential
        )
    }

    private func validate(_ configuration: DevelopmentAuthorityConfiguration, nodeID: NodeID) throws {
        guard configuration.credential.claims.nodeID == nodeID else {
            throw NodeBootstrapError.credentialIdentityMismatch
        }
        try CredentialVerifier.verify(
            configuration.credential,
            trustedAuthorityPublicKey: configuration.authorityPublicKey,
            environment: configuration.credential.claims.environment
        )
    }
}
