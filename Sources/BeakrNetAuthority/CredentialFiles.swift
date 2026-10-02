import Foundation
import BeakrNetCore

public enum CredentialFiles {
    public static func saveAuthority(
        _ authority: CredentialAuthority,
        privateKeyURL: URL,
        publicKeyURL: URL
    ) throws {
        try createParentDirectory(for: privateKeyURL)
        try createParentDirectory(for: publicKeyURL)
        try authority.privateKeyRepresentation.write(to: privateKeyURL, options: .atomic)
        try authority.publicKeyRepresentation.write(to: publicKeyURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: privateKeyURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: publicKeyURL.path
        )
    }

    public static func loadAuthority(privateKeyURL: URL) throws -> CredentialAuthority {
        try CredentialAuthority(
            privateKeyRepresentation: Data(contentsOf: privateKeyURL)
        )
    }

    public static func saveCredential(_ credential: NodeCredential, to url: URL) throws {
        try createParentDirectory(for: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(credential).write(to: url, options: .atomic)
    }

    public static func loadCredential(from url: URL) throws -> NodeCredential {
        try JSONDecoder().decode(NodeCredential.self, from: Data(contentsOf: url))
    }

    private static func createParentDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
