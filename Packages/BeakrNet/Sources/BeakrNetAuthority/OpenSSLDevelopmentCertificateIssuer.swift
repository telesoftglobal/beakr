#if os(macOS)
import Foundation
import BeakrNetCore

public struct OpenSSLDevelopmentCertificateIssuer: CertificateMaterialIssuing {
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
        let extensionsURL = directory.appendingPathComponent("extensions.cnf")
        let certificatePEMURL = directory.appendingPathComponent("leaf.pem")
        let certificateDERURL = directory.appendingPathComponent("leaf.der")
        try Self.publicKeyPEM(nodePublicKey).write(to: publicKeyURL, options: .atomic)
        try Self.extensions.write(to: extensionsURL, atomically: true, encoding: .utf8)

        let validityDays = max(1, Int(ceil(validity / 86_400)))
        let serial = Self.randomSerial()
        try run([
            "x509", "-new",
            "-force_pubkey", publicKeyURL.path,
            "-subj", "/CN=BeakrNet Node \(nodeID.rawValue.uuidString.lowercased())",
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
            let reason = String(data: data, encoding: .utf8) ?? "unknown OpenSSL error"
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
    case commandFailed(reason: String)
}
#endif
