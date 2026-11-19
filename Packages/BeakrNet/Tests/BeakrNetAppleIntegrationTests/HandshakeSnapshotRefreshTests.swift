#if os(macOS)
import Foundation
import Network
import Security
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetHost
import BeakrNetSecurity

extension ProductionLANTLSIntegrationTests {
    @Test("A long-lived connection controller uses refreshed revocations for each new handshake", .timeLimit(.minutes(2)))
    func handshakeSnapshotRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("beakr-handshake-refresh-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = CertificateFixture(root: root)
        try fixture.createCA("ca")
        let anchor = try fixture.certificate("ca")
        let nodes = [NodeIdentity(), NodeIdentity()]
        let identities = try nodes.enumerated().map { try fixture.identity("peer\($0.offset)", ca: "ca", node: $0.element) }
        let certificates = try nodes.indices.map { try fixture.certificate("peer\($0)") }
        let authority = CredentialAuthority()
        let network = NetworkID()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let old = try authority.issueRevocationSnapshot(revocations: [], now: now.addingTimeInterval(-90_000))
        let fresh = try authority.issueRevocationSnapshot(revocations: [], now: now)
        let credentials = try nodes.map {
            try authority.issue(nodeID: $0.nodeID, nodePublicKey: $0.publicKeyRepresentation,
                networkID: network, environment: "refresh-regression", validity: 3600, serviceScopes: ["lan"], now: now)
        }
        func configuration(_ index: Int, snapshot: CredentialRevocationSnapshot) -> LANTransportConfiguration {
            LANTransportConfiguration(identity: nodes[index], credential: credentials[index],
                trustedAuthorityPublicKey: authority.publicKeyRepresentation, networkID: network,
                environment: "refresh-regression", revocationSnapshot: snapshot,
                localCertificateDER: SecCertificateCopyData(certificates[index]) as Data,
                localCertificatePublicKey: nodes[index].publicKeyRepresentation,
                capabilities: .init(preservesOrder: true, supportsImmediateDelivery: true,
                    supportsQueuedDelivery: true, supportsBackgroundDelivery: false), now: { now })
        }
        let distributor = RevocationSnapshotDistributor(trustedAuthorityPublicKey: authority.publicKeyRepresentation, now: { now })
        _ = try await distributor.publish(old)
        let registry = ProfileConnectionRegistry(networkID: network, localNodeID: nodes[0].nodeID,
            revocations: distributor, routePolicy: ProfileRoutePolicyController())
        // Retain this exact controller across every phase. Its original configuration is stale.
        let controller = ProfileLANConnectionController(registry: registry, configuration: configuration(0, snapshot: old))
        let nonce = Data(repeating: 0x51, count: 32)
        let revoked = try authority.issueRevocationSnapshot(revocations: [.init(
            credentialID: credentials[1].claims.credentialID,
            revokedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1000), reason: "Disposable regression")], now: now.addingTimeInterval(1))
        for phase in 0..<3 {
            if phase == 1 { _ = try await distributor.publish(fresh) }
            if phase == 2 { _ = try await distributor.publish(revoked) }
            try await connect(client: identities[1], server: identities[0], anchor: anchor, rejectingSide: nil) { client, server in
                let incoming = NetworkBonjourConnection(connection: server)
                let outgoing = NetworkBonjourConnection(connection: client)
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    client.cancel(); server.cancel()
                }
                defer { deadline.cancel() }
                let sender = Task<LANTransport?, Never> {
                    try? await LANTransport.authenticate(connection: outgoing, role: .initiator,
                        expectedPeerNodeID: nodes[0].nodeID, advertisementNonce: nonce,
                        configuration: configuration(1, snapshot: fresh))
                }
                do {
                    _ = try await controller.authenticateAndAdmit(connection: incoming, role: .acceptor,
                        expectedPeerNodeID: nodes[1].nodeID, advertisementNonce: nonce, sessionID: SessionID())
                    #expect(phase == 1, "Only refreshed, non-revoked evidence permits admission")
                    #expect(await controller.connectionCount() == 1)
                    #expect(await registry.connectionCount() == 1)
                    let remote = await sender.value
                    #expect(remote != nil)
                    await controller.connectionEnded(incoming.id)
                    await remote?.close()
                } catch {
                    if phase == 1 { Issue.record("Refreshed snapshot did not repair retained controller: \(error)") }
                    else { #expect(error as? LANHandshakeError == (phase == 0 ? .staleRevocationSnapshot : .revokedCredential)) }
                    client.cancel(); server.cancel()
                    if let remote = await sender.value { await remote.close() }
                }
                #expect(await controller.connectionCount() == 0)
                #expect(await registry.connectionCount() == 0)
                print("Retained controller snapshot phase \(phase): stale rejection / refreshed admission / revoked rejection")
            }
        }
        await controller.stopAll()
    }
}
#endif
