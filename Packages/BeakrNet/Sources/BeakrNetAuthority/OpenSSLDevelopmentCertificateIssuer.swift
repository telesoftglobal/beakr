#if os(macOS)
import Foundation
import BeakrNetCore
import OSLog

public struct OpenSSLDevelopmentCertificateIssuer: CertificateMaterialIssuing {
    private static let logger = Logger(
        subsystem: "net.beakr.BeakrNetAuthority",
        category: "CertificateIssuer"
    )

    public let executableURL: URL
    public let authorityCertificateURL: URL
    public let authorityPrivateKeyURL: URL

    public init(
        executableURL: URL,
        authorityCertificateURL: URL,
        authorityPrivateKeyURL: URL
    ) {
        self.executableURL = executableURL
        self.authorityCertificateURL = authorityCertificateURL
        self.authorityPrivateKeyURL = authorityPrivateKeyURL
    }

    public func issueCertificate(
        nodeID: NodeID,
        nodePublicKey: Data,
        certificateSigningRequestDER: Data,
        validity: TimeInterval,
        now: Date
    ) async throws -> IssuedCertificateMaterial {
        guard nodePublicKey.count == 65, nodePublicKey.first == 0x04 else {
            throw OpenSSLDevelopmentCertificateIssuerError.invalidP256PublicKey
        }
        guard validity > 0,
              validity <= CertificateEnrollmentValidator.maximumCertificateValidity else {
            throw OpenSSLDevelopmentCertificateIssuerError.invalidValidity
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw OpenSSLDevelopmentCertificateIssuerError.executableUnavailable
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakrnet-certificate-issuance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let publicKeyURL = directory.appendingPathComponent("node-public.pem")
        let requestURL = directory.appendingPathComponent("node-request.pem")
        let requestPublicKeyURL = directory.appendingPathComponent("request-public.pem")
        let extensionsURL = directory.appendingPathComponent("extensions.cnf")
        let certificatePEMURL = directory.appendingPathComponent("leaf.pem")
        let certificateDERURL = directory.appendingPathComponent("leaf.der")
        try Self.publicKeyPEM(nodePublicKey).write(to: publicKeyURL, options: .atomic)
        try Self.certificateRequestPEM(certificateSigningRequestDER)
            .write(to: requestURL, options: .atomic)
        try Self.extensions.write(to: extensionsURL, atomically: true, encoding: .utf8)

        try run([
            "req", "-in", requestURL.path,
            "-verify", "-noout"
        ])
        try run([
            "req", "-in", requestURL.path,
            "-pubkey", "-noout", "-out", requestPublicKeyURL.path
        ])
        guard try Self.normalizedPEM(at: requestPublicKeyURL)
                == Self.normalizedPEM(at: publicKeyURL) else {
            throw OpenSSLDevelopmentCertificateIssuerError.certificateRequestKeyMismatch
        }

        let validityDays = max(1, Int(ceil(validity / 86_400)))
        let serial = Self.randomSerial()
        try run([
            "x509", "-req",
            "-in", requestURL.path,
            "-CA", authorityCertificateURL.path,
            "-CAkey", authorityPrivateKeyURL.path,
            "-set_serial", serial,
            "-days", String(validityDays),
            "-sha256",
            "-extfile", extensionsURL.path,
            "-out", certificatePEMURL.path
        ])
        try run([
            "x509",
            "-in", certificatePEMURL.path,
            "-outform", "DER",
            "-out", certificateDERURL.path
        ])

        return IssuedCertificateMaterial(
            leafCertificateDER: try Data(contentsOf: certificateDERURL),
            certificateChainDER: [try Self.certificateDER(fromPEM: authorityCertificateURL)]
        )
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "unknown OpenSSL error"
            let reason = "\(executableURL.path) \(arguments.joined(separator: " ")): \(output)"
            Self.logger.error("Certificate issuance failed: \(reason, privacy: .public)")
            throw OpenSSLDevelopmentCertificateIssuerError.commandFailed(reason: reason)
        }
    }

    private static func publicKeyPEM(_ x963: Data) -> Data {
        let subjectPublicKeyInfoPrefix = Data([
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
            0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
            0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
            0x42, 0x00
        ])
        let encoded = (subjectPublicKeyInfoPrefix + x963).base64EncodedString(
            options: [.lineLength64Characters, .endLineWithLineFeed]
        )
        return Data(
            "-----BEGIN PUBLIC KEY-----\n\(encoded)\n-----END PUBLIC KEY-----\n".utf8
        )
    }

    private static func certificateRequestPEM(_ der: Data) -> Data {
        let encoded = der.base64EncodedString(
            options: [.lineLength64Characters, .endLineWithLineFeed]
        )
        return Data(
            "-----BEGIN CERTIFICATE REQUEST-----\n\(encoded)\n-----END CERTIFICATE REQUEST-----\n".utf8
        )
    }

    private static func certificateDER(fromPEM url: URL) throws -> Data {
        let text = try String(contentsOf: url, encoding: .utf8)
        let base64 = text
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: base64) else {
            throw OpenSSLDevelopmentCertificateIssuerError.invalidAuthorityCertificate
        }
        return data
    }

    private static func normalizedPEM(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8).filter { !$0.isWhitespace }
    }

    private static func randomSerial() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static let extensions = """
    basicConstraints = critical,CA:FALSE
    keyUsage = critical,digitalSignature
    extendedKeyUsage = critical,clientAuth,serverAuth
    subjectAltName = DNS:localhost
    subjectKeyIdentifier = hash
    authorityKeyIdentifier = keyid,issuer
    """
}

public enum OpenSSLDevelopmentCertificateIssuerError: Error, Equatable, Sendable {
    case executableUnavailable
    case invalidP256PublicKey
    case invalidValidity
    case invalidAuthorityCertificate
    case certificateRequestKeyMismatch
    case commandFailed(reason: String)
}
#endif
