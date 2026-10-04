import Foundation
import Testing
import BeakrNetCore
import BeakrNetData
import BeakrNetHost
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
