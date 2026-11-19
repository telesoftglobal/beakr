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

nonisolated enum MessageFlagColor: String, CaseIterable, Codable, Equatable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray
}

nonisolated struct ContextMailboxMetadata: Codable, Equatable, Sendable {
    var outgoingMessages: [OutgoingMessage]
    var recipients: [MessageRecipient]
    var removedRecipientIDs: Set<UUID>
    var readMessageIDs: Set<UUID>
    var flaggedMessageIDs: Set<UUID>
    var messageFlagColors: [UUID: MessageFlagColor]
    var sentReadReceiptIDs: Set<UUID>
    var trashedMessageIDs: Set<UUID>

    private enum CodingKeys: String, CodingKey {
        case outgoingMessages
        case recipients
        case removedRecipientIDs
        case readMessageIDs
        case flaggedMessageIDs
        case messageFlagColors
        case sentReadReceiptIDs
        case trashedMessageIDs
    }

    init(
        outgoingMessages: [OutgoingMessage],
        recipients: [MessageRecipient],
        removedRecipientIDs: Set<UUID>,
        readMessageIDs: Set<UUID>,
        flaggedMessageIDs: Set<UUID>,
        messageFlagColors: [UUID: MessageFlagColor] = [:],
        sentReadReceiptIDs: Set<UUID>,
        trashedMessageIDs: Set<UUID> = []
    ) {
        self.outgoingMessages = outgoingMessages
        self.recipients = recipients
        self.removedRecipientIDs = removedRecipientIDs
        self.readMessageIDs = readMessageIDs
        self.flaggedMessageIDs = flaggedMessageIDs
        self.messageFlagColors = messageFlagColors
        self.sentReadReceiptIDs = sentReadReceiptIDs
        self.trashedMessageIDs = trashedMessageIDs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outgoingMessages = try container.decode([OutgoingMessage].self, forKey: .outgoingMessages)
        recipients = try container.decode([MessageRecipient].self, forKey: .recipients)
        removedRecipientIDs = try container.decode(Set<UUID>.self, forKey: .removedRecipientIDs)
        readMessageIDs = try container.decode(Set<UUID>.self, forKey: .readMessageIDs)
        flaggedMessageIDs = try container.decode(Set<UUID>.self, forKey: .flaggedMessageIDs)
        messageFlagColors = try container.decodeIfPresent(
            [UUID: MessageFlagColor].self,
            forKey: .messageFlagColors
        ) ?? Dictionary(uniqueKeysWithValues: flaggedMessageIDs.map { ($0, .orange) })
        sentReadReceiptIDs = try container.decode(Set<UUID>.self, forKey: .sentReadReceiptIDs)
        trashedMessageIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .trashedMessageIDs) ?? []
    }

    static let empty = ContextMailboxMetadata(
        outgoingMessages: [],
        recipients: [],
        removedRecipientIDs: [],
        readMessageIDs: [],
        flaggedMessageIDs: [],
        sentReadReceiptIDs: [],
        trashedMessageIDs: []
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
    private var pendingRecords: [MessageID: Task<Bool, Never>] = [:]
    private var attachmentGeneration = UUID()
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

    @discardableResult
    func record(_ envelope: BeakrNetEnvelope) async -> Bool {
        if knownMessageIDs.contains(envelope.messageID) { return true }
        if let pending = pendingRecords[envelope.messageID] { return await pending.value }
        let generation = attachmentGeneration
        let pending = Task { await self.persistAndPublish(envelope, generation: generation) }
        pendingRecords[envelope.messageID] = pending
        let saved = await pending.value
        if attachmentGeneration == generation { pendingRecords.removeValue(forKey: envelope.messageID) }
        return saved
    }

    private func persistAndPublish(_ envelope: BeakrNetEnvelope, generation: UUID) async -> Bool {
        guard attachmentGeneration == generation else { return false }
        guard let message = try? codec.decode(envelope: envelope),
              message.operation.namespace == "beakr",
              message.operation.name == "text-message" || message.operation.name == "read-receipt" else { return false }
        guard !knownMessageIDs.contains(envelope.messageID) else { return true }
        guard let dataState else {
            reportPersistenceFailure("A received message could not be saved because mailbox storage is not ready.")
            return false
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
            return false
        }
        // An old profile's successful write must not publish into a newly attached inbox.
        guard attachmentGeneration == generation else { return true }
        knownMessageIDs.insert(envelope.messageID)
        process(
            message,
            source: envelope.sourceNodeID.rawValue,
            receivedAt: receivedAt,
            isRestored: false,
            storageMessageID: envelope.messageID,
            provenance: provenance
        )
        return true
    }

    func attach(_ dataState: PersistentDataState, context: MessageProvenanceContext) async {
        attachmentGeneration = UUID()
        pendingRecords.removeAll()
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
    private(set) var messageFlagColors: [UUID: MessageFlagColor] = [:]
    private(set) var trashedMessageIDs: Set<UUID> = []
    private var sentReadReceiptIDs: Set<UUID> = []
    private var replyMessage: IncomingMessage?
    var hasReplyContext: Bool { replyMessage != nil }
    private var mailboxGeneration = UUID()

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
        mailboxGeneration = UUID()
        clearReplyContext()
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
        messageFlagColors = metadata.messageFlagColors
        sentReadReceiptIDs = metadata.sentReadReceiptIDs
        trashedMessageIDs = metadata.trashedMessageIDs
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

    func prepareReply(to message: IncomingMessage) {
        replyMessage = message
        destinationID = message.source.flatMap { activeRecipientIDs.contains($0) ? $0 : nil }
        messageText = ""
    }

    func discardDraft() {
        clearReplyContext()
        destinationID = nil
        messageText = ""
    }

    func clearReplyContext() {
        replyMessage = nil
    }

    func prepareForward(body: String) {
        clearReplyContext()
        destinationID = nil
        messageText = "---------- Forwarded message ----------\n\(body)"
    }

    func prepareResend(to destination: UUID, body: String) {
        clearReplyContext()
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
    func flagColor(for messageID: UUID) -> MessageFlagColor? { messageFlagColors[messageID] }

    func setRead(_ isRead: Bool, messageID: UUID) {
        if isRead { readMessageIDs.insert(messageID) }
        else { readMessageIDs.remove(messageID) }
        persistMailboxMetadata()
    }

    func openIncomingMessage(_ message: IncomingMessage) async {
        let generation = mailboxGeneration
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
            guard mailboxGeneration == generation else { return }
            sentReadReceiptIDs.insert(message.id)
            persistMailboxMetadata()
            communicationActivitySequence += 1
        } catch {
            guard mailboxGeneration == generation else { return }
            statusMessage = "The opened receipt will be retried when this message is opened again."
        }
    }

    func toggleFlag(messageID: UUID) {
        setFlag(flaggedMessageIDs.contains(messageID) ? nil : .orange, messageID: messageID)
    }

    func setFlag(_ color: MessageFlagColor?, messageID: UUID) {
        if let color {
            flaggedMessageIDs.insert(messageID)
            messageFlagColors[messageID] = color
        } else {
            flaggedMessageIDs.remove(messageID)
            messageFlagColors.removeValue(forKey: messageID)
        }
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
            messageFlagColors.removeAll()
            trashedMessageIDs.formIntersection(outgoingMessages.map(\.id))
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
        trashedMessageIDs.formUnion(deletedIDs)
        persistMailboxMetadata()
        if deletedIDs.count == queuedIDs.count {
            statusMessage = queuedIDs.isEmpty ? "There are no queued messages to move." : "Queued messages moved to Trash."
        } else {
            statusMessage = "Some queued messages could not be deleted."
        }
    }

    func deleteIncomingMessage(id: UUID) async {
        guard incomingMessages.contains(where: { $0.id == id }) else { return }
        trashedMessageIDs.insert(id)
        persistMailboxMetadata()
        statusMessage = "Message moved to Trash."
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
        trashedMessageIDs.insert(id)
        persistMailboxMetadata()
        statusMessage = "Message moved to Trash."
    }

    func restoreMessage(id: UUID) {
        guard trashedMessageIDs.remove(id) != nil else { return }
        persistMailboxMetadata()
        statusMessage = "Message restored."
    }

    func permanentlyDeleteIncomingMessage(id: UUID) async {
        do {
            try await inbox?.delete(correlationID: id)
            incomingMessages.removeAll { $0.id == id }
            trashedMessageIDs.remove(id)
            readMessageIDs.remove(id)
            flaggedMessageIDs.remove(id)
            messageFlagColors.removeValue(forKey: id)
            persistMailboxMetadata()
            statusMessage = "Message permanently deleted."
        } catch {
            statusMessage = "The message could not be permanently deleted."
        }
    }

    func permanentlyDeleteOutgoingMessage(id: UUID) {
        guard trashedMessageIDs.contains(id) else { return }
        outgoingMessages.removeAll { $0.id == id }
        trashedMessageIDs.remove(id)
        persistMailboxMetadata()
        statusMessage = "Message permanently deleted."
    }

    func send() async {
        let trimmedMessage = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destinationUUID = destinationID, !trimmedMessage.isEmpty else {
            statusMessage = "Choose a network device and enter a message."
            return
        }

        let generation = mailboxGeneration
        let repliedMessage = replyMessage.flatMap { $0.source == destinationUUID ? $0 : nil }
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
                guard mailboxGeneration == generation else { return }
                if let index = outgoingMessages.firstIndex(where: { $0.id == correlationID.rawValue }) {
                    outgoingMessages[index].provenance = provenance
                    outgoingMessages[index].deliveryAttemptCount = (outgoingMessages[index].deliveryAttemptCount ?? 0) + 1
                }
            } else {
                try await messagingService.send(request)
                guard mailboxGeneration == generation else { return }
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
            // Queue admission, not composer presentation or eventual delivery,
            // establishes that the original message has been read.
            if mailboxGeneration == generation, let repliedMessage {
                clearReplyContext()
                await openIncomingMessage(repliedMessage)
            }
        } catch BeakrMessagingSetupError.notConfigured {
            guard mailboxGeneration == generation else { return }
            recordDeliveryFailure(id: correlationID.rawValue, error: "Messaging is not configured.")
            updateMessage(id: correlationID.rawValue, state: .failed)
            statusMessage = "Messaging is not implemented in this build."
        } catch {
            guard mailboxGeneration == generation else { return }
            recordDeliveryFailure(id: correlationID.rawValue, error: String(describing: error))
            updateMessage(id: correlationID.rawValue, state: .failed)
            let nsError = error as NSError
            BeakrDiagnosticLog.emit("queue admission failed: \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)", level: .failure, logger: BeakrDiagnosticLog.delivery)
            if let runtimeError = error as? ApplicationLANRuntimeError {
                switch runtimeError {
                case .notRunning:
                    statusMessage = "Messaging is not running for the active network. Retry Device Setup."
                case .missingMembershipSnapshot:
                    statusMessage = "The selected device is not in the active network membership. Refresh the network or choose a current device."
                case .localMembershipRemoved:
                    statusMessage = "Membership has been revoked for this device. A new invitation is required to rejoin this network."
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
            messageFlagColors: messageFlagColors,
            sentReadReceiptIDs: sentReadReceiptIDs,
            trashedMessageIDs: trashedMessageIDs
        )
    }
}
