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

enum NodeBootstrapError: Error {
    case invalidURL
    case invalidAuthorityKey
    case invalidCredential
    case credentialIdentityMismatch
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

    init() {
        identityLoader = KeychainNodeIdentityLoader()
        configurationStore = DevelopmentAuthorityConfigurationStore()
    }

    init(identityLoader: any NodeIdentityLoading) {
        self.identityLoader = identityLoader
        configurationStore = DevelopmentAuthorityConfigurationStore()
    }

    init(identityLoader: any NodeIdentityLoading,
         configurationStore: any DevelopmentAuthorityConfigurationStoring) {
        self.identityLoader = identityLoader
        self.configurationStore = configurationStore
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
            state = .identityReady
            statusMessage = "Development authority configuration is verified. Certificate enrollment is next."
        } catch {
            state = .needsConfiguration
            statusMessage = "Configuration rejected. Verify the HTTPS URL, authority key, and node credential."
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
