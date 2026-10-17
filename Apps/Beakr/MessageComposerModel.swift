import Foundation
import Observation
import BeakrNetCore
import BeakrNetData
import BeakrNetHost

enum MessageDeliveryState: String, Codable, Equatable, Sendable {
    case sending
    case queued
    case sent
    case delivered
    case failed
}

struct OutgoingMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let destination: UUID
    let body: String
    var state: MessageDeliveryState
    var deliveredAt: Date? = nil
    var openedAt: Date? = nil
    var provenance: OutgoingMessageProvenance? = nil
    var deliveryAttemptCount: Int? = nil
    var lastDeliveryFailure: String? = nil
}

nonisolated struct OutgoingMessageProvenance: Codable, Equatable, Sendable {
    let storageMessageID: UUID
    let correlationID: UUID
    let networkID: UUID
    let profileID: UUID
    let sourceDeviceID: UUID
    let destinationDeviceID: UUID
    let sessionID: UUID
    let envelopeCreatedAt: Date
    let queuedAt: Date
    let authorityID: UUID
    let authorityEndpoint: String
    let localCredentialID: UUID
}

nonisolated protocol OutgoingProvenanceMessagingService: HostMessagingService {
    func sendWithProvenance(_ request: HostMessageRequest) async throws -> OutgoingMessageProvenance
}

nonisolated struct MessageReadReceipt: Codable, Equatable, Sendable {
    let messageID: UUID
    let openedAt: Date
}

nonisolated struct IncomingMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: UUID?
    let body: String
    let receivedAt: Date
    let isRestored: Bool
    let provenance: MessageProvenance?

    init(
        id: UUID,
        source: UUID?,
        body: String,
        receivedAt: Date,
        isRestored: Bool,
        provenance: MessageProvenance?
    ) {
        self.id = id
        self.source = source
        self.body = body
        self.receivedAt = receivedAt
        self.isRestored = isRestored
        self.provenance = provenance
    }

    init(id: UUID, source: UUID?, body: String, receivedAt: Date, isRestored: Bool) {
        self.init(
            id: id,
            source: source,
            body: body,
            receivedAt: receivedAt,
            isRestored: isRestored,
            provenance: nil
        )
    }

    var subject: String {
        body.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "No Subject"
    }

    var preview: String {
        let nonemptyLines = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let remaining = nonemptyLines.dropFirst().joined(separator: " ")
        return remaining.isEmpty ? body : remaining
    }
}

nonisolated struct MessageProvenance: Codable, Equatable, Sendable {
    let storageMessageID: UUID
    let correlationID: UUID
    let networkID: UUID
    let profileID: UUID
    let sourceDeviceID: UUID
    let destinationDeviceID: UUID
    let sessionID: UUID
    let envelopeCreatedAt: Date
    let receivedAt: Date
    let authorityID: UUID
    let authorityEndpoint: String
    let localCredentialID: UUID
}

nonisolated struct MessageProvenanceContext: Equatable, Sendable {
    let profileID: UUID
    let authorityID: UUID
    let authorityEndpoint: String
    let localCredentialID: UUID
}

struct MessageRecipient: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String

    var address: UUID { id }
}

nonisolated struct ContextMailboxMetadata: Codable, Equatable, Sendable {
    var outgoingMessages: [OutgoingMessage]
    var recipients: [MessageRecipient]
    var removedRecipientIDs: Set<UUID>
    var readMessageIDs: Set<UUID>
    var flaggedMessageIDs: Set<UUID>
    var sentReadReceiptIDs: Set<UUID>

    static let empty = ContextMailboxMetadata(
        outgoingMessages: [],
        recipients: [],
        removedRecipientIDs: [],
        readMessageIDs: [],
        flaggedMessageIDs: [],
        sentReadReceiptIDs: []
    )
}

nonisolated enum ContextMailboxMetadataStore {
    private struct Document: Codable {
        static let currentFormatVersion = 1
        let formatVersion: Int
        let metadata: ContextMailboxMetadata
    }

    static func load(from fileURL: URL) throws -> ContextMailboxMetadata {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let document = try decoder.decode(Document.self, from: Data(contentsOf: fileURL))
        guard document.formatVersion == Document.currentFormatVersion else {
            throw ContextMailboxMetadataError.unsupportedFormatVersion(document.formatVersion)
        }
        return document.metadata
    }

    static func save(_ metadata: ContextMailboxMetadata, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(
            formatVersion: Document.currentFormatVersion,
            metadata: metadata
        ))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

nonisolated enum ContextMailboxMetadataError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
}

actor ApplicationMessageInbox {
    private let codec = DataCodec()
    private var continuations: [UUID: AsyncStream<IncomingMessage>.Continuation] = [:]
    private var failureContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
    private var receiptContinuations: [UUID: AsyncStream<MessageReadReceipt>.Continuation] = [:]
    private var knownReceipts: [UUID: MessageReadReceipt] = [:]
    private var dataState: PersistentDataState?
    private var knownMessageIDs: Set<MessageID> = []
    private var provenanceContext: MessageProvenanceContext?

    func updates() -> AsyncStream<IncomingMessage> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<IncomingMessage>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    func persistenceFailures() -> AsyncStream<String> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<String>.makeStream()
        failureContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeFailureContinuation(id) }
        }
        return stream
    }

    func readReceiptUpdates() -> AsyncStream<MessageReadReceipt> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MessageReadReceipt>.makeStream()
        receiptContinuations[id] = continuation
        for receipt in knownReceipts.values { continuation.yield(receipt) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeReceiptContinuation(id) }
        }
        return stream
    }

    func record(_ envelope: BeakrNetEnvelope) async {
        guard let message = try? codec.decode(envelope: envelope),
              message.operation.namespace == "beakr",
              message.operation.name == "text-message" || message.operation.name == "read-receipt" else { return }
        guard !knownMessageIDs.contains(envelope.messageID) else { return }
        guard let dataState else {
            reportPersistenceFailure("A received message could not be saved because mailbox storage is not ready.")
            return
        }
        let receivedAt = Date()
        let provenance = provenanceContext.map {
            MessageProvenance(
                storageMessageID: envelope.messageID.rawValue,
                correlationID: message.correlationID.rawValue,
                networkID: envelope.networkID.rawValue,
                profileID: $0.profileID,
                sourceDeviceID: envelope.sourceNodeID.rawValue,
                destinationDeviceID: envelope.destinationNodeID.rawValue,
                sessionID: envelope.sessionID.rawValue,
                envelopeCreatedAt: envelope.createdAt,
                receivedAt: receivedAt,
                authorityID: $0.authorityID,
                authorityEndpoint: $0.authorityEndpoint,
                localCredentialID: $0.localCredentialID
            )
        }
        do {
            try await dataState.record(StoredDataResult(
                messageID: envelope.messageID,
                idempotencyKey: message.idempotencyKey,
                response: message,
                completedAt: receivedAt,
                applicationMetadata: provenance.flatMap { try? JSONEncoder().encode($0) }
            ))
        } catch {
            reportPersistenceFailure("A received message could not be saved. Check available storage and try again.")
            return
        }
        knownMessageIDs.insert(envelope.messageID)
        process(
            message,
            source: envelope.sourceNodeID.rawValue,
            receivedAt: receivedAt,
            isRestored: false,
            storageMessageID: envelope.messageID,
            provenance: provenance
        )
    }

    func attach(_ dataState: PersistentDataState, context: MessageProvenanceContext) async {
        self.dataState = dataState
        provenanceContext = context
        knownMessageIDs.removeAll()
        knownReceipts.removeAll()
        for result in await dataState.recordedResults() {
            guard let message = result.response,
                  message.operation.namespace == "beakr",
                  knownMessageIDs.insert(result.messageID).inserted else { continue }
            process(
                message,
                source: result.applicationMetadata
                    .flatMap { try? JSONDecoder().decode(MessageProvenance.self, from: $0) }?
                    .sourceDeviceID,
                receivedAt: result.completedAt,
                isRestored: true,
                storageMessageID: result.messageID,
                provenance: result.applicationMetadata.flatMap { try? JSONDecoder().decode(MessageProvenance.self, from: $0) }
            )
        }
    }

    func clearHistory() async throws {
        knownMessageIDs.removeAll()
        knownReceipts.removeAll()
        try await dataState?.clearRecordedResults()
    }

    func delete(correlationID: UUID) async throws {
        guard let dataState else { return }
        guard let result = await dataState.recordedResults().first(where: {
            $0.response?.correlationID.rawValue == correlationID
        }) else { return }
        try await dataState.removeRecordedResult(result.messageID)
        knownMessageIDs.remove(result.messageID)
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func removeFailureContinuation(_ id: UUID) {
        failureContinuations.removeValue(forKey: id)
    }

    private func removeReceiptContinuation(_ id: UUID) {
        receiptContinuations.removeValue(forKey: id)
    }

    private func process(
        _ message: DataMessage,
        source: UUID?,
        receivedAt: Date,
        isRestored: Bool,
        storageMessageID: MessageID,
        provenance: MessageProvenance?
    ) {
        switch message.operation.name {
        case "text-message":
            guard let body = String(data: message.body, encoding: .utf8) else { return }
            let incoming = IncomingMessage(
                id: message.correlationID.rawValue,
                source: source,
                body: body,
                receivedAt: receivedAt,
                isRestored: isRestored,
                provenance: provenance
            )
            for continuation in continuations.values { continuation.yield(incoming) }
        case "read-receipt":
            guard let receipt = try? JSONDecoder().decode(MessageReadReceipt.self, from: message.body) else { return }
            knownReceipts[receipt.messageID] = receipt
            for continuation in receiptContinuations.values { continuation.yield(receipt) }
        default:
            break
        }
    }

    private func reportPersistenceFailure(_ message: String) {
        for continuation in failureContinuations.values { continuation.yield(message) }
    }
}

actor ApplicationDeliveryUpdates {
    private var continuations: [UUID: AsyncStream<(UUID, Date)>.Continuation] = [:]
    private var deliveredCorrelationIDs: [UUID: Date] = [:]

    func updates() -> AsyncStream<(UUID, Date)> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<(UUID, Date)>.makeStream()
        continuations[id] = continuation
        for (correlationID, deliveredAt) in deliveredCorrelationIDs {
            continuation.yield((correlationID, deliveredAt))
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    func recordDelivered(correlationID: UUID, deliveredAt: Date = Date()) {
        deliveredCorrelationIDs[correlationID] = deliveredAt
        for continuation in continuations.values {
            continuation.yield((correlationID, deliveredAt))
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
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
    var destinationID: UUID?
    var messageText = ""
    private(set) var outgoingMessages: [OutgoingMessage] = []
    private(set) var incomingMessages: [IncomingMessage] = []
    private(set) var recipients: [MessageRecipient] = []
    private(set) var statusMessage = "Messages are stored securely and delivered over the active network."
    private(set) var receivedFeedbackSequence = 0
    private(set) var communicationActivitySequence = 0
    private(set) var mailboxPersistenceError: String?

    private var messagingService: any HostMessagingService
    private let inbox: ApplicationMessageInbox?
    private let deliveryUpdates: ApplicationDeliveryUpdates?
    private var mailboxMetadataURL: URL?
    private var removedRecipientIDs: Set<UUID> = []
    private var activeRecipientIDs: Set<UUID> = []
    private(set) var onlineRecipientIDs: Set<UUID> = []
    private(set) var readMessageIDs: Set<UUID> = []
    private(set) var flaggedMessageIDs: Set<UUID> = []
    private var sentReadReceiptIDs: Set<UUID> = []

    init(
        messagingService: any HostMessagingService,
        inbox: ApplicationMessageInbox? = nil,
        deliveryUpdates: ApplicationDeliveryUpdates? = nil,
        mailboxMetadataURL: URL? = nil
    ) {
        self.messagingService = messagingService
        self.inbox = inbox
        self.deliveryUpdates = deliveryUpdates
        attachMailboxMetadata(fileURL: mailboxMetadataURL)
    }

    func attachMailboxMetadata(fileURL: URL?) {
        mailboxMetadataURL = fileURL
        incomingMessages = []
        let metadata: ContextMailboxMetadata
        do {
            metadata = try fileURL.map(ContextMailboxMetadataStore.load) ?? .empty
            mailboxPersistenceError = nil
        } catch {
            metadata = .empty
            mailboxPersistenceError = "Mailbox metadata could not be opened."
        }
        outgoingMessages = metadata.outgoingMessages
        recipients = metadata.recipients
        removedRecipientIDs = metadata.removedRecipientIDs
        readMessageIDs = metadata.readMessageIDs
        flaggedMessageIDs = metadata.flaggedMessageIDs
        sentReadReceiptIDs = metadata.sentReadReceiptIDs
        destinationID = nil
        messageText = ""
    }

    func replaceMessagingService(_ service: any HostMessagingService) {
        messagingService = service
    }

    func observeIncomingMessages() async {
        guard let inbox else { return }
        for await message in await inbox.updates() {
            if !incomingMessages.contains(where: { $0.id == message.id }) {
                incomingMessages.insert(message, at: 0)
                if !message.isRestored {
                    receivedFeedbackSequence += 1
                    communicationActivitySequence += 1
                }
            }
        }
    }

    func observeMailboxPersistenceFailures() async {
        guard let inbox else { return }
        for await message in await inbox.persistenceFailures() {
            mailboxPersistenceError = message
            statusMessage = message
        }
    }

    func observeDeliveryUpdates() async {
        guard let deliveryUpdates else { return }
        for await (correlationID, deliveredAt) in await deliveryUpdates.updates() {
            if updateMessage(id: correlationID, state: .delivered, deliveredAt: deliveredAt) {
                statusMessage = "Message delivered."
                communicationActivitySequence += 1
            }
        }
    }

    func observeReadReceipts() async {
        guard let inbox else { return }
        for await receipt in await inbox.readReceiptUpdates() {
            guard let index = outgoingMessages.firstIndex(where: { $0.id == receipt.messageID }),
                  outgoingMessages[index].openedAt == nil else { continue }
            outgoingMessages[index].openedAt = receipt.openedAt
            if outgoingMessages[index].deliveredAt == nil {
                outgoingMessages[index].deliveredAt = receipt.openedAt
                outgoingMessages[index].state = .delivered
            }
            persistOutgoingMessages()
            statusMessage = "Message opened."
            communicationActivitySequence += 1
        }
    }

    static func unconfigured() -> MessageComposerModel {
        MessageComposerModel(messagingService: UnconfiguredHostMessagingService())
    }

    var canSend: Bool {
        guard let destinationID else { return false }
        return activeRecipientIDs.contains(destinationID) &&
            !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var addressableRecipients: [MessageRecipient] {
        recipients.filter { activeRecipientIDs.contains($0.id) }
    }

    func isAddressable(_ id: UUID) -> Bool {
        activeRecipientIDs.contains(id)
    }

    func outgoingMessages(forKnownNetworkIDs networkIDs: [NetworkID]) -> [OutgoingMessage] {
        let rawNetworkIDs = Set(networkIDs.map(\.rawValue))
        return outgoingMessages.filter { message in
            guard let networkID = message.provenance?.networkID else { return false }
            return rawNetworkIDs.contains(networkID)
        }
    }

    func prepareReply(to sender: UUID) {
        destinationID = activeRecipientIDs.contains(sender) ? sender : nil
        messageText = ""
    }

    func prepareForward(body: String) {
        destinationID = nil
        messageText = "---------- Forwarded message ----------\n\(body)"
    }

    func prepareResend(to destination: UUID, body: String) {
        destinationID = activeRecipientIDs.contains(destination) ? destination : nil
        messageText = body
    }

    func synchronizeRecipients(with members: [NetworkMemberSummary]) {
        activeRecipientIDs = Set(members.map(\.id))
        if let destinationID, !activeRecipientIDs.contains(destinationID) {
            self.destinationID = nil
        }
        var changed = false
        for member in members where !removedRecipientIDs.contains(member.id) {
            if let index = recipients.firstIndex(where: { $0.id == member.id }) {
                if !member.isPlaceholderName, recipients[index].name != member.displayName {
                    recipients[index].name = member.displayName
                    changed = true
                }
            } else {
                recipients.append(MessageRecipient(id: member.id, name: member.displayName))
                changed = true
            }
        }
        if changed { persistRecipients() }
    }

    func synchronizeOnlineRecipients(with ids: Set<UUID>) {
        onlineRecipientIDs = ids
    }

    @discardableResult
    func addRecipient(name: String, addressText: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAddress = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let address = UUID(uuidString: normalizedAddress) else {
            statusMessage = "Enter a friendly name and a valid recipient address."
            return false
        }
        removedRecipientIDs.remove(address)
        if let index = recipients.firstIndex(where: { $0.id == address }) {
            recipients[index].name = trimmedName
        } else {
            recipients.append(MessageRecipient(id: address, name: trimmedName))
        }
        persistRecipients()
        statusMessage = "Recipient saved."
        return true
    }

    func renameRecipient(id: UUID, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = recipients.firstIndex(where: { $0.id == id }) else { return }
        recipients[index].name = name
        persistRecipients()
    }

    func removeRecipient(id: UUID) {
        recipients.removeAll { $0.id == id }
        removedRecipientIDs.insert(id)
        if destinationID == id { destinationID = nil }
        persistRecipients()
    }

    func displayName(for address: UUID) -> String {
        recipients.first(where: { $0.id == address })?.name ?? address.uuidString
    }

    var unreadIncomingCount: Int {
        incomingMessages.lazy.filter { !self.readMessageIDs.contains($0.id) }.count
    }

    func isRead(_ messageID: UUID) -> Bool { readMessageIDs.contains(messageID) }
    func isFlagged(_ messageID: UUID) -> Bool { flaggedMessageIDs.contains(messageID) }

    func setRead(_ isRead: Bool, messageID: UUID) {
        if isRead { readMessageIDs.insert(messageID) }
        else { readMessageIDs.remove(messageID) }
        persistMailboxMetadata()
    }

    func openIncomingMessage(_ message: IncomingMessage) async {
        setRead(true, messageID: message.id)
        guard !sentReadReceiptIDs.contains(message.id), let source = message.source else { return }
        let receipt = MessageReadReceipt(messageID: message.id, openedAt: Date())
        guard let body = try? JSONEncoder().encode(receipt) else { return }
        do {
            try await messagingService.send(HostMessageRequest(
                destination: NodeID(rawValue: source),
                message: DataMessage(
                    kind: .message,
                    operation: DataOperation(namespace: "beakr", name: "read-receipt", version: 1),
                    correlationID: DataCorrelationID(),
                    idempotencyKey: DataIdempotencyKey(),
                    body: body
                )
            ))
            sentReadReceiptIDs.insert(message.id)
            persistMailboxMetadata()
            communicationActivitySequence += 1
        } catch {
            statusMessage = "The opened receipt will be retried when this message is opened again."
        }
    }

    func toggleFlag(messageID: UUID) {
        if flaggedMessageIDs.contains(messageID) { flaggedMessageIDs.remove(messageID) }
        else { flaggedMessageIDs.insert(messageID) }
        persistMailboxMetadata()
    }

    func deleteMessageHistory() async {
        do {
            try await inbox?.clearHistory()
            outgoingMessages.removeAll { $0.state == .sent || $0.state == .delivered || $0.state == .failed }
            persistOutgoingMessages()
            incomingMessages.removeAll()
            readMessageIDs.removeAll()
            flaggedMessageIDs.removeAll()
            persistMailboxMetadata()
            statusMessage = "Message history deleted. Queued messages were preserved."
        } catch {
            statusMessage = "Some stored message history could not be deleted."
        }
    }

    func deleteQueuedMessages() async {
        let queuedIDs = outgoingMessages
            .filter { $0.state == .queued || $0.state == .sending }
            .map(\.id)
        var deletedIDs: Set<UUID> = []
        for id in queuedIDs {
            do {
                try await messagingService.cancel(correlationID: DataCorrelationID(rawValue: id))
                deletedIDs.insert(id)
            } catch {
                continue
            }
        }
        outgoingMessages.removeAll { deletedIDs.contains($0.id) }
        persistOutgoingMessages()
        if deletedIDs.count == queuedIDs.count {
            statusMessage = queuedIDs.isEmpty ? "There are no queued messages to delete." : "Queued messages deleted."
        } else {
            statusMessage = "Some queued messages could not be deleted."
        }
    }

    func deleteIncomingMessage(id: UUID) async {
        do {
            try await inbox?.delete(correlationID: id)
            incomingMessages.removeAll { $0.id == id }
            readMessageIDs.remove(id)
            flaggedMessageIDs.remove(id)
            persistMailboxMetadata()
            statusMessage = "Message deleted."
        } catch {
            statusMessage = "The message could not be deleted."
        }
    }

    func deleteOutgoingMessage(id: UUID) async {
        guard let message = outgoingMessages.first(where: { $0.id == id }) else { return }
        if message.state == .queued || message.state == .sending {
            do {
                try await messagingService.cancel(correlationID: DataCorrelationID(rawValue: id))
            } catch {
                statusMessage = "The queued message could not be cancelled."
                return
            }
        }
        outgoingMessages.removeAll { $0.id == id }
        persistOutgoingMessages()
        statusMessage = "Message deleted."
    }

    func send() async {
        let trimmedMessage = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destinationUUID = destinationID, !trimmedMessage.isEmpty else {
            statusMessage = "Choose a network device and enter a message."
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
        persistOutgoingMessages()

        do {
            let request = HostMessageRequest.text(
                    destination: NodeID(rawValue: destinationUUID),
                    body: trimmedMessage,
                    correlationID: correlationID
            )
            if let provenanceService = messagingService as? any OutgoingProvenanceMessagingService {
                let provenance = try await provenanceService.sendWithProvenance(request)
                if let index = outgoingMessages.firstIndex(where: { $0.id == correlationID.rawValue }) {
                    outgoingMessages[index].provenance = provenance
                    outgoingMessages[index].deliveryAttemptCount = (outgoingMessages[index].deliveryAttemptCount ?? 0) + 1
                }
            } else {
                try await messagingService.send(request)
                if let index = outgoingMessages.firstIndex(where: { $0.id == correlationID.rawValue }) {
                    outgoingMessages[index].deliveryAttemptCount = (outgoingMessages[index].deliveryAttemptCount ?? 0) + 1
                }
            }
            let acceptedState: MessageDeliveryState = onlineRecipientIDs.contains(destinationUUID) ? .sent : .queued
            updateMessage(id: correlationID.rawValue, state: acceptedState)
            messageText = ""
            statusMessage = acceptedState == .sent
                ? "Message sent. Waiting for delivery confirmation."
                : "Recipient is offline. The message will be sent when the device reconnects."
        } catch BeakrMessagingSetupError.notConfigured {
            recordDeliveryFailure(id: correlationID.rawValue, error: "Messaging is not configured.")
            updateMessage(id: correlationID.rawValue, state: .failed)
            statusMessage = "Messaging is not implemented in this build."
        } catch {
            recordDeliveryFailure(id: correlationID.rawValue, error: String(describing: error))
            updateMessage(id: correlationID.rawValue, state: .failed)
            let nsError = error as NSError
            print("[Beakr Delivery] queue admission failed: \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")
            if let runtimeError = error as? ApplicationLANRuntimeError {
                switch runtimeError {
                case .notRunning:
                    statusMessage = "Messaging is not running for the active network. Retry Device Setup."
                case .missingMembershipSnapshot:
                    statusMessage = "The selected device is not in the active network membership. Refresh the network or choose a current device."
                case .missingRevocationSnapshot:
                    statusMessage = "Network trust information is unavailable. Retry Device Setup."
                case .alreadyRunning:
                    statusMessage = "Messaging is already starting. Try again in a moment."
                }
            } else {
                statusMessage = "The message could not be queued. Try again after checking network setup."
            }
        }
    }

    private func recordDeliveryFailure(id: UUID, error: String) {
        guard let index = outgoingMessages.firstIndex(where: { $0.id == id }) else { return }
        outgoingMessages[index].deliveryAttemptCount = (outgoingMessages[index].deliveryAttemptCount ?? 0) + 1
        outgoingMessages[index].lastDeliveryFailure = error
        persistOutgoingMessages()
    }

    @discardableResult
    private func updateMessage(id: UUID, state: MessageDeliveryState, deliveredAt: Date? = nil) -> Bool {
        guard let index = outgoingMessages.firstIndex(where: { $0.id == id }) else { return false }
        guard outgoingMessages[index].state != state ||
                (state == .delivered && outgoingMessages[index].deliveredAt == nil) else { return false }
        guard outgoingMessages[index].state != .delivered || state == .delivered else { return false }
        outgoingMessages[index].state = state
        if state == .delivered {
            outgoingMessages[index].deliveredAt = deliveredAt ?? outgoingMessages[index].deliveredAt ?? Date()
        }
        persistOutgoingMessages()
        return true
    }

    private func persistRecipients() {
        persistMailboxMetadata()
    }

    private func persistMailboxMetadata() {
        guard let mailboxMetadataURL else { return }
        do {
            try ContextMailboxMetadataStore.save(currentMailboxMetadata, to: mailboxMetadataURL)
            mailboxPersistenceError = nil
        } catch {
            mailboxPersistenceError = "Mailbox metadata could not be saved."
            statusMessage = "Mailbox metadata could not be saved. Check available storage."
        }
    }

    private func persistOutgoingMessages() {
        persistMailboxMetadata()
    }

    private var currentMailboxMetadata: ContextMailboxMetadata {
        ContextMailboxMetadata(
            outgoingMessages: outgoingMessages,
            recipients: recipients,
            removedRecipientIDs: removedRecipientIDs,
            readMessageIDs: readMessageIDs,
            flaggedMessageIDs: flaggedMessageIDs,
            sentReadReceiptIDs: sentReadReceiptIDs
        )
    }
}
