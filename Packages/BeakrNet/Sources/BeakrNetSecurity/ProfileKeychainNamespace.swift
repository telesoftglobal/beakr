import Foundation
import Security
import BeakrNetCore

public struct ProfileKeychainNamespace: Hashable, Sendable {
    public let baseService: String
    public let profileID: NetworkProfileID

    public init(baseService: String, profileID: NetworkProfileID) {
        precondition(!baseService.isEmpty)
        self.baseService = baseService
        self.profileID = profileID
    }

    public var service: String {
        "\(baseService).profile.\(profileID.rawValue.uuidString.lowercased())"
    }

    public var nodeSigningKeyAccount: String { "node-signing-key" }
    public var nodeCredentialAccount: String { "node-credential" }
}

public enum ProfileKeychainCredentialError: Error, Equatable, Sendable {
    case profileNetworkMismatch
    case profileNodeMismatch
    case invalidStoredValue
    case noncanonicalStoredValue
    case unexpectedStatus(OSStatus)
}

public struct KeychainNodeCredentialStore: Sendable {
    public let namespace: ProfileKeychainNamespace

    public init(namespace: ProfileKeychainNamespace) {
        self.namespace = namespace
    }

    public func save(_ credential: NodeCredential, for profile: NetworkProfile) throws {
        try Self.validate(credential, for: profile)
        let data = try Self.encoder().encode(credential)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ProfileKeychainCredentialError.unexpectedStatus(updateStatus)
        }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ProfileKeychainCredentialError.unexpectedStatus(addStatus)
        }
    }

    public func load(for profile: NetworkProfile) throws -> NodeCredential? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ProfileKeychainCredentialError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let credential = try? Self.decoder().decode(NodeCredential.self, from: data) else {
            throw ProfileKeychainCredentialError.invalidStoredValue
        }
        guard try Self.encoder().encode(credential) == data else {
            throw ProfileKeychainCredentialError.noncanonicalStoredValue
        }
        try Self.validate(credential, for: profile)
        return credential
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProfileKeychainCredentialError.unexpectedStatus(status)
        }
    }

    public static func validate(_ credential: NodeCredential, for profile: NetworkProfile) throws {
        guard credential.claims.networkID == profile.networkID else {
            throw ProfileKeychainCredentialError.profileNetworkMismatch
        }
        guard credential.claims.nodeID == profile.localNodeID else {
            throw ProfileKeychainCredentialError.profileNodeMismatch
        }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace.service,
            kSecAttrAccount as String: namespace.nodeCredentialAccount
        ]
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
