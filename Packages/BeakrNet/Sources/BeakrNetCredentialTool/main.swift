import Foundation
import BeakrNetCore
import BeakrNetAuthority
import BeakrNetSecurity

@main
struct BeakrNetCredentialTool {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            return
        }

        switch command {
        case "create-network":
            guard (arguments.count == 6 || arguments.count == 7 || arguments.count == 10),
                  let validitySeconds = TimeInterval(arguments[5]),
                  validitySeconds > 0 else { printUsage(); return }
            let controlPlaneURL: URL?
            if arguments.count >= 7 {
                guard let parsedURL = URL(string: arguments[6]) else { printUsage(); return }
                controlPlaneURL = parsedURL
            } else {
                controlPlaneURL = nil
            }
            let tlsConfiguration: NetworkBootstrapTLSConfiguration?
            if arguments.count == 10 {
                guard let tlsPassword = ProcessInfo.processInfo.environment["BEAKRNET_AUTHORITY_TLS_PASSWORD"] else {
                    throw CredentialToolError.missingAuthorityTLSPassword
                }
                tlsConfiguration = .init(
                    openSSLExecutableURL: URL(fileURLWithPath: arguments[7]),
                    serverHostname: arguments[8],
                    pkcs12Password: tlsPassword,
                    validityDays: Int(arguments[9]) ?? 0
                )
            } else {
                tlsConfiguration = nil
            }
            let result = try await NetworkBootstrap.create(
                at: URL(fileURLWithPath: arguments[1], isDirectory: true),
                displayName: arguments[2],
                environment: arguments[3],
                serviceScopes: arguments[4].split(separator: ",").map(String.init),
                credentialValidity: validitySeconds,
                controlPlaneURL: controlPlaneURL,
                tlsConfiguration: tlsConfiguration
            )
            print("Created network \(result.manifest.profile.networkID.rawValue.uuidString)")
            print("Profile: \(result.manifest.profile.id.rawValue.uuidString)")
            print("Administrator node: \(result.manifest.profile.localNodeID.rawValue.uuidString)")
            print("Authority: \(result.manifest.authorityID.rawValue.uuidString)")
            print("Bundle: \(result.bundleURL.path)")

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
            guard arguments.count == 8,
                  let networkUUID = UUID(uuidString: arguments[4]),
                  let validitySeconds = TimeInterval(arguments[7]),
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
                networkID: NetworkID(rawValue: networkUUID),
                environment: arguments[5],
                validity: validitySeconds,
                serviceScopes: arguments[6].split(separator: ",").map(String.init)
            )
            try CredentialFiles.saveCredential(
                credential,
                to: URL(fileURLWithPath: arguments[3])
            )
            print("Issued credential for \(nodeIdentity.nodeID.rawValue.uuidString)")

        case "issue-public":
            guard arguments.count == 9,
                  let nodeUUID = UUID(uuidString: arguments[2]),
                  let publicKey = Data(base64Encoded: arguments[3]),
                  let networkUUID = UUID(uuidString: arguments[5]),
                  let validitySeconds = TimeInterval(arguments[8]),
                  validitySeconds > 0 else { printUsage(); return }
            let nodeID = NodeID(rawValue: nodeUUID)
            guard NodeIdentity.nodeID(forPublicKeyRepresentation: publicKey) == nodeID else {
                throw CredentialToolError.nodeIDDoesNotMatchPublicKey
            }
            let authority = try CredentialFiles.loadAuthority(
                privateKeyURL: URL(fileURLWithPath: arguments[1])
            )
            let credential = try authority.issue(
                nodeID: nodeID,
                nodePublicKey: publicKey,
                networkID: NetworkID(rawValue: networkUUID),
                environment: arguments[6],
                validity: validitySeconds,
                serviceScopes: arguments[7].split(separator: ",").map(String.init)
            )
            try CredentialFiles.saveCredential(
                credential,
                to: URL(fileURLWithPath: arguments[4])
            )
            print("Issued credential for \(nodeID.rawValue.uuidString)")

        case "inspect":
            guard arguments.count == 2 else { printUsage(); return }
            let credential = try CredentialFiles.loadCredential(
                from: URL(fileURLWithPath: arguments[1])
            )
            print("Credential: \(credential.claims.credentialID.uuidString)")
            print("Issuer: \(credential.claims.issuerID.rawValue.uuidString)")
            print("Network: \(credential.claims.networkID.rawValue.uuidString)")
            print("Node: \(credential.claims.nodeID.rawValue.uuidString)")
            print("Environment: \(credential.claims.environment)")
            print("Expires: \(credential.claims.expiresAtMilliseconds)")

        case "verify":
            guard arguments.count == 5,
                  let networkUUID = UUID(uuidString: arguments[3]) else { printUsage(); return }
            let credential = try CredentialFiles.loadCredential(
                from: URL(fileURLWithPath: arguments[1])
            )
            let authorityPublicKey = try Data(
                contentsOf: URL(fileURLWithPath: arguments[2])
            )
            try CredentialVerifier.verify(
                credential,
                trustedAuthorityPublicKey: authorityPublicKey,
                networkID: NetworkID(rawValue: networkUUID),
                environment: arguments[4]
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

        case "trust-approve":
            guard arguments.count == 6,
                  let networkUUID = UUID(uuidString: arguments[4]) else { printUsage(); return }
            let authority = try CredentialFiles.loadAuthority(
                privateKeyURL: URL(fileURLWithPath: arguments[1])
            )
            let credential = try CredentialFiles.loadCredential(
                from: URL(fileURLWithPath: arguments[2])
            )
            let coordinator = try await AuthorityTrustStateCoordinator.open(
                authority: authority,
                networkID: NetworkID(rawValue: networkUUID),
                environment: arguments[5],
                ledgerURL: URL(fileURLWithPath: arguments[3])
            )
            try await coordinator.approve(
                credential: credential,
                certificatePublicKey: credential.claims.nodePublicKey
            )
            let generation = await coordinator.membershipSnapshot().claims.generation
            print("Approved node \(credential.claims.nodeID.rawValue.uuidString) at generation \(generation)")

        case "trust-remove":
            guard arguments.count == 7,
                  let networkUUID = UUID(uuidString: arguments[3]),
                  let nodeUUID = UUID(uuidString: arguments[5]) else { printUsage(); return }
            let authority = try CredentialFiles.loadAuthority(
                privateKeyURL: URL(fileURLWithPath: arguments[1])
            )
            let coordinator = try await AuthorityTrustStateCoordinator.open(
                authority: authority,
                networkID: NetworkID(rawValue: networkUUID),
                environment: arguments[4],
                ledgerURL: URL(fileURLWithPath: arguments[2])
            )
            try await coordinator.removeAndRevoke(
                nodeID: NodeID(rawValue: nodeUUID),
                reason: arguments[6]
            )
            let generation = await coordinator.membershipSnapshot().claims.generation
            print("Removed and revoked node \(nodeUUID.uuidString) at generation \(generation)")

#if os(macOS)
        case "issue-lan-certificate":
            guard arguments.count == 10,
                  let nodeUUID = UUID(uuidString: arguments[4]),
                  let publicKey = Data(base64Encoded: arguments[5]),
                  let certificateSigningRequestDER = Data(base64Encoded: arguments[6]),
                  let validity = TimeInterval(arguments[9]),
                  validity > 0 else { printUsage(); return }
            let nodeID = NodeID(rawValue: nodeUUID)
            guard NodeIdentity.nodeID(forPublicKeyRepresentation: publicKey) == nodeID else {
                throw CredentialToolError.nodeIDDoesNotMatchPublicKey
            }
            let issuer = OpenSSLDevelopmentCertificateIssuer(
                executableURL: URL(fileURLWithPath: arguments[1]),
                authorityCertificateURL: URL(fileURLWithPath: arguments[2]),
                authorityPrivateKeyURL: URL(fileURLWithPath: arguments[3])
            )
            let material = try await issuer.issueCertificate(
                nodeID: nodeID,
                nodePublicKey: publicKey,
                certificateSigningRequestDER: certificateSigningRequestDER,
                validity: validity,
                now: Date()
            )
            try material.leafCertificateDER.write(
                to: URL(fileURLWithPath: arguments[7]),
                options: .atomic
            )
            guard let authorityDER = material.certificateChainDER.first else {
                throw CredentialToolError.missingCertificateChain
            }
            try authorityDER.write(
                to: URL(fileURLWithPath: arguments[8]),
                options: .atomic
            )
            print("Issued LAN certificate for \(nodeID.rawValue.uuidString)")
#endif

        default:
            printUsage()
        }
    }

    private static func printUsage() {
        print("Usage:")
        print("  BeakrNetCredentialTool create-network <output-directory> <display-name> <environment> <comma-scopes> <validity-seconds> [https-control-plane-url [openssl server-hostname tls-validity-days]]")
        print("    Set BEAKRNET_AUTHORITY_TLS_PASSWORD when generating authority TLS files.")
        print("  BeakrNetCredentialTool create-authority <private-key> <public-key>")
        print("  BeakrNetCredentialTool issue <authority-private-key> <node-key> <credential> <network-id> <environment> <comma-scopes> <validity-seconds>")
        print("  BeakrNetCredentialTool issue-public <authority-private-key> <node-id> <public-key-base64> <credential> <network-id> <environment> <comma-scopes> <validity-seconds>")
        print("  BeakrNetCredentialTool inspect <credential>")
        print("  BeakrNetCredentialTool verify <credential> <authority-public-key> <network-id> <environment>")
        print("  BeakrNetCredentialTool create-revocations <authority-private-key> <snapshot>")
        print("  BeakrNetCredentialTool revoke <authority-private-key> <credential> <snapshot> <reason>")
        print("  BeakrNetCredentialTool verify-revocations <snapshot> <authority-public-key>")
        print("  BeakrNetCredentialTool trust-approve <authority-private-key> <credential> <trust-ledger> <network-id> <environment>")
        print("  BeakrNetCredentialTool trust-remove <authority-private-key> <trust-ledger> <network-id> <environment> <node-id> <reason>")
#if os(macOS)
        print("  BeakrNetCredentialTool issue-lan-certificate <openssl> <ca-cert-pem> <ca-key-pem> <node-id> <public-key-base64> <csr-der-base64> <leaf-der> <chain-der> <validity-seconds>")
#endif
    }
}

enum CredentialToolError: Error {
    case nodeIDDoesNotMatchPublicKey
    case missingCertificateChain
    case missingAuthorityTLSPassword
}
