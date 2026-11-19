import Foundation
import Security

public struct StoredLANTLSIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let leafCertificate: SecCertificate
    public let certificateChain: [SecCertificate]

    public init(
        identity: SecIdentity,
        leafCertificate: SecCertificate,
        certificateChain: [SecCertificate]
    ) {
        self.identity = identity
        self.leafCertificate = leafCertificate
        self.certificateChain = certificateChain
    }
}

public struct KeychainLANTLSIdentityStore: Sendable {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public init(namespace: ProfileKeychainNamespace) {
        service = namespace.service
    }

    public func install(
        leafCertificateDER: Data,
        certificateChainDER: [Data],
        nodeIdentity: NodeIdentity
    ) throws -> StoredLANTLSIdentity {
        let leaf = try certificate(from: leafCertificateDER)
        try validate(leaf: leaf, nodeIdentity: nodeIdentity)
        let chain = try certificateChainDER.map(certificate(from:))
        let privateKey = try ensurePrivateKey(nodeIdentity)

        let previousMaterial = try activeMaterial()
        try addCertificate(leaf, label: leafLabel)
        for (index, certificate) in chain.enumerated() {
            try addCertificate(certificate, label: "\(service).lan-tls.chain.\(index)")
        }

        let stored = try identity(
            matching: leafCertificateDER,
            chain: chain,
            privateKey: privateKey
        )
        do {
            try setActiveMaterial(ActiveMaterial(
                leafCertificateDER: leafCertificateDER,
                certificateChainDER: certificateChainDER
            ))
        } catch {
            if previousMaterial?.leafCertificateDER != leafCertificateDER {
                try? deleteCertificate(leafCertificateDER, label: leafLabel)
            }
            throw error
        }

        if let previousLeafDER = previousMaterial?.leafCertificateDER,
           previousLeafDER != leafCertificateDER {
            try? deleteCertificate(previousLeafDER, label: leafLabel)
            for (index, certificateDER) in (previousMaterial?.certificateChainDER ?? []).enumerated()
                where !certificateChainDER.contains(certificateDER) {
                try? deleteCertificate(certificateDER, label: chainLabel(index))
            }
        }
        return stored
    }

    public func load() throws -> StoredLANTLSIdentity? {
        guard let material = try activeMaterial() else { return nil }
        let chain = try material.certificateChainDER.map(certificate(from:))
        return try identity(matching: material.leafCertificateDER, chain: chain)
    }

    public func delete() throws {
        if let material = try activeMaterial() {
            try? deleteCertificate(material.leafCertificateDER, label: leafLabel)
            for (index, certificateDER) in material.certificateChainDER.enumerated() {
                try? deleteCertificate(certificateDER, label: chainLabel(index))
            }
        }
        for query in [activePointerQuery, privateKeyQuery] {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainLANTLSIdentityStoreError.unexpectedStatus(status)
            }
        }
    }

    private var keyTag: Data {
        Data("\(service).lan-tls.private-key".utf8)
    }

    private var leafLabel: String { "\(service).lan-tls.leaf" }

    private func chainLabel(_ index: Int) -> String {
        "\(service).lan-tls.chain.\(index)"
    }

    private var privateKeyQuery: [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
    }

    private var activePointerQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "lan-tls-active-certificate"
        ]
    }

    private func certificate(from data: Data) throws -> SecCertificate {
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw KeychainLANTLSIdentityStoreError.invalidCertificate
        }
        return certificate
    }

    private func validate(leaf: SecCertificate, nodeIdentity: NodeIdentity) throws {
        guard let key = SecCertificateCopyKey(leaf) else {
            throw KeychainLANTLSIdentityStoreError.certificateKeyUnavailable
        }
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(key, &error) as Data?,
              representation == nodeIdentity.publicKeyRepresentation else {
            throw KeychainLANTLSIdentityStoreError.certificateKeyMismatch
        }
    }

    private func ensurePrivateKey(_ nodeIdentity: NodeIdentity) throws -> SecKey {
        let representation = nodeIdentity.publicKeyRepresentation + nodeIdentity.privateKeyRepresentation
        var result: CFTypeRef?
        var query = privateKeyQuery
        query[kSecReturnRef as String] = true
        let existingStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if existingStatus == errSecSuccess {
            guard let key = result, CFGetTypeID(key) == SecKeyGetTypeID() else {
                throw KeychainLANTLSIdentityStoreError.invalidStoredValue
            }
            let secKey = unsafeDowncast(key as AnyObject, to: SecKey.self)
            var error: Unmanaged<CFError>?
            guard SecKeyCopyExternalRepresentation(secKey, &error) as Data? == representation else {
                throw KeychainLANTLSIdentityStoreError.privateKeyMismatch
            }
            return secKey
        }
        guard existingStatus == errSecItemNotFound else {
            throw KeychainLANTLSIdentityStoreError.unexpectedStatus(existingStatus)
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256
        ]
        var creationError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            representation as CFData,
            attributes as CFDictionary,
            &creationError
        ) else {
            throw KeychainLANTLSIdentityStoreError.invalidPrivateKey
        }
        var addition = privateKeyQuery
        addition[kSecValueRef as String] = key
        addition[kSecAttrLabel as String] = "\(service).lan-tls.private-key"
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addition as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainLANTLSIdentityStoreError.unexpectedStatus(status)
        }
        return key
    }

    private func addCertificate(_ certificate: SecCertificate, label: String) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw KeychainLANTLSIdentityStoreError.unexpectedStatus(status)
        }
    }

    private func identity(
        matching leafDER: Data,
        chain: [SecCertificate],
        privateKey suppliedPrivateKey: SecKey? = nil
    ) throws -> StoredLANTLSIdentity {
        let leaf = try certificate(from: leafDER)
#if os(macOS)
        var matchedIdentity: SecIdentity?
        let matchStatus = SecIdentityCreateWithCertificate(nil, leaf, &matchedIdentity)
        guard matchStatus == errSecSuccess, let matchedIdentity else {
            if matchStatus == errSecItemNotFound {
                throw KeychainLANTLSIdentityStoreError.identityUnavailable
            }
            throw KeychainLANTLSIdentityStoreError.unexpectedStatus(matchStatus)
        }
        return StoredLANTLSIdentity(
            identity: matchedIdentity,
            leafCertificate: leaf,
            certificateChain: chain
        )
#else
        let privateKey: SecKey
        if let suppliedPrivateKey {
            privateKey = suppliedPrivateKey
        } else {
            var query = privateKeyQuery
            query[kSecReturnRef as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else {
                if status == errSecItemNotFound {
                    throw KeychainLANTLSIdentityStoreError.identityUnavailable
                }
                throw KeychainLANTLSIdentityStoreError.unexpectedStatus(status)
            }
            guard let result, CFGetTypeID(result) == SecKeyGetTypeID() else {
                throw KeychainLANTLSIdentityStoreError.invalidStoredValue
            }
            privateKey = unsafeDowncast(result as AnyObject, to: SecKey.self)
        }

        guard let identity = SecIdentityCreate(nil, leaf, privateKey) else {
            throw KeychainLANTLSIdentityStoreError.identityUnavailable
        }
        return StoredLANTLSIdentity(
            identity: identity,
            leafCertificate: leaf,
            certificateChain: chain
        )
#endif
    }

    private func activeMaterial() throws -> ActiveMaterial? {
        var query = activePointerQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let material = try? JSONDecoder().decode(ActiveMaterial.self, from: data) else {
                throw KeychainLANTLSIdentityStoreError.invalidStoredValue
            }
            return material
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainLANTLSIdentityStoreError.unexpectedStatus(status)
        }
    }

    private func setActiveMaterial(_ material: ActiveMaterial) throws {
        let data = try JSONEncoder().encode(material)
        let updateStatus = SecItemUpdate(
            activePointerQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainLANTLSIdentityStoreError.unexpectedStatus(updateStatus)
        }
        var attributes = activePointerQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainLANTLSIdentityStoreError.unexpectedStatus(addStatus)
        }
    }

    private struct ActiveMaterial: Codable {
        let leafCertificateDER: Data
        let certificateChainDER: [Data]
    }

    private func deleteCertificate(_ data: Data, label: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueData as String: data,
            kSecAttrLabel as String: label
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainLANTLSIdentityStoreError.unexpectedStatus(status)
        }
    }
}

public enum KeychainLANTLSIdentityStoreError: Error, Equatable, Sendable, LocalizedError {
    case invalidCertificate
    case certificateKeyUnavailable
    case certificateKeyMismatch
    case invalidPrivateKey
    case privateKeyMismatch
    case identityUnavailable
    case invalidStoredValue
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidCertificate:
            "The issued certificate is not valid DER certificate data."
        case .certificateKeyUnavailable:
            "The issued certificate does not contain a usable public key."
        case .certificateKeyMismatch:
            "The issued certificate belongs to a different node key."
        case .invalidPrivateKey:
            "The node private key could not be imported into Keychain."
        case .privateKeyMismatch:
            "A different node private key already exists in Keychain."
        case .identityUnavailable:
            "Keychain could not associate the issued certificate with the node private key."
        case .invalidStoredValue:
            "Keychain returned an invalid stored identity value."
        case let .unexpectedStatus(status):
            "Keychain operation failed (OSStatus \(status)): \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Security error")."
        }
    }
}
