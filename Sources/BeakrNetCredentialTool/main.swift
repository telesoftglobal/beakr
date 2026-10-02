import Foundation
import BeakrNetCore
import BeakrNetAuthority
import BeakrNetSecurity

@main
struct BeakrNetCredentialTool {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            return
        }

        switch command {
        case "create-authority":
            guard arguments.count == 3 else { printUsage(); return }
            let authority = CredentialAuthority()
            try CredentialFiles.saveAuthority(
                authority,
                privateKeyURL: URL(fileURLWithPath: arguments[1]),
                publicKeyURL: URL(fileURLWithPath: arguments[2])
            )
            print("Created authority \(authority.authorityID.rawValue.uuidString)")

        case "issue":
            guard arguments.count == 7,
                  let validitySeconds = TimeInterval(arguments[6]),
                  validitySeconds > 0 else { printUsage(); return }
            let authority = try CredentialFiles.loadAuthority(
                privateKeyURL: URL(fileURLWithPath: arguments[1])
            )
            let nodeIdentity = try FileNodeIdentityStore(
                fileURL: URL(fileURLWithPath: arguments[2])
            ).loadOrCreate()
            let credential = try authority.issue(
                nodeID: nodeIdentity.nodeID,
                nodePublicKey: nodeIdentity.publicKeyRepresentation,
                environment: arguments[4],
                validity: validitySeconds,
                serviceScopes: arguments[5].split(separator: ",").map(String.init)
            )
            try CredentialFiles.saveCredential(
                credential,
                to: URL(fileURLWithPath: arguments[3])
            )
            print("Issued credential for \(nodeIdentity.nodeID.rawValue.uuidString)")

        case "inspect":
            guard arguments.count == 2 else { printUsage(); return }
            let credential = try CredentialFiles.loadCredential(
                from: URL(fileURLWithPath: arguments[1])
            )
            print("Credential: \(credential.claims.credentialID.uuidString)")
            print("Issuer: \(credential.claims.issuerID.rawValue.uuidString)")
            print("Node: \(credential.claims.nodeID.rawValue.uuidString)")
            print("Environment: \(credential.claims.environment)")
            print("Expires: \(credential.claims.expiresAtMilliseconds)")

        case "verify":
            guard arguments.count == 4 else { printUsage(); return }
            let credential = try CredentialFiles.loadCredential(
                from: URL(fileURLWithPath: arguments[1])
            )
            let authorityPublicKey = try Data(
                contentsOf: URL(fileURLWithPath: arguments[2])
            )
            try CredentialVerifier.verify(
                credential,
                trustedAuthorityPublicKey: authorityPublicKey,
                environment: arguments[3]
            )
            print("Credential is valid")

        case "create-revocations":
            guard arguments.count == 3 else { printUsage(); return }
            let authority = try CredentialFiles.loadAuthority(
                privateKeyURL: URL(fileURLWithPath: arguments[1])
            )
            let snapshot = try authority.issueRevocationSnapshot(revocations: [])
            try CredentialFiles.saveRevocationSnapshot(
                snapshot,
                to: URL(fileURLWithPath: arguments[2])
            )
            print("Created empty revocation snapshot")

        case "revoke":
            guard arguments.count == 5 else { printUsage(); return }
            let authority = try CredentialFiles.loadAuthority(
                privateKeyURL: URL(fileURLWithPath: arguments[1])
            )
            let credential = try CredentialFiles.loadCredential(
                from: URL(fileURLWithPath: arguments[2])
            )
            let revokedAt = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
            let snapshot = try authority.issueRevocationSnapshot(
                revocations: [
                    CredentialRevocation(
                        credentialID: credential.claims.credentialID,
                        revokedAtMilliseconds: revokedAt,
                        reason: arguments[4]
                    )
                ]
            )
            try CredentialFiles.saveRevocationSnapshot(
                snapshot,
                to: URL(fileURLWithPath: arguments[3])
            )
            print("Revoked credential \(credential.claims.credentialID.uuidString)")

        case "verify-revocations":
            guard arguments.count == 3 else { printUsage(); return }
            let snapshot = try CredentialFiles.loadRevocationSnapshot(
                from: URL(fileURLWithPath: arguments[1])
            )
            let publicKey = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            let revoked = try RevocationVerifier.verify(
                snapshot,
                trustedAuthorityPublicKey: publicKey
            )
            print("Revocation snapshot is valid with \(revoked.count) entries")

        default:
            printUsage()
        }
    }

    private static func printUsage() {
        print("Usage:")
        print("  BeakrNetCredentialTool create-authority <private-key> <public-key>")
        print("  BeakrNetCredentialTool issue <authority-private-key> <node-key> <credential> <environment> <comma-scopes> <validity-seconds>")
        print("  BeakrNetCredentialTool inspect <credential>")
        print("  BeakrNetCredentialTool verify <credential> <authority-public-key> <environment>")
        print("  BeakrNetCredentialTool create-revocations <authority-private-key> <snapshot>")
        print("  BeakrNetCredentialTool revoke <authority-private-key> <credential> <snapshot> <reason>")
        print("  BeakrNetCredentialTool verify-revocations <snapshot> <authority-public-key>")
    }
}
