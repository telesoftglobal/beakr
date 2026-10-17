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
    @Test("Send to an offline recipient queues through the host API and clears the composer")
    func queueMessage() async {
        let suiteName = "BeakrTests.Queue.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        let destination = UUID()
        model.destinationID = destination
        model.messageText = "Hello from Beakr"

        await model.send()

        #expect(model.messageText.isEmpty)
        #expect(model.outgoingMessages.count == 1)
        #expect(model.outgoingMessages[0].state == .queued)
        let requests = await service.requests
        #expect(requests.count == 1)
        #expect(requests[0].destination == NodeID(rawValue: destination))
        #expect(String(data: requests[0].message.body, encoding: .utf8) == "Hello from Beakr")

        let restoredModel = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        #expect(restoredModel.outgoingMessages == model.outgoingMessages)
    }

    @Test("Send to an online recipient records sent until delivery is confirmed")
    func sendOnlineMessage() async {
        let suiteName = "BeakrTests.SendOnline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        let destination = UUID()
        model.destinationID = destination
        model.messageText = "Hello online device"
        model.synchronizeOnlineRecipients(with: [destination])

        await model.send()

        #expect(model.messageText.isEmpty)
        #expect(model.outgoingMessages.first?.state == .sent)
        #expect(model.statusMessage == "Message sent. Waiting for delivery confirmation.")
    }

    @Test("Missing destination never reaches the host service")
    func invalidDestination() async {
        let suiteName = "BeakrTests.InvalidDestination.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        model.destinationID = nil
        model.messageText = "Hello"

        await model.send()

        #expect(await service.requests.isEmpty)
        #expect(model.outgoingMessages.isEmpty)
    }

    @Test("Host failure remains visible and does not claim the message was queued")
    func hostFailure() async {
        let suiteName = "BeakrTests.HostFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = MessageComposerModel(messagingService: FailingMessagingService(), mailboxMetadataURL: metadataURL(suiteName))
        model.destinationID = UUID()
        model.messageText = "Hello"

        await model.send()

        #expect(model.outgoingMessages.count == 1)
        #expect(model.outgoingMessages[0].state == .failed)
        #expect(!model.messageText.isEmpty)
    }

    @Test("Recipients have friendly names and removed discoveries stay removed")
    func recipientDirectory() {
        let suiteName = "BeakrTests.Recipients.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        let address = UUID()
        let discovered = NetworkMemberSummary(id: address, displayName: "Network Device ABC123")

        model.synchronizeRecipients(with: [discovered])
        #expect(model.recipients.first?.name == "Network Device ABC123")
        model.synchronizeRecipients(with: [
            NetworkMemberSummary(id: address, displayName: "Hallway iPhone")
        ])
        #expect(model.recipients.first?.name == "Hallway iPhone")
        model.synchronizeRecipients(with: [
            NetworkMemberSummary(
                id: address,
                displayName: "Network Device ABC123",
                isPlaceholderName: true
            )
        ])
        #expect(model.recipients.first?.name == "Hallway iPhone")
        model.renameRecipient(id: address, name: "Kitchen iPhone")
        #expect(model.displayName(for: address) == "Kitchen iPhone")
        model.synchronizeRecipients(with: [
            NetworkMemberSummary(id: address, displayName: "Renamed Remotely")
        ])
        #expect(model.displayName(for: address) == "Renamed Remotely")

        model.removeRecipient(id: address)
        model.synchronizeRecipients(with: [discovered])
        #expect(model.recipients.isEmpty)

        #expect(model.addRecipient(name: "Alice", addressText: address.uuidString))
        #expect(model.displayName(for: address) == "Alice")
    }

    @Test("Inbox metadata persists and legacy messages derive a subject")
    func inboxMetadata() {
        let suiteName = "BeakrTests.InboxMetadata.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let messageID = UUID()
        let message = IncomingMessage(
            id: messageID,
            source: UUID(),
            body: "Meeting Tomorrow\nPlease bring the latest notes.",
            receivedAt: Date(),
            isRestored: true
        )

        #expect(message.subject == "Meeting Tomorrow")
        #expect(message.preview == "Please bring the latest notes.")

        let model = MessageComposerModel(messagingService: RecordingMessagingService(), mailboxMetadataURL: metadataURL(suiteName))
        model.setRead(true, messageID: messageID)
        model.toggleFlag(messageID: messageID)

        let restoredModel = MessageComposerModel(messagingService: RecordingMessagingService(), mailboxMetadataURL: metadataURL(suiteName))
        #expect(restoredModel.isRead(messageID))
        #expect(restoredModel.isFlagged(messageID))
    }

    @Test("Opening an incoming message queues one durable read receipt")
    func readReceipt() async throws {
        let suiteName = "BeakrTests.ReadReceipt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        let message = IncomingMessage(
            id: UUID(),
            source: UUID(),
            body: "Hello",
            receivedAt: Date(),
            isRestored: false
        )

        await model.openIncomingMessage(message)
        await model.openIncomingMessage(message)

        let requests = await service.requests
        #expect(requests.count == 1)
        #expect(requests[0].destination.rawValue == message.source)
        #expect(requests[0].message.operation.name == "read-receipt")
        let receipt = try JSONDecoder().decode(MessageReadReceipt.self, from: requests[0].message.body)
        #expect(receipt.messageID == message.id)
        #expect(model.isRead(message.id))
    }

    @Test("History deletion preserves queued messages and queued deletion cancels them")
    func separateMessageDeletion() async {
        let suiteName = "BeakrTests.Deletion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = RecordingMessagingService()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        model.destinationID = UUID()
        model.messageText = "Keep queued"
        await model.send()

        await model.deleteMessageHistory()
        #expect(model.outgoingMessages.count == 1)
        #expect(model.outgoingMessages[0].state == .queued)

        let correlationID = model.outgoingMessages[0].id
        await model.deleteQueuedMessages()
        #expect(model.outgoingMessages.isEmpty)
        #expect(await service.cancelledCorrelationIDs == [correlationID])

        model.destinationID = UUID()
        model.messageText = "Delete one"
        await model.send()
        let individualID = model.outgoingMessages[0].id
        await model.deleteOutgoingMessage(id: individualID)
        #expect(model.outgoingMessages.isEmpty)
        #expect(await service.cancelledCorrelationIDs == [correlationID, individualID])

        let restoredModel = MessageComposerModel(messagingService: service, mailboxMetadataURL: metadataURL(suiteName))
        #expect(restoredModel.outgoingMessages.isEmpty)
    }

    @Test("Bootstrap restores a stable identity before requesting authority configuration")
    func bootstrapIdentity() async throws {
        let nodeID = NodeID()
        let profile = try NetworkProfile(networkID: NetworkID(), localNodeID: nodeID, displayName: "Test")
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: nodeID),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: SuccessfulTrustBootstrapper(),
            profileRuntimeManager: MemoryProfileRuntimeManager(initialProfile: profile)
        )

        await model.start()

        #expect(model.nodeID == nodeID.rawValue)
        #expect(model.state == .needsConfiguration)
    }

    @Test("Bootstrap startup is idempotent across repeated window tasks")
    func bootstrapStartupIsIdempotent() async throws {
        let nodeID = NodeID()
        let profile = try NetworkProfile(networkID: NetworkID(), localNodeID: nodeID, displayName: "Test")
        let profileManager = MemoryProfileRuntimeManager(initialProfile: profile)
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: nodeID),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: SuccessfulTrustBootstrapper(),
            profileRuntimeManager: profileManager
        )

        await model.start()
        await model.start()

        #expect(await profileManager.activeProfileRequests == 1)
    }

    @Test("Profile registry load failures remain distinct from an empty registry")
    func profileRegistryLoadFailure() async {
        let model = NodeBootstrapModel(
            identityLoader: FailingIdentityLoader(),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: SuccessfulTrustBootstrapper(),
            profileRuntimeManager: MemoryProfileRuntimeManager(failsToLoad: true)
        )

        await model.start()

        #expect(model.state == .failed)
        #expect(model.activeNetworkConnectivity == .failed)
        #expect(model.profileRegistryLoadFailure != nil)
        #expect(model.statusMessage.contains("Network data could not be loaded"))
    }

    @Test("Bootstrap fails closed when secure identity storage is unavailable")
    func bootstrapFailure() async throws {
        let profile = try NetworkProfile(networkID: NetworkID(), localNodeID: NodeID(), displayName: "Test")
        let model = NodeBootstrapModel(
            identityLoader: FailingIdentityLoader(),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: SuccessfulTrustBootstrapper(),
            profileRuntimeManager: MemoryProfileRuntimeManager(initialProfile: profile)
        )

        await model.start()

        #expect(model.nodeID == nil)
        #expect(model.state == .failed)
        #expect(model.networks.count == 1)
        #expect(model.networks.first?.id == profile.id)
        #expect(model.networks.first?.isActive == true)
    }

    @Test("A network can become active after the previous profile failed to start")
    func switchNetworkAfterBootstrapFailure() async throws {
        let nodeID = NodeID()
        let home = try NetworkProfile(networkID: NetworkID(), localNodeID: nodeID, displayName: "Home")
        let office = try NetworkProfile(networkID: NetworkID(), localNodeID: nodeID, displayName: "Office")
        let profileManager = MultipleProfileRuntimeManager(initialProfile: home)
        await profileManager.addAndActivate(office)
        try await profileManager.activate(home.id)
        let model = NodeBootstrapModel(
            identityLoader: FailingIdentityLoader(),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: SuccessfulTrustBootstrapper(),
            profileRuntimeManager: profileManager
        )

        await model.start()
        #expect(model.state == .failed)

        await model.switchNetwork(to: office.id)

        #expect(await profileManager.activeProfile()?.id == office.id)
        #expect(model.networks.first(where: { $0.id == office.id })?.isActive == true)
        #expect(model.networks.first(where: { $0.id == home.id })?.isActive == false)
    }

    @Test("Verified development authority configuration advances bootstrap")
    func authorityConfiguration() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: SuccessfulTrustBootstrapper(),
            profileRuntimeManager: MemoryProfileRuntimeManager(),
            lanRuntimeManager: TestLANRuntimeManager()
        )
        await model.start()
        model.controlPlaneURL = "https://authority.example"
        model.networkIDText = networkID.rawValue.uuidString
        model.authorityPublicKeyBase64 = authority.publicKeyRepresentation.base64EncodedString()
        model.credentialJSON = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)

        await model.saveDevelopmentConfiguration()

        #expect(model.state == .ready)
        #expect(model.credentialJSON.isEmpty)
    }

    @Test("A configured network remains inactive without a usable local network")
    func configuredNetworkWithoutLocalNetworkIsInactive() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager()
        await profileRuntimeManager.setInitialProfile(try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Test Network"
        ))
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SuccessfulTrustBootstrapper(),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: TestLANRuntimeManager(localNetworkAvailable: false),
            networkStartTimeout: .milliseconds(50)
        )

        await model.start()

        #expect(model.state == .ready)
        #expect(model.activeNetworkConnectivity == .inactive)
        #expect(model.activeNetworkStatusTitle == "Inactive")
    }

    @Test("Certificate and revocation recovery are required before bootstrap is ready")
    func trustRecovery() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager()
        let peerID = UUID()
        let lanRuntimeManager = TestLANRuntimeManager(authenticatedPeerIDs: [peerID])
        await profileRuntimeManager.setInitialProfile(try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Test Network"
        ))
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SuccessfulTrustBootstrapper(),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: lanRuntimeManager,
            networkStartTimeout: .milliseconds(50)
        )
        await model.start()

        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.onlineMemberIDs == [peerID])
        #expect(model.activeNetworkStatusTitle == "Active — Connected to 1 device")

        await model.applicationDidEnterBackground()

        #expect(model.state == .ready)
        #expect(model.activeNetworkConnectivity == .inactive)
        #expect(model.onlineMemberIDs.isEmpty)
        #expect(await lanRuntimeManager.startCount == 1)
        #expect(await lanRuntimeManager.stopCount == 1)
        #expect(await profileRuntimeManager.checkpointLifecycles == [.background])

        await model.applicationBecameActive()

        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.onlineMemberIDs == [peerID])
        #expect(await lanRuntimeManager.startCount == 2)

        await model.reconnectActiveNetwork()

        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(await lanRuntimeManager.startCount == 3)
        #expect(await lanRuntimeManager.stopCount == 2)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    await model.reconnectActiveNetwork()
                }
            }
        }

        #expect(await lanRuntimeManager.startCount == 4)
        #expect(await lanRuntimeManager.stopCount == 3)

        await lanRuntimeManager.setStartDelay(.seconds(5))
        await model.reconnectActiveNetwork()

        #expect(model.state == .ready)
        #expect(model.activeNetworkConnectivity == .failed)
        #expect(model.statusMessage == "Local Network startup timed out. Pull down to retry.")

        await lanRuntimeManager.setStartDelay(nil)
        await model.reconnectActiveNetwork()

        #expect(model.state == .ready)
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
    }

    @Test("A shared network rename preserves profile identity and online peers")
    func sharedNetworkRenamePreservesIdentityAndConnectivity() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Green"
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager(initialProfile: profile)
        let peerID = UUID()
        let lanRuntimeManager = TestLANRuntimeManager(authenticatedPeerIDs: [peerID])
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SuccessfulTrustBootstrapper(),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: lanRuntimeManager,
            networkStartTimeout: .milliseconds(50)
        )
        await model.start()
        await lanRuntimeManager.setSharedNetworkName("Home")

        await model.refreshNetworkMembers()

        let renamed = try #require(await profileRuntimeManager.profiles().first)
        #expect(renamed.id == profile.id)
        #expect(renamed.networkID == profile.networkID)
        #expect(renamed.localNodeID == profile.localNodeID)
        #expect(renamed.displayName == "Home")
        #expect(model.onlineMemberIDs == [peerID])
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
    }

    @Test("Foregrounding retries a failed LAN startup instead of remaining inactive")
    func foregroundRetriesFailedLANStartup() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "development",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Home"
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager(initialProfile: profile)
        let peerID = UUID()
        let lanRuntimeManager = TestLANRuntimeManager(authenticatedPeerIDs: [peerID])
        await lanRuntimeManager.failNextStarts(1)
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SuccessfulTrustBootstrapper(),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: lanRuntimeManager,
            networkStartTimeout: .milliseconds(50)
        )

        await model.start()
        #expect(model.state == .identityReady)
        #expect(model.activeNetworkConnectivity == .failed)

        await model.applicationDidEnterBackground()
        #expect(model.activeNetworkConnectivity == .inactive)

        await model.applicationBecameActive(forceRestart: true)

        #expect(model.state == .ready)
        #expect(model.activeNetworkConnectivity == .connected(peerCount: 1))
        #expect(model.onlineMemberIDs == [peerID])
        #expect(await lanRuntimeManager.startCount == 2)
    }

    @Test("Forgetting a joined network removes only the local profile")
    func forgetJoinedNetwork() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Joined Network"
        )
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://joined.local:8443")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let profileRuntimeManager = MemoryProfileRuntimeManager(initialProfile: profile)
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: configuration),
            trustBootstrapper: SuccessfulTrustBootstrapper(),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: TestLANRuntimeManager(),
            networkCreator: NonOwningNetworkCreator()
        )
        await model.start()

        await model.forgetJoinedNetwork(profile.id)

        #expect(await profileRuntimeManager.profiles().isEmpty)
        #expect(model.networks.isEmpty)
        #expect(model.state == .needsConfiguration)
    }

    @Test("Forgetting a production profile preserves its Context-owned messages")
    func forgettingPreservesContextMessageStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeakrContextForget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = try NetworkProfile(
            networkID: NetworkID(),
            localNodeID: NodeID(),
            displayName: "Preserved Network"
        )
        let manager = ApplicationProfileRuntimeManager(applicationRoot: directory)
        try await manager.addAndActivate(profile)
        let runtime = try await manager.start(profile: profile)
        try await runtime.dataState.clearRecordedResults()
        let correlationID = DataCorrelationID()
        let receivedAt = Date(timeIntervalSince1970: 1_760_000_000)
        try await runtime.dataState.record(StoredDataResult(
            messageID: MessageID(),
            idempotencyKey: DataIdempotencyKey(),
            response: DataMessage(
                kind: .message,
                operation: DataOperation(namespace: "beakr", name: "text-message", version: 1),
                correlationID: correlationID,
                idempotencyKey: DataIdempotencyKey(),
                body: Data("Preserved message".utf8)
            ),
            completedAt: receivedAt
        ))
        let messageStoreURL = runtime.paths.dataStateURL
        let contextID = try #require(runtime.contextID)

        try await manager.forget(profile: profile)

        #expect(try await manager.profiles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: messageStoreURL.path))
        let exposedContext = try #require(try await manager.context(networkID: profile.networkID))
        #expect(exposedContext.id == contextID)
        #expect(exposedContext.attachedProfileIDs.isEmpty)
        #expect(try await manager.contexts().map(\.id) == [contextID])
        let archivedMessages = try await manager.incomingMessages(contextID: contextID)
        #expect(archivedMessages.map(\.id) == [correlationID.rawValue])
        #expect(archivedMessages.map(\.body) == ["Preserved message"])
        #expect(archivedMessages.map(\.receivedAt) == [receivedAt])
        let contexts = try PersistentContextRegistry.open(
            fileURL: directory.appendingPathComponent("contexts.json"),
            contextsRootURL: directory.appendingPathComponent("Contexts", isDirectory: true)
        )
        let archived = try #require(await contexts.context(networkID: profile.networkID))
        #expect(archived.id == contextID)
        #expect(archived.attachedProfileIDs.isEmpty)

        let replacement = try NetworkProfile(
            networkID: profile.networkID,
            localNodeID: NodeID(),
            displayName: "Preserved Network"
        )
        try await manager.addAndActivate(replacement)
        let reattached = try await manager.start(profile: replacement)
        #expect(reattached.contextID == contextID)
        #expect(reattached.messageStoreID == runtime.messageStoreID)
        #expect(
            reattached.paths.dataStateURL.resolvingSymlinksInPath()
                == messageStoreURL.resolvingSymlinksInPath()
        )
        #expect(FileManager.default.fileExists(atPath: reattached.paths.dataStateURL.path))
    }

    @Test("Deleting an archived Context permanently removes its registry entry and stored data")
    func deletingArchivedContextRemovesStoredData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeakrContextDelete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = try NetworkProfile(
            networkID: NetworkID(),
            localNodeID: NodeID(),
            displayName: "Disposable Network"
        )
        let manager = ApplicationProfileRuntimeManager(applicationRoot: directory)
        try await manager.addAndActivate(profile)
        let runtime = try await manager.start(profile: profile)
        let contextID = try #require(runtime.contextID)
        let metadataURL = try #require(runtime.mailboxMetadataURL)
        try ContextMailboxMetadataStore.save(.empty, to: metadataURL)
        let contextRoot = metadataURL.deletingLastPathComponent().deletingLastPathComponent()

        await #expect(throws: ApplicationContextDeletionError.contextStillAttached(contextID)) {
            try await manager.deleteContext(contextID)
        }

        try await manager.forget(profile: profile)
        #expect(FileManager.default.fileExists(atPath: contextRoot.path))

        try await manager.deleteContext(contextID)

        #expect(try await manager.contexts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: contextRoot.path))
        await #expect(throws: ContextRegistryError.unknownContext(contextID)) {
            _ = try await manager.mailboxMetadata(contextID: contextID)
        }
    }

    @Test("Create Network activates the authoritative profile returned by the Mac creator")
    func createNetwork() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Red Network"
        )
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan", "admin"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://red-mac.local:8443")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: MemoryAuthorityConfigurationStore(),
            trustBootstrapper: SuccessfulTrustBootstrapper(),
            profileRuntimeManager: MemoryProfileRuntimeManager(),
            lanRuntimeManager: TestLANRuntimeManager(),
            networkCreator: FixedAuthoritativeNetworkCreator(
                created: .init(
                    profile: profile,
                    configuration: configuration,
                    authority: TestAuthorityRunner()
                )
            )
        )
        model.networkDisplayName = "Red Network"
        model.authorityHostname = "red-mac.local"
        model.authorityPort = "8443"

        await model.createNetwork()

        #expect(model.state == .ready)
        #expect(model.nodeID == identity.nodeID.rawValue)
        #expect(model.profileID == profile.id.rawValue)
        #expect(model.networkIDText == networkID.rawValue.uuidString)
        #expect(model.networkDisplayName == "Local Network")
        let createdNetwork = try #require(model.networks.first { $0.id == profile.id })
        #expect(createdNetwork.canManageNetwork)
        #expect(createdNetwork.isHostingAuthority)
        #expect(createdNetwork.canExchangeMessages)
        #expect(model.activeNetworkRole == "Authority Host and Manager")

        await model.renameOwnedNetwork(profile.id, to: "Blue")

        #expect(model.activeNetworkName == "Blue")
        #expect(model.profileID == profile.id.rawValue)
        #expect(model.networkIDText == networkID.rawValue.uuidString)
    }

    @Test("A signed admin credential grants management without hosting the authority")
    func portableNetworkManagementAuthorization() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let networkID = NetworkID()
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Portable Authority"
        )
        let credential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan", "admin"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: credential
        )

        let authorization = try #require(NodeBootstrapModel.verifiedAuthorization(
            profile: profile,
            configuration: configuration,
            isHostingAuthority: false
        ))

        #expect(authorization.networkID == networkID)
        #expect(authorization.nodeID == identity.nodeID)
        #expect(authorization.capabilities.contains(.manageNetwork))
        #expect(authorization.capabilities.contains(.exchangeMessages))
        #expect(!authorization.capabilities.contains(.hostAuthority))
    }

    @Test("An invalid admin credential cannot grant network management")
    func rejectsInvalidNetworkManagementAuthorization() throws {
        let identity = NodeIdentity()
        let signingAuthority = CredentialAuthority()
        let trustedAuthority = CredentialAuthority()
        let networkID = NetworkID()
        let profile = try NetworkProfile(
            networkID: networkID,
            localNodeID: identity.nodeID,
            displayName: "Untrusted Authority"
        )
        let credential = try signingAuthority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: networkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan", "admin"]
        )
        let configuration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://authority.example")!,
            networkID: networkID,
            authorityPublicKey: trustedAuthority.publicKeyRepresentation,
            credential: credential
        )

        #expect(NodeBootstrapModel.verifiedAuthorization(
            profile: profile,
            configuration: configuration,
            isHostingAuthority: false
        ) == nil)
    }

    @Test("Create Network preserves an existing profile and activates the new network")
    func createAdditionalNetwork() async throws {
        let identity = NodeIdentity()
        let authority = CredentialAuthority()
        let originalNetworkID = NetworkID()
        let originalProfile = try NetworkProfile(
            networkID: originalNetworkID,
            localNodeID: identity.nodeID,
            displayName: "Original"
        )
        let originalCredential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: originalNetworkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan"]
        )
        let originalConfiguration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://original.local:8443")!,
            networkID: originalNetworkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: originalCredential
        )

        let newNetworkID = NetworkID()
        let newProfile = try NetworkProfile(
            networkID: newNetworkID,
            localNodeID: identity.nodeID,
            displayName: "New Network"
        )
        let newCredential = try authority.issue(
            nodeID: identity.nodeID,
            nodePublicKey: identity.publicKeyRepresentation,
            networkID: newNetworkID,
            environment: "production",
            validity: 3_600,
            serviceScopes: ["lan", "admin"]
        )
        let newConfiguration = DevelopmentAuthorityConfiguration(
            controlPlaneURL: URL(string: "https://new.local:8443")!,
            networkID: newNetworkID,
            authorityPublicKey: authority.publicKeyRepresentation,
            credential: newCredential
        )
        let profileRuntimeManager = MultipleProfileRuntimeManager(initialProfile: originalProfile)
        let model = NodeBootstrapModel(
            identityLoader: FixedIdentityLoader(nodeID: identity.nodeID),
            configurationStore: FixedAuthorityConfigurationStore(configuration: originalConfiguration),
            trustBootstrapper: SuccessfulTrustBootstrapper(),
            profileRuntimeManager: profileRuntimeManager,
            lanRuntimeManager: TestLANRuntimeManager(),
            networkCreator: FixedAuthoritativeNetworkCreator(
                created: .init(
                    profile: newProfile,
                    configuration: newConfiguration,
                    authority: TestAuthorityRunner()
                )
            )
        )

        await model.start()
        model.networkDisplayName = "New Network"
        await model.createNetwork()

        #expect(model.state == .ready)
        #expect(model.profileID == newProfile.id.rawValue)
        #expect(await profileRuntimeManager.profiles().count == 2)
        #expect(await profileRuntimeManager.activeProfile()?.id == newProfile.id)
        #expect(model.networkDisplayName == "Local Network")
        let originalNetwork = try #require(model.networks.first { $0.id == originalProfile.id })
        let createdNetwork = try #require(model.networks.first { $0.id == newProfile.id })
        #expect(!originalNetwork.canManageNetwork)
        #expect(!originalNetwork.isHostingAuthority)
        #expect(originalNetwork.canExchangeMessages)
        #expect(createdNetwork.canManageNetwork)
        #expect(createdNetwork.isHostingAuthority)
        #expect(createdNetwork.canExchangeMessages)
    }

    @Test("Invitation metadata reports creation, expiration, and remaining time")
    func invitationMetadata() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let authority = CredentialAuthority()
        let invitation = try authority.issueNetworkInvitation(
            networkID: NetworkID(),
            environment: "production",
            controlPlaneURL: URL(string: "https://authority.local:8443")!,
            authorityCertificateDER: Data([0x01]),
            validity: 600,
            now: now
        )
        let encoded = String(
            decoding: try NetworkInvitationWireCodec.encode(invitation),
            as: UTF8.self
        )

        let metadata = try #require(InvitationMetadata(invitation: encoded))

        #expect(metadata.issuedAt == now)
        #expect(metadata.expiresAt == now.addingTimeInterval(600))
        #expect(metadata.remaining(at: now.addingTimeInterval(90)) == 510)
        #expect(!metadata.isExpired(at: now.addingTimeInterval(599)))
        #expect(metadata.isExpired(at: now.addingTimeInterval(600)))
    }

    @Test("Mailbox metadata remains isolated by Context")
    func mailboxMetadataIsContextScoped() async {
        let firstURL = metadataURL("BeakrTests.ContextA.\(UUID().uuidString)")
        let secondURL = metadataURL("BeakrTests.ContextB.\(UUID().uuidString)")
        let service = RecordingMessagingService()
        let recipient = UUID()
        let model = MessageComposerModel(messagingService: service, mailboxMetadataURL: firstURL)

        model.synchronizeRecipients(with: [
            NetworkMemberSummary(id: recipient, displayName: "Context A Device")
        ])
        model.destinationID = recipient
        model.messageText = "Stored only in Context A"
        await model.send()

        model.attachMailboxMetadata(fileURL: secondURL)
        #expect(model.outgoingMessages.isEmpty)
        #expect(model.recipients.isEmpty)

        model.attachMailboxMetadata(fileURL: firstURL)
        #expect(model.outgoingMessages.count == 1)
        #expect(model.outgoingMessages.first?.body == "Stored only in Context A")
        #expect(model.recipients.first?.name == "Context A Device")
    }

    @Test("Network member metadata preserves the last authenticated name and last-seen date")
    func networkMemberMetadataRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeakrTests.MemberMetadata.\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("network-members.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let memberID = UUID()
        let lastSeen = Date(timeIntervalSince1970: 1_760_000_000)
        let metadata = NetworkMemberMetadata(
            id: memberID,
            displayName: "Hallway iPhone",
            lastSeen: lastSeen
        )

        try NetworkMemberMetadataStore.save([memberID: metadata], to: fileURL)
        let restored = try NetworkMemberMetadataStore.load(from: fileURL)

        #expect(restored == [memberID: metadata])
    }

    private func metadataURL(_ suiteName: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
            .appendingPathComponent("mailbox-metadata.json")
    }
}

private actor RecordingMessagingService: HostMessagingService {
    private(set) var requests: [HostMessageRequest] = []
    private(set) var cancelledCorrelationIDs: [UUID] = []

    func send(_ request: HostMessageRequest) async throws {
        requests.append(request)
    }

    func cancel(correlationID: DataCorrelationID) async throws {
        cancelledCorrelationIDs.append(correlationID.rawValue)
    }
}

private struct FailingMessagingService: HostMessagingService {
    func send(_ request: HostMessageRequest) async throws {
        throw BeakrMessagingSetupError.notConfigured
    }

    func cancel(correlationID: DataCorrelationID) async throws {}
}

private struct FixedIdentityLoader: NodeIdentityLoading {
    let nodeID: NodeID
    func loadOrCreateNodeID(profileID: NetworkProfileID) throws -> NodeID { nodeID }
}

private struct FailingIdentityLoader: NodeIdentityLoading {
    func loadOrCreateNodeID(profileID: NetworkProfileID) throws -> NodeID { throw BeakrMessagingSetupError.notConfigured }
}

private struct MemoryAuthorityConfigurationStore: DevelopmentAuthorityConfigurationStoring {
    func load(profile: NetworkProfile) throws -> DevelopmentAuthorityConfiguration? { nil }
    func save(_ configuration: DevelopmentAuthorityConfiguration, profile: NetworkProfile) throws {}
    func delete(profile: NetworkProfile) throws {}
}

private struct FixedAuthorityConfigurationStore: DevelopmentAuthorityConfigurationStoring {
    let configuration: DevelopmentAuthorityConfiguration
    func load(profile: NetworkProfile) throws -> DevelopmentAuthorityConfiguration? { configuration }
    func save(_ configuration: DevelopmentAuthorityConfiguration, profile: NetworkProfile) throws {}
    func delete(profile: NetworkProfile) throws {}
}

private struct SuccessfulTrustBootstrapper: NodeTrustBootstrapping {
    func enrollAndRecover(
        using configuration: DevelopmentAuthorityConfiguration,
        profile: NetworkProfile,
        revocationSnapshotURL: URL
    ) async throws {}
}

private enum TestProfileRuntimeError: Error {
    case unavailable
}

private actor MemoryProfileRuntimeManager: ApplicationProfileRuntimeManaging {
    private var active = false
    private var initialProfile: NetworkProfile?
    private(set) var checkpointLifecycles: [HostLifecycleState] = []
    private(set) var activeProfileRequests = 0
    private let failsToLoad: Bool

    init(initialProfile: NetworkProfile? = nil, failsToLoad: Bool = false) {
        self.initialProfile = initialProfile
        self.failsToLoad = failsToLoad
    }

    func setInitialProfile(_ profile: NetworkProfile) {
        initialProfile = profile
    }

    func activeProfile() throws -> NetworkProfile? {
        activeProfileRequests += 1
        if failsToLoad { throw TestProfileRuntimeError.unavailable }
        return initialProfile
    }

    func profiles() -> [NetworkProfile] { initialProfile.map { [$0] } ?? [] }

    func activate(_ profileID: NetworkProfileID) throws {
        guard initialProfile?.id == profileID else {
            throw NetworkProfileRegistryError.unknownProfile(profileID)
        }
    }

    func addAndActivate(_ profile: NetworkProfile) throws {
        initialProfile = profile
    }

    func rename(_ profileID: NetworkProfileID, to displayName: String) throws {
        guard let profile = initialProfile, profile.id == profileID else {
            throw NetworkProfileRegistryError.unknownProfile(profileID)
        }
        initialProfile = try NetworkProfile(
            id: profile.id,
            networkID: profile.networkID,
            localNodeID: profile.localNodeID,
            displayName: displayName,
            createdAt: profile.createdAt
        )
    }

    func start(profile proposedProfile: NetworkProfile) async throws -> ApplicationProfileRuntime {
        guard !active else { throw ActiveProfileRuntimeError.runtimeAlreadyActive(NetworkProfileID()) }
        active = true
        let profile: NetworkProfile
        if let initialProfile {
            profile = initialProfile
        } else {
            profile = try NetworkProfile(
                id: proposedProfile.id,
                networkID: proposedProfile.networkID,
                localNodeID: proposedProfile.localNodeID,
                displayName: "Test Network", createdAt: Date(timeIntervalSince1970: 1_000)
            )
        }
        guard profile.id == proposedProfile.id,
              profile.networkID == proposedProfile.networkID,
              profile.localNodeID == proposedProfile.localNodeID else {
            throw NodeBootstrapError.activeProfileMismatch
        }
        initialProfile = profile
        let paths = ProfileRuntimePaths(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(profile.id.rawValue.uuidString, isDirectory: true)
        )
        return ApplicationProfileRuntime(
            profile: profile,
            paths: paths,
            dataState: try await PersistentDataState.open(fileURL: paths.dataStateURL)
        )
    }

    func stop() throws {
        guard active else { throw ActiveProfileRuntimeError.runtimeNotActive }
        active = false
    }

    func delete(profile: NetworkProfile) {
        active = false
        if initialProfile?.id == profile.id { initialProfile = nil }
    }

    func checkpoint(lifecycle: HostLifecycleState) throws {
        guard active else { throw ActiveProfileRuntimeError.runtimeNotActive }
        checkpointLifecycles.append(lifecycle)
    }
}

private actor MultipleProfileRuntimeManager: ApplicationProfileRuntimeManaging {
    private var storedProfiles: [NetworkProfile]
    private var activeProfileID: NetworkProfileID?
    private var runtimeIsActive = false

    init(initialProfile: NetworkProfile) {
        storedProfiles = [initialProfile]
        activeProfileID = initialProfile.id
    }

    func activeProfile() -> NetworkProfile? {
        storedProfiles.first { $0.id == activeProfileID }
    }

    func profiles() -> [NetworkProfile] { storedProfiles }

    func activate(_ profileID: NetworkProfileID) throws {
        guard storedProfiles.contains(where: { $0.id == profileID }) else {
            throw NetworkProfileRegistryError.unknownProfile(profileID)
        }
        activeProfileID = profileID
    }

    func addAndActivate(_ profile: NetworkProfile) {
        storedProfiles.append(profile)
        activeProfileID = profile.id
    }

    func rename(_ profileID: NetworkProfileID, to displayName: String) throws {
        guard let index = storedProfiles.firstIndex(where: { $0.id == profileID }) else {
            throw NetworkProfileRegistryError.unknownProfile(profileID)
        }
        let profile = storedProfiles[index]
        storedProfiles[index] = try NetworkProfile(
            id: profile.id,
            networkID: profile.networkID,
            localNodeID: profile.localNodeID,
            displayName: displayName,
            createdAt: profile.createdAt
        )
    }

    func start(profile: NetworkProfile) async throws -> ApplicationProfileRuntime {
        guard !runtimeIsActive else {
            throw ActiveProfileRuntimeError.runtimeAlreadyActive(profile.id)
        }
        guard activeProfileID == profile.id else {
            throw NodeBootstrapError.activeProfileMismatch
        }
        runtimeIsActive = true
        let paths = ProfileRuntimePaths(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(profile.id.rawValue.uuidString, isDirectory: true)
        )
        return ApplicationProfileRuntime(
            profile: profile,
            paths: paths,
            dataState: try await PersistentDataState.open(fileURL: paths.dataStateURL)
        )
    }

    func checkpoint(lifecycle: HostLifecycleState) throws {
        guard runtimeIsActive else { throw ActiveProfileRuntimeError.runtimeNotActive }
    }

    func stop() throws {
        guard runtimeIsActive else { throw ActiveProfileRuntimeError.runtimeNotActive }
        runtimeIsActive = false
    }

    func delete(profile: NetworkProfile) {
        runtimeIsActive = false
        storedProfiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            activeProfileID = storedProfiles.first?.id
        }
    }
}

private actor TestLANRuntimeManager: ApplicationLANRuntimeManaging {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private let peerIDs: Set<UUID>
    private let isLocalNetworkAvailable: Bool
    private var sharedNetworkName: String?
    private var startDelay: Duration?
    private var startFailuresRemaining = 0

    init(authenticatedPeerIDs: Set<UUID> = [], localNetworkAvailable: Bool = true) {
        peerIDs = authenticatedPeerIDs
        isLocalNetworkAvailable = localNetworkAvailable
    }

    func start(
        configuration: DevelopmentAuthorityConfiguration,
        runtime: ApplicationProfileRuntime,
        displayName: String
    ) async throws {
        startCount += 1
        if startFailuresRemaining > 0 {
            startFailuresRemaining -= 1
            throw ApplicationLANRuntimeError.notRunning
        }
        if let startDelay {
            try await Task.sleep(for: startDelay)
        }
    }

    func stop() {
        stopCount += 1
    }

    func authenticatedPeerIDs() -> Set<UUID> {
        peerIDs
    }

    func localNetworkAvailable() -> Bool {
        isLocalNetworkAvailable
    }

    func networkDisplayName() -> String? {
        sharedNetworkName
    }

    func setSharedNetworkName(_ name: String?) {
        sharedNetworkName = name
    }

    func localNetworkAvailabilityUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(isLocalNetworkAvailable)
            continuation.finish()
        }
    }

    func setStartDelay(_ delay: Duration?) {
        startDelay = delay
    }

    func failNextStarts(_ count: Int) {
        startFailuresRemaining = count
    }
}

private actor TestAuthorityRunner: ApplicationAuthorityRunning {
    func stop() {}

    func createInvitation(validity: TimeInterval) throws -> NetworkInvitation {
        throw NetworkInvitationError.invalidConfiguration
    }
}

private struct NonOwningNetworkCreator: AuthoritativeNetworkCreating {
    func create(displayName: String, hostname: String, port: UInt16) async throws
        -> CreatedAuthoritativeNetwork {
        throw BeakrMessagingSetupError.notConfigured
    }

    func restore(profile: NetworkProfile) async throws -> (any ApplicationAuthorityRunning)? { nil }

    func owns(profile: NetworkProfile) async throws -> Bool { false }

    func authorityCertificateDER(profile: NetworkProfile) async throws -> Data {
        throw BeakrMessagingSetupError.notConfigured
    }

    func rename(profile: NetworkProfile, to displayName: String) async throws {
        throw BeakrMessagingSetupError.notConfigured
    }

    func delete(profile: NetworkProfile) async throws {
        throw BeakrMessagingSetupError.notConfigured
    }
}

private struct FixedAuthoritativeNetworkCreator: AuthoritativeNetworkCreating {
    let created: CreatedAuthoritativeNetwork
    let createdProfileID: NetworkProfileID
    let authorityCertificateDER: Data?

    init(created: CreatedAuthoritativeNetwork) {
        self.created = created
        createdProfileID = created.profile.id
        authorityCertificateDER = created.configuration.authorityCertificateDER
    }

    func create(displayName: String, hostname: String, port: UInt16) async throws
        -> CreatedAuthoritativeNetwork {
        created
    }

    func restore(profile: NetworkProfile) async throws -> (any ApplicationAuthorityRunning)? {
        nil
    }

    func owns(profile: NetworkProfile) async throws -> Bool {
        profile.id == createdProfileID
    }

    func authorityCertificateDER(profile: NetworkProfile) async throws -> Data {
        authorityCertificateDER ?? Data()
    }

    func rename(profile: NetworkProfile, to displayName: String) async throws {}

    func delete(profile: NetworkProfile) async throws {}
}
