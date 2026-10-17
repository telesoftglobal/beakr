import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetHost
import BeakrNetSecurity

@Suite("Authenticated profile membership directory")
struct ProfileMembershipDirectoryTests {
    @Test("Signed membership persists, resolves stable sessions, and obeys revocation")
    func persistenceResolutionAndRevocation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakr-membership-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("membership.json")
        let now = Date(timeIntervalSince1970: 1_000)
        let networkID = NetworkID()
        let authority = CredentialAuthority()
        let node = NodeIdentity()
        let credential = try authority.issue(
            nodeID: node.nodeID,
            nodePublicKey: node.publicKeyRepresentation,
            networkID: networkID,
            environment: "test",
            validity: 3_600,
            serviceScopes: ["lan"],
            now: now
        )
        let sessionID = SessionID()
        let claims = ProfileMembershipClaims(
            networkID: networkID,
            generation: 1,
            generatedAtMilliseconds: 1_000_000,
            records: [ProfileMembershipRecord(
                credential: credential,
                certificatePublicKey: node.publicKeyRepresentation,
                sessionID: sessionID
            )]
        )
        let signer = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        )
        let snapshot = try signer.sign(claims)
        let directory = try await ProfileMembershipDirectory.open(
            fileURL: fileURL,
            networkID: networkID,
            environment: "test",
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            revokedCredentialIDs: [],
            now: { now }
        )
        try await directory.activate(snapshot)
        let resolved = await directory.resolve(certificatePublicKey: node.publicKeyRepresentation)
        #expect(resolved?.expectedPeerNodeID == node.nodeID)
        #expect(resolved?.sessionID == sessionID)

        let reopened = try await ProfileMembershipDirectory.open(
            fileURL: fileURL,
            networkID: networkID,
            environment: "test",
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            revokedCredentialIDs: [],
            now: { now }
        )
        #expect(await reopened.generation() == 1)
        #expect(await reopened.resolve(certificatePublicKey: node.publicKeyRepresentation) != nil)
        await reopened.updateRevokedCredentialIDs([credential.claims.credentialID])
        #expect(await reopened.resolve(certificatePublicKey: node.publicKeyRepresentation) == nil)
    }

    @Test("Rollback and duplicate certificate bindings fail closed")
    func rollbackAndDuplicateKey() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("beakr-membership-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_000)
        let networkID = NetworkID()
        let authority = CredentialAuthority()
        let signer = try ProfileMembershipAuthority(
            privateKeyRepresentation: authority.privateKeyRepresentation
        )
        let first = NodeIdentity()
        let second = NodeIdentity()
        func credential(_ identity: NodeIdentity) throws -> NodeCredential {
            try authority.issue(
                nodeID: identity.nodeID,
                nodePublicKey: identity.publicKeyRepresentation,
                networkID: networkID,
                environment: "test",
                validity: 3_600,
                serviceScopes: ["lan"],
                now: now
            )
        }
        let firstRecord = try ProfileMembershipRecord(
            credential: credential(first),
            certificatePublicKey: first.publicKeyRepresentation,
            sessionID: SessionID()
        )
        let directory = try await ProfileMembershipDirectory.open(
            fileURL: root.appendingPathComponent("membership.json"),
            networkID: networkID,
            environment: "test",
            trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            revokedCredentialIDs: [],
            now: { now }
        )
        try await directory.activate(try signer.sign(ProfileMembershipClaims(
            networkID: networkID,
            generation: 2,
            generatedAtMilliseconds: 1_000_000,
            records: [firstRecord]
        )))
        await #expect(throws: ProfileMembershipDirectoryError.generationRollback) {
            try await directory.activate(try signer.sign(ProfileMembershipClaims(
                networkID: networkID,
                generation: 1,
                generatedAtMilliseconds: 1_000_000,
                records: [firstRecord]
            )))
        }
        let duplicateKey = try ProfileMembershipRecord(
            credential: credential(second),
            certificatePublicKey: first.publicKeyRepresentation,
            sessionID: SessionID()
        )
        await #expect(throws: ProfileMembershipVerificationError.duplicateCertificateKey) {
            try await directory.activate(try signer.sign(ProfileMembershipClaims(
                networkID: networkID,
                generation: 3,
                generatedAtMilliseconds: 1_000_000,
                records: [firstRecord, duplicateKey]
            )))
        }
    }
}
