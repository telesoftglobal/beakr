import Foundation
import Network
import Security

public enum AuthorityServerTLSConfiguration {
    public static func parameters(localIdentity: SecIdentity) throws -> NWParameters {
        guard let protocolIdentity = sec_identity_create(localIdentity) else {
            throw LANTLSConfigurationError.identityConversionFailed
        }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        // Authority connections are short-lived and pinned. Avoid Security.framework's
        // persistent TLS session cache so a damaged/full cache cannot destabilize enrollment.
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_local_identity(options, protocolIdentity)
        sec_protocol_options_set_peer_authentication_required(options, false)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}
