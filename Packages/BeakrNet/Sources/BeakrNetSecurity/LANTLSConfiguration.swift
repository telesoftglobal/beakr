import CryptoKit
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
    case pkcs12ImportFailed(status: Int32)
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
        verificationQueue: DispatchQueue = DispatchQueue(label: "BeakrNet.LANTLSVerification"),
        diagnosticSink: @escaping @Sendable (String) -> Void = { _ in },
        verificationResult: @escaping @Sendable (Bool) -> Void = { _ in }
    ) throws -> NWParameters {
        guard let protocolIdentity = sec_identity_create(localIdentity) else {
            throw LANTLSConfigurationError.identityConversionFailed
        }

        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        // LAN peers authenticate every connection with pinned profile credentials.
        // Disable persistent TLS resumption state to keep discovery reconnects independent
        // from Security.framework's shared session cache.
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_local_identity(options, protocolIdentity)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let verificationID = UUID()
            let trusted = evaluate(secTrust, peerRole: role.peerRole, policy: trustPolicy) { reason in
                diagnosticSink("tls-certificate-verification-failed verification=\(verificationID) localRole=\(role) peerRole=\(role.peerRole) \(reason)")
            }
            if !trusted {
                let chain = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate]) ?? []
                for (index, certificate) in chain.enumerated() {
                    diagnosticSink("tls-certificate-chain verification=\(verificationID) source=evaluated-chain index=\(index) sha256=\(fingerprint(certificate))")
                }
                if case .production(let anchors) = trustPolicy {
                    for (index, certificate) in anchors.enumerated() {
                        diagnosticSink("tls-certificate-chain verification=\(verificationID) source=configured-anchor index=\(index) sha256=\(fingerprint(certificate))")
                    }
                }
                var localCertificate: SecCertificate?
                if SecIdentityCopyCertificate(localIdentity, &localCertificate) == errSecSuccess,
                   let localCertificate {
                    diagnosticSink("tls-certificate-chain verification=\(verificationID) source=local-leaf sha256=\(fingerprint(localCertificate))")
                }
            }
            verificationResult(trusted)
            complete(trusted)
        }, verificationQueue)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 2
        return NWParameters(tls: tls, tcp: tcp)
    }

    private static func fingerprint(_ certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func evaluate(
        _ trust: SecTrust,
        peerRole: LANTLSRole,
        policy: LANTLSTrustPolicy,
        diagnosticSink: (String) -> Void
    ) -> Bool {
        func check(_ status: OSStatus, stage: String) -> Bool {
            guard status == errSecSuccess else {
                let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Security error"
                diagnosticSink("stage=\(stage) domain=NSOSStatusErrorDomain code=\(status) reason=\(reason)")
                return false
            }
            return true
        }

        let peerIsServer = peerRole == .acceptor
        guard check(SecTrustSetPolicies(trust, SecPolicyCreateSSL(peerIsServer, nil)), stage: "set-policy") else {
            return false
        }

        switch policy {
        case .developmentSelfSigned:
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                diagnosticSink("stage=configure-anchors reason=missing-peer-certificate")
                return false
            }
            guard check(SecTrustSetAnchorCertificates(trust, [leaf] as CFArray), stage: "set-development-anchor"),
                  check(SecTrustSetAnchorCertificatesOnly(trust, true), stage: "restrict-anchors") else {
                return false
            }
        case .production(let authorityCertificates):
            guard !authorityCertificates.isEmpty else {
                diagnosticSink("stage=configure-anchors reason=missing-authority-certificates")
                return false
            }
            guard check(SecTrustSetAnchorCertificates(trust, authorityCertificates as CFArray), stage: "set-authority-anchors"),
                  check(SecTrustSetAnchorCertificatesOnly(trust, true), stage: "restrict-anchors") else {
                return false
            }
        }

        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        if !trusted {
            // Preserve Security's explanation, including certificate-chain failures,
            // without serializing certificates, keys or the full userInfo dictionary.
            if let error {
                let nsError = error as Error as NSError
                diagnosticSink("stage=evaluate domain=\(nsError.domain) code=\(nsError.code) reason=\(nsError.localizedDescription)")
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    diagnosticSink("stage=evaluate-underlying domain=\(underlying.domain) code=\(underlying.code) reason=\(underlying.localizedDescription)")
                }
            } else {
                diagnosticSink("stage=evaluate reason=trust-rejected-without-error")
            }
        }
        return trusted
    }

}

public enum LANTLSIdentityLoader {
    public static func importPKCS12(
        _ data: Data,
        password: String,
        memoryOnly: Bool = false
    ) throws -> (identity: SecIdentity, certificate: SecCertificate) {
        var imported: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
#if os(macOS)
        if memoryOnly { options[kSecImportToMemoryOnly as String] = true }
#endif
        let status = SecPKCS12Import(
            data as CFData,
            options as CFDictionary,
            &imported
        )
        guard status == errSecSuccess else {
            if status == errSecDecode { throw LANTLSConfigurationError.invalidPKCS12 }
            throw LANTLSConfigurationError.pkcs12ImportFailed(status: status)
        }
        guard let items = imported as? [[String: Any]] else {
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
