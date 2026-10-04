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

    public func install(
        leafCertificateDER: Data,
        certificateChainDER: [Data],
        nodeIdentity: NodeIdentity
    ) throws -> StoredLANTLSIdentity {
        let leaf = try certificate(from: leafCertificateDER)
        try validate(leaf: leaf, nodeIdentity: nodeIdentity)
        let chain = try certificateChainDER.map(certificate(from:))
        try ensurePrivateKey(nodeIdentity)

        let previousMaterial = try activeMaterial()
        try addCertificate(leaf, label: leafLabel)
        for (index, certificate) in chain.enumerated() {
            try addCertificate(certificate, label: "\(service).lan-tls.chain.\(index)")
        }

        let stored = try identity(matching: leafCertificateDER, chain: chain)
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

    private func ensurePrivateKey(_ nodeIdentity: NodeIdentity) throws {
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
            return
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
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addition as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainLANTLSIdentityStoreError.unexpectedStatus(status)
        }
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

    private func identity(matching leafDER: Data, chain: [SecCertificate]) throws -> StoredLANTLSIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw KeychainLANTLSIdentityStoreError.unexpectedStatus(status)
        }
        let identities: [SecIdentity]
        if let values = result as? [Any] {
            identities = values.compactMap { value in
                guard CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else { return nil }
                return unsafeDowncast(value as AnyObject, to: SecIdentity.self)
            }
        } else if let result, CFGetTypeID(result) == SecIdentityGetTypeID() {
            identities = [unsafeDowncast(result as AnyObject, to: SecIdentity.self)]
        } else {
            throw KeychainLANTLSIdentityStoreError.invalidStoredValue
        }

        for identity in identities {
            var leaf: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess, let leaf else { continue }
            if SecCertificateCopyData(leaf) as Data == leafDER {
                return StoredLANTLSIdentity(
                    identity: identity,
                    leafCertificate: leaf,
                    certificateChain: chain
                )
            }
        }
        throw KeychainLANTLSIdentityStoreError.identityUnavailable
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

public enum KeychainLANTLSIdentityStoreError: Error, Equatable, Sendable {
    case invalidCertificate
    case certificateKeyUnavailable
    case certificateKeyMismatch
    case invalidPrivateKey
    case privateKeyMismatch
    case identityUnavailable
    case invalidStoredValue
    case unexpectedStatus(OSStatus)
}
