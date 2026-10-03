import Dispatch
import Foundation
import Network
import Security

public enum RelayTLSConfigurationError: Error, Equatable, Sendable {
    case preSharedKeyTooShort
    case preSharedKeyTooLarge
}

public enum RelayTLSConfiguration {
    public static let minimumPreSharedKeyLength = 32
    public static let maximumPreSharedKeyLength = 64

    private static let identity = Data("beakrnet-relay-development-v1".utf8)

    public static func parameters(preSharedKey: Data) throws -> NWParameters {
        try validate(preSharedKey: preSharedKey)

        let tlsOptions = NWProtocolTLS.Options()
        let securityOptions = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(securityOptions, .TLSv12)
        sec_protocol_options_set_peer_authentication_required(securityOptions, false)
        sec_protocol_options_append_tls_ciphersuite(
            securityOptions,
            tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!
        )

        let keyDispatchData = preSharedKey.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityDispatchData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            securityOptions,
            keyDispatchData as dispatch_data_t,
            identityDispatchData as dispatch_data_t
        )

        return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    }

    public static func loadPreSharedKey(from fileURL: URL) throws -> Data {
        let key = try Data(contentsOf: fileURL)
        try validate(preSharedKey: key)
        return key
    }

    public static func createPreSharedKey(at fileURL: URL) throws -> Data {
        var generator = SystemRandomNumberGenerator()
        let key = Data(
            (0..<minimumPreSharedKeyLength).map {
                _ in UInt8.random(in: .min ... .max, using: &generator)
            }
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try key.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        return key
    }

    public static func validate(preSharedKey: Data) throws {
        guard preSharedKey.count >= minimumPreSharedKeyLength else {
            throw RelayTLSConfigurationError.preSharedKeyTooShort
        }
        guard preSharedKey.count <= maximumPreSharedKeyLength else {
            throw RelayTLSConfigurationError.preSharedKeyTooLarge
        }
    }
}
