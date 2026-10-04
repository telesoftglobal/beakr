import Foundation
import Testing
import BeakrNetAuthority
import BeakrNetCore
import BeakrNetData
import BeakrNetHost
import BeakrNetSecurity
@testable import Beakr

@MainActor
struct BeakrTests {
    @Test("Valid message queues through the host API and clears the composer")
    func queueMessage() async {
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service)
        let destination = UUID()
        model.destinationText = destination.uuidString
        model.messageText = "Hello from Beakr"

        await model.send()

        #expect(model.messageText.isEmpty)
        #expect(model.outgoingMessages.count == 1)
        #expect(model.outgoingMessages[0].state == .queued)
        let requests = await service.requests
        #expect(requests.count == 1)
        #expect(requests[0].destination == NodeID(rawValue: destination))
        #expect(String(data: requests[0].message.body, encoding: .utf8) == "Hello from Beakr")
    }

    @Test("Invalid destination never reaches the host service")
    func invalidDestination() async {
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service)
        model.destinationText = "not-a-node-id"
        model.messageText = "Hello"

        await model.send()

        #expect(await service.requests.isEmpty)
        #expect(model.outgoingMessages.isEmpty)
    }

    @Test("Host failure remains visible and does not claim the message was queued")
    func hostFailure() async {
        let model = MessageComposerModel(messagingService: FailingMessagingService())
        model.destinationText = UUID().uuidString
        model.messageText = "Hello"

        await model.send()

        #expect(model.outgoingMessages.count == 1)
        #expect(model.outgoingMessages[0].state == .failed)
        #expect(!model.messageText.isEmpty)
    }

    @Test("Bootstrap restores a stable identity before requesting authority configuration")
    func bootstrapIdentity() async {
        let nodeID = NodeID()
        let model = NodeBootstrapModel(identityLoader: FixedIdentityLoader(nodeID: nodeID))

        await model.start()

        #expect(model.nodeID == nodeID.rawValue)
        #expect(model.state == .needsConfiguration)
    }

    @Test("Bootstrap fails closed when secure identity storage is unavailable")
    func bootstrapFailure() async {
        let model = NodeBootstrapModel(identityLoader: FailingIdentityLoader())

        await model.start()

        #expect(model.nodeID == nil)
        #expect(model.state == .failed)
    }

    @Test("Verified development authority configuration advances bootstrap")
    func authorityConfiguration() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: MemoryAuthorityConfigurationStore()
        )
        await model.start()
        model.controlPlaneURL = "https://authority.example"
        model.authorityPublicKeyBase64 = authority.publicKeyRepresentation.base64EncodedString()
        model.credentialJSON = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)

        model.saveDevelopmentConfiguration()

        #expect(model.state == .identityReady)
        #expect(model.credentialJSON.isEmpty)
    }

    @Test("Certificate and revocation recovery are required before bootstrap is ready")
    func trustRecovery() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SuccessfulTrustBootstrapper()
        )
        await model.start()

        await model.enrollAndRecoverTrust()

        #expect(model.state == .ready)
    }
}

private actor RecordingMessagingService: HostMessagingService {
    private(set) var requests: [HostMessageRequest] = []

    func send(_ request: HostMessageRequest) async throws {
        requests.append(request)
    }

    func cancel(correlationID: DataCorrelationID) async throws {}
}

private struct FailingMessagingService: HostMessagingService {
    func send(_ request: HostMessageRequest) async throws {
        throw BeakrMessagingSetupError.notConfigured
    }

    func cancel(correlationID: DataCorrelationID) async throws {}
}

private struct FixedIdentityLoader: NodeIdentityLoading {
    let nodeID: NodeID
    func loadOrCreateNodeID() throws -> NodeID { nodeID }
}

private struct FailingIdentityLoader: NodeIdentityLoading {
    func loadOrCreateNodeID() throws -> NodeID { throw BeakrMessagingSetupError.notConfigured }
}

private struct MemoryAuthorityConfigurationStore: DevelopmentAuthorityConfigurationStoring {
    func load() throws -> DevelopmentAuthorityConfiguration? { nil }
    func save(_ configuration: DevelopmentAuthorityConfiguration) throws {}
}

private struct FixedAuthorityConfigurationStore: DevelopmentAuthorityConfigurationStoring {
    let configuration: DevelopmentAuthorityConfiguration
    func load() throws -> DevelopmentAuthorityConfiguration? { configuration }
    func save(_ configuration: DevelopmentAuthorityConfiguration) throws {}
}

private struct SuccessfulTrustBootstrapper: NodeTrustBootstrapping {
    func enrollAndRecover(using configuration: DevelopmentAuthorityConfiguration) async throws {}
}
