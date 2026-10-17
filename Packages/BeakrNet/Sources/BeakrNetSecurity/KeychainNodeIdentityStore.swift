import Foundation
import Security

public struct KeychainNodeIdentityStore: Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String = "node-signing-key") {
        self.service = service
        self.account = account
    }

    public init(namespace: ProfileKeychainNamespace) {
        service = namespace.service
        account = namespace.nodeSigningKeyAccount
    }

    public func loadOrCreate() throws -> NodeIdentity {
        if let privateKey = try loadPrivateKey() {
            return try NodeIdentity(privateKeyRepresentation: privateKey)
        }

        let identity = NodeIdentity()
        try save(privateKey: identity.privateKeyRepresentation)
        return identity
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainNodeIdentityStoreError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func loadPrivateKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainNodeIdentityStoreError.invalidStoredValue
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainNodeIdentityStoreError.unexpectedStatus(status)
        }
    }

    private func save(privateKey: Data) throws {
        var attributes = baseQuery
        attributes[kSecValueData as String] = privateKey
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainNodeIdentityStoreError.unexpectedStatus(status)
        }
    }
}

public enum KeychainNodeIdentityStoreError: Error, Equatable, Sendable {
    case invalidStoredValue
    case unexpectedStatus(OSStatus)
}
