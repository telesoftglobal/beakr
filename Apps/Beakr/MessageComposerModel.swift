import Foundation
import Observation
import BeakrNetCore
import BeakrNetData
import BeakrNetHost

enum MessageDeliveryState: Equatable {
    case sending
    case queued
    case failed
}

struct OutgoingMessage: Identifiable, Equatable {
    let id: UUID
    let destination: UUID
    let body: String
    var state: MessageDeliveryState
}

enum BeakrMessagingSetupError: Error {
    case notConfigured
}

actor UnconfiguredHostMessagingService: HostMessagingService {
    func send(_ request: HostMessageRequest) async throws {
        throw BeakrMessagingSetupError.notConfigured
    }

    func cancel(correlationID: DataCorrelationID) async throws {
        throw BeakrMessagingSetupError.notConfigured
    }
}

@MainActor
@Observable
final class MessageComposerModel {
    var destinationText = ""
    var messageText = ""
    private(set) var outgoingMessages: [OutgoingMessage] = []
    private(set) var statusMessage = "Node setup is required before messages can be queued."

    private let messagingService: any HostMessagingService

    init(messagingService: any HostMessagingService) {
        self.messagingService = messagingService
    }

    static func unconfigured() -> MessageComposerModel {
        MessageComposerModel(messagingService: UnconfiguredHostMessagingService())
    }

    var canSend: Bool {
        UUID(uuidString: destinationText.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() async {
        let trimmedDestination = destinationText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destinationUUID = UUID(uuidString: trimmedDestination), !trimmedMessage.isEmpty else {
            statusMessage = "Enter a valid destination Node ID and a message."
            return
        }

        let correlationID = DataCorrelationID()
        let outgoing = OutgoingMessage(
            id: correlationID.rawValue,
            destination: destinationUUID,
            body: trimmedMessage,
            state: .sending
        )
        outgoingMessages.insert(outgoing, at: 0)

        do {
            try await messagingService.send(
                .text(
                    destination: NodeID(rawValue: destinationUUID),
                    body: trimmedMessage,
                    correlationID: correlationID
                )
            )
            updateMessage(id: correlationID.rawValue, state: .queued)
            messageText = ""
            statusMessage = "Message is safely queued for delivery."
        } catch BeakrMessagingSetupError.notConfigured {
            updateMessage(id: correlationID.rawValue, state: .failed)
            statusMessage = "Complete node enrollment and session setup before sending."
        } catch {
            updateMessage(id: correlationID.rawValue, state: .failed)
            statusMessage = "The message could not be queued. Try again after checking setup and storage."
        }
    }

    private func updateMessage(id: UUID, state: MessageDeliveryState) {
        guard let index = outgoingMessages.firstIndex(where: { $0.id == id }) else { return }
        outgoingMessages[index].state = state
    }
}
