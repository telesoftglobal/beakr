import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetHost
import BeakrNetSecurity

@Suite("Authenticated profile membership directory")
struct ProfileMembershipDirectoryTests {
    @Test("Corrupt or wrong-authority persisted membership cannot reopen",
          arguments: [false, true])
    func corruptPersistedMembershipFailsClosed(wrongAuthority: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("membership.json")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let invalid = try ProfileMembershipAuthority(
            privateKeyRepresentation: CredentialAuthority().privateKeyRepresentation
        ).sign(.init(networkID: networkID, generation: 1,
                     generatedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000), records: []))
        let bytes = wrongAuthority ? try ProfileMembershipWireCodec.encode(invalid) : Data("{broken".utf8)
        try bytes.write(to: fileURL, options: .atomic)

        await #expect(throws: (any Error).self) {
            _ = try await ProfileMembershipDirectory.open(
                fileURL: fileURL, networkID: networkID, environment: "test",
                trustedAuthorityPublicKey: authority.publicKeyRepresentation,
                revokedCredentialIDs: [], now: { now }
            )
        }
        #expect(try Data(contentsOf: fileURL) == bytes)
    }

    @Test("Pair sessions require both endpoints, regardless of canonical ordering",
          arguments: ["missing", "revoked", "expired"], [false, true])
    func bothEndpointsMustBeEligible(invalidity: String, invalidateHigher: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = MembershipTestClock(start)
        let network = NetworkID()
        let authority = CredentialAuthority()
        let identities = [NodeIdentity(), NodeIdentity()].sorted {
            $0.nodeID.rawValue.uuidString < $1.nodeID.rawValue.uuidString
        }
        let invalidIndex = invalidateHigher ? 1 : 0
        let credentials = try identities.enumerated().map { index, identity in
            try authority.issue(
                nodeID: identity.nodeID, nodePublicKey: identity.publicKeyRepresentation,
                networkID: network, environment: "test",
                validity: index == invalidIndex ? 10 : 3_600,
                serviceScopes: ["lan"], now: start
            )
        }
        let sessions = [SessionID(), SessionID()]
        let records = identities.indices.map { index in
            ProfileMembershipRecord(credential: credentials[index],
                                    certificatePublicKey: identities[index].publicKeyRepresentation,
                                    sessionID: sessions[index])
        }
        let signer = try ProfileMembershipAuthority(privateKeyRepresentation: authority.privateKeyRepresentation)
        let directory = try await ProfileMembershipDirectory.open(
            fileURL: root.appendingPathComponent("membership.json"), networkID: network,
            environment: "test", trustedAuthorityPublicKey: authority.publicKeyRepresentation,
            revokedCredentialIDs: [], now: { clock.now() }
        )
        try await directory.activate(try signer.sign(ProfileMembershipClaims(
            networkID: network, generation: 1, generatedAtMilliseconds: 1_000_000, records: records
        )))
        let low = identities[0].nodeID
        let high = identities[1].nodeID
        #expect(await directory.connectionSessionID(localNodeID: low, peerNodeID: high) == sessions[1])
        #expect(await directory.connectionSessionID(localNodeID: high, peerNodeID: low) == sessions[1])

        switch invalidity {
        case "missing":
            try await directory.activate(try signer.sign(ProfileMembershipClaims(
                networkID: network, generation: 2, generatedAtMilliseconds: 1_000_000,
                records: [records[1 - invalidIndex]]
            )))
        case "revoked":
            await directory.updateRevokedCredentialIDs([credentials[invalidIndex].claims.credentialID])
        default:
            // Move beyond credential expiry and the verifier's allowed clock skew.
            clock.advance(by: 120)
        }
        #expect(await directory.connectionSessionID(localNodeID: low, peerNodeID: high) == nil)
        #expect(await directory.connectionSessionID(localNodeID: high, peerNodeID: low) == nil)
    }

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

private final class MembershipTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value = value.addingTimeInterval(interval)
    }
}
