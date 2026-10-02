import Foundation
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
    }
}
