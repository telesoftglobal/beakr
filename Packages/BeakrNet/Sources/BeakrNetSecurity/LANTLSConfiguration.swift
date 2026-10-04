import Foundation
import Network
import Security

public enum LANTLSRole: Sendable {
    case initiator
    case acceptor
}

public enum LANTLSConfigurationError: Error, Equatable, Sendable {
    case identityConversionFailed
    case invalidPKCS12
    case identityMissing
    case certificateMissing
}

public enum LANTLSTrustPolicy: @unchecked Sendable {
    case developmentSelfSigned
    case production(authorityCertificates: [SecCertificate])
}

public enum LANTLSConfiguration {
    public static func parameters(
        localIdentity: SecIdentity,
        role: LANTLSRole,
        trustPolicy: LANTLSTrustPolicy,
        verificationQueue: DispatchQueue = DispatchQueue(label: "BeakrNet.LANTLSVerification")
    ) throws -> NWParameters {
        guard let protocolIdentity = sec_identity_create(localIdentity) else {
            throw LANTLSConfigurationError.identityConversionFailed
        }

        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_local_identity(options, protocolIdentity)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            complete(evaluate(secTrust, peerRole: role.peerRole, policy: trustPolicy))
        }, verificationQueue)

        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    private static func evaluate(
        _ trust: SecTrust,
        peerRole: LANTLSRole,
        policy: LANTLSTrustPolicy
    ) -> Bool {
        let peerIsServer = peerRole == .acceptor
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(peerIsServer, nil)) == errSecSuccess else {
            return false
        }

        switch policy {
        case .developmentSelfSigned:
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first,
                  SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
                return false
            }
        case .production(let authorityCertificates):
            guard !authorityCertificates.isEmpty,
                  SecTrustSetAnchorCertificates(
                    trust,
                    authorityCertificates as CFArray
                  ) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
                return false
            }
        }

        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}

public enum LANTLSIdentityLoader {
    public static func importPKCS12(
        _ data: Data,
        password: String
    ) throws -> (identity: SecIdentity, certificate: SecCertificate) {
        var imported: CFArray?
        let status = SecPKCS12Import(
            data as CFData,
            [kSecImportExportPassphrase as String: password] as CFDictionary,
            &imported
        )
        guard status == errSecSuccess, let items = imported as? [[String: Any]] else {
            throw LANTLSConfigurationError.invalidPKCS12
        }
        guard let value = items.first?[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
            throw LANTLSConfigurationError.identityMissing
        }
        let identity = unsafeDowncast(value as AnyObject, to: SecIdentity.self)
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else {
            throw LANTLSConfigurationError.certificateMissing
        }
        return (identity, certificate)
    }
}

private extension LANTLSRole {
    var peerRole: LANTLSRole {
        switch self {
        case .initiator: .acceptor
        case .acceptor: .initiator
        }
    }
}
