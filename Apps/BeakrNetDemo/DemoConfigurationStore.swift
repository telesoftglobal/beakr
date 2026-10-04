import Foundation
import Security

struct SavedPeer: Codable, Equatable, Identifiable {
    let nodeID: String
    var name: String

    var id: String { nodeID }
}

struct DemoConfiguration {
    let relayHost: String
    let relayPort: String
    let preSharedKeyBase64: String
    let credentialJSON: String
    let destinationNodeID: String
    let authorityPublicKeyBase64: String
    let controlPlaneURL: String
}

struct DemoConfigurationStore {
    private let defaults = UserDefaults.standard
    private let keychain = DemoConfigurationKeychain(service: "net.beakr.demo.relay-configuration")

    private enum Key {
        static let relayHost = "relayHost"
        static let relayPort = "relayPort"
        static let destinationNodeID = "destinationNodeID"
        static let preSharedKey = "preSharedKey"
        static let credential = "credential"
        static let savedPeers = "savedPeers"
        static let authorityPublicKey = "authorityPublicKey"
        static let controlPlaneURL = "controlPlaneURL"
    }

    func load() throws -> DemoConfiguration {
        DemoConfiguration(
            relayHost: defaults.string(forKey: Key.relayHost) ?? "127.0.0.1",
            relayPort: defaults.string(forKey: Key.relayPort) ?? "7878",
            preSharedKeyBase64: try keychain.load(account: Key.preSharedKey) ?? "",
            credentialJSON: try keychain.load(account: Key.credential) ?? "",
            destinationNodeID: defaults.string(forKey: Key.destinationNodeID) ?? "",
            authorityPublicKeyBase64: defaults.string(forKey: Key.authorityPublicKey) ?? "",
            controlPlaneURL: defaults.string(forKey: Key.controlPlaneURL) ?? ""
        )
    }

    func save(_ configuration: DemoConfiguration) throws {
        defaults.set(configuration.relayHost, forKey: Key.relayHost)
        defaults.set(configuration.relayPort, forKey: Key.relayPort)
        saveDestinationNodeID(configuration.destinationNodeID)
        try keychain.save(configuration.preSharedKeyBase64, account: Key.preSharedKey)
        try keychain.save(configuration.credentialJSON, account: Key.credential)
        defaults.set(configuration.authorityPublicKeyBase64, forKey: Key.authorityPublicKey)
        defaults.set(configuration.controlPlaneURL, forKey: Key.controlPlaneURL)
    }

    func saveDestinationNodeID(_ nodeID: String) {
        defaults.set(nodeID, forKey: Key.destinationNodeID)
    }

    func loadSavedPeers() -> [SavedPeer] {
        guard let data = defaults.data(forKey: Key.savedPeers),
              let peers = try? JSONDecoder().decode([SavedPeer].self, from: data) else {
            return []
        }
        return peers
    }

    func saveSavedPeers(_ peers: [SavedPeer]) throws {
        defaults.set(try JSONEncoder().encode(peers), forKey: Key.savedPeers)
    }

    func clear() throws {
        defaults.removeObject(forKey: Key.relayHost)
        defaults.removeObject(forKey: Key.relayPort)
        defaults.removeObject(forKey: Key.destinationNodeID)
        defaults.removeObject(forKey: Key.authorityPublicKey)
        defaults.removeObject(forKey: Key.controlPlaneURL)
        try keychain.delete(account: Key.preSharedKey)
        try keychain.delete(account: Key.credential)
    }
}

private struct DemoConfigurationKeychain {
    let service: String

    func load(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw DemoConfigurationStoreError.invalidStoredValue
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw DemoConfigurationStoreError.unexpectedKeychainStatus(status)
        }
    }

    func save(_ value: String, account: String) throws {
        let query = baseQuery(account: account)
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw DemoConfigurationStoreError.unexpectedKeychainStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw DemoConfigurationStoreError.unexpectedKeychainStatus(updateStatus)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DemoConfigurationStoreError.unexpectedKeychainStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum DemoConfigurationStoreError: Error {
    case invalidStoredValue
    case unexpectedKeychainStatus(OSStatus)
}
